#!/bin/bash
# "Why?" engine (PLAN_0_3_0 M3/M4): every lens against fixture scenarios with expected
# causes and honest confidence, plus the macOS diagnostic-report reader. Pure values; the
# reader check writes only into a temporary folder it creates and removes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift Sources/HeliosApp/Telemetry/*.swift \
  Tests/DiagnoseChecks.swift -o .build/Checks/DiagnoseChecks
exec .build/Checks/DiagnoseChecks "$@"
