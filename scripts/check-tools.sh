#!/bin/bash
# Tools (PLAN_0_3_0 M6): Keep Awake, URL scheme, rules and done-watchers as pure values.
# No hardware, no assertions held, no notifications sent.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift Sources/HeliosApp/Telemetry/*.swift \
  Tests/ToolsChecks.swift -o .build/Checks/ToolsChecks
exec .build/Checks/ToolsChecks "$@"
