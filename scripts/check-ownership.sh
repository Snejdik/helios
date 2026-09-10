#!/bin/bash
# Fast focused ownership verification including fresh-process recovery simulation.
# No privileged service, launchd registration, or physical SMC writes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework IOKit \
  Sources/Shared/MetricValue.swift Sources/Shared/SMCClient.swift Sources/Shared/FanModels.swift \
  Sources/Shared/FanOwnershipPreflight.swift Sources/Shared/HeliosServiceIdentity.swift \
  Sources/HeliosDaemon/ControlLease.swift Sources/HeliosDaemon/FanOwnershipTransition.swift Sources/HeliosDaemon/FanOwnershipRecovery.swift \
  Sources/HeliosDaemon/FanOwnershipProductionRecovery.swift \
  Tests/OwnershipChecks.swift -o .build/Checks/OwnershipChecks
exec .build/Checks/OwnershipChecks
