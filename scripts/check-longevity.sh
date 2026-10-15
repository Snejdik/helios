#!/bin/bash
# Longevity (PLAN_0_3_0 M5) on synthetic history: battery wear and habits, adapter and
# cable, SSD endurance, cooling against the Mac's own first weeks, memory and swap, word
# grades, the report document and reminders. Pure values; the store check writes only into
# a temporary folder it creates and removes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift Sources/HeliosApp/Telemetry/*.swift \
  Tests/LongevityChecks.swift -o .build/Checks/LongevityChecks
exec .build/Checks/LongevityChecks "$@"
