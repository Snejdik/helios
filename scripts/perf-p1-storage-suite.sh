#!/bin/bash
# Focused validation for Performance P1b Storage.
# Each case is measured after a clean app relaunch so previously-opened Full
# Monitor/Storage UI cannot contaminate hidden-idle CPU/RSS measurements.
set -euo pipefail
cd "$(dirname "$0")/.."
duration="${1:-90}"
release_app="$PWD/.build/DerivedData/Build/Products/Release/Helios.app"
release_exe="$release_app/Contents/MacOS/Helios"

if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -lt 30 ]; then
  echo "Usage: $0 [seconds-per-capture >= 30]" >&2
  exit 2
fi
if [ ! -x "$release_exe" ]; then
  echo "FAIL Release Helios not found at: $release_exe" >&2
  echo "Run ./scripts/perf-prepare-release.sh first." >&2
  exit 1
fi

printf '%s\n' "Helios Performance P1b Storage validation"
printf '%s\n\n' "Each capture runs for ${duration}s."
printf '%s\n' "IMPORTANT: after you configure each case and press Enter, this script"
printf '%s\n' "will quit and relaunch Helios itself, then wait 25s before measuring."
printf '%s\n' "That intentionally clears retained UI/window state from the measurement."
printf '%s\n\n' "Keep AC/battery source, brightness and Cooling -> System unchanged."

clean_relaunch() {
  killall Helios 2>/dev/null || true
  sleep 2
  open "$release_app"
  local ok=0
  for _ in $(seq 1 30); do
    if pgrep -f "$release_exe" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" -ne 1 ]; then
    echo "FAIL Release Helios did not relaunch from expected path" >&2
    pgrep -fl Helios || true
    exit 1
  fi
  # Allow helper reconnect, collector startup/warm-up and any launch-only work
  # to finish. Do not open any Helios UI during this wait.
  sleep 25
}

run_case() {
  local name="$1"
  local text="$2"
  printf '%s\n' "------------------------------------------------------------"
  printf '%s\n' "$text"
  printf '%s\n' "Use Helios UI now to configure this case. Then CLOSE Settings/Dashboard/Full Monitor/Energy Inspector/popovers."
  read -r -p "Press Enter when configuration is saved and every Helios UI surface is closed... " _
  printf '%s\n' "Clean-relaunching Release Helios; do not open its UI..."
  clean_relaunch
  ./scripts/perf-baseline.sh "$name" "$duration"
}

run_case "P1B-SIMPLE" "P1B-SIMPLE — Select preset Simple. Do not manually change collectors. Cooling -> System."
run_case "P1B-STORAGE" "P1B-STORAGE — Select Simple AGAIN, then turn ON only Storage. Preset becoming Custom is correct."
run_case "P1B-RECOMMENDED" "P1B-RECOMMENDED — Select preset Recommended. Do not manually change collectors. Cooling -> System."

printf '\n%s\n' "PASS P1b Storage validation captures complete."
printf '%s\n' "Zip perf-baseline and upload it for before/after analysis."
