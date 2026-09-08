#!/bin/bash
# Compile the Phase 4.5 Step 5 standalone sleep/wake-validation executable.
# Building and --describe are read-only. Physical writes occur only when the
# resulting executable is explicitly run with sudo --run/--sleep-wake and the
# exact confirmation token.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Validation/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Validation/ModuleCache -framework IOKit \
  Sources/Shared/MetricValue.swift Sources/Shared/SMCClient.swift Sources/Shared/FanModels.swift \
  Sources/Shared/FanOwnershipPreflight.swift \
  Sources/HeliosDaemon/FanOwnershipTransition.swift Sources/HeliosDaemon/FanOwnershipRecovery.swift \
  Tools/Phase45PhysicalValidation.swift \
  -o .build/Validation/Phase45PhysicalValidation
.build/Validation/Phase45PhysicalValidation --describe
