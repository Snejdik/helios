#!/bin/bash
# Native external-beta diagnostics checks. Never sends a network request.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache \
  Sources/HeliosApp/Diagnostics/*.swift Tests/DiagnosticsChecks.swift \
  -o .build/Checks/DiagnosticsChecks
exec .build/Checks/DiagnosticsChecks
