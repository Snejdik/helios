#!/bin/bash
# Guided high-signal initial suite: daemon-only + Recommended/Simple/Detailed idle.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION="${1:-300}"
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || (( DURATION < 30 )); then
  echo "Usage: ./scripts/perf-suite.sh [duration_seconds>=30]" >&2
  exit 64
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: perf-suite.sh must run on macOS." >&2
  exit 1
fi

cat <<EOF
Helios RC8 initial performance suite
====================================
Each scenario runs for ${DURATION}s.

Keep these conditions unchanged across A/B/C:
- same power source and display brightness
- no Xcode build / browser benchmark / large copy in the background
- fan mode: System
- close Dashboard, Full Monitor, Energy Inspector and metric popovers
- after changing a preset, wait ~15 seconds before pressing Enter

The suite never changes Helios settings itself.
EOF

run_step() {
  local scenario="$1"
  local instruction="$2"
  echo
  echo "------------------------------------------------------------"
  echo "$instruction"
  read -r -p "Press Enter when ready (or Ctrl-C to stop)... " _
  ./scripts/perf-baseline.sh "$scenario" "$DURATION"
}

run_step 0 "SCENARIO 0 — Quit the Helios app completely. Leave the installed HeliosDaemon running."
run_step A "SCENARIO A — Launch Helios, choose Recommended preset, fan mode System, then close every Helios window/popover."
run_step B "SCENARIO B — Choose Simple preset, fan mode System, keep every Helios window/popover closed."
run_step C "SCENARIO C — Choose Detailed preset, fan mode System, keep every Helios window/popover closed."

echo
python3 - <<'PY'
from pathlib import Path
runs = sorted(Path('perf-baseline').glob('*-*'))[-4:]
out = Path('perf-baseline/INITIAL-SUITE.md')
lines = ['# Helios initial performance suite', '']
for run in runs:
    report = run / 'REPORT.md'
    lines += [f'## {run.name}', '']
    if report.exists():
        text = report.read_text()
        # Keep the process and persistence sections in the suite roll-up; raw
        # powermetrics details stay in each run directory.
        start = text.find('## Process sampling')
        end = text.find('## powermetrics')
        lines.append(text[start:end].strip() if start >= 0 and end > start else 'See run report.')
    else:
        lines.append('Missing run report.')
    lines.append('')
out.write_text('\n'.join(lines))
print(out.read_text())
PY

echo
echo "PASS initial performance suite complete: perf-baseline/INITIAL-SUITE.md"
