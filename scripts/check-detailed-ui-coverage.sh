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
windows = (root / 'Sources/HeliosApp/HeliosWindows.swift').read_text()
overview = (root / 'Sources/HeliosApp/OverviewViewController.swift').read_text()
marker = '// MARK: - Complete published telemetry'
if marker not in windows:
    raise SystemExit('FAIL: complete published telemetry marker missing from Full Monitor')
expert = windows[windows.index(marker):]
ui_all = expert + '\n' + overview

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

missing = []
count = 0
for name in published_structs:
    body = struct_body(name)
    fields = []
    for line in body.splitlines():
        match = re.match(r'\s*let\s+(\w+)\s*:', line)
        if match:
            fields.append(match.group(1))
    for field in fields:
        count += 1
        if not re.search(rf'\.\s*{re.escape(field)}\b', ui_all):
            missing.append(f'{name}.{field}')

# Derived summaries are backend-published data too even though they are computed
# properties rather than stored lets. Keep an explicit contract for the values
# users specifically asked not to lose (lifetime I/O, Helios footprint, battery
# summaries, fan/thermal summaries, etc.).
derived = [
    'usagePercent', 'appBytes', 'cacheBytes', 'availableBytes',
    'healthPercent', 'rawStateOfChargePercent', 'stateOfChargePercent',
    'cellBalanceMillivolts', 'maximumSoCReading', 'maximumSoCCelsius',
    'durationSeconds', 'batteryChargeDeltaPercent', 'batteryMinimumPercent',
    'batteryMaximumPercent', 'batteryMinimumTemperatureCelsius',
    'batteryMaximumTemperatureCelsius', 'batteryMinimumHealthPercent',
    'batteryMaximumHealthPercent', 'latestBatteryCycleCount',
    'storageLifetimeReadDeltaBytes', 'storageLifetimeWrittenDeltaBytes',
    'heliosAverageCPUPercent', 'heliosPeakCPUPercent', 'heliosAveragePowerWatts',
    'heliosPeakPowerWatts', 'heliosPeakMemoryBytes', 'heliosAverageWakeupsPerSecond',
    'batteryEnergyWattHours', 'measuredBatteryPowerCoverageSeconds',
    'peakReadBytesPerSecond', 'peakWriteBytesPerSecond', 'latest',
    'estimatedBytes', 'isReadyForValidation', 'summary',
]
for field in derived:
    count += 1
    if not re.search(rf'\.\s*{re.escape(field)}\b', ui_all):
        missing.append(f'derived.{field}')

# Every live sampler in TelemetrySnapshot must be represented in the detailed
# UI metadata/diagnostic surface so a stopped or failed collector is visible.
monitor = (root / 'Sources/HeliosApp/Telemetry/TelemetryMonitor.swift').read_text()
snapshot_match = re.search(r'struct\s+TelemetrySnapshot\s*:\s*Sendable\s*\{(.*?)\n\}', monitor, re.S)
if not snapshot_match:
    raise SystemExit('FAIL: TelemetrySnapshot declaration not found')
for field in re.findall(r'\bvar\s+(\w+)\s*=\s*MetricSample', snapshot_match.group(1)):
    count += 1
    if not re.search(rf'\.\s*{re.escape(field)}\b', expert):
        missing.append(f'TelemetrySnapshot.{field}')

if missing:
    print('FAIL: backend-published telemetry fields missing from UI:', file=sys.stderr)
    for item in missing:
        print(f'  - {item}', file=sys.stderr)
    raise SystemExit(1)

required_phrases = [
    'CPU internals', 'Memory internals', 'GPU internals',
    'Thermal sensors', 'Fan telemetry', 'Battery internals',
    'Energy history internals', 'Storage internals', 'NVMe SMART / Lifetime',
    'Network internals', 'Wi-Fi radio', 'Process sampler',
    'System internals', 'Display inventory', 'Mounted volumes',
    'USB inventory', 'Bluetooth inventory', 'Audio inventory',
    'Persistent history state', 'Health event log',
    'Raw SMC numeric inventory', 'All Diagnostics',
]
for phrase in required_phrases:
    if phrase not in windows:
        raise SystemExit(f'FAIL: detailed UI surface missing: {phrase}')

print(f'PASS RC8 detailed UI coverage: {count} backend-published stored/derived telemetry fields remain reachable without changing the frozen backend')
PY
