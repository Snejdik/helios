# Helios

A native Swift macOS Menu Bar observability and fan-control utility. The pinned `Mac16,1` / macOS build `25G83` fan profile has passed authenticated production **Boost**, validated-range **Manual**, TG-style **Auto Cooling Rules**, crash/restart recovery, real sleep/wake restoration, ownership journaling, a hard 95°C emergency floor, and pre-emptible System release. The privileged helper is intentionally **fan-only**.

The unprivileged app now combines the monitoring surface normally spread across several utilities: thermal/SMC telemetry, CPU and Memory as independent modules, GPU, battery/power diagnostics, network/Wi-Fi, processes, per-app energy history, NVMe SMART and physical/process I/O attribution, storage/volumes, displays, USB, Bluetooth, audio, sleep blockers, system/capability diagnostics, persistent health/history, clocks, installed-application inventory, and a read-only Cleanup Scout. Next22 is the broad functional-freeze candidate before the planned Simple / Advanced / All UI redesign.

**Battery policy boundary:** Helios observes battery state but never changes charging behavior. macOS owns charging policy. Battery/charger values are read-only telemetry and the privileged helper exposes no battery-control path.

The primary validation target is an M4 MacBook Pro running macOS Tahoe 26.6.2. The project preserves a macOS 13.0 deployment floor; compatibility on other releases and Mac families is capability-discovered but still requires physical validation.

## Build

Open `Helios.xcodeproj` and select the shared **HeliosApp** scheme. Building the app also builds and embeds **HeliosDaemon**. No package manager, project generator, or external dependencies are required.

Debug and Release use `Apple Development` signing with Personal Team `3J76KPDS9C`, shared by both targets through `Config/Base.xcconfig`:

```sh
xcodebuild -project Helios.xcodeproj -scheme HeliosApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build
```

Use `-configuration Release` for the optimized build. The application is produced at `.build/DerivedData/Build/Products/<configuration>/Helios.app`.

The Team ID was confirmed against the installed certificate's subject OU and Xcode settings. To use another local development team, copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig` and enter its verified Team ID. Builds require a matching signing identity in the login keychain. Developer ID signing and notarization are reserved for later distribution work.

Secure helper communication requires an Apple-signed Team identity and rejects debugger/injection exception entitlements. Ad-hoc builds display **Signing Required** if the helper becomes eligible to run. Automatic debug entitlement injection is disabled; for a Team-signed run, launch the app directly or turn off **Debug executable** in the scheme. Registration and OS approval remain separate from signing and build success.

Signing verified on 2026-09-06: Debug and Release builds in `.build/DerivedData` succeeded. `codesign -dv --verbose=4` reports `TeamIdentifier=3J76KPDS9C` and `Authority=Apple Development: jakub.snejda@icloud.com (9249C7D2K3)` for each `Helios.app` and its `Contents/Library/HelperTools/HeliosDaemon`. All four artifacts pass strict signature validation and the existing XPC signing requirements, with hardened runtime enabled and empty entitlements. Verification ran outside the development sandbox so macOS trust services were accessible; full signature output is retained under `.build/Verification/signing-{Debug,Release}-{app,daemon}.log`.

## Structure

| Location | Responsibility |
| --- | --- |
| `Sources/HeliosApp` | Fixed-width AppKit status widget and thermals-first native SwiftUI cards |
| `Sources/HeliosApp/Telemetry` | Independent Mach, battery, and read-only AppleSMC providers; typed samples and polling |
| `Sources/HeliosDaemon` | Authenticated XPC, SMC writer, independent control lease, ownership journal, and lifecycle recovery |
| `Sources/Shared` | Read-only SMC transport, typed samples/fan models, host clock, XPC interfaces, and signing requirements |
| `Config` | Shared build settings and base entitlements, Debug/Release configurations |
| `Resources` | App/daemon Info.plists and bundle-contained LaunchDaemon plist |
| `docs/SPEC.md` | Approved functional foundation and boundaries between phases |
| `Tests`, `scripts` | Provider/presentation checks, native renders, registration fixtures, and isolated NSXPC/watchdog verification |

Launch the built app to see the fixed 80-point CPU/temperature menu-bar widget. The current pre-redesign popover deliberately exposes the complete engineering surface: **CPU** and **Memory** are separate modules; CPU includes aggregate/per-core activity plus logical/physical/P/E topology, while Memory includes pressure, app/wired/compressed/cache/free accounting and swap counters. Additional cards cover P/E/GPU thermals plus trusted/raw sensor browsing, GPU activity/memory, battery and adapter/cell diagnostics, independent `PSTR` Total System Power, Network/CoreWLAN plus route/DNS/interface detail, native per-process CPU/energy/memory/I/O/wakeups, seven-day per-app energy attribution and trends, NVMe SMART/physical I/O, mounted volumes, displays, USB/Bluetooth/audio-output inventory, sleep blockers, system/capability detail, clocks, and persistent health/history. Heavy application/cache inventory is on-demand. Missing and stale readings remain explicit rather than guessed.

Battery charge percentage now prefers the same normalized system state-of-charge source macOS publishes, while raw mAh-derived SoC remains separately available as expert diagnostics. Signed battery power, cell/adapter telemetry and history are observational only; they never alter charging policy and are never substituted for independent board/system power.

All telemetry, including fan count/current/target/min/max RPM, runs unprivileged in the app. **Thermals & Cooling** presents **System / Boost / Manual / Auto**. Boost still resolves inside the root daemon to exactly 6550 RPM. Manual exposes a 50-RPM-step slider, while the privileged daemon independently clamps and quantizes every request to the validated 2317–6550 RPM range. Auto adds separate Power Adapter/Battery rule profiles, All Fans/per-fan targets, 0–100% relative MIN/MAX speed, TG-style Any Sensor/Always/Average CPU/Highest CPU sources, trusted group/individual sensors, rule copy/reorder/persistence, highest-speed-wins evaluation, hysteresis/debounce, and safe downshift transitions. A fresh trusted Max SoC >=95°C forces factory-max cooling in the privileged coordinator even if Manual/Auto asks for a lower target.

The **Helper Service** card provides Install Helper, Uninstall, Reinstall, and Open System Settings actions with separate registration and connection status. Protocol v3 requires Reinstall if an older helper is registered; v3 adds an explicit graceful/immediate release flag without exposing SMC details. On a clean startup the daemon first runs recovery, then a read-only exact-profile gate. It does not construct the production SMC writer until an authenticated fresh control calculation actually arrives. The production writer is pinned to `Mac16,1` / `25G83` / fan 0 and its complete write allowlist is `Ftst` 0/1, `F0Md` 0/1, and `F0Tg` as an integral target inside 2317–6550 RPM. Factory min/max keys, another fan, raw bytes, and out-of-range targets are not representable through this path. See [Phase 4.6](docs/PHASE4_6.md) and [Phase 4.7](docs/PHASE4_7.md).

The typed helper protocol is v3 (introduced in Next14), so an older registered helper must be reinstalled before this build can connect. After reinstall, `check-ipc.sh` and the installed-helper verification should confirm the v3 handshake and repeated heartbeats. Reinstall waits for process termination and stable removal status before registering, addressing an observed Tahoe Background Task Management race. Before rebuilding a registered bundle, quit Helios and run the Debug app executable with `--unregister-helper`; after building, run it with `--reinstall-helper`, then launch normally. Use `--verify-installed-xpc` with the normal app closed for a twelve-second production connection check. Exact evidence and commands are in [the live Phase 3 repair record](docs/PHASE3.md#live-production-repair--2026-09-06).

## Telemetry checks

```sh
./scripts/check-all.sh                # Canonical full regression gate + Xcode Debug build
./scripts/check-runtime-policy.sh     # Reject subprocess/spawn APIs in runtime Swift sources
./scripts/check-battery-readonly.sh   # Enforce telemetry-only battery scope and fan-only helper
./scripts/check-telemetry.sh          # Deterministic fixtures; no hardware access
./scripts/check-telemetry.sh --live   # Also reads this Mac as the current user
./scripts/check-storage.sh            # Focused storage parser/rate fixtures
./scripts/check-storage.sh --live     # Read-only IOKit inventory/counters on this Mac
./scripts/check-presentation.sh      # Fixed-width checks and light/dark fixture renders
./scripts/check-ipc.sh               # Unprivileged anonymous XPC, trust rejection, lease and registration checks
./scripts/check-ownership.sh         # Fast ownership/recovery + Phase 4.6 Boost/Override-gate fixtures
./scripts/check-fans.sh              # Full simulated fan suite: rollback, recovery, leases, thermal policy
./scripts/check-fans.sh --live       # Also reads this Mac's fans; never writes physical hardware
```

These development scripts compile standalone Swift check binaries; Helios never launches scripts or subprocesses. Because each broad script invokes `swiftc` independently, the full fan/telemetry/IPC/presentation set recompiles overlapping sources and is intentionally slower than an incremental Xcode build. During Phase 4.x iteration, run the focused `check-ownership.sh` plus an incremental `xcodebuild`; reserve the full four-script regression sweep for phase/milestone checkpoints or changes that touch those subsystems. Do not delete `.build/DerivedData` for normal incremental builds unless diagnosing a stale build. After a Debug build, `Helios.app/Contents/MacOS/Helios --fan-preflight` prints the current Mac16,1 ownership capability baseline without compiling another checker or writing SMC state.
`Helios.app/Contents/MacOS/Helios --storage-preflight` prints the read-only physical-storage/controller baseline and now attempts one native NVMe SMART health-log read. When supported it includes health, wear, lifetime read/write, temperature and lifetime counters; failures stay typed and do not fall back to pretending since-boot counters are TBW. See [Phase 5](docs/PHASE5.md).
`Helios.app/Contents/MacOS/Helios --performance-preflight` reads GPU PerformanceStatistics, Total System Power (`PSTR`), swap, and battery voltage/current/adapter fields as the normal user. It performs no fan writes and uses no subprocesses. See [Phase 6](docs/PHASE6.md).
`Helios.app/Contents/MacOS/Helios --utility-preflight` validates the Next19 native SystemConfiguration/getifaddrs network layer, system/load/uptime fields and IOPowerSources battery time-remaining state. It is read-only, unprivileged and performs no fan writes or subprocesses. See [Phase 7](docs/PHASE7.md).
`Helios.app/Contents/MacOS/Helios --observability-preflight` validates Next20 per-core CPU, CoreWLAN radio telemetry and native libproc `RUSAGE_INFO_V6` process counters on the current Mac. The probe intentionally performs no fan writes, notification prompt, persistent-history write, subprocess execution, or privileged telemetry.

AppleSMC and anonymous NSXPC may be blocked inside a development-tool sandbox. Run live/IPC checks from a normal user terminal; they reject root execution. `check-ipc.sh --build-only` compiles without opening a listener.

See [Phase 4.5](docs/PHASE4_5.md) for the recorded physical ownership, crash-recovery and sleep/wake evidence, [Phase 4.6](docs/PHASE4_6.md) for production Boost/Manual evidence, and [Phase 4.7](docs/PHASE4_7.md) for Next15 Cooling Rules. [ROADMAP.md](docs/ROADMAP.md) tracks overall product progress.

### Current fan-control gate (Next15)

Boost, Manual target changes, explicit soft System release, SIGKILL recovery and sleep/wake pre-emption are physically green on the pinned `Mac16,1` / `25G83` profile. Production writes remain restricted to `Ftst` 0/1, `F0Md` 0/1 and integral `F0Tg` 2317–6550 RPM.

Next15 does **not** add a new root write API for Auto. The unprivileged Cooling Rules engine converts rules into the already validated Manual/Boost calculations from fresh telemetry. Separate Power Adapter/Battery profiles are persisted, but the control mode never is: every app launch starts in System. Manual/Boost failures require explicit re-selection; an already-selected Auto policy may remain armed after a transient failure only when the daemon has independently verified clean System restoration, and it retries from a later fresh thermal batch after a bounded backoff.

TG-style rule behavior includes All Fans or a specific fan, 0% = factory minimum / 100% = factory maximum, Any Sensor, Always, Average CPU, Highest CPU, trusted SoC groups and individual trusted sensors, highest-active-percentage wins, copying/reordering, and smooth downshifts. An `SSD` source appears automatically when native NVMe SMART temperature is successfully available; unsupported controllers simply omit it.

Helios adds a stricter safety envelope: missing/stale telemetry returns System, upward cooling transitions are immediate, and trusted Max SoC >=95°C is forced to factory max in the privileged daemon regardless of a lower Manual/Auto request. Safety releases still bypass all cosmetic transitions.

### Next15-fixed compile correction

`FanControlView.controlLabel` now explicitly returns its `switch` expression after the Auto early-return branch. This fixes the Swift 6 `string literal is unused` warnings-as-errors seen by `check-presentation.sh` and the full Xcode build. No fan policy, XPC surface, privileged writer behavior, lease, journal, or SMC write path changed.


### Next15-fixed2 Auto Rules reliability
- `Always` is unconditional and shows no temperature threshold.
- Auto can always be reopened while the validated helper/telemetry are available, even if one power profile has zero rules. An empty profile means System control.
- A transient acquisition failure that has already restored System disarms Auto/Manual/Boost but does not permanently disable the Auto editor; the user may explicitly reselect the mode and retry.

### Next15-fixed3 IPC harness reliability
`check-ipc.sh` no longer reports an opaque `FAIL: timeout` when asynchronous anonymous-XPC/main-actor propagation is delayed on a busy development Mac. Harness-only state waits now allow 5 seconds and carry a precise stage label. Product deadlines (diagnostic lease expiry, fan-control lease expiry, app control timeout, and hung callback timing) are unchanged and remain asserted independently; there is no retry-on-failure and no runtime/XPC behavior change.


### Next15 fixed4: recoverable acquisition retry

A recoverable fan acquisition/hardware failure that is followed by independently verified System restoration now re-arms the control lease gate **without clearing sample/sequence history**. The reset uses a dedicated recovery generation: if sleep, disconnect, expiry, or another safety revocation races hardware cleanup, that newer generation wins and recovery completion cannot re-arm control. This allows only a later genuinely fresh calculation to retry while stale/replayed calculations remain rejected. The fan/IPC regressions cover failure → clean System → fresh Manual retry and the concurrent-revocation race.

### Next15 fixed5 audit note

Fixed5 separated accepted/pending XPC commands from daemon-confirmed fan ownership
and repaired several Auto/UI lifecycle races. That version still treated every live
rule edit as a reason to cancel an in-flight takeover and return through System; live
hardware testing later proved that policy too churn-heavy for an interactive rules
editor. Fixed7 replaces that reconfiguration behavior with stable same-ownership
updates described below. `Always` remains available independently of dynamic sensor
discovery, inactive power-profile edits do not interrupt the live profile, sleep
invalidates fan/thermal control state immediately, and notification-driven charger
changes publish immediately.

### Next15 fixed6: Swift 6 semantic build fix and audit

The Fixed5 Auto Rules state-machine hardening was correct at runtime but introduced
one Swift 6 compile error: a stored `@Published` property initializer referenced
`Self.baseRuleSensorOptions`. Swift rejects covariant `Self` from stored-property
initializers even on a final class. Fixed6 declares the property without a default
and initializes it explicitly in `FanControlModel.init`, preserving the invariant
that `Always` is available before dynamic thermal discovery.

As part of this fix, the complete Sources/Tests/Tools tree was parsed with Swift
6.2, all shell scripts were syntax-checked, the Xcode project plist was validated,
and the CoolingRules + FanControlModel unit was independently type-checked under
Swift 6 strict warnings using a minimal local compatibility harness. No daemon,
SMC write allowlist, lease, recovery, or fan safety behavior changed.

### Next15 fixed7: Auto Rules stabilization freeze

Live testing showed that the remaining instability was architectural rather than an
SMC regression: every Stepper/menu edit in the active Auto profile intentionally
cancelled acquisition, revoked the lease, restored System, and then tried to
reacquire on a later sample. Because Mac16,1 may spend several seconds in bounded
F0Md arbitration, normal editing could repeatedly pre-empt the transaction.

Fixed7 changes Auto into a persistent policy state:

- editing a live matching rule no longer releases ownership or cancels acquisition;
  the newest configuration is compiled on the next fresh 500 ms thermal batch;
- if ownership is already confirmed, the new rule becomes a normal F0Tg target
  update with no Ftst/F0Md reacquisition;
- if acquisition is still in flight, it is allowed to finish, then the next fresh
  sample applies the newest target; if the edit removes all demand, that next fresh
  sample performs one verified System release;
- a transient hardware/acquisition failure that has already restored clean System
  keeps the explicitly selected Auto policy armed, waits a two-second backoff, and
  retries only from newer telemetry; Manual and Boost still disarm on failure;
- rule rows distinguish a matching policy from confirmed hardware control, and the
  Auto header reports waiting/acquiring instead of implying ownership;
- Add Rule now explicitly offers an **Always Rule** so unconditional rules are
  discoverable without knowing that option is inside the sensor menu.

Power-source ambiguity/changes, stale telemetry, disconnect, sleep, shutdown,
recoveryRequired, and no-matching-rule behavior remain fail-closed to System. The
privileged writer and its SMC allowlist are unchanged.

### Next17 Step 2: native NVMe SMART + richer storage telemetry

The unprivileged app enumerates whole physical storage through IOKit and reports device/controller identity, root capacity, throughput, IOPS and boot-scoped driver counters. For NVMe devices that advertise SMART, Next17 opens Apple's native `IONVMeSMARTInterface` plugin as the normal user and calls only the read-only SMART health-log function. The 512-byte NVMe log is parsed for Critical Warning, temperature, spare/threshold, Percentage Used, lifetime Data Units Read/Written, host commands, busy time, power cycles/hours, unsafe shutdowns, media errors and error-log entries. Lifetime bytes use the NVMe 512,000-byte data-unit definition. SMART is cached for 30 seconds and remains isolated from the privileged fan daemon. Boot-scoped IOBlockStorage counters are still never mislabeled as lifetime TBW.

### Next17 fixed2 validation hardening

`Tests/FanChecks.swift` now uses the suite's existing `require(...)` assertion helper for the SSD Cooling Rules checks; the previous accidental `check(...)` calls prevented only the focused fan test from compiling even though the production Xcode target built successfully. A new `scripts/check-all.sh` runs ownership, IPC, fan, storage, telemetry, presentation, and the full Xcode Debug build as one pre-handoff regression gate. It is simulation/read-only only and performs no physical fan writes.

### Next17 compatibility hardening

Swift 6 does not import `kIOCFPlugInInterfaceID` from `IOCFPlugIn.h` because the C macro expands to a Core Foundation UUID object. Helios constructs the exact public `C244E858-109C-11D4-91D4-0050E4C6426F` UUID explicitly and regression-tests all three UUIDs used by the NVMe SMART plugin path. The native reader also accepts both read-only health-log entry points exposed by `IONVMeSMARTInterface`: `SMARTReadData`, with a `GetLogPage(0x02)` fallback. No storage write/admin mutation command is added.

### Next18 Step 1: GPU, swap and whole-system power

Next18 adds an unprivileged IOKit GPU provider for Device/Renderer/Tiler utilization, model/core count when exposed, and mapped/in-use unified memory. Memory gains native `vm.swapusage` (`xsw_usage`) used/total values. Battery telemetry gains independent voltage/current, raw-capacity charge percentage, adapter rated wattage and charging state. Total System Power is no longer inferred from battery flow: Helios probes the separate read-only AppleSMC `PSTR` board/system rail and shows a typed unavailable state if that source is missing or malformed. No daemon/XPC/fan-write surface changes are made. `--performance-preflight` is the dedicated live read-only validation command.


### Next19 Step 1: system, network and live history

Next19 adds a native read-only SystemConfiguration/getifaddrs network provider (primary interface, IPv4/IPv6, link/MTU, throughput, packets and errors), a system-information provider (model/chip, OS, uptime, 1/5/15-minute load, thermal state and Low Power Mode), IOPowerSources battery time remaining, and an in-memory 3,600-point live history. History plots CPU/GPU/Max SoC/PSTR/fan/network values and integrates session Wh only across short consecutive valid PSTR intervals. Storage UI also exposes additional already-parsed NVMe SMART and boot-scoped operation/error fields. `--utility-preflight` is the dedicated live read-only validation command. No daemon, fan/XPC control, SMC write, lease, journal or 95°C emergency behavior is widened.


### Next20 Step 1: observability, persisted history and health

Next20 is a large unprivileged observability milestone. CPU telemetry keeps the existing aggregate Mach accounting and adds per-logical-CPU deltas. A native libproc provider samples accessible processes at a conservative five-second cadence and reports CPU activity, physical/Neural-Engine footprint, disk I/O, wakeups, instruction/cycle rates, IPC, and direct task/P-core energy counters when `RUSAGE_INFO_V6` is available. Inaccessible processes are omitted rather than escalated through the privileged helper, and PID reuse/counter rollback reset rate calculation. Process names/paths are resolved only for the final top-N union to avoid broad string lookups on every sample.

CoreWLAN adds best-effort Wi-Fi SSID plus RSSI/noise/SNR, TX rate/power, channel/band/width, PHY and security without automatically requesting Location permission. Persistent telemetry is an append-friendly, versioned NDJSON file under `~/Library/Application Support/Helios/`, paced to about one sample per 30 seconds and retained to 24 hours/3,000 points. It is gap-safe for PSTR energy, atomically compacts stale or malformed records, and treats all filesystem failures as observability-only. Health evaluation watches trusted fresh thermal/memory/battery/NVMe states; notifications are never requested automatically and can only be enabled by explicit user action. Unknown raw thermal sensors remain display-only and never enter fan safety/Cooling Rules. Physical external drives are shown separately while virtual Disk Images are filtered.

`--observability-preflight` is the dedicated live read-only Next20 hardware probe. The entire `Sources/HeliosDaemon` tree plus fan-control model, Cooling Rules, shared fan/XPC trust types and `SMCClient` remain byte-for-byte unchanged from the validated Next19-fixed baseline. See [Next20](docs/NEXT20.md).


### Next21: I/O attribution, persistent trends and capability report

Next21 separates whole-device IOBlockStorage traffic from native libproc process accounting and from Helios' own process footprint. The Storage card can show since-Helios physical deltas, boot-average device traffic, process-accounted rates/current leaders, 24-hour observed physical traffic and native NVMe lifetime-counter deltas without claiming those independent accounting layers must reconcile 1:1. A crash-tolerant `io-activity-v1.ndjson` audit (approximately 30-second cadence, 24-hour retention) can be copied or exported as CSV.

The process provider keeps a bounded PID-start-time keyed session ledger for current/session reader and writer attribution and explicitly measures Helios CPU, task power, RAM, wakeups and disk I/O. Persistent history adds battery energy/temperature/health/cycles, NVMe lifetime deltas and Helios overhead summaries. Health transitions are retained locally for seven days, notification authorization refreshes when the card is shown, and a System-card capability matrix reports major read-only providers without weakening the separate fan-write production gate. `--io-preflight` is the dedicated read-only Next21 hardware probe. See [Next21](docs/NEXT21.md).
### Next22: functional-freeze observability sweep

Next22 separates CPU and Memory into independent modules; adds physical/P/E CPU topology, richer VM/swap accounting, normalized system battery SoC plus raw battery/cell/adapter diagnostics, route/DNS/interface data, display/volume/USB/Bluetooth/audio-output inventories, sleep-blocking power assertions, clocks, installed-app architecture/size inventory, a read-only Cleanup Scout, bounded seven-day per-app energy history with CSV export and recent-vs-previous trends, and an on-demand display-only raw numeric SMC inventory. Expensive inventories are on-demand/slow-cadence. Battery telemetry is strictly read-only and the privileged helper remains fan-only.

After a green `check-all.sh`, useful read-only live probes are:

```sh
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --feature-preflight
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --smc-inventory-preflight
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --maintenance-preflight
```

`--maintenance-preflight` intentionally performs filesystem metadata/content inspection for application/cache inventory and can create noticeable read I/O; it still performs no cleanup or deletion.

