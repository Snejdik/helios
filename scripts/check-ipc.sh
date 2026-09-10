#!/bin/bash
# Isolated, unprivileged NSXPC checks. No launchd registration or hardware access.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework Security -framework ServiceManagement -framework SystemConfiguration \
  Sources/Shared/*.swift Sources/HeliosDaemon/DiagnosticLease.swift \
  Sources/HeliosDaemon/DaemonSession.swift Sources/HeliosDaemon/DaemonListenerDelegate.swift \
  Sources/HeliosDaemon/Fan*.swift Sources/HeliosDaemon/ControlLease.swift \
  Sources/HeliosApp/Telemetry/*.swift Sources/HeliosApp/CoolingRules.swift Sources/HeliosApp/FanControlModel.swift \
  Sources/HeliosApp/DaemonClient.swift Sources/HeliosApp/DaemonService.swift \
  Tests/FanFixtures.swift Tests/IPCChecks.swift -o .build/Checks/IPCChecks
codesign --force --sign - --identifier com.snejda.Helios.IPCChecks .build/Checks/IPCChecks
if [[ "${1:-}" == "--build-only" ]]; then exit 0; fi
exec .build/Checks/IPCChecks
