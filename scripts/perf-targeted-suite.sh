#!/bin/bash
# Guided Release targeted suite that isolates the cost of GPU, Network,
# Processes & Energy, and Storage relative to the Simple baseline.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${1:-90}"
STABILIZE="${PERF_STABILIZE_SECONDS:-15}"

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || (( DURATION < 30 )); then
  echo "Usage: ./scripts/perf-targeted-suite.sh [duration_seconds>=30]" >&2
  exit 64
fi
if ! [[ "$STABILIZE" =~ ^[0-9]+$ ]] || (( STABILIZE < 0 )); then
  echo "FAIL: PERF_STABILIZE_SECONDS must be an integer >= 0." >&2
  exit 64
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: perf-targeted-suite.sh must run on macOS." >&2
  exit 1
fi

verify_release_app() {
  local pids pid count command
  pids="$(pgrep -x Helios || true)"
  count="$(printf '%s\n' "$pids" | awk 'NF {n++} END {print n+0}')"
  if [[ "$count" -ne 1 ]]; then
    echo "FAIL: exactly one Helios app process must be running; found $count." >&2
    pgrep -fl Helios || true
    exit 2
  fi
  pid="$(printf '%s\n' "$pids" | awk 'NF {print; exit}')"
  command="$(ps -p "$pid" -o command= 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
  case "$command" in
    *"/Build/Products/Release/Helios.app/Contents/MacOS/Helios"*) ;;
    *)
      echo "FAIL: targeted suite requires the Release app, but this is running:" >&2
      echo "  $command" >&2
      echo "Run ./scripts/perf-prepare-release.sh first." >&2
      exit 2
      ;;
  esac
}

verify_release_app

cat <<EOINTRO
Helios RC8 targeted Release performance suite
==============================================
Each capture runs for ${DURATION}s. After you press Enter, the script itself waits
${STABILIZE}s before measuring, so you do NOT need to time the settling period.

IMPORTANT terminology:
- "System" below means Cooling -> fan control mode -> System.
- It does NOT mean the "System Power" collector.
- In the Simple baseline, System Power stays ON exactly as the Simple preset sets it.
- Turning one extra collector ON will change the preset label to Custom. That is EXPECTED.

Keep constant for every run:
- same Mac / same Release build
- same power source and display brightness
- Cooling fan mode = System
- no Xcode build, benchmark, large copy, or other heavy workload
- close Settings, Dashboard, Full Monitor, Energy Inspector and every Helios popover before pressing Enter

The suite does not modify Helios settings itself.
EOINTRO

declare -a RUN_DIRS=()

run_step() {
  local scenario="$1"
  local instruction="$2"
  local latest
  echo
  echo "------------------------------------------------------------"
  echo "$instruction"
  echo
  read -r -p "Configure Helios exactly as above, CLOSE all Helios windows/popovers, then press Enter... " _
  verify_release_app
  if (( STABILIZE > 0 )); then
    echo "Settling for ${STABILIZE}s..."
    sleep "$STABILIZE"
  fi
  ./scripts/perf-baseline.sh "$scenario" "$DURATION"
  latest="$(find perf-baseline -mindepth 1 -maxdepth 1 -type d -name "*-${scenario}" 2>/dev/null | sort | tail -1 || true)"
  if [[ -z "$latest" ]]; then
    echo "FAIL: could not identify output directory for $scenario." >&2
    exit 3
  fi
  RUN_DIRS+=("$latest")
}

run_step "R-SIMPLE" "R-SIMPLE — Select preset Simple. Do not manually change any collector. Cooling -> System."
run_step "R-GPU" "R-GPU — Select Simple AGAIN, then turn ON only GPU. Preset becoming Custom is correct. Leave Network, Wi-Fi, Processes & Energy, Storage, Devices & peripherals OFF."
run_step "R-NETWORK" "R-NETWORK — Select Simple AGAIN, then turn ON only Network. Preset becoming Custom is correct. GPU, Wi-Fi, Processes & Energy, Storage, Devices & peripherals stay OFF."
run_step "R-PROCESSES" "R-PROCESSES — Select Simple AGAIN, then turn ON only Processes & Energy. Preset becoming Custom is correct. GPU, Network, Wi-Fi, Storage, Devices & peripherals stay OFF."
run_step "R-STORAGE" "R-STORAGE — Select Simple AGAIN, then turn ON only Storage. Preset becoming Custom is correct. GPU, Network, Wi-Fi, Processes & Energy, Devices & peripherals stay OFF."
run_step "R-RECOMMENDED" "R-RECOMMENDED — Select preset Recommended. Do not manually change collectors. Cooling -> System."

SIMPLE="${RUN_DIRS[0]}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
SUMMARY="perf-baseline/TARGETED-SUITE-${STAMP}.md"
{
  echo "# Helios targeted Release performance suite"
  echo
  echo "Simple reference: \`$SIMPLE\`"
  echo
  echo "| Scenario | Run directory |"
  echo "|---|---|"
  for i in 0 1 2 3 4 5; do
    scenario="$(basename "${RUN_DIRS[$i]}" | sed 's/^[0-9]\{8\}-[0-9]\{6\}-//')"
    echo "| $scenario | \`${RUN_DIRS[$i]}\` |"
  done
  echo
  echo "## Comparisons versus R-SIMPLE"
  echo
} > "$SUMMARY"

for i in 1 2 3 4 5; do
  ./scripts/perf-compare.py "$SIMPLE" "${RUN_DIRS[$i]}" > /dev/null
  COMPARE_FILE="${RUN_DIRS[$i]}/COMPARE-vs-$(basename "$SIMPLE").md"
  {
    echo "### $(basename "${RUN_DIRS[$i]}" | sed 's/^[0-9]\{8\}-[0-9]\{6\}-//')"
    echo
    if [[ -f "$COMPARE_FILE" ]]; then
      python3 - "$COMPARE_FILE" <<'PYROLLUP'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace")
start = text.find("## CPU / memory")
end = text.find("## Common powermetrics scalar keys")
print(text[start:end].strip() if start >= 0 and end > start else text.strip())
PYROLLUP
    else
      echo "Comparison file missing."
    fi
    echo
  } >> "$SUMMARY"
done

echo
cat "$SUMMARY"
echo
echo "PASS targeted Release suite complete: $SUMMARY"
echo "Upload the whole perf-baseline folder (ZIP) for analysis."
