#!/bin/bash
# Full local regression gate. Simulated/read-only checks only; no physical fan writes.
# Next23 presentation + full app compilation run first so UI/compiler regressions
# fail before the longer frozen-backend regression suites.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-runtime-policy.sh
./scripts/check-battery-readonly.sh
./scripts/check-next23-ui-boundary.sh
./scripts/check-preferences-semantic.sh
./scripts/check-detailed-ui-coverage.sh
./scripts/check-ui8-portable.sh

# Fail fast on Next23 UI warnings/type errors and native render regressions.
./scripts/check-presentation.sh

# Compile the complete application before spending minutes on backend simulations.
xcodebuild \
  -project Helios.xcodeproj \
  -scheme HeliosApp \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build -quiet
printf '%s\n' "PASS Next23 full Xcode build before long regression suites"

./scripts/check-ownership.sh
./scripts/check-ipc.sh
./scripts/check-fans.sh
./scripts/check-storage.sh
./scripts/check-telemetry.sh

printf '%s\n' "PASS full Helios regression gate and Xcode build"
