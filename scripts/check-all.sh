#!/bin/bash
# Full local regression gate. Simulated/read-only checks only; no physical fan writes.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/check-runtime-policy.sh
./scripts/check-battery-readonly.sh
./scripts/check-ownership.sh
./scripts/check-ipc.sh
./scripts/check-fans.sh
./scripts/check-storage.sh
./scripts/check-telemetry.sh
./scripts/check-presentation.sh

xcodebuild \
  -project Helios.xcodeproj \
  -scheme HeliosApp \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  build -quiet

echo "PASS full Helios regression gate and Xcode build"
