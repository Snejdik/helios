#!/bin/bash
# Build and launch the Release Helios app for performance measurements.
# Does not stop/reinstall HeliosDaemon and does not alter Helios preferences.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: perf-prepare-release.sh must run on macOS." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "FAIL: xcodebuild is unavailable. Install/select Xcode first." >&2
  exit 1
fi

APP_PATH=".build/DerivedData/Build/Products/Release/Helios.app"
APP_EXEC="$PWD/$APP_PATH/Contents/MacOS/Helios"

cat <<'TXT'
Helios near-final performance test — Release preparation
======================================================
This will:
- quit only the Helios app (NOT HeliosDaemon)
- build HeliosApp in Release for arm64 into .build/DerivedData
- remove quarantine only from the newly built local Helios.app if needed
- launch that exact Release app
- verify the running executable path

It does NOT reinstall/remove the privileged helper and does NOT change presets.
TXT

echo
echo "Quitting any currently running Helios app..."
killall Helios 2>/dev/null || true
sleep 1

if ! pgrep -x HeliosDaemon >/dev/null 2>&1; then
  echo "WARN: HeliosDaemon is not currently visible. The app can still build, but verify helper status in Helios before measuring." >&2
fi

echo
echo "Building Release..."
xcodebuild \
  -project Helios.xcodeproj \
  -scheme HeliosApp \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  build

if [[ ! -x "$APP_PATH/Contents/MacOS/Helios" ]]; then
  echo "FAIL: Release executable was not produced at: $APP_PATH/Contents/MacOS/Helios" >&2
  exit 2
fi

# A source ZIP downloaded from the browser may carry quarantine recursively.
# Clear it only on this freshly built development app; never disable Gatekeeper globally.
if xattr -p com.apple.quarantine "$APP_PATH" >/dev/null 2>&1; then
  echo "Clearing quarantine from the freshly built local Release app..."
  xattr -dr com.apple.quarantine "$APP_PATH"
fi

echo
echo "Launching Release Helios..."
open "$APP_PATH"

PID=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  PID="$(pgrep -x Helios | head -1 || true)"
  [[ -n "$PID" ]] && break
  sleep 1
done
if [[ -z "$PID" ]]; then
  echo "FAIL: Helios did not start within 10 seconds." >&2
  exit 2
fi

RUNNING="$(ps -p "$PID" -o command= 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
if [[ "$RUNNING" != "$APP_EXEC" ]]; then
    echo "FAIL: the running Helios is not the expected Release build." >&2
    echo "PID: $PID" >&2
    echo "Running: $RUNNING" >&2
    echo "Expected executable: $APP_EXEC" >&2
    exit 2
fi

echo
echo "PASS Release Helios is running."
echo "PID: $PID"
echo "Executable: $RUNNING"
echo
echo "Next: verify Helios works normally and helper is connected, then run:"
echo "  ./scripts/perf-final-core-suite.sh 90"
