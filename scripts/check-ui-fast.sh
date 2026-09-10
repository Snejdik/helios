#!/bin/bash
# Fast Next23 UI/UX gate for iteration. No physical fan writes and no privileged actions.
# Includes telemetry-history regression coverage because Next23 charts consume those samples.
# A successful UI candidate must still pass check-all.sh before commit/release.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-runtime-policy.sh
./scripts/check-battery-readonly.sh
./scripts/check-next23-ui-boundary.sh
./scripts/check-preferences-semantic.sh
./scripts/check-detailed-ui-coverage.sh
./scripts/check-ui8-portable.sh
./scripts/check-presentation.sh
./scripts/check-telemetry.sh --ui-history-only

xcodebuild \
  -project Helios.xcodeproj \
  -scheme HeliosApp \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build -quiet

printf '%s\n' "PASS Next23 fast UI/UX + chart telemetry gate and full Xcode build"
