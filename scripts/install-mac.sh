#!/bin/sh
# Build Gnimu Monitor for macOS in Release and install it in /Applications.
#
#   scripts/install-mac.sh
#
# Set DEST to install somewhere else (DEST=~/Applications scripts/install-mac.sh).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="Gnimu Monitor"
DEST=${DEST:-/Applications}
BUILD_DIR="$ROOT/build/mac"

echo "Building $APP_NAME (Release)..."
xcodebuild \
  -project "$ROOT/GnimuMonitor/GnimuMonitor.xcodeproj" \
  -scheme GnimuMonitor \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  -quiet \
  build

BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "Build finished but $BUILT is missing" >&2; exit 1; }

# Replacing an app that is running leaves the old copy in memory, so ask it to quit first.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quitting the running ${APP_NAME}..."
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "$APP_NAME is still running; quit it and run this again." >&2
    exit 1
  fi
fi

echo "Installing to ${DEST}..."
rm -rf "$DEST/$APP_NAME.app"
ditto "$BUILT" "$DEST/$APP_NAME.app"

BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$DEST/$APP_NAME.app/Contents/Info.plist")
echo "Installed $APP_NAME build $BUILD_NUMBER at $DEST/$APP_NAME.app"
