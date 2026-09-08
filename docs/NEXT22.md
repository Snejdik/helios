# Next22 — Functional Freeze Candidate

## Goal
Next22 closes the broad monitoring feature set before the Simple / Advanced / All UI redesign. Product scope is deliberately narrow at the control boundary: Helios deeply observes macOS and hardware, while the only privileged hardware control remains the already validated fan subsystem.

## Hard safety boundaries
- Battery and charger support is telemetry-only. macOS owns charging policy.
- `Sources/HeliosDaemon/*` stays fan-only and byte-identical to Next21-fixed.
- No new fan/XPC/SMC write primitive is introduced.
- Explicit System selection may begin with the existing cosmetic soft release, but the app now has a bounded 3-second fallback that supersedes a stalled graceful request with the existing immediate restore path. The fallback is cancelled if the user selects another mode or System is confirmed first.
- Unknown raw SMC numeric channels are unitless display-only evidence.
- Runtime Swift sources remain subprocess-free.
- Maintenance scanners inspect only; they do not delete, modify, execute, uninstall or quarantine anything.

## New/expanded observability
### CPU
- Separate CPU module.
- Aggregate user/system/nice/idle utilization.
- Per-logical-core activity.
- Capability-discovered logical/physical/performance/efficiency core topology.
- Load averages and native top-process integration.

### Memory
- Separate Memory module.
- Pressure plus physical/used/available/app/wired/compressed/cache/active/inactive/free breakdown.
- Swap used/total and swap-in/out counters.
- Process memory leaders and persistent trend inputs.

### Battery & power — read-only
- System-normalized SoC for user-facing charge percentage.
- Raw mAh-derived SoC retained separately for expert diagnostics.
- Current/full/design capacity, health, cycles, manufacture date, temperature, voltage/current and signed battery power.
- Adapter/charger voltage/current data when published by AppleSmartBattery.
- Cell voltages and balance when published.
- Independent PSTR Total System Power remains the whole-system source; battery flow is never substituted.

### Per-app history
- Consumes the existing native process-counter stream.
- Aggregates energy, CPU core-seconds, wakeups and peak memory by application/process identity.
- Approximately one persisted aggregate bucket per minute.
- Seven-day bounded retention and malformed/unusable sample rejection.
- All-observed and on-battery leader views.
- Recent 1h vs previous 1h descriptive energy comparison.
- CSV export.
- Missing/inaccessible system processes are not estimated.

### Hardware/system inventories
- Displays: active/asleep, pixel/logical size, refresh, rotation, physical dimensions/scaling metadata where available.
- Mounted volumes: path, filesystem description/UUID, capacity/free, local/removable/internal/network/read-only state.
- USB: native IOKit device inventory.
- Bluetooth: paired/connected state, RSSI and accessory battery fields when macOS already publishes them; no active scan.
- Audio: CoreAudio device/output inventory, output channel counts, sample rate and transport where available. Input-scope properties are intentionally not probed so Helios does not request microphone access merely to inventory devices.
- Sleep blockers: process power assertions that keep display/system awake.
- Network: primary/active interfaces plus gateway, DNS, search domains and interface inventory.
- Clock/calendar: local zone metadata and pinned-zone backend.
- Raw numeric SMC: on-demand, display-only, unitless expert inventory.

### Maintenance observation
- Installed-app inventory with bundle/version, size and Apple Silicon/Intel/Universal Mach-O classification.
- Read-only Cleanup Scout for selected caches and developer artifacts such as Xcode DerivedData/archives/simulator caches and Homebrew cache.
- These operations are on-demand because walking application/cache trees can cause measurable read I/O.

## Persistence and cadence
- Existing telemetry history, I/O audit and health-event stores remain bounded and crash tolerant.
- Per-app history adds a separate bounded NDJSON store at low frequency.
- Heavy inventory operations are not part of the one-second core telemetry loop.
- Optimization of wakeups/CPU/I/O happens after feature freeze and is measured rather than guessed.

## Regression requirements
Run on the target Mac:

```sh
./scripts/check-all.sh
```

The canonical gate includes:
- runtime subprocess policy,
- battery telemetry-only/helper fan-only policy,
- ownership/XPC/Auto/fan safety,
- storage/SMART/CPU/memory/battery/GPU/process/network/Wi-Fi/history/I/O/capability/health/SMC fixtures,
- presentation renders,
- full Xcode Debug build.

After that gate is green, run read-only live probes:

```sh
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --feature-preflight
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --smc-inventory-preflight
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --maintenance-preflight
```

The first two must not write persistence, request notifications, spawn subprocesses, issue fan writes or use the privileged helper. The maintenance probe is also non-mutating but may read filesystem contents/metadata.

## Exit criterion
When Next22 passes the target-M4 regression/build and live preflights, the broad monitoring feature set freezes. Subsequent work reorganizes the same capability model into Simple / Advanced / All UI, then measures and reduces wakeups/CPU/I/O/energy overhead, followed by cross-Mac QA and release engineering.

### Runtime preflight corrections (fixed3)
- Sleep-blocker parsing now follows the public `IOPMCopyAssertionsByProcess` shape: top-level PIDs are `CFNumber` keys and assertion records use `AssertType` / `AssertLevel` / `AssertName` keys. Malformed individual records are ignored without invalidating the whole sample.
- Bluetooth device signal now uses `IOBluetoothDevice.rawRSSI()` for actual perceived dBm. `rssi()` is relative to the controller's golden range and can legitimately return `0`, so it was not suitable for a field labeled dBm. `+127` remains the unavailable sentinel.
- Both corrections are read-only and do not alter fan ownership, fan writes, battery policy, helper privileges, or scan behavior.

- Runtime privacy hardening: the app bundle declares `NSBluetoothAlwaysUsageDescription` for paired/connected Bluetooth inventory. CoreAudio input scope remains intentionally unqueried, avoiding the Hardened Runtime audio-input entitlement and microphone permission surface.
