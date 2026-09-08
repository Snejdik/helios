#!/bin/bash
# Phase 4.5 Step 5 orchestration wrapper. The validator itself receives real
# macOS power notifications; this script does not call pmset or another sleep CLI.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOL=.build/Validation/Phase45PhysicalValidation
if [[ ! -x "$TOOL" ]]; then
  echo "Build the validation tool first: ./scripts/build-phase45-validation.sh" >&2
  exit 1
fi
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this wrapper with sudo: sudo ./scripts/run-phase45-sleep-wake-validation.sh" >&2
  exit 1
fi

exec "$TOOL" \
  --sleep-wake \
  --confirm 'HELIOS-PHASE45-MAC16,1-25G83'
