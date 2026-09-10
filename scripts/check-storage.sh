#!/bin/bash
# Focused read-only storage verification. Helios never launches this script.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework IOKit \
  Sources/Shared/MetricValue.swift Sources/HeliosApp/Telemetry/StorageProvider.swift \
  Tests/StorageChecks.swift -o .build/Checks/StorageChecks
exec .build/Checks/StorageChecks "$@"
