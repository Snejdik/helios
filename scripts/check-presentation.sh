#!/bin/bash
# Native fixture rendering and anti-jitter checks; never invoked by Helios itself.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework SwiftUI -framework IOKit -framework Security -framework ServiceManagement -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift Sources/HeliosApp/DaemonClient.swift Sources/HeliosApp/DaemonService.swift Sources/HeliosApp/DaemonServiceCard.swift \
  Sources/HeliosApp/CoolingRules.swift Sources/HeliosApp/FanControlModel.swift Sources/HeliosApp/FanControlView.swift \
  Sources/HeliosApp/Telemetry/*.swift Sources/HeliosApp/MenuBarView.swift \
  Sources/HeliosApp/PresentationValues.swift Sources/HeliosApp/OverviewViewController.swift \
  Tests/PresentationChecks.swift -o .build/Checks/PresentationChecks
exec .build/Checks/PresentationChecks
