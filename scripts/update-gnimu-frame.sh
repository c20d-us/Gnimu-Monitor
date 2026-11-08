#!/usr/bin/env bash
# Gnimu Monitor
# Copyright (C) 2026 Chris Halstead
# SPDX-License-Identifier: GPL-3.0-or-later

# Usage: scripts/update-gnimu-frame.sh [path to the Gnimu-protocol checkout]
#
# Copies the Swift reference decoder for the Gnimu frame, and its test vectors,
# out of the Gnimu-protocol repo into the app and its tests, stamping each copy
# with the protocol revision it came from. Don't edit the copies by hand: change
# the protocol repo, commit it, and run this again. Refuses to copy from a
# checkout with uncommitted changes, so the stamp is always true.
set -euo pipefail
cd "$(dirname "$0")/.."

protocol="${1:-../Gnimu-protocol}"
[ -d "$protocol/swift/Sources/GnimuFrame" ] || { echo "No Gnimu-protocol checkout at $protocol" >&2; exit 1; }
if [ -n "$(git -C "$protocol" status --porcelain)" ]; then
  echo "$protocol has uncommitted changes; commit them first." >&2
  exit 1
fi
rev="$(git -C "$protocol" rev-parse --short HEAD)"

copy() {
  local from="$1" to="$2"
  mkdir -p "$(dirname "$to")"
  {
    echo "// Copied from Gnimu-protocol $rev (spec v1) by scripts/update-gnimu-frame.sh."
    echo "// Don't edit here: change the protocol repo and copy again."
    cat "$from"
  } > "$to"
}

app="GnimuMonitor/GnimuMonitor/GnimuFrame"
tests="GnimuMonitor/Gnimu MonitorTests/GnimuFrame"
copy "$protocol/swift/Sources/GnimuFrame/FrameV1.swift"  "$app/FrameV1.swift"
copy "$protocol/swift/Sources/GnimuFrame/LayoutV1.swift" "$app/LayoutV1.swift"
copy "$protocol/swift/Tests/GnimuFrameTests/VectorsV1.swift" "$tests/VectorsV1.swift"
echo "Copied Gnimu frame decoder and vectors from Gnimu-protocol $rev."
