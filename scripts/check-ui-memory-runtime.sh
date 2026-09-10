#!/bin/bash
# Optimized, test-only native lifecycle stress over production UI sources.
# Uses isolated defaults and deterministic data; never connects to the helper.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/Checks/ModuleCache
python3 - <<'PYFIXTURE'
from pathlib import Path
source = Path('Tests/PresentationChecks.swift').read_text()
start = source.index('  private static func fixture(')
end = source.index('  private static func graphLivePoint(', start)
fixture = source[start:end].replace('private static func fixture', 'static func fixture', 1)
Path('.build/Checks/UIMemoryFixture.swift').write_text('import Foundation\n@MainActor enum UIMemoryFixture {\n' + fixture + '}\n')
PYFIXTURE
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path .build/Checks/ModuleCache -framework AppKit -framework SwiftUI -framework IOKit -framework Security -framework ServiceManagement -framework SystemConfiguration -framework CoreWLAN -framework CoreGraphics -framework IOBluetooth -framework CoreAudio -framework UserNotifications -lproc \
  Sources/Shared/*.swift Sources/HeliosApp/DaemonClient.swift Sources/HeliosApp/DaemonService.swift Sources/HeliosApp/DaemonServiceCard.swift \
  Sources/HeliosApp/CoolingRules.swift Sources/HeliosApp/FanControlModel.swift Sources/HeliosApp/FanControlView.swift \
  Sources/HeliosApp/Telemetry/*.swift Sources/HeliosApp/HeliosPreferences.swift Sources/HeliosApp/MenuBarView.swift \
  Sources/HeliosApp/HeliosBrand.swift Sources/HeliosApp/HeliosGraphKit.swift Sources/HeliosApp/HeliosBatteryEstimate.swift \
  Sources/HeliosApp/HeliosMetricPopovers.swift Sources/HeliosApp/HeliosDashboardView.swift Sources/HeliosApp/HeliosWindows.swift \
  Sources/HeliosApp/PresentationValues.swift Sources/HeliosApp/OverviewViewController.swift Sources/HeliosApp/StatusItemController.swift \
  Tests/UIMemoryChecks.swift .build/Checks/UIMemoryFixture.swift -o .build/Checks/UIMemoryChecks
exec .build/Checks/UIMemoryChecks
