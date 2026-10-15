#!/bin/bash
# RC5 contract: every telemetry value that the frozen backend publishes to the
# app layer must remain reachable from the UI. This intentionally audits model
# fields, not parser/provider implementation state that is never published.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import re, sys

root = Path('.')
# 0.3.0: the Legacy Full Monitor (and its hand-written "Complete published telemetry"
# section) was retired. Every published value now stays reachable through the
# Diagnostics page's "All readings", which reflects over the whole TelemetrySnapshot
# and the summaries kept beside it, so a new field needs no UI work to appear.
ui_files = [p for p in sorted((root / 'Sources/HeliosApp').rglob('*.swift')) if '/Telemetry/' not in str(p)]
ui_all = '\n'.join(p.read_text() for p in ui_files)
readings = (root / 'Sources/HeliosApp/V2/HeliosAllReadings.swift').read_text()
diagnostics_page = (root / 'Sources/HeliosApp/V2/HeliosDiagnosticsPage.swift').read_text()
for required in ['Mirror(reflecting: snapshot).children', 'func flatten(', '("persistentHistory", model.persistentHistory)',
                 '("ioAudit", model.ioAudit)', '("appEnergy", model.appEnergy)', '("healthEvents", model.healthCenter.events)']:
    if required not in readings:
        raise SystemExit(f'FAIL: All readings no longer reflects every published value: {required}')
if 'HeliosAllReadingsSection(model: model)' not in diagnostics_page:
    raise SystemExit('FAIL: All readings is not reachable from the Diagnostics page')
if re.search(r'maximumDepth = [0-5]\b', readings):
    raise SystemExit('FAIL: All readings is too shallow to reach nested telemetry fields')

telemetry_files = list((root / 'Sources/HeliosApp/Telemetry').glob('*.swift'))
shared_files = [root / 'Sources/Shared/FanModels.swift', root / 'Sources/Shared/FanOwnershipPreflight.swift']
backend = '\n'.join(p.read_text() for p in telemetry_files + shared_files)

# These are the value models actually retained/published to OverviewViewModel,
# Full Monitor, persistent history, audit/energy summaries, or explicit
# on-demand Maintenance/SMC surfaces. Internal rate-calculator snapshots and
# parser scratch structs are intentionally excluded because exposing them would
# require changing the frozen backend contract.
published_structs = [
    'CPUMetrics', 'MemoryMetrics', 'GPUMetrics', 'SystemPowerMetrics',
    'BatteryPower', 'BatteryMetrics', 'ThermalReading', 'ThermalMetrics',
    'SystemMetrics', 'NetworkThroughput', 'NetworkMetrics', 'WiFiMetrics',
    'ProcessActivity', 'ProcessMetrics', 'StorageIOCounters', 'StorageThroughput',
    'NVMeCounter128', 'NVMeSMARTHealth', 'StorageDeviceMetrics', 'RootVolumeMetrics',
    'StorageMetrics', 'DisplayDeviceMetrics', 'DisplayMetrics', 'MountedVolumeMetrics',
    'VolumeMetrics', 'USBDeviceMetrics', 'USBMetrics', 'BluetoothBatteryMetrics',
    'BluetoothDeviceMetrics', 'BluetoothMetrics', 'AudioDeviceMetrics', 'AudioMetrics',
    'PowerAssertionMetrics', 'PowerAssertionsMetrics', 'ClockZoneMetrics', 'ClockMetrics',
    'SMCNumericReading', 'SMCNumericMetrics', 'CapabilityItem', 'CapabilityReport',
    'AppEnergyEntry', 'AppEnergyBucket', 'AppEnergyTrend', 'AppEnergySummary',
    'IOActivityRecord', 'IOActivitySummary', 'TelemetryHistoryPoint',
    'PersistedTelemetryPoint', 'PersistentHistorySummary', 'HealthIssue',
    'HealthEventRecord', 'FanReading', 'FanInventory', 'FanOwnershipPreflightFan',
    'FanOwnershipPreflightEvidence', 'FanOwnershipMachineProfile',
    'FanOwnershipPreflightSnapshot', 'CleanupCandidate', 'CleanupMetrics',
    'InstalledApplicationMetrics', 'ApplicationsMetrics',
]

def struct_body(name: str) -> str:
    match = re.search(rf'\bstruct\s+{re.escape(name)}\b[^{{]*\{{', backend)
    if not match:
        raise SystemExit(f'FAIL: published telemetry struct {name} not found')
    i, depth = match.end(), 1
    while i < len(backend) and depth:
        if backend[i] == '{': depth += 1
        elif backend[i] == '}': depth -= 1
        i += 1
    if depth:
        raise SystemExit(f'FAIL: could not parse {name}')
    return backend[match.end():i-1]

count = 0
for name in published_structs:
    body = struct_body(name)
    count += sum(1 for line in body.splitlines() if re.match(r'\s*let\s+(\w+)\s*:', line))

# Derived summaries are computed properties, which reflection does not list. Keep an
# explicit contract for the ones people asked not to lose: each must still be shown
# somewhere in the interface.
derived = [
    'usagePercent', 'appBytes', 'cacheBytes', 'availableBytes',
    'healthPercent', 'stateOfChargePercent', 'cellBalanceMillivolts',
    'maximumSoCReading', 'maximumSoCCelsius', 'durationSeconds', 'latest', 'summary',
]
missing = []
for field in derived:
    count += 1
    if not re.search(rf'\.\s*{re.escape(field)}\b', ui_all):
        missing.append(f'derived.{field}')

# Every live sampler in TelemetrySnapshot is a stored property, so reflection shows it.
monitor = (root / 'Sources/HeliosApp/Telemetry/TelemetryMonitor.swift').read_text()
snapshot_match = re.search(r'struct\s+TelemetrySnapshot\s*:\s*Sendable\s*\{(.*?)\n\}', monitor, re.S)
if not snapshot_match:
    raise SystemExit('FAIL: TelemetrySnapshot declaration not found')
if re.search(r'\b(static\s+)?var\s+\w+\s*:\s*MetricSample<[^>]+>\s*\{', snapshot_match.group(1)):
    raise SystemExit('FAIL: a TelemetrySnapshot sampler became a computed property that reflection cannot see')
count += len(re.findall(r'\bvar\s+(\w+)\s*:\s*MetricSample', snapshot_match.group(1)))

if missing:
    print('FAIL: backend-published telemetry fields missing from UI:', file=sys.stderr)
    for item in missing:
        print(f'  - {item}', file=sys.stderr)
    raise SystemExit(1)

print(f'PASS detailed UI coverage: {count} published telemetry fields reachable (All readings reflects every stored field; derived summaries shown in the interface)')
PY
