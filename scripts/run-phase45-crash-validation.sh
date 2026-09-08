#!/bin/bash
# Phase 4.5 Step 3: intentionally SIGKILL an owned validation process, then
# recover from the durable journal in a fresh process. This script performs
# physical SMC writes and is pinned to Mac16,1 / 25G83 by the validator.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "ERROR: run this harness with sudo" >&2
  echo "  sudo ./scripts/run-phase45-crash-validation.sh" >&2
  exit 2
fi

binary=".build/Validation/Phase45PhysicalValidation"
marker="/var/db/com.snejda.Helios.phase45-crash-ready-v1"
log=".build/Validation/phase45-crash-child.log"
confirm="HELIOS-PHASE45-MAC16,1-25G83"
harness="HELIOS-PHASE45-CRASH-WRAPPER-V1"

if [[ ! -x "$binary" ]]; then
  echo "ERROR: build the validator first with ./scripts/build-phase45-validation.sh" >&2
  exit 2
fi

rm -f "$marker" "$log"
child=""
cleanup_marker() { rm -f "$marker"; }
trap cleanup_marker EXIT

# Refuse to start from anything except the validated clean baseline.
"$binary" --preflight

echo
echo "=== STEP 3A: arm durable ownership in child process ==="
"$binary" --arm-crash --confirm "$confirm" --orchestrated-by "$harness" >"$log" 2>&1 &
child=$!

ready=0
for _ in $(seq 1 200); do
  if [[ -f "$marker" ]]; then
    marker_pid="$(tr -d '[:space:]' < "$marker")"
    if [[ "$marker_pid" != "$child" ]]; then
      echo "ERROR: crash marker PID mismatch (marker=$marker_pid child=$child)" >&2
      break
    fi
    ready=1
    break
  fi
  if ! kill -0 "$child" 2>/dev/null; then
    break
  fi
  sleep 0.10
done

cat "$log" || true

if [[ $ready -ne 1 ]]; then
  echo "ERROR: child never reached CRASH_ARMED; forcing termination and journal recovery" >&2
  if kill -0 "$child" 2>/dev/null; then
    kill -KILL "$child" 2>/dev/null || true
  fi
  wait "$child" 2>/dev/null || true
  rm -f "$marker"
  "$binary" --restore-only || true
  exit 1
fi

echo
echo "=== STEP 3B: intentional SIGKILL ==="
echo "SIGKILL pid=$child after durable owned state and observed physical response"
kill -KILL "$child"
wait "$child" 2>/dev/null || true
rm -f "$marker"

# The old process is now gone. A new executable instance must recover solely
# from durable journal state plus current hardware readback.
echo
echo "=== STEP 3C: fresh-process recovery from journal ==="
"$binary" --restore-only

echo
echo "=== STEP 3D: final read-only verification ==="
"$binary" --preflight

echo
echo "PHASE45 CRASH/RESTART RESTORATION PASSED"
echo "Validated: owned process SIGKILL -> fresh process journal recovery -> clean System baseline."
echo "This does NOT yet enable production takeover; automatic daemon restart/wake integration remains gated."
