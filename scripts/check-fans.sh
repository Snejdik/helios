#!/bin/bash
# Simulated fan writes only; --live additionally reads this Mac without privileges.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration \
  Sources/Shared/*.swift Sources/HeliosApp/Telemetry/*.swift \
  Sources/HeliosApp/DaemonClient.swift Sources/HeliosApp/CoolingRules.swift Sources/HeliosApp/FanControlModel.swift \
  Sources/HeliosDaemon/Fan*.swift Sources/HeliosDaemon/ControlLease.swift \
  Tests/FanFixtures.swift Tests/FanChecks.swift -o .build/Checks/FanChecks
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
exec .build/Checks/FanChecks "$@"
