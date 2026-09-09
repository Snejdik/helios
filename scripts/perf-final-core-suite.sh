#!/bin/bash
# Near-final performance validation. Clean relaunch between presets removes retained UI state.
set -euo pipefail
cd "$(dirname "$0")/.."
duration="${1:-90}"
release_app="$PWD/.build/DerivedData/Build/Products/Release/Helios.app"
release_exe="$release_app/Contents/MacOS/Helios"

if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -lt 30 ]; then
  echo "Usage: $0 [seconds-per-capture >= 30]" >&2; exit 2
fi
if [ ! -x "$release_exe" ]; then
  echo "FAIL Release Helios not found at: $release_exe" >&2
  echo "Run ./scripts/perf-prepare-release.sh first." >&2; exit 1
fi

cat <<TXT
Helios Apple-Silicon RC1 near-final performance suite
====================================================
Each capture runs for ${duration}s.
After you configure a preset and press Enter, the script clean-relaunches the same Release app,
waits 25s for helper reconnect/warm-up, then measures with all Helios UI closed.
Keep power source, brightness and Cooling -> System unchanged.
TXT

clean_relaunch() {
  killall Helios 2>/dev/null || true
  sleep 2
  open "$release_app"
  local ok=0
  for _ in $(seq 1 30); do
    if pgrep -f "$release_exe" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  [ "$ok" -eq 1 ] || { echo 'FAIL expected Release Helios did not relaunch' >&2; pgrep -fl Helios || true; exit 1; }
  sleep 25
}

run_case() {
  local name="$1" text="$2"
  echo '------------------------------------------------------------'
  echo "$text"
  echo 'Configure Helios, then CLOSE Settings/Dashboard/Full Monitor/Energy Inspector/all popovers.'
  read -r -p 'Press Enter when ready... ' _
  echo 'Clean-relaunching Release Helios; do not open Helios UI during the capture...'
  clean_relaunch
  ./scripts/perf-baseline.sh "$name" "$duration"
}

run_case 'RC1-SIMPLE' 'RC1-SIMPLE — Select preset Simple. Cooling -> System. No manual collector changes.'
run_case 'RC1-RECOMMENDED' 'RC1-RECOMMENDED — Select preset Recommended. Cooling -> System. No manual collector changes.'
run_case 'RC1-DETAILED' 'RC1-DETAILED — Select preset Detailed. Cooling -> System. No manual collector changes.'

echo
printf '%s\n' 'PASS RC1 near-final performance captures complete. Zip perf-baseline and upload it for analysis.'
