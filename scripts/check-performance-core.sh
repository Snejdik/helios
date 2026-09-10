#!/bin/bash
# Static guard for consolidated near-final performance work. No hardware access.
set -euo pipefail
cd "$(dirname "$0")/.."

process="Sources/HeliosApp/Telemetry/ProcessProvider.swift"
gpu="Sources/HeliosApp/Telemetry/GPUProvider.swift"
network="Sources/HeliosApp/Telemetry/NetworkProvider.swift"
energy="Sources/HeliosApp/Telemetry/AppEnergyHistory.swift"
history="Sources/HeliosApp/Telemetry/PersistentHistory.swift"
ioaudit="Sources/HeliosApp/Telemetry/IOActivityAudit.swift"
windows="Sources/HeliosApp/HeliosWindows.swift"
status="Sources/HeliosApp/StatusItemController.swift"

required_process=(
  'private var currentScratch: [Int32: ProcessCounterSnapshot] = [:]'
  'private var sessionAccountedReadBytes: UInt64 = 0'
  'private static func topCandidates('
  'private static func topSessionKeys('
  'rate.diskReadBytesDelta > 0 || rate.diskWriteBytesDelta > 0 || session[key] != nil'
)
for needle in "${required_process[@]}"; do grep -Fq "$needle" "$process" || { echo "FAIL process optimization guard missing: $needle" >&2; exit 1; }; done

required_gpu=(
  'private var cachedIdentity:'
  'IORegistryEntryCreateCFProperty('
  '"PerformanceStatistics" as CFString'
)
for needle in "${required_gpu[@]}"; do grep -Fq "$needle" "$gpu" || { echo "FAIL GPU optimization guard missing: $needle" >&2; exit 1; }; done

required_network=(
  'private static let routeRefreshInterval: Duration = .seconds(5)'
  'static func readLinks() throws -> NetworkLinkInventory'
  'private var cachedRoute: RouteMetadata?'
  'let links = try NetworkInterfaceReader.readLinks()'
)
for needle in "${required_network[@]}"; do grep -Fq "$needle" "$network" || { echo "FAIL network optimization guard missing: $needle" >&2; exit 1; }; done

for file in "$energy" "$history" "$ioaudit"; do
  grep -Fq 'private var appendHandle: FileHandle?' "$file" || { echo "FAIL append-handle cache missing in $file" >&2; exit 1; }
  grep -Fq 'private var knownFileSize: Int?' "$file" || { echo "FAIL file-size cache missing in $file" >&2; exit 1; }
  if grep -Fq 'defer { try? handle.close() }' "$file"; then
    echo "FAIL per-append FileHandle close/reopen path remains in $file" >&2
    exit 1
  fi
done

grep -Fq 'private var cachedSummary: AppEnergySummary?' "$energy" || { echo 'FAIL app-energy summary cache missing' >&2; exit 1; }
grep -Fq 'self.appEnergy != summary' Sources/HeliosApp/OverviewViewController.swift || { echo 'FAIL app-energy no-op publish suppression missing' >&2; exit 1; }
grep -Fq 'popover.contentViewController = nil' "$status" || { echo 'FAIL closed popover tree release missing' >&2; exit 1; }
grep -Fq 'func windowWillClose(_ notification: Notification)' "$windows" || { echo 'FAIL closed window controller release missing' >&2; exit 1; }
grep -Fq 'energyInspectorState.clearDerivedCache()' "$windows" || { echo 'FAIL Energy Inspector derived-cache release missing' >&2; exit 1; }

printf '%s\n' 'PASS near-final performance core: process leader selection/session accounting, narrow GPU reads, cached network metadata, persistent append handles, no-op app-energy publication, and closed-UI release are present'
