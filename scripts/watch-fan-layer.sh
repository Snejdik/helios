#!/usr/bin/env bash
# Records what the fans, the temperatures and the Helios helper do, for the
# cool-only fan layer. Read-only: SMC reads and the helper's log; it never
# talks to Helios or the helper and never writes to a fan.
#
#   bash scripts/watch-fan-layer.sh [minutes=10] [interval-seconds=1]
#
# Run it next to Helios while you use System / Manual / Auto / Boost. Ctrl-C
# ends early (the report is still written). Output in .build/monitor/:
#   fan-layer-<time>.csv   one row per sample (Ftst, mode/target/actual per fan, hottest SoC °C)
#   fan-layer-<time>.log   the helper's log for the same period (every fan write and result)
#   fan-layer-<time>.txt   summary to hand to an assistant
set -uo pipefail
cd "$(dirname "$0")/.."

minutes="${1:-10}"
interval="${2:-1}"
case "$minutes$interval" in *[!0-9]*|'') echo "Usage: $0 [minutes] [interval-seconds]" >&2; exit 2 ;; esac
[ "$interval" -ge 1 ] || { echo "Interval must be at least 1 second." >&2; exit 2; }

OUT=".build/monitor"
TOOL=".build/Tools/FanLayerWatch"
mkdir -p "$OUT" .build/Tools .build/Checks/ModuleCache
stamp="$(date +%Y%m%d-%H%M%S)"
csv="$OUT/fan-layer-$stamp.csv"
logfile="$OUT/fan-layer-$stamp.log"
report="$OUT/fan-layer-$stamp.txt"

if [ ! -x "$TOOL" ] || [ Tools/FanLayerWatch.swift -nt "$TOOL" ] || [ Sources/Shared/FanLayerProfile.swift -nt "$TOOL" ]; then
  echo "Building the read-only sampler…"
  cp Tools/FanLayerWatch.swift .build/Tools/main.swift # top-level code must be main.swift
  xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
    -module-cache-path .build/Checks/ModuleCache -framework IOKit \
    Sources/Shared/MetricValue.swift Sources/Shared/SMCClient.swift Sources/Shared/FanModels.swift \
    Sources/Shared/FanOwnershipPreflight.swift Sources/Shared/FanLayerProfile.swift Sources/Shared/FanLayerPolicy.swift \
    .build/Tools/main.swift -o "$TOOL" || { echo "Sampler build failed." >&2; exit 1; }
fi

started="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Recording fans and temperatures for $minutes min (every ${interval}s). Ctrl-C ends early."
echo "Data: $csv"
"$TOOL" "$((minutes * 60))" "$interval" "$csv" &
sampler=$!
trap 'kill -INT $sampler 2>/dev/null' INT
wait $sampler
trap - INT
wait $sampler 2>/dev/null

/usr/bin/log show --start "$started" --info --predicate 'subsystem == "com.snejda.Helios.Daemon"' > "$logfile" 2>/dev/null

count() { grep -c -- "$1" "$logfile" 2>/dev/null || true; }
{
  echo "Helios fan layer watch — $started, $minutes min requested, every ${interval}s"
  echo "Mac: $(sysctl -n hw.model) · macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  helper="$(launchctl print system/com.snejda.Helios.Daemon 2>/dev/null | sed -n 's/^[[:space:]]*pid = //p' | head -1)"
  echo "Helper pid: ${helper:-not running}"
  echo
  echo "== Samples (csv) =="
  awk -F, 'NR==1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
    {
      n++; t = $col["max_soc_c"]; f = $col["ftst"]; a = $col["f0_actual"]; g = $col["f0_target"]; m = $col["f0_mode"]
      if (t != "" && t > maxT) maxT = t; if (t != "" && (minT == "" || t < minT)) minT = t
      if (a != "" && a > maxA) maxA = a; if (g != "" && g > maxG) maxG = g
      if (f == 1) owned++
      if (prev == 0 && f == 1) takeovers++
      if (prev == 1 && f == 0) releases++
      if (f != "") prev = f
      if (m == 1) manual++
      last = $0; lastF = f; lastM = m
    }
    END {
      printf "samples %d, fans held by Helios (Ftst=1) in %d samples, takeovers %d, releases %d\n", n, owned, takeovers, releases
      printf "hottest SoC %.1f °C (coolest %.1f), highest fan target %d RPM, highest fan speed %d RPM\n", maxT, minT, maxG, maxA
      printf "last sample: %s\n", last
      if (lastF == 0 && (lastM == 3 || lastM == 0)) print "end state: fans under macOS (Ftst=0, mode " lastM ")"
      else print "end state: NOT under macOS — check the helper log"
    }' "$csv"
  echo
  echo "== Helper log =="
  echo "fan writes: $(count 'Fan layer write')  (Ftst=1: $(grep -c 'key=Ftst bytes=\[01\]' "$logfile" 2>/dev/null || true), F0Md=1: $(grep -c 'key=F0Md bytes=\[01\]' "$logfile" 2>/dev/null || true), target: $(grep -c 'key=F[0-9]Tg' "$logfile" 2>/dev/null || true), releases Ftst=0: $(grep -c 'key=Ftst bytes=\[00\]' "$logfile" 2>/dev/null || true))"
  echo "arbitration retries (SMCResult=0x82): $(count 'SMCResult=0x82')"
  echo "failed requests: $(count 'Fan request failed')   macOS took the fans back: $(count 'reclaimed the fans')"
  echo "sessions disarmed: $(count 'Session disarmed')   recovery runs: $(count 'recovered to System')   faults: $(grep -cE ' Fault |could not be confirmed' "$logfile" 2>/dev/null || true)"
  echo
  echo "Last helper messages:"
  grep -vE 'Heartbeat|^Timestamp|^Filtering' "$logfile" | sed -E 's/^[0-9-]+ ([0-9:.]+)[^ ]* +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/\1 /' | tail -25
} > "$report"

cat "$report"
echo
echo "Report: $report"
