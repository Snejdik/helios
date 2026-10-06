#!/usr/bin/env bash
# Opens the signed Helios 0.2 build for a manual test run.
# Run by the owner, or by an assistant the owner has allowed to (never any fan write).
#
#   bash scripts/run-helios.sh            open the already built app
#   bash scripts/run-helios.sh --build    build it first (signed Release), then open
#   bash scripts/run-helios.sh --dry-run  run the checks, do not open
#   bash scripts/run-helios.sh --build --watch   build, open, then measure for 10 minutes
#   bash scripts/run-helios.sh --replace ...     quit the running Helios first (graceful, so
#                                                the fans return to System), then continue
#
# Env: HELIOS_APP=<path to Helios.app>   HELIOS_PROC=<process name, default Helios>
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${HELIOS_APP:-.build/DerivedData-0.2-rc/Build/Products/Release/Helios.app}"
PROC="${HELIOS_PROC:-Helios}"
build=0 dry=0 watch=0 replace=0
for arg in "$@"; do
  case "$arg" in
    --build) build=1 ;;
    --dry-run) dry=1 ;;
    --watch) watch=1 ;;
    --replace) replace=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$build" -eq 1 ]; then
  echo "Building signed Release (a couple of minutes)…"
  xcodebuild -project Helios.xcodeproj -scheme HeliosApp -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData-0.2-rc \
    -disableAutomaticPackageResolution build -quiet
fi

[ -d "$APP" ] || { echo "Not built yet: $APP" >&2; echo "Run: bash scripts/run-helios.sh --build" >&2; exit 1; }

codesign --verify --deep --strict "$APP" 2>/dev/null \
  || { echo "The app's signature is invalid. Rebuild: bash scripts/run-helios.sh --build" >&2; exit 1; }
team="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
helper_team="$(codesign -dv "$APP/Contents/Library/HelperTools/HeliosDaemon" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ -n "$team" ] && [ "$team" = "$helper_team" ] \
  || { echo "App and helper are not signed by the same team ('$team' vs '$helper_team')." >&2; exit 1; }
version="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist") build $(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"

# Never run two copies: the old one must quit first so cooling returns to System.
if [ "$replace" -eq 1 ] && [ "$dry" -eq 0 ] && pgrep -x "$PROC" >/dev/null; then
  echo "Quitting the running $PROC gracefully…"
  osascript -e "tell application \"$PROC\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -x "$PROC" >/dev/null || break; sleep 1; done
  pgrep -x "$PROC" >/dev/null && { echo "$PROC did not quit within 30 s; quit it by hand (menu bar icon → Quit)." >&2; exit 1; }
  sleep 2
fi
if running="$(pgrep -x "$PROC")"; then
  echo "Helios is already running (pid $(echo "$running" | tr '\n' ' '))." >&2
  echo "Quit it first: menu bar icon → Quit (or ⌘Q), then run this again." >&2
  exit 1
fi

echo "Helios $version, signed by team $team."
if [ "$dry" -eq 1 ]; then echo "Dry run: not opening."; exit 0; fi
open "$APP"
if [ "$watch" -eq 1 ]; then
  echo "Opened. Measuring for 10 minutes: click through the app, leave the window closed for a while."
  exec bash scripts/watch-helios.sh 10
fi
echo "Opened. To measure it, run:"
echo "  bash scripts/watch-helios.sh 10"
