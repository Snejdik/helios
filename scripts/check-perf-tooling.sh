#!/bin/bash
# Portable regression checks for performance tooling only. No app/runtime source changes.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in scripts/perf-baseline.sh scripts/perf-suite.sh scripts/perf-prepare-release.sh scripts/perf-targeted-suite.sh scripts/perf-report.py scripts/perf-compare.py docs/PERFORMANCE_BASELINE.md docs/PERFORMANCE_TARGETED.md; do
  [[ -f "$f" ]] || { echo "FAIL missing $f" >&2; exit 1; }
done
bash -n scripts/perf-baseline.sh
bash -n scripts/perf-suite.sh
bash -n scripts/perf-prepare-release.sh
bash -n scripts/perf-targeted-suite.sh
bash -n scripts/perf-ui-memory-check.sh
bash -n scripts/perf-final-core-suite.sh
python3 -m py_compile scripts/perf-report.py scripts/perf-compare.py

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP-after"' EXIT
cat > "$TMP/metadata.txt" <<'EOF'
scenario=TEST
duration_seconds=60
started_at=2026-09-09T09:45:00+02:00
macos=26.6.2
hardware_model=Mac16,1
power_source=AC Power
powermetrics_samplers=tasks,thermal,smc
source_fingerprint=testfingerprint
EOF
cat > "$TMP/process-samples.tsv" <<'EOF'
timestamp	name	pid	cpu_percent	rss_kib	cpu_time
2026-09-09T09:45:00+02:00	Helios	100	0,2	50000	00:01.00
2026-09-09T09:45:05+02:00	Helios	100	0,4	52000	00:01.02
2026-09-09T09:45:00+02:00	HeliosDaemon	101	0.1	8000	00:00.50
EOF
cat > "$TMP/persistence-before.tsv" <<'EOF'
path	bytes	mtime_ns
/Users/test/Library/Application Support/Helios/history-v1.ndjson	1000	1
EOF
cat > "$TMP/persistence-after.tsv" <<'EOF'
path	bytes	mtime_ns
/Users/test/Library/Application Support/Helios/history-v1.ndjson	1600	2
EOF
python3 - "$TMP/powermetrics.plist" <<'PY'
import copy, plistlib, sys
sample = {
    'tasks': [
        {'name': 'Helios', 'pid': 100, 'cpu_time': 0.2, 'wakeups': 2, 'energy_impact': 0.5, 'disk_writes': 100},
        {'name': 'HeliosDaemon', 'pid': 101, 'cpu_time': 0.1, 'wakeups': 1, 'energy_impact': 0.2},
    ],
    'thermal_pressure': 0,
    'cpu_power_mw': 350.0,
}
with open(sys.argv[1], 'wb') as f:
    f.write(plistlib.dumps(sample))
    f.write(b'\0')
    interval = copy.deepcopy(sample)
    interval['is_delta'] = True
    f.write(plistlib.dumps(interval))
    f.write(b'\0')
    summary = copy.deepcopy(sample)
    summary['is_delta'] = False
    summary['tasks'][0]['wakeups'] = 9999
    summary['cpu_power_mw'] = 9999
    f.write(plistlib.dumps(summary))
    f.write(b'\0')
PY
scripts/perf-report.py "$TMP" --json >/dev/null
grep -Fq '| Helios | 2 | 0.300 |' "$TMP/REPORT.md"
grep -Fq '600 B' "$TMP/REPORT.md"
grep -Fq '`wakeups`' "$TMP/REPORT.md"
grep -Fq '`cpu_power_mw`' "$TMP/REPORT.md"
python3 - "$TMP/powermetrics-helios-records.json" "$TMP/REPORT.md" <<'PYINTERVALS'
import json, pathlib, sys
records = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert len(records['Helios']) == 2
assert [r['wakeups'] for r in records['Helios']] == [2, 2]
assert '| `cpu_power_mw` | 350 | 350 | 350 |' in pathlib.Path(sys.argv[2]).read_text()
PYINTERVALS
cp -R "$TMP" "$TMP-after"
scripts/perf-compare.py "$TMP" "$TMP-after" >/dev/null
grep -Fq 'Avg CPU' "$TMP-after/COMPARE-vs-$(basename "$TMP").md"

printf '%s\n' "PASS performance tooling: shell syntax, parser fixture, persistence delta, powermetrics plist decoding"

# Exercise the actual preparation script's verification branch with paths from
# two different checkouts; a matching Release suffix is not sufficient.
python3 - <<'PYVERIFY'
from pathlib import Path
import os, subprocess
source = Path('scripts/perf-prepare-release.sh').read_text()
start = source.index('if [[ "$RUNNING" != "$APP_EXEC" ]]; then')
end = source.index('\nfi', start) + len('\nfi')
check = source[start:end]
expected = '/repo/current/.build/DerivedData/Build/Products/Release/Helios.app/Contents/MacOS/Helios'
for actual, status in [(expected, 0), (expected.replace('/current/', '/old/'), 2), (expected + ' --other', 2)]:
    result = subprocess.run(['bash', '-c', check], env=dict(os.environ, APP_EXEC=expected, RUNNING=actual, PID='1'), capture_output=True)
    assert result.returncode == status, (actual, result.stderr)
print('PASS Release preparation rejects other checkouts and unexpected launch arguments')
PYVERIFY
