# Helios - Functional Specification

## Next23 presentation override

The Next22 backend and privileged-control boundaries remain frozen, but the legacy fixed 80-point status item and 380×700 diagnostic popover described below are superseded for Next23 presentation work. Next23 uses user-selectable fixed-geometry menu-bar modules (default CPU + Cooling), a fixed 420×600 internally scrolling Simple / Advanced / All popover, a separate resizable Full Monitor with native sidebar navigation, and a separate Settings window. Live values must never participate in menu-bar sizing. Expert disclosures must not resize the popover. UI preferences must not change telemetry polling, battery policy, XPC fan authorization, SMC write keys, leases, recovery, or the 95°C emergency floor.


## Hardware & Validation Baseline
- Primary target: M4 MacBook Pro, 16 GB RAM, 1 TB SSD, running macOS Tahoe 26.6.2 stable (25G83).
- Local toolchain verified during Phase 1: Xcode 26.6 (17F113), Swift 6.3.3, macOS 26.5 SDK. Use the installed SDK; do not invent a matching 26.6.2 SDK identifier.
- Retain macOS 13.0 as the compatibility floor. Other OS versions and M-series models require independent capability and safety validation.

## Distribution
- Personal use for now; no Mac App Store, ever. May share via direct/notarized download later.
- Local Debug and Release builds require Apple Development signing with the same Team identity for both targets. Developer-specific Team IDs belong in ignored `Config/Local.xcconfig`; the public base configuration stays developer-neutral. Earlier verification records retain only sanitized historical signing references.
- Upgrade to paid Developer ID for notarization/direct distribution. Local compilation and signature validity do not establish that SMAppService will permit registration or launch.
- The installed SDK's `SMAppService.h` documents signing requirements and notarization for apps containing LaunchDaemons. Phase 3 verifies registration separately; local ad-hoc testing reached Requires Approval but does not prove permission to launch a root daemon. No phase bypasses OS approval.

## Core Modules

### 1. Telemetry Provider (Read-Only)
- CPU & Memory via Mach host statistics (`host_statistics64`, `processor_info`).
- Thermals via Apple SMC keys (`sp78`/`fpe2`/`flt` decoding) through `IOKit` (`AppleSMC` service) — dynamic key discovery, no hardcoded Intel-era arrays.
- GPU usage via `IOAccelerator` performance statistics.
- SSD: free/used storage, real-time throughput, NVMe SMART (TBW, wear %).

### 2. Privileged Fan Controller (SMAppService daemon + NSXPCConnection)
- **System**: Apple default fan management.
- **Boost**: 100% RPM takeover, bounded by each fan's SMC-reported maximum.
- **Manual** (internal daemon mode `.override`, explicit opt-in): user-selected RPM within independently daemon-clamped factory limits.
- **Auto**: TG-style cooling rules select normalized fan demand from trusted telemetry. Separate Power Adapter/Battery profiles may target All Fans or individual fans; simultaneous rules resolve to the highest requested percent for each fan. Apple does not retain automatic fan control while Helios owns a fan.
- Telemetry and curve calculations reside in HeliosApp. HeliosDaemon remains the narrow, lease-bound SMC writer with hardware-limit validation.
- Curve engine requires: hysteresis/debounce (no oscillation), dual-rate polling (~2s baseline, 250–500ms once a "watch" threshold is crossed), and an independent heartbeat/staleness check.
- Reacts to sleep/wake via `NSWorkspace` notifications and AC/battery transitions via IOKit power-source notifications (not polling); optional "aggressive curve only on AC" toggle.
- Hard RPM clamping to hardware min/max reported by SMC.

### 3. Battery & Power
- Raw metrics (CoconutBattery parity): design/max capacity (mAh), health %, cycle count, cell temperature, and charger wattage via `AppleSmartBattery`/IOKit. Distinguish charger capability from measured draw.
- **Battery Discharge/Charge**: voltage × signed battery current, with units normalized to watts and direction labeled. This is battery power, not total system demand while connected to AC.
- **Total System Power**: a separately validated unprivileged board/system measurement when available. Next18 probes read-only AppleSMC `PSTR`; otherwise the field is explicitly unavailable. Never substitute battery charging watts or adapter-rated watts.
- **Per-App Resource / Energy Attribution**: sample accessible processes in-process through Darwin/libproc at a conservative ~5-second cadence while telemetry is active. `RUSAGE_INFO_V6` supplies cumulative task CPU time, physical/Neural-Engine footprint, disk I/O, wakeups, instructions/cycles and ARM task/P-core energy counters. Convert only monotonic deltas over a validated interval; protect against PID reuse with `ri_proc_start_abstime`, reject counter rollback, and omit inaccessible processes rather than using the root helper.
- When the kernel exposes `ri_energy_nj` / `ri_penergy_nj`, their deltas may be shown as direct task/P-core watts. These are not Activity Monitor's proprietary Energy Impact score and must never be replaced with a guessed proportional PSTR share. Unsupported rusage flavor/fields remain unavailable.

### 4. History & Alerts
- Rolling in-memory buffer (~60 min) for live graphs: CPU/GPU, temps, RPM, PSTR and network rates.
- Persisted 24-hour history in a lightweight append-friendly versioned NDJSON file, normally paced to one point per ~30 seconds. Compaction is atomic; malformed/truncated tails, wall-clock rollback and long PSTR gaps must never invent history or energy.
- Threshold-based health issues from fresh trusted telemetry. `UserNotifications` permission is requested only after an explicit user action; notifications are edge-triggered when an issue becomes newly active.

### 5. User Interface (Menu Bar)
- Status item: fixed 80-point custom view with two 40-point columns. The left stacks an approximately 8-point CPU caption above an 11-point semibold percentage; the right stacks a thermometer SF Symbol above Max SoC temperature. Monospaced digits and fixed drawing bounds prevent all value-driven width changes.
- Popover: Thermals & Cooling at the top, gauges for CPU/GPU/RAM/Temps, per-fan controls with mode selector, battery/power panel, history graphs, daemon status indicator.
- UI/graphs refresh at 1 second when visible. Process attribution samples at a conservative ~5-second cadence and resolves names/paths only for displayed top-N candidates. The independent thermal control loop retains its ~2-second baseline and 250–500 ms watch cadence.
- Idle performance targets: under 25–30 MB memory and <0.2% baseline CPU; measure actual footprint and wakeups separately. Combined app/daemon memory accounting remains to be confirmed before performance acceptance.

### 6. Graceful Degradation & Compatibility
- macOS version gate: minimum macOS 13 (SMAppService requirement) — clear alert if unsupported.
- Each module independently probes required SMC/IOKit keys at launch/wake; missing or malformed data marks that module "unavailable" with an inline notice — never crashes or blocks other modules.
- XPC client/daemon exchange a protocol version on connect; mismatch reports Reinstall Required and provides an explicit Reinstall action that awaits unregistration before registering again.
- `OSLog` for all failure paths; simple "Copy diagnostics" UI action.

### 7. Failsafe & Watchdog
- Initial control lease: 5 seconds. Only a fresh, completed app calculation based on fresh sensor data renews the lease; a connected client or generic heartbeat is insufficient.
- The daemon independently monitors lease expiration using monotonic time and restores System mode on expiration or XPC disconnect, even if the app's curve engine hangs.
- Daemon crash recovery must restore System on restart. For Phase 4.1 the user explicitly accepted restart recovery after SIGKILL instead of impossible instantaneous cleanup by a dead process. Physical restart recovery must still be validated before enabling a production profile.
- Curve-engine staleness, sleep/wake, and restoration of all affected fan state require independent validation before enabling takeover.
- Clean uninstall: `SMAppService.daemon.unregister()` + removal of installed files.

## Phase 1 Boundary
- Deliver an AppKit Menu Bar app and an embedded LaunchDaemon executable in one Xcode project, with shared base entitlements, Debug/Release configurations, and local build/signature verification.
- Include bundle-contained LaunchDaemon metadata using `BundleProgram` and the intended Mach service identity.
- The app may inspect service registration status. The daemon rejects all incoming connections until authentication and the versioned lease protocol are implemented.
- No telemetry, AppleSMC reads/writes, fan control, curve/lease engine, service registration, or installation in Phase 1.

## Phase 2 Boundary — Read-Only Telemetry Foundation
- Only HeliosApp gains providers: per-processor Mach tick deltas, Mach VM page categories and native kernel memory pressure, AppleSmartBattery raw mAh/cycles/cell temperature/battery power, and dynamically discovered AppleSMC temperatures.
- Temperature decoding in this phase supports signed big-endian `sp78` and little-endian `flt `. M4-family `Tp`/`Te`/`Tg` prefixes classify P-core/E-core/GPU sensor groups; these are empirical grouping hints, not a physical-core inventory. Unclassified temperatures remain outside Max SoC.
- CPU/memory sample approximately every second, thermals independently every 2 seconds, and the UI refreshes every second. Battery sampling uses IOKit power notifications plus a 5-second fallback for current and temperature changes. Sleep pauses sampling; wake resets CPU baselines and reopens/reprobes IOKit/SMC.
- Each provider and individual battery/sensor field reports typed failures. Old successful readings expire from the UI. Missing instantaneous current may use explicitly labeled averaged current; missing raw capacity never falls back to normalized percentages.
- Total System Power remains explicitly unavailable. GPU utilization, storage, attribution, graphs, and performance acceptance are later work.
- No fan reads/writes, daemon IPC, daemon registration, curve calculations, control lease, or privileged operations are added. The existing daemon continues to reject every connection.
- See `PHASE2.md` for reproducible checks, observed hardware capabilities, and validation limits.

## Phase 2.1 Boundary — UI & Presentation Polish
- Replace the plain status string with the fixed-width, two-column widget described above. Keep the native status button's interaction and accessibility behavior.
- Replace diagnostic text blocks with three native cards: Thermals & Cooling, CPU & Memory, and Battery & Power. Use bold titles, subtle dividers, semantic light/dark colors, and secondary breakdown labels.
- Display P-Core, E-Core, and GPU sensor-group averages/maxima. Unknown groups stay outside these summaries; missing groups show unavailable values rather than zero. These are sensor-group statistics, not individual physical-core measurements.
- Keep the popover at 380 points wide, with a 700-point height capped to the available display; allow scrolling on shorter displays. Create its SwiftUI view lazily and update it only while visible.
- Preserve all Phase 2 data acquisition, freshness limits, polling, typed failures, raw capacity semantics, and independent system-power labeling. No fan controls, SMC writes, daemon IPC, service registration, or Phase 3 work.
- Keep generated checks/renders/build logs in ignored `.build` directories and remove identified Helios scratch artifacts from `/tmp`. See `PHASE2_1.md` for verification.

## Phase 3 Boundary — Privileged LaunchDaemon & XPC Handshake
- Add user-triggered install, uninstall, reinstall, and approval-settings actions using `SMAppService.daemon(plistName:)`. Expose Missing / Requires Approval / Installed separately from connection status. Refresh after errors, activation, wake, and while registered; pending approval must not interrupt telemetry.
- Use public macOS 13 NSXPC connection/listener code-signing requirements to authenticate both peers against an Apple anchor, the local signing Team ID, exact app/helper identifiers, and absence of `get-task-allow`, disabled library validation, and DYLD environment exceptions. Validate requirement syntax using Security before passing it to Foundation.
- Shared base entitlements stay empty; disable Xcode's automatic debug entitlement injection. Ad-hoc builds still compile and run telemetry, but secure production IPC reports Signing Required. There is no runtime trust bypass. Personal Team registration/launch remains a separate verification gate when a certificate becomes available.
- Exchange protocol version, session UUID, and nonce over a typed NSXPC interface. Each one-second heartbeat uses the next sequence and a new nonce; the daemon challenges the app in the reverse direction before acknowledging it. The app answers on the main actor and rejects late replies from old connections. Requests time out after two seconds.
- Scaffold a five-second **diagnostic liveness lease** with monotonic time and an independent daemon queue/timer. Expiry, disconnect, and invalid requests disarm the session and invalidate its connection. Only one non-root app session may be active. Hardware control is always disarmed; heartbeat traffic cannot arm or command it.
- Actual fan-state restoration, fan/SMC writes, manual RPM, and the fresh-calculation control lease remain later work. Phase 3 adds no IOKit access to the daemon.
- Verify deterministic lease boundaries, real anonymous NSXPC transport and peer rejection, app reconnect/error handling, simulated registration states, and a bounded live registration/removal probe. Distinguish these checks from an authenticated root-daemon session. See `PHASE3.md` for observed results and limitations.

## Phase 4 Boundary — Fan Control Engine & Safety Policies
- Add an independent unprivileged fan provider using `FNum`, per-fan `Ac`, `Tg`, `Mn`, and `Mx`. Decode `fpe2` and `flt ` with finite-value/size checks; zero RPM and zero fans are valid. Keep failures per field and expire stale display values.
- Shared SMC code remains read-only. A daemon-only transport writes discovered per-fan mode (`Md`/`md`) and target (`Tg`) keys. Re-read limits before every calculation, clamp each fan separately, reject non-finite/unsupported values and existing foreign manual ownership, and read back accepted mode/target values.
- System clears owned manual modes and target overrides. Boost requests the validated factory maximum. On the current production Mac16,1/25G83 profile, Override applies a user-selected target that the daemon independently clamps/quantizes to 2317–6550 RPM; moving the slider waits for a new completed thermal batch before writing. Explicit user System release may use a cosmetic soft ramp, while stale telemetry, expiry, disconnect, shutdown, sleep, and recovery restore immediately.
- The old fixed Auto Max pilot is superseded by Next15 Auto Rules. Rules support Power Adapter/Battery profiles, All Fans/per-fan targets, 0–100% MIN→MAX mapping, Always/Any Sensor/Average CPU/Highest CPU/Max SoC/P-Core/E-Core/GPU/Battery and individual trusted SoC sources, 0.5 s engage debounce, 3°C release hysteresis and 3 s release debounce. Upward cooling changes are immediate; only downshifts may use the user transition duration. Unknown/unclassified SMC keys are never rule inputs.
- Trusted Max SoC >=95°C is a non-configurable emergency floor: the app demands 100%, and independently the privileged coordinator coerces every accepted fresh Manual/Auto calculation at or above 95°C to Boost/factory max. Emergency release requires <=88°C for five seconds. This preserves the safety lesson from the earlier Minecraft pilot while allowing richer user rules below the hard floor.
- Protocol v3 keeps typed scalar calculation/release/status methods and adds only a graceful/immediate boolean to System release. Require a fresh original `mach_continuous_time` acquisition timestamp and increasing control sequence; reject samples more than three seconds old, future samples, and repeats. The steady control lease expires after five seconds; the validated initial M4 acquisition has a separate hard 12-second transaction bound. Diagnostic heartbeats cannot extend either lease.
- Run lease revocation on a queue independent of driver calls. Recheck the permit before/after writes, serialize hardware operations, reject overlapping calculations, and roll back partial updates. A stalled kernel call cannot be interrupted by Swift; subsequent writes are cancelled and restoration runs as soon as the driver permits it.
- A root-owned, locked, non-symlink recovery journal records potentially touched fan IDs before writing. Clear it only after all automatic modes are confirmed. Startup attempts journal recovery before allowing new requests. Graceful SIGTERM/SIGINT and native system-sleep notifications request restoration; launchd requests restart after unsuccessful exits.
- No process can execute cleanup after SIGKILL or a crash, and launchd restart has scheduling/throttling delays. Immediate physical restoration therefore remains an unfulfilled hardware-validation gate. No production control profile is enabled in this phase; no UI/environment/XPC bypass is provided. Ad-hoc builds continue to reject production IPC independently of this gate.
- Integrate fan readouts and System/Boost/Manual/Auto selection into Thermals & Cooling. Manual exposes the validated slider; Auto exposes editable TG-style cooling rules with separate adapter/battery profiles and rule transition controls. Present accepted control state separately from requested mode. Disable unavailable controls and preserve a System-restoration action when state is uncertain.
- Verify simulated writes, clamping, rollback, journal recovery, expiry despite live heartbeats, stale-sample replay rejection, disconnect cleanup, native UI layouts, strict Swift 6 builds, and read-only fan access on the target Mac. Physical writes, forced-kill recovery, and signed privileged end-to-end control remain unverified. See `PHASE4.md`.

## Phase 4.1 Boundary — Controlled Physical Validation
- Physical testing was explicitly authorized for this exact M4 MacBook Pro / macOS 26.6.2 (25G83), one fan, 2317–6550 RPM factory bounds. Keep signing, peer authentication, clamping, leases, journal, rollback and readback unchanged; no factory-limit writes, arbitrary SMC writes or firmware unlock/test modes.
- The first 3000 RPM trial reached the installed root daemon but SMC rejected `F0Md` (`ui8 `, value 1) with result `0x82`. Testing stopped under the user's explicit stop-on-rejection contract. Final readback was automatic mode 3, target 0, actual 0, with unchanged factory limits.
- No production hardware profile is enabled. Additional RPM, Boost, active-control disconnect/termination and startup-recovery tests were not performed. Temporary validation allowances were removed. See `PHASE4_1.md` for exact transactions and remaining limits.

## Next19 system/network/history boundary
- System and network telemetry remain entirely unprivileged and read-only. System identity/load/uptime use Foundation/Darwin in-process APIs; network primary-interface/address discovery uses SystemConfiguration and link counters use `getifaddrs` AF_LINK data.
- Public `if_data` byte/packet counters are 32-bit volatile statistics. Rate calculations must handle modulo-2^32 rollover, reset/warm up when the primary interface changes, reject invalid sampling intervals, and must not label those counters as lifetime traffic totals.
- Battery time remaining comes only from `IOPSGetTimeRemainingEstimate`. Preserve its unknown/calculating and unlimited/on-AC states; never infer time remaining from a single instantaneous battery-power sample.
- Live history is bounded to 3,600 roughly one-second in-memory points. Session Wh may integrate only consecutive valid independent PSTR readings with a short bounded gap; sleep/stale/unavailable intervals are excluded rather than interpolated.
- Next19 history is intentionally non-persistent. Do not add a database or background write loop merely to claim long-term history.
- The network/system/history milestone must not alter `Sources/HeliosDaemon/*`, XPC fan-control messages, ownership leases/journal recovery, fan bounds or the independent 95°C emergency floor.

## Next21 Boundary — I/O attribution, persistent trends and capability discovery
- Keep three storage-accounting layers explicitly separate: whole-device IOBlockStorage counters/rates, libproc per-process I/O, and Helios' own process I/O. Never claim process totals must equal physical device traffic; APFS metadata, VM paging, cached writeback and kernel work can legitimately create a gap.
- Track whole-device primary-storage read/write deltas since the current Helios process first observes the device. A device change or counter rollback resets that baseline rather than producing a spike. Boot-average rates may divide boot-scoped counters by verified system uptime but remain labelled as boot averages, never lifetime wear/TBW.
- Keep per-process session I/O keyed by PID plus `ri_proc_start_abstime`, preserve only monotonic valid deltas, bound ledger growth, and never use the privileged helper to inspect inaccessible tasks. Preserve direct `RUSAGE_INFO_V6` task/P-core energy semantics and keep process rates on the conservative cadence.
- Persist a best-effort 24-hour I/O audit in `io-activity-v1.ndjson` at roughly 30-second cadence. Retain at most 3,000 records, reject unordered/device-handoff/rollback gaps from physical delta integration, compact malformed tails before future appends, and treat all filesystem errors as observability-only.
- Expand `history-v1.ndjson` with battery health/signed power/AC/temp/cycles, NVMe lifetime counters, storage/process rates, and Helios CPU/power/memory/wakeups. PSTR and signed battery-energy integration must remain gap-safe; NVMe lifetime deltas must reset on device/counter changes.
- Keep a seven-day bounded `health-events-v1.ndjson` activation/resolution history. Notification permission remains opt-in; refreshing authorization when the card appears may update UI state but must never change fan-control decisions.
- Expose a read-only hardware capability matrix for major providers. A successful fan telemetry/profile check is diagnostic evidence only and must never bypass the existing pinned daemon production-write gate.
- `--io-preflight` is read-only: it may warm live delta providers in memory and print device/process/network attribution, but must not write persistent history/audit files, request notification permission, issue fan writes, spawn subprocesses, or route telemetry through the root daemon.
- Next21 must not modify the validated `Sources/HeliosDaemon/*`, fan-control model/Cooling Rules/DaemonClient, shared fan/XPC trust types, or `SMCClient` write surface.

## Next22 Boundary — Functional freeze, broad read-only observability
- Product scope is detailed macOS/hardware observability plus the already validated fan-control subsystem. The privileged daemon remains fan-only. Battery/charger data is read-only; macOS alone owns charging policy. No battery/charger-control XPC method, SMC write, IORegistry write, or policy override is permitted.
- Split CPU and Memory into independent domain models. CPU reports aggregate/per-core activity and capability-discovered logical/physical/performance/efficiency topology. Memory reports VM-derived app/wired/compressed/cache/active/inactive/free/available values, pressure, swap usage and swap-in/out counters with failure isolation.
- Battery presentation must distinguish normalized system SoC from raw mAh-derived SoC. Retain raw/design/full/current capacity, health, signed power, voltage/current, adapter/charging telemetry, cell voltages/balance, cycle/manufacture data and history only as read-only diagnostics. Unknown or unavailable fields remain unavailable.
- Add native, unprivileged inventories for displays, mounted volumes, USB, Bluetooth, CoreAudio devices, sleep-blocking power assertions, route/DNS/interface data and clocks. Hardware APIs may fail independently; no one provider may make the overview unavailable.
- Installed-application and cleanup inventories are explicit/on-demand maintenance observations. They may inspect file metadata/sizes but never delete, mutate, quarantine, uninstall or execute discovered content. `--maintenance-preflight` is read-only but may generate filesystem read traffic.
- Persist bounded per-app energy/CPU/wakeup/peak-memory aggregates at roughly one-minute cadence for at most seven days using the existing native process-counter stream. Aggregate by stable application identity when possible; keep system/inaccessible-process gaps explicit. Absolute process energy remains descriptive, not billing-grade, and must not be conflated with PSTR whole-system energy.
- Provide CSV export and recent-hour vs previous-hour descriptive trends without inventing missing samples. Sleep/offline/invalid-delta gaps are not interpolated.
- On-demand raw numeric SMC inventory is expert/display-only and unitless unless a key is explicitly characterized. It cannot become a trusted thermal input, health threshold, Cooling Rule source, or privileged write target merely by being numeric.
- Heavy inventories and long-term attribution must use conservative cadence/on-demand execution. Next22 correctness is prioritized first; wakeup/CPU/I/O minimization is a separate post-feature-freeze optimization pass measured using Helios' own process telemetry.
- `--feature-preflight` and `--smc-inventory-preflight` perform no persistent writes, notification prompts, fan writes, subprocesses or privileged telemetry. The battery read-only policy is enforced by `scripts/check-battery-readonly.sh` inside the canonical `check-all.sh`.
- Next22 must leave `Sources/HeliosDaemon/*`, fan-control models/Cooling Rules/DaemonClient, shared fan/XPC trust types and `SMCClient` byte-identical to the validated Next21-fixed baseline.

