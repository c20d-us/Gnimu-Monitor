#!/bin/sh
# Build Gnimu Monitor for iOS in Release and install it on paired iPhones and iPads.
#
#   scripts/install-ios.sh                 every paired physical iPhone/iPad
#   scripts/install-ios.sh iPhone          only devices whose name contains "iPhone"
#   scripts/install-ios.sh "CLH iPad Pro"  a name, or a device identifier/UDID
#
# Devices must be unlocked and reachable by USB or Wi-Fi. List what the script
# can see with: xcrun devicectl list devices
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="Gnimu Monitor"
BUILD_DIR="$ROOT/build/ios"
DEVICE_JSON=$(mktemp)
trap 'rm -f "$DEVICE_JSON"' EXIT

# Pick the targets first, so a typo fails before a long build.
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1

# One "identifier<TAB>name" line per matching physical, paired iOS/iPadOS device.
TARGETS=$(python3 -I - "$DEVICE_JSON" "$@" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = [w.lower() for w in sys.argv[2:]]
for d in devices:
    props = d.get("properties", {})
    hw = props.get("hardware", {})
    if hw.get("platform") != "iOS" or hw.get("reality") != "physical":
        continue
    if props.get("connection", {}).get("pairingState") != "paired":
        continue
    name = d.get("deviceProperties", {}).get("name", d["identifier"])
    udid = hw.get("udid", "")
    keys = [name.lower(), d["identifier"].lower(), udid.lower()]
    if wanted and not any(w in k for w in wanted for k in keys):
        continue
    print(f'{d["identifier"]}\t{name}')
PY
)

if [ -z "$TARGETS" ]; then
  echo "No paired iPhone or iPad matched. See: xcrun devicectl list devices" >&2
  exit 1
fi

echo "Targets:"
echo "$TARGETS" | cut -f2 | sed 's/^/  /'

echo "Building $APP_NAME for iOS (Release)..."
xcodebuild \
  -project "$ROOT/GnimuMonitor/GnimuMonitor.xcodeproj" \
  -scheme GnimuMonitor \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  -allowProvisioningUpdates \
  -quiet \
  build

BUILT="$BUILD_DIR/Build/Products/Release-iphoneos/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "Build finished but $BUILT is missing" >&2; exit 1; }

BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$BUILT/Info.plist")
FAILED=0
# tab-separated, read from a here-doc so the loop stays in this shell
while IFS="$(printf '\t')" read -r ID NAME; do
  echo "Installing build $BUILD_NUMBER on ${NAME}..."
  # The first connection after the devices have been idle often gets reset;
  # a second attempt normally succeeds, so try once more before giving up.
  if ! xcrun devicectl device install app --device "$ID" "$BUILT" >/dev/null &&
     { echo "  connection failed, retrying..." >&2; sleep 2
       ! xcrun devicectl device install app --device "$ID" "$BUILT" >/dev/null; }; then
    echo "  failed on $NAME (is it unlocked and connected?)" >&2
    FAILED=1
  fi
done <<TARGETS_EOF
$TARGETS
TARGETS_EOF

[ "$FAILED" -eq 0 ] && echo "Done." || { echo "Finished with failures." >&2; exit 1; }
