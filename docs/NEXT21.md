# Next21 — Attribution, trends and capability milestone

Next21 is the final large observability/diagnostics sprint built on the physically validated Next20 baseline. It keeps the privileged fan-control and XPC safety core byte-for-byte unchanged and expands only the unprivileged read-only utility layer.

## Storage I/O attribution

The Storage card now distinguishes three accounting layers instead of treating the boot-scoped device counters as if they belonged to Helios:

- physical primary-device IOBlockStorage counters and current throughput;
- native libproc per-process disk read/write rates and session totals;
- Helios' own process disk read/write rate and session totals.

The physical device counters include all macOS/APFS/VM/cache/kernel I/O. Process accounting is a different kernel layer and is deliberately not presented as a reconciliation that must sum to device traffic.

A 24-hour append-friendly audit is persisted at:

`~/Library/Application Support/Helios/io-activity-v1.ndjson`

It stores approximately one record every 30 seconds, retains at most 24 hours / 3,000 records, tolerates malformed/truncated tails, and integrates physical counter deltas only across short ordered observations on the same device. UI actions can copy a compact audit or export the retained audit as CSV.

The Storage card also exposes:

- physical read/write since the current Helios process first observed the primary device;
- boot-average read/write derived from the whole-device counters and system uptime;
- current process-accounted read/write;
- current top reader/writer and session writer;
- 24-hour observed physical read/write;
- persistent NVMe lifetime-read/lifetime-write deltas when native SMART remains available.

## Process/session diagnostics

The existing RUSAGE_INFO_V6 provider now keeps a bounded PID-start-time keyed session ledger. It adds current top readers/writers, session read/write leaders, total process-accounted session bytes, and a dedicated Helios self-footprint view. PID reuse, counter rollback and invalid sampling intervals remain fail-closed.

The Helios self view reports current CPU, native task energy, physical memory, wakeups, disk rates and session I/O. Persistent telemetry additionally summarizes 24-hour average/peak Helios CPU/power, peak memory and average wakeups so later optimization can be measured rather than guessed.

## Persistent trend expansion

The existing 24-hour history now persists additional independent values:

- battery health, signed battery power, AC state, temperature and cycle count;
- storage device identity and native NVMe lifetime read/write counters;
- physical storage throughput and process-accounted I/O rates;
- Helios CPU/power/memory/wakeup footprint.

History can be exported as CSV. PSTR and signed battery-energy integrations remain gap-safe and never bridge sleep, long gaps, stale data or clock rollback. NVMe lifetime deltas reset on device handoff or counter rollback rather than inventing traffic.

## Health event history

Health evaluation remains independent of fan-control decisions. Next21 adds a seven-day local transition history for activated/resolved health conditions in `health-events-v1.ndjson`, with retention bounds and malformed-tail recovery. Notification permission is still requested only by explicit user action; the card refreshes authorization whenever it is shown so changes made in System Settings no longer require an app restart.

## Hardware capability matrix

The System card now exposes a read-only capability report for per-core CPU, GPU PerformanceStatistics, PSTR, native NVMe SMART, per-process RUSAGE_INFO_V6, CoreWLAN, AppleSmartBattery, SMC thermals, fan telemetry and the fan-control surface match. The report is diagnostic evidence only. In particular, successful fan discovery/profile matching does **not** authorize writes; production fan writes remain separately pinned to the validated daemon gate.

## Read-only I/O preflight

After the canonical regression gate passes, run:

```sh
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --io-preflight
```

It warms delta providers in memory, then prints physical device counters/rates, boot-average traffic, process-accounted I/O, top reader/writer, Helios' own footprint and network session transfer. The probe performs no fan writes, persistent history/audit writes, notification prompt, subprocess execution or privileged telemetry.

## Frozen safety boundary

The following remain byte-for-byte unchanged from the validated Next20 baseline before packaging:

- `Sources/HeliosDaemon/*`
- `Sources/HeliosApp/FanControlModel.swift`
- `Sources/HeliosApp/CoolingRules.swift`
- `Sources/HeliosApp/DaemonClient.swift`
- `Sources/Shared/FanModels.swift`
- `Sources/Shared/FanOwnershipPreflight.swift`
- `Sources/Shared/HeliosXPCProtocol.swift`
- `Sources/Shared/XPCTrustRequirement.swift`
- `Sources/Shared/SMCClient.swift`

Next21 therefore adds no new SMC write key, fan target, ownership transition, lease path, root telemetry command or XPC fan-control capability.
