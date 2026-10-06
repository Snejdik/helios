#!/bin/bash
# Cool-only fan layer: pure policy, tiers, v3 journal, cross-build recovery and
# the engine/coordinator failure matrix against simulated hardware only.
# No privileged service, launchd registration or physical SMC writes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration \
  Sources/Shared/*.swift Sources/HeliosApp/Telemetry/*.swift \
  Sources/HeliosDaemon/Fan*.swift Sources/HeliosDaemon/ControlLease.swift \
  Tests/FanLayerChecks.swift -o .build/Checks/FanLayerChecks
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
exec .build/Checks/FanLayerChecks "$@"
