#!/usr/bin/env bash
# Measures a running Helios and writes a short report you can hand to an assistant.
# Read-only: samples CPU, memory, wakeups and the history files; it never touches
# Helios itself, its helper or any fan control.
#
#   bash scripts/watch-helios.sh [minutes=10] [interval-seconds=10]
#
# Use it while you click through the app; leave the window closed for part of the
# time so the idle cost is visible too. Stop early with Ctrl-C (the report is
# still written). Output: .build/monitor/report-<time>.txt and .csv
#
# Env: HELIOS_PROC=<process name, default Helios>
set -uo pipefail
cd "$(dirname "$0")/.."

PROC="${HELIOS_PROC:-Helios}"
minutes="${1:-10}"
interval="${2:-10}"
case "$minutes$interval" in *[!0-9]*|'') echo "Usage: $0 [minutes] [interval-seconds]" >&2; exit 2 ;; esac
[ "$interval" -ge 2 ] || { echo "Interval must be at least 2 seconds." >&2; exit 2; }

DATA="$HOME/Library/Application Support/Helios"
OUT=".build/monitor"
mkdir -p "$OUT"
stamp="$(date +%Y%m%d-%H%M%S)"
csv="$OUT/report-$stamp.csv"
report="$OUT/report-$stamp.txt"

echo "Waiting for $PROC to start (up to 2 minutes)…"
pid=""
for _ in $(seq 1 120); do
  pid="$(pgrep -x "$PROC" | head -1)"
  [ -n "$pid" ] && break
  sleep 1
done
[ -n "$pid" ] || { echo "$PROC is not running. Start it with: bash scripts/run-helios.sh" >&2; exit 1; }

started="$(date '+%Y-%m-%d %H:%M:%S')"
started_epoch="$(date +%s)"
echo "Watching $PROC (pid $pid) for $minutes min, every ${interval}s. Ctrl-C ends early."
echo "time,cpu_pct,footprint_mb,rss_mb,idle_wakeups_per_s,helper_cpu_pct,helper_rss_mb" > "$csv"
logfile="$OUT/log-$stamp.txt"

# Inode changes of the history files = full rewrites (the 0.2 fix should make them rare).
# State lives in plain files because macOS ships bash 3.2 (no associative arrays).
state="$OUT/.state-$stamp"; mkdir -p "$state"
for f in "$DATA"/*.ndjson; do
  [ -e "$f" ] || continue
  stat -f %i "$f" > "$state/$(basename "$f").inode"; echo 0 > "$state/$(basename "$f").rewrites"
done

footprint_mb() {  # "Footprint: 1584 KB" -> MB
  footprint -p "$1" 2>/dev/null | awk '/Footprint:/ {
    v=$(NF-5); u=$(NF-4); if (u=="KB") v/=1024; else if (u=="GB") v*=1024; else if (u=="B") v/=1048576
    printf "%.1f", v; exit }'
}

finish() {
  trap - INT TERM
  ended="$(date '+%Y-%m-%d %H:%M:%S')"
  {
    echo "Helios measurement report"
    echo "Window: $started → $ended   process: $PROC (pid $pid)"
    app="$(ps -p "$pid" -o comm= 2>/dev/null)"
    echo
    echo "== Context"
    echo "Mac: $(sysctl -n hw.model)  macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))  uptime since $(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/' | xargs -I{} date -r {} '+%m-%d %H:%M')"
    echo "Power: $(pmset -g batt 2>/dev/null | head -1)   Thermal: $(pmset -g therm 2>/dev/null | grep -i -E 'CPU_Speed_Limit|thermal' | tr '\n' ' ')"
    echo "Helios: $(plutil -extract CFBundleShortVersionString raw "$(dirname "$(dirname "$app")")/Info.plist" 2>/dev/null) build $(plutil -extract CFBundleVersion raw "$(dirname "$(dirname "$app")")/Info.plist" 2>/dev/null)   helper: $(pgrep -x HeliosDaemon >/dev/null && echo running || echo 'not running')   other Helios processes: $(pgrep -x Helios | wc -l | tr -d ' ')"
    app="$(ps -p "$pid" -o comm= 2>/dev/null)"
    [ -n "$app" ] && echo "Binary: $app"
    echo
    echo "== Resource use (samples: $(($(wc -l < "$csv") - 1)))"
    awk -F, 'NR>1 && $2!="" { n++; c+=$2; if ($2>cm) cm=$2
        if (n==1) f0=$3; fl=$3; if ($3>fm) fm=$3; if ($5!="") { wn++; w+=$5; if ($5>wm) wm=$5 } }
      END { if (n==0) print "no samples"; else
        printf "CPU      avg %.2f%%  max %.1f%%\nMemory   first %.0f MB  last %.0f MB  max %.0f MB (physical footprint)\nWakeups  avg %.0f/s  max %.0f/s\n", c/n, cm, f0, fl, fm, (wn ? w/wn : 0), wm }' "$csv"
    echo
    echo "== History files (rewrites = file replaced during the window)"
    for f in "$DATA"/*.ndjson; do
      [ -e "$f" ] || continue
      printf '%-28s %8s KB   rewrites: %s   last change: %s\n' "$(basename "$f")" \
        "$(( $(stat -f %z "$f") / 1024 ))" "$(cat "$state/$(basename "$f").rewrites" 2>/dev/null || echo new)" "$(stat -f '%Sm' -t '%H:%M:%S' "$f")"
    done
    echo
    echo "== Helper (HeliosDaemon, sampled with ps)"
    awk -F, 'NR>1 && $6!="" { n++; c+=$6; if ($6>cm) cm=$6; if ($7>rm) rm=$7 }
      END { if (n==0) print "no helper samples (not running or not readable)"; else
        printf "CPU avg %.2f%% max %.1f%%   RSS max %.1f MB\n", c/n, cm, rm }' "$csv"
    echo
    echo "== Log summary (full log in $logfile)"
    log show --start "$started" --info --debug --predicate 'subsystem == "com.snejda.Helios"' > "$logfile" 2>/dev/null
    printf 'lines %s   errors %s   faults %s\n' "$(wc -l < "$logfile" | tr -d ' ')" \
      "$(grep -c -E '^\S+ \S+ +0x[0-9a-f]+ +Error' "$logfile")" "$(grep -c -E '^\S+ \S+ +0x[0-9a-f]+ +Fault' "$logfile")"
    echo "Most frequent messages:"
    sed -E 's/^[^ ]+ [^ ]+ +0x[0-9a-f]+ +[A-Za-z]+ +[0-9]+ +[0-9]+ +//' "$logfile" | sed -E 's/[0-9]+(\.[0-9]+)?/N/g' | sort | uniq -c | sort -rn | head -8
    echo
    echo "== Log (subsystem com.snejda.Helios, errors and faults only)"
    log show --start "$started" --info --predicate \
      'subsystem == "com.snejda.Helios" AND (messageType == error OR messageType == fault)' 2>/dev/null \
      | tail -n 40
    echo
    echo "== Crash reports since start"
    crashes="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Helios*' -newermt "$started" 2>/dev/null)"
    echo "${crashes:-none}"
    if ! kill -0 "$pid" 2>/dev/null; then echo; echo "NOTE: $PROC (pid $pid) was no longer running at the end."; fi
  } > "$report"
  echo
  cat "$report"
  rm -rf "$state"
  echo
  echo "Report: $report"
  exit 0
}
trap finish INT TERM

end_epoch=$((started_epoch + minutes * 60))
prev_total=""; prev_epoch=0
while [ "$(date +%s)" -lt "$end_epoch" ]; do
  kill -0 "$pid" 2>/dev/null || break
  # One short top sample (1 s) gives CPU and the idle-wakeup total.
  read -r cpu wake_total < <(top -l 2 -s 1 -pid "$pid" -stats cpu,idlew 2>/dev/null | tail -1)
  # top reports idle wakeups as a running total ("53499+"); turn it into a rate.
  now_epoch="$(date +%s)"; wake=""
  total="${wake_total%[+-]}"
  case "$total" in ''|*[!0-9]*) total="" ;; esac
  if [ -n "$total" ] && [ -n "$prev_total" ] && [ "$now_epoch" -gt "$prev_epoch" ] && [ "$total" -ge "$prev_total" ]; then
    wake="$(awk -v a="$total" -v b="$prev_total" -v dt="$((now_epoch - prev_epoch))" 'BEGIN { printf "%.0f", (a-b)/dt }')"
  fi
  prev_total="$total"; prev_epoch="$now_epoch"
  rss="$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.1f", $1/1024}')"
  helper="$(ps -axo pid=,%cpu=,rss=,comm= 2>/dev/null | awk '$4 ~ /HeliosDaemon$/ { printf "%s,%.1f", $2, $3/1024; exit }')"
  echo "$(date +%H:%M:%S),${cpu:-},$(footprint_mb "$pid"),${rss:-},${wake:-},${helper:-,}" >> "$csv"
  for f in "$DATA"/*.ndjson; do
    [ -e "$f" ] || continue
    name="$(basename "$f")"; now="$(stat -f %i "$f")"
    if [ -f "$state/$name.inode" ] && [ "$now" != "$(cat "$state/$name.inode")" ]; then
      echo $(( $(cat "$state/$name.rewrites") + 1 )) > "$state/$name.rewrites"
    fi
    echo "$now" > "$state/$name.inode"
    [ -f "$state/$name.rewrites" ] || echo 0 > "$state/$name.rewrites"
  done
  tail -1 "$csv" | awk -F, '{ printf "%s  CPU %s%%  memory %s MB  wakeups %s/s\n", $1, $2, $3, ($5==""?"-":$5) }'
  sleep "$((interval > 1 ? interval - 1 : 1))"
done
finish
