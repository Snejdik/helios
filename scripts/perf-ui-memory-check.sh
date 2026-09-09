#!/bin/bash
# Manual memory-recovery smoke test for closed SwiftUI/AppKit presentation trees.
# RC3 isolates the three reconstructible UI groups and then performs the same
# repeated stress used by RC1/RC2. Measures RSS + vmmap Physical footprint.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."
cycles="${1:-3}"
if ! [[ "$cycles" =~ ^[0-9]+$ ]] || [ "$cycles" -lt 3 ] || [ "$cycles" -gt 10 ]; then
  echo "Usage: $0 [cycles: 3-10]" >&2
  exit 2
fi
release_exe="$PWD/.build/DerivedData/Build/Products/Release/Helios.app/Contents/MacOS/Helios"

pid="$(pgrep -f "$release_exe" | head -1 || true)"
if [ -z "$pid" ]; then
  echo 'FAIL expected Release Helios is not running. Run ./scripts/perf-prepare-release.sh first.' >&2
  exit 1
fi

running="$(ps -p "$pid" -o command= | sed 's/^[[:space:]]*//')"
if [ "$running" != "$release_exe" ]; then
  echo "FAIL running process is not this repository's exact Release executable" >&2
  exit 1
fi
run_dir=".build/Perf/ui-memory-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_dir"
printf 'stage|rss_mib|physical_mib\n' > "$run_dir/measurements.csv"

rss_mib() {
  ps -p "$pid" -o rss= | awk '{printf "%.2f", $1/1024}'
}

capture_vmmap() {
  local output="$1"
  vmmap -summary "$pid" > "$output"
}

physical_mib() {
  python3 - "$1" <<'PY'
import re, sys
text=open(sys.argv[1], encoding='utf-8', errors='replace').read()
m=re.search(r'^Physical footprint:\s+([0-9.]+)([KMG])$', text, re.M)
if not m:
    raise SystemExit('unable to parse vmmap Physical footprint')
value=float(m.group(1)); unit=m.group(2)
scale={'K':1/1024, 'M':1, 'G':1024}[unit]
print(f'{value*scale:.2f}')
PY
}

mkdir -p .build/Perf

measure() {
  local label="$1"
  local slug="$2"
  local map="$run_dir/${slug}-vmmap.txt"
  capture_vmmap "$map"
  local rss phys
  rss="$(rss_mib)"
  phys="$(physical_mib "$map")"
  printf '%s|%s|%s\n' "$label" "$rss" "$phys" | tee -a "$run_dir/measurements.csv"
}

baseline="$(measure Baseline baseline)"
base_rss="$(printf '%s' "$baseline" | cut -d'|' -f2)"
base_phys="$(printf '%s' "$baseline" | cut -d'|' -f3)"
printf 'Baseline RSS: %s MiB\n' "$base_rss"
printf 'Baseline physical footprint: %s MiB\n' "$base_phys"

stage() {
  local title="$1" slug="$2" instructions="$3"
  printf '\n%s\n%s\n' "$title" "$instructions"
  printf 'Close that Helios UI completely, then press Enter here... '
  read -r _
  echo 'Waiting 15s for AppKit/SwiftUI/autorelease cleanup...'
  sleep 15
  if ! kill -0 "$pid" 2>/dev/null; then
    echo 'FAIL Release Helios exited during the UI memory test.' >&2
    exit 1
  fi
  local row rss phys
  row="$(measure "$title" "$slug")"
  rss="$(printf '%s' "$row" | cut -d'|' -f2)"
  phys="$(printf '%s' "$row" | cut -d'|' -f3)"
  python3 - "$title" "$base_rss" "$rss" "$base_phys" "$phys" <<'PY'
import sys
label=sys.argv[1]
br, ar, bp, ap = map(float, sys.argv[2:])
print(f'{label} RSS: {ar:.2f} MiB ({ar-br:+.2f} MiB vs baseline)')
print(f'{label} physical: {ap:.2f} MiB ({ap-bp:+.2f} MiB vs baseline)')
PY
}

stage 'After Full Monitor' full-monitor 'Open Full Monitor, visit Overview, Storage, Processes and Expert once.'
stage 'After Energy Inspector' energy 'Open Energy Inspector and switch 1h -> 6h -> 24h once.'
stage 'After popovers' popovers 'Open/close the Helios Dashboard and 3 metric popovers once.'

for ((cycle=1; cycle<=cycles; cycle++)); do
  stage "After repeated cycle $cycle" "cycle-$cycle" \
    'Full Monitor: Overview -> Storage -> Processes -> Expert; Energy Inspector: 1h -> 6h -> 24h; Dashboard + 3 metric popovers. Close every surface.'
done
echo 'Waiting 45s for final cleanup...'
sleep 45

if ! kill -0 "$pid" 2>/dev/null; then
  echo 'FAIL Release Helios exited during the UI memory test.' >&2
  exit 1
fi

after="$(measure Final final)"
after_rss="$(printf '%s' "$after" | cut -d'|' -f2)"
after_phys="$(printf '%s' "$after" | cut -d'|' -f3)"
python3 - "$base_rss" "$after_rss" "$base_phys" "$after_phys" <<'PY'
import sys
br, ar, bp, ap = map(float, sys.argv[1:])
print(f'Final after-close RSS: {ar:.2f} MiB')
print(f'Delta RSS vs baseline: {ar-br:+.2f} MiB')
print(f'Final after-close physical footprint: {ap:.2f} MiB')
print(f'Delta physical footprint vs baseline: {ap-bp:+.2f} MiB')
print('Assess the per-cycle physical-footprint trend; one final delta alone cannot prove a plateau.')
PY
printf 'Measurements and vmmap summaries: %s\n' "$run_dir"
