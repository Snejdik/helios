#!/bin/bash
# Chip profiles and passive sensor-map verification (PLAN_0_3_0 M1): every chip family,
# fanless and unknown Macs, and the verifier against synthetic load/temperature series.
# Pure fixtures; no SMC access, no IORegistry, no fan writes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework IOKit -framework Security -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift Sources/HeliosApp/Telemetry/*.swift \
  Tests/ChipProfileChecks.swift -o .build/Checks/ChipProfileChecks
exec .build/Checks/ChipProfileChecks "$@"
