#!/bin/bash
# Measure one Helios performance scenario on the real Mac without changing app runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: ./scripts/perf-baseline.sh SCENARIO [DURATION_SECONDS]

Examples:
  ./scripts/perf-baseline.sh 0 300
  ./scripts/perf-baseline.sh A 300

Scenarios are labels only. The script never changes Helios preferences or fan state.
Use perf-suite.sh for the guided 0/A/B/C sequence.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 64
fi

SCENARIO="$1"
DURATION="${2:-300}"
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || (( DURATION < 30 )); then
  echo "FAIL: duration must be an integer >= 30 seconds" >&2
  exit 64
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FAIL: perf-baseline.sh must run on macOS." >&2
  exit 1
fi
if ! command -v powermetrics >/dev/null 2>&1; then
  echo "FAIL: powermetrics is unavailable." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is unavailable." >&2
  exit 1
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
SAFE_SCENARIO="$(printf '%s' "$SCENARIO" | tr -cs 'A-Za-z0-9._-' '_')"
RUN_DIR="perf-baseline/${STAMP}-${SAFE_SCENARIO}"
mkdir -p "$RUN_DIR"

# Capture an exact SHA-256 manifest and one aggregate fingerprint for Sources/.
# Python keeps this portable across macOS/BSD userland (no GNU sort -z needed).
SOURCE_FINGERPRINT="$(python3 - "$RUN_DIR/source-hashes.sha256" <<'PY'
import hashlib
import sys
from pathlib import Path
out = Path(sys.argv[1])
rows = []
for path in sorted(Path("Sources").rglob("*")):
    if not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    rows.append(f"{digest}  {path.as_posix()}")
out.write_text("\n".join(rows) + "\n")
print(hashlib.sha256(out.read_bytes()).hexdigest())
PY
)"

POWER_SOURCE="unknown"
if command -v pmset >/dev/null 2>&1; then
  POWER_SOURCE="$(pmset -g batt 2>/dev/null | head -1 | sed 's/[[:space:]]\+/ /g' || true)"
fi
MACOS="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
HARDWARE_MODEL="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
STARTED_AT="$(date '+%Y-%m-%dT%H:%M:%S%z')"

POWERMETRICS_HELP="$(powermetrics -h 2>&1 || true)"
printf '%s\n' "$POWERMETRICS_HELP" > "$RUN_DIR/powermetrics-help.txt"

SAMPLERS=(tasks)
for candidate in thermal smc cpu_power gpu_power battery; do
  if printf '%s\n' "$POWERMETRICS_HELP" | grep -Eq "(^|[^[:alnum:]_])${candidate}([^[:alnum:]_]|$)"; then
    SAMPLERS+=("$candidate")
  fi
done
SAMPLER_CSV="$(IFS=,; echo "${SAMPLERS[*]}")"

cat > "$RUN_DIR/metadata.txt" <<EOF
scenario=$SCENARIO
duration_seconds=$DURATION
started_at=$STARTED_AT
macos=$MACOS
hardware_model=$HARDWARE_MODEL
power_source=$POWER_SOURCE
powermetrics_samplers=$SAMPLER_CSV
source_fingerprint=$SOURCE_FINGERPRINT
EOF

snapshot_persistence() {
  local out="$1"
  python3 - "$out" <<'PY'
import csv
import sys
from pathlib import Path
out = Path(sys.argv[1])
base = Path.home() / "Library" / "Application Support" / "Helios"
with out.open("w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t")
    w.writerow(["path", "bytes", "mtime_ns"])
    if base.exists():
        for p in sorted(x for x in base.iterdir() if x.is_file()):
            try:
                st = p.stat()
            except OSError:
                continue
            w.writerow([str(p), st.st_size, st.st_mtime_ns])
PY
}

capture_process_list() {
  {
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "Helios=$(pgrep -x Helios | paste -sd, - || true)"
    echo "HeliosDaemon=$(pgrep -x HeliosDaemon | paste -sd, - || true)"
    ps -axo pid=,ppid=,%cpu=,rss=,time=,comm= | grep -E '/Helios$|/HeliosDaemon$|(^|[[:space:]])Helios$|(^|[[:space:]])HeliosDaemon$' || true
  } > "$1"
}

snapshot_persistence "$RUN_DIR/persistence-before.tsv"
capture_process_list "$RUN_DIR/processes-before.txt"

APP_PID="$(pgrep -x Helios | head -1 || true)"
DAEMON_PID="$(pgrep -x HeliosDaemon | head -1 || true)"
APP_COMMAND=""
APP_BUILD_CONFIGURATION="not-running"
if [[ -n "$APP_PID" ]]; then
  APP_COMMAND="$(ps -p "$APP_PID" -o command= 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
  case "$APP_COMMAND" in
    *"/Build/Products/Release/Helios.app/Contents/MacOS/Helios"*) APP_BUILD_CONFIGURATION="Release" ;;
    *"/Build/Products/Debug/Helios.app/Contents/MacOS/Helios"*) APP_BUILD_CONFIGURATION="Debug" ;;
    *) APP_BUILD_CONFIGURATION="unknown" ;;
  esac
fi
printf 'app_build_configuration=%s\n' "$APP_BUILD_CONFIGURATION" >> "$RUN_DIR/metadata.txt"
printf 'app_command=%s\n' "$APP_COMMAND" >> "$RUN_DIR/metadata.txt"

if [[ "$SCENARIO" == "0" ]]; then
  if [[ -n "$APP_PID" ]]; then
    echo "FAIL: scenario 0 requires the Helios app to be fully quit; PID $APP_PID is still running." >&2
    exit 2
  fi
  if [[ -z "$DAEMON_PID" ]]; then
    echo "FAIL: scenario 0 requires HeliosDaemon to be installed/running." >&2
    exit 2
  fi
else
  if [[ -z "$APP_PID" ]]; then
    echo "FAIL: scenario $SCENARIO requires the Helios app to be running." >&2
    exit 2
  fi
fi

# One privilege prompt up front; do not run the whole harness through sudo or
# HOME/Application Support accounting would point at root.
# A terminal can authorize once up front. Automated runners may authorize each
# concrete read-only command separately; do not block them on a generic sudo -v.
if [[ -t 0 ]]; then
  echo "Authorizing powermetrics (sudo)..."
  sudo -v
fi

printf 'timestamp\tname\tpid\tcpu_percent\trss_kib\tcpu_time\n' > "$RUN_DIR/process-samples.tsv"
(
  END=$(( $(date +%s) + DURATION ))
  while (( $(date +%s) < END )); do
    NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    for NAME in Helios HeliosDaemon; do
      while IFS= read -r PID; do
        [[ -n "$PID" ]] || continue
        ROW="$(LC_ALL=C ps -p "$PID" -o pid=,%cpu=,rss=,time= 2>/dev/null | awk 'NF {print $1"\t"$2"\t"$3"\t"$4}' || true)"
        if [[ -n "$ROW" ]]; then
          printf '%s\t%s\t%s\n' "$NOW" "$NAME" "$ROW"
        fi
      done < <(pgrep -x "$NAME" || true)
    done
    sleep 5
  done
) >> "$RUN_DIR/process-samples.tsv" &
PS_SAMPLER_PID=$!

# Boundary memory snapshots only; not a recurring heavy profiler.
for NAME in Helios HeliosDaemon; do
  PID="$(pgrep -x "$NAME" | head -1 || true)"
  [[ -n "$PID" ]] || continue
  if command -v vmmap >/dev/null 2>&1; then
    if [[ "$NAME" == "HeliosDaemon" ]]; then
      sudo vmmap -summary "$PID" > "$RUN_DIR/vmmap-${NAME}-before.txt" 2>&1 || true
    else
      vmmap -summary "$PID" > "$RUN_DIR/vmmap-${NAME}-before.txt" 2>&1 || true
    fi
  fi
done

SAMPLE_MS=5000
SAMPLE_COUNT=$(( (DURATION + 4) / 5 ))
PM_ARGS=(
  --samplers "$SAMPLER_CSV"
  --show-process-energy
  --show-process-io
  --show-process-samp-norm
  --show-usage-summary
  --order wakeups
  --sample-rate "$SAMPLE_MS"
  --sample-count "$SAMPLE_COUNT"
  --format plist
  --output-file "$RUN_DIR/powermetrics.plist"
)

echo "Measuring scenario $SCENARIO for ${DURATION}s..."
set +e
sudo powermetrics "${PM_ARGS[@]}" 2> "$RUN_DIR/powermetrics-stderr.txt"
PM_STATUS=$?
set -e
wait "$PS_SAMPLER_PID" || true

capture_process_list "$RUN_DIR/processes-after.txt"
snapshot_persistence "$RUN_DIR/persistence-after.tsv"

for NAME in Helios HeliosDaemon; do
  PID="$(pgrep -x "$NAME" | head -1 || true)"
  [[ -n "$PID" ]] || continue
  if command -v vmmap >/dev/null 2>&1; then
    if [[ "$NAME" == "HeliosDaemon" ]]; then
      sudo vmmap -summary "$PID" > "$RUN_DIR/vmmap-${NAME}-after.txt" 2>&1 || true
    else
      vmmap -summary "$PID" > "$RUN_DIR/vmmap-${NAME}-after.txt" 2>&1 || true
    fi
  fi
done

printf 'powermetrics_exit_status=%s\n' "$PM_STATUS" >> "$RUN_DIR/metadata.txt"
./scripts/perf-report.py "$RUN_DIR" --json > "$RUN_DIR/report-console.txt"
cat "$RUN_DIR/REPORT.md"

echo
echo "PASS performance capture complete: $RUN_DIR"
if (( PM_STATUS != 0 )); then
  echo "WARN: powermetrics exited with status $PM_STATUS; process/RSS/persistence data were still captured." >&2
  tail -40 "$RUN_DIR/powermetrics-stderr.txt" >&2 || true
fi
