#!/bin/bash
# Development verification only; Helios never launches this script or any CLI.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/MetricValue.swift Sources/Shared/SMCClient.swift Sources/Shared/FanModels.swift Sources/Shared/FanOwnershipPreflight.swift \
  Sources/HeliosApp/Telemetry/*.swift Tests/TelemetryChecks.swift \
  -o .build/Checks/TelemetryChecks
exec .build/Checks/TelemetryChecks "$@"
