# Helios - Agent Guidelines

## Role & Mission
You are building **Helios**, a lightweight, high-performance macOS Menu Bar system monitoring and fan control utility written natively in Swift.

## Strict Engineering Constraints
- **Language & Stack:** Pure Swift (Swift 5.9+ / Swift 6), AppKit / SwiftUI for UI, native system APIs.
- **No External CLI Spawning:** Never use `Process()` or shell invocations (`top`, `sysctl`, `sudo`, `powermetrics`, `pmset`) for runtime metrics or fan control. All operations must use native C/Darwin APIs, Mach kernel calls, or IOKit.
- **Privilege Separation:** 
  - UI runs as an unprivileged Menu Bar app.
  - SMC fan write operations must be delegated to a privileged LaunchDaemon registered via `SMAppService` (macOS 13+).
  - Communication happens strictly via `NSXPCConnection`.
- **Primary validation target:** M4 MacBook Pro running macOS Tahoe 26.6.2 stable (25G83). Use the installed macOS SDK; the SDK version need not match the host patch version. Retain macOS 13.0 as the compatibility floor, without claiming validation on other hardware or releases.
- **Code Style:** Idiomatic Swift, clean modular separation (Data Source / Telemetry / IPC / UI), thread-safe concurrency (Swift Concurrency `async`/`await` or dedicated dispatch queues).
- **Error Handling:** Graceful degradation. If sensors cannot be read or permissions are missing, present a clean empty/fallback state rather than crashing.

## Next22 Functional-Freeze Boundary
- Helios is an OS/hardware observability utility plus the already validated fan-control subsystem. The privileged helper remains **fan-only**.
- Battery support is telemetry-only. macOS owns charging policy. Do not add any battery/charger control path, battery SMC/IORegistry writes, or XPC method that can alter battery/charger state. `scripts/check-battery-readonly.sh` is a mandatory regression gate.
- Preserve the validated fan-control write surface exactly: no new daemon/XPC/SMC primitives, no broader model profile, and no coupling between monitoring/maintenance features and fan-control authorization.
- Next22 may broaden read-only observability aggressively: CPU topology, separate Memory accounting, process/app energy history, battery diagnostics, network route/DNS/interface detail, displays, mounted volumes, USB, Bluetooth, audio, sleep assertions, installed-app inventory, cleanup estimates, clocks, and display-only SMC numeric inventory.
- Expensive inventory/scanning work must be slow-cadence or explicit on-demand. It must not become a one-second background poller merely because the UI can display it.
- Raw/unknown SMC numeric keys are expert display-only. Never infer units or feed unknown channels into Max SoC, Cooling Rules, alerts, or privileged writes.
- Long-term per-app energy is descriptive attribution from native process counters. Keep caveats visible: inaccessible/system processes may be absent and process-accounted energy/I/O is not guaranteed to equal whole-system PSTR/physical-device accounting.
- Keep runtime code subprocess-free. Development scripts may invoke compiler/build tooling; shipped runtime sources must not call Process/NSTask/popen/posix_spawn.
- Next22 is the final broad functional milestone before the planned Simple / Advanced / All information-architecture redesign and later performance/wakeup optimization.

## Architecture Guidelines
1. **HeliosApp (Main Menu Bar App):**
   - Host `NSStatusItem` via SwiftUI / AppKit.
   - Handles real-time polling of CPU, GPU, RAM, thermals via IOKit/Mach APIs.
   - Handles IPC client for daemon commands.
   - Owns the telemetry and curve engine. Completed calculations based on fresh telemetry renew the daemon's control lease.
2. **HeliosDaemon (Privileged Helper):**
   - Headless LaunchDaemon managed by `SMAppService.daemon(plistName:)`.
   - Validates XPC clients (Team ID / Entitlements).
   - Direct Apple SMC write operations for target fan RPM / manual override.
   - Enforces a short control lease (initial target: 5 seconds) and independently restores System mode when fresh calculations stop arriving. A live XPC connection alone does not renew the lease.

## Current Implementation Scope
- Phase 4: read-only fan telemetry, app-owned temperature policy, daemon-only SMC control engine, independent control lease, recovery journal, and native fan controls. Preserve existing telemetry and fixed-width presentation.
- The menu-bar item is fixed at 80 points with two fixed 40-point columns, 8-point captions, and 11-point semibold monospaced digits. Never size it from its current text or use variable status-item length.
- Present thermals-first native cards with grouped sensor averages/maxima, muted CPU/memory breakdowns, and explicit battery power labels. Keep raw SMC keys and kernel error codes out of the main presentation; retain failure details in help/accessibility.
- Debug and Release now use Apple Development signing with the verified Personal Team `3J76KPDS9C`, shared by both targets in `Config/Base.xcconfig`. Preserve empty base entitlements and disabled debug entitlement injection. Developer ID signing/notarization remain later distribution work.
- Protocol v3 adds bounded calculation, fan-status, and typed System-release requests with only a graceful/immediate boolean. Never accept raw SMC keys/bytes, caller-supplied hardware bounds, or lease durations over XPC. Compile the SMC write transport only into HeliosDaemon.
- Authenticate both peers using public NSXPC signing requirements: Apple anchor, matching Team ID, exact peer signing identifier, and absence of debugger/injection exception entitlements. Ad-hoc builds must fail closed; never add an unsigned, PID-only, or bundle-ID-only fallback. Test-only anonymous listeners can pin the exact test executable's CDHash.
- Keep diagnostic and hardware-control leases separate. Only a completed calculation with a strictly newer original thermal sample timestamp and sequence may renew steady-state control. Accept samples at most three seconds old; the ordinary steady lease remains five seconds. The validated M4 initial takeover may arm a separate hard-bounded 12-second acquisition transaction after that fresh sample is accepted, because Ftst/F0Md arbitration can outlive five seconds. Revocation/generation changes remain effective during acquisition, and successful acquisition returns to the five-second steady lease without clearing sample/sequence replay history. Heartbeats/status/UI refreshes never renew control.
- System restores owned fans; Boost uses the pinned factory maximum; Manual (internally daemon `.override`) is enabled only on the validated Mac16,1/25G83 single-fan profile and is daemon-clamped/quantized to 2317–6550 RPM. Next15 replaces the pilot Auto Max checkbox with a TG-style Auto Rules layer: separate Power Adapter/Battery profiles, All Fans/per-fan targets, 0–100% MIN→MAX mapping, aggregate/individual trusted sensors, highest-demand-wins semantics, copy/reorder, persistence of rules only, hysteresis/debounce, and a privileged 95°C factory-max floor. Start every app session in System and never persist a takeover. Manual/Boost failures require explicit re-selection. Auto is a persistent policy only while explicitly selected: after a transient failure it may remain armed and retry solely when the daemon has independently verified clean System restoration, capability remains valid, a bounded backoff has elapsed, and a newer fresh thermal sample is available.
- Record ownership durably before first touching fans. On partial failure, expiry, disconnect, shutdown, or sleep, revoke further writes and attempt restoration of every owned fan. Retain the recovery journal and report unconfirmed state if restoration fails. Recover the journal before new takeover after restart.
- Phase 4.1/4.3 established two hardware facts that remain mandatory: protected manual-mode writes may return retryable `SMCResult=0x82`, and `Ftst` write acknowledgement is not synchronous observable ownership. Never infer state from transport success; use bounded stable readback and never brute-force or invent firmware unlock keys. See docs/PHASE4_1.md and docs/PHASE4_3.md.
- Phase 4.4 introduced the v2 conservative ownership journal/state machine plus bounded acquisition, steady-state verification/update and recovery executors. Risk is persisted before any corresponding hardware write and is cleared only after independently verified release. Recovery ordering follows live evidence: request per-fan automatic while retaining risk, persist global release, wait for stable `Ftst=0`, then verify Apple-managed fan state and clear fan bits. See docs/PHASE4_4.md.
- Phase 4.5 physically validated the pinned `Mac16,1` / `25G83` / one-fan profile: bounded `Ftst` acquisition, repeated retryable `0x82` before `F0Md=1`, 3000 RPM target/readback and real fan response, graceful release, intentional SIGKILL -> fresh-process v2-journal recovery, and real sleep/wake restoration with a fresh AppleSMC reprobe. System may legitimately read mode 0 or 3 and an Apple target such as 2317 RPM after release. See docs/PHASE4_5.md.
- Phase 4.6 production control is pinned to `Mac16,1` / `25G83` / fan 0. Startup recovery and an exact read-only profile gate must pass before the daemon advertises Boost/Override; the writer remains lazy until the first authenticated fresh calculation. The only writable keys remain `Ftst` 0/1, `F0Md` 0/1 and `F0Tg`; `F0Tg` is now restricted to integral 2317–6550 RPM. Boost is fixed at 6550; Override is daemon-clamped/rounded and same-session target changes use the owned-target update executor. Explicit user System release may use a cancellable soft ramp, while sleep/disconnect/stale telemetry/lease expiry/shutdown/recovery bypass it and restore immediately. A read-only external-controller baseline must still run while the Helios journal is clean; if it rejects, do not create recovery authority or clear another controller's `Ftst`. See docs/PHASE4_6.md.
- Read SMAppService.status after both success and failure; registration may throw while leaving Requires Approval. Never claim Installed proves an authenticated XPC connection. Use fresh SMAppService handles, await asynchronous unregister, then require one second of stable notRegistered status (five-second deadline) before reinstalling; this host has a confirmed BTM disposition race after the completion callback. See docs/PHASE3.md for the verified installed root-daemon handshake.
- Dynamically discover temperature keys, but only curated M4-family keys may become trusted P/E/GPU fan-control inputs. Unknown `Tp`/`Te`/`Tg` keys stay unclassified and must not inflate Max SoC. Treat groups as thermal zones, not exact physical-core identity. Keep the raw hottest key in help/diagnostics rather than the main presentation.
- Preserve per-field typed failures and signed battery charge/discharge labeling. Total System Power may be shown only from an independent successful read-only board/system source (Next18 uses AppleSMC PSTR); never substitute battery flow or adapter-rated watts. Development check scripts may invoke build tools; app/runtime sources must never spawn external commands.


### Phase 4.7 Next15 status
The pinned Mac16,1 / 25G83 production Boost and Manual paths are physically validated end-to-end: paced Ftst/F0Md acquisition, arbitrary daemon-clamped 2317–6550 RPM targets, same-session target updates without reacquisition, graceful soft System release, crash/restart recovery, and immediate sleep pre-emption followed by a fresh clean AppleSMC wake reprobe. Next15 adds a TG-style Auto Rules policy above that validated backend without adding any new raw SMC primitive or XPC hardware surface. Rules use separate Power Adapter/Battery profiles, normalized fan percentages, trusted thermal sources and highest-demand-wins evaluation. The daemon independently forces factory max for every accepted fresh calculation at or above 95°C, so a low Manual/Auto request cannot suppress emergency cooling. Power-source uncertainty/profile changes, stale telemetry, disconnect, sleep, lease expiry, shutdown and recovery fail closed to System. Live edits to the currently selected Auto profile do not themselves force a System round-trip; the next fresh thermal evaluation updates the already-owned target or releases once if no rule matches. SMART/SSD/HDD sources and other Mac/OS production profiles remain staged. See docs/PHASE4_7.md.

- Next13-fixed: fixed the Swift 6 strict-concurrency test harness by replacing an unsynchronized captured engine-factory counter with a lock-protected test-only counter. No runtime fan-control behavior changed.
- Next13-fixed2/fixed3/fixed4: repaired stale broad-suite fixtures/expectations left behind by earlier recovery, stable-readback, and acquisition-lease hardening. In particular, the stalled-writer watchdog test now blocks beyond the dedicated 12-second acquisition lease instead of expecting the old five-second takeover timeout. These are test-harness corrections only; production SMC behavior is unchanged.

### Next13 fixed5 note
A live Auto Max arming race proved that an accepted Ftst=1 may still be invisible when cancellation starts. Recovery must therefore treat the durable global-risk bit as authority to issue Ftst=0 unconditionally and must not accept two immediate stale-zero reads as proof of release. Global-only recovery is valid when no fan write was journaled.

### Next15 fixed2 note
Auto Rules configuration remains editable/reopenable after a transient, fully restored hardware-acquisition failure. Hardware failure still disarms the selected mode and requires an explicit new selection, but it no longer masquerades as permanent helper unavailability when the daemon already confirmed System. Empty AC/Battery profiles are valid System-only configurations, and `Always` is an unconditional rule with no temperature threshold.

### Next15 fixed3 note
Keep IPC test harness scheduling slack distinct from product safety deadlines. Anonymous NSXPC + reverse callbacks + main-actor publication may occasionally exceed 3 seconds on a loaded development Mac; harness state waits use 5 seconds with stage-labelled timeouts. Never mask a failure with automatic retries, and do not relax the independently asserted production lease/deadline semantics.

### Next15 fixed7 Auto Rules invariants
- Treat an accepted XPC calculation as **pending**, never as proof of SMC ownership. Only daemon `.boost` / `.override` replies establish confirmed control.
- Auto is a persistent policy while explicitly selected. A live rule edit must not revoke an in-flight/owned transaction merely because a Stepper/menu value changed. Re-evaluate on the next fresh thermal batch; update F0Tg under existing ownership, or release once if no rule matches.
- A transient calculation failure may keep Auto armed only after the daemon has verified clean System restoration and the capability is still available. Apply a bounded retry backoff and require a newer thermal sample. Manual/Boost remain explicit one-shot modes and disarm on failure.
- Editing the inactive Power Adapter/Battery profile is configuration-only and must not interrupt healthy cooling on the active profile.
- `Always` is a permanent unconditional rule source and must remain available even if dynamic thermal sensor discovery is temporarily unavailable; the editor also exposes an explicit Add Rule > Always Rule path.
- Rule UI must distinguish **matching policy** from **confirmed fan ownership**. Never show a green Active rule solely because its condition matches while the daemon is still System/acquiring/recovering.
- Sleep and power-source transitions remain fail-closed: sleep immediately invalidates app fan/thermal samples; ambiguous/changed power source returns Auto to System before evaluating the new profile.

### Next15 fixed6 build invariant
Swift does not permit covariant `Self` in a stored-property initializer. For
class-level defaults used by stored properties, initialize them explicitly in
`init` (or reference the concrete final type) rather than writing `= Self.foo`.
Keep `Always` seeded before any dynamic thermal discovery. Fixed6 is a compile-only
repair; do not widen SMC capabilities or alter safety semantics as part of this fix.

## Next16 storage boundary
- Storage telemetry is read-only and unprivileged. Never call `diskutil`, `system_profiler`, `smartctl`, `iostat`, or any subprocess at runtime.
- IOBlockStorage `Statistics` counters are boot/runtime I/O counters. Never label or infer them as SMART lifetime TBW.
- SSD wear/health/TBW may be exposed only from a successful native NVMe SMART health-log read. Never infer it from IOBlockStorage counters. The native reader is unprivileged, read-only, cached, and failure-isolated.
- Storage failures must remain isolated from fan control and must never expand the privileged daemon or SMC write surface. SSD temperature may feed Auto Cooling Rules only when a fresh, successfully parsed native SMART sample exists; the independent 95°C SoC emergency guard remains authoritative.

## Next17 native NVMe SMART boundary
- Native NVMe SMART is unprivileged and read-only. It may call only Apple's SMART health-log read interface; no NVMe write/admin mutation commands are allowed.
- Keep the IONVMeSMARTInterface `version`/`revision` fields in the vtable prefix. Removing them changes the function-pointer offset and is unsafe.
- SMART failures are isolated and cached; never infer SMART wear/TBW from boot-scoped IOBlockStorage statistics.
- SSD temperature can appear as an Auto Cooling Rules source only from a fresh successful SMART sample. It cannot replace the independent trusted Max-SoC emergency floor in the privileged daemon.

- Next17 SMART ABI note: never reference `kIOCFPlugInInterfaceID` directly from Swift; Xcode 26 does not import that macro. Use the exact UUID constructor in `NVMeSMARTUUIDs.pluginInterface()`. Keep NVMe SMART access read-only (`SMARTReadData` or `GetLogPage` 0x02 only).

## Next18 performance/power boundary
- GPU telemetry is unprivileged and read-only. Use native IOKit accelerator properties only; never spawn `ioreg`, `system_profiler`, or a benchmark to obtain utilization. Missing `PerformanceStatistics` fields are independently unavailable.
- Total System Power is independent from battery flow. Next18 may read only the AppleSMC `PSTR` key through the read-only app-side SMC transport and must reject malformed/non-finite/implausible values. Do not add a shared SMC write API.
- Native swap uses Darwin `sysctlbyname("vm.swapusage")` with `xsw_usage`; this is an in-process kernel query, not the `sysctl` executable.
- New GPU/power/memory/battery telemetry must not alter `Sources/HeliosDaemon/*`, XPC control messages, production fan write keys, ownership journal semantics, leases, or the 95°C emergency floor.
- Do not fabricate GPU frequency, component power, process energy, history, or network values from unrelated counters. Add those only with separately validated sources and typed failure states.
- `scripts/check-runtime-policy.sh` is part of the canonical milestone gate and rejects runtime `Process`/`NSTask`/`popen`/`posix_spawn` execution paths.

- Before handing off a milestone build, run `./scripts/check-all.sh`; it is the canonical simulation/read-only regression gate and must pass before any new physical fan validation.

## Next19 utility/history invariants
- System/network/history are read-only app-side features. Do not route them through the privileged daemon.
- Network traffic rates derive from AF_LINK counters with explicit 32-bit rollover and interface-handoff warm-up; never present volatile counters as lifetime traffic.
- Battery remaining time comes from IOPowerSources semantics, not a watts/capacity guess.
- Session energy is measured-coverage PSTR integration only. Never bridge sleep/stale/missing intervals or substitute battery/adapter power.
- Keep the validated fan daemon, XPC control surface, Cooling Rules, recovery/lease logic and 95°C floor unchanged while this milestone is validated.

## Next21 observability boundary
- Whole-device IOBlockStorage counters, libproc per-process I/O, and Helios self-I/O are different accounting layers. Never claim process totals must reconcile 1:1 with physical device traffic. Label boot-scoped counters as boot-scoped and lifetime NVMe SMART counters as lifetime.
- Keep `io-activity-v1.ndjson`, `history-v1.ndjson`, and `health-events-v1.ndjson` unprivileged, bounded, append-friendly observability only. Filesystem failures must never affect fan safety or privileged control.
- Session attribution must key processes by PID + process start absolute time, reject rollback/invalid intervals, and never use the root helper to access an otherwise inaccessible process.
- The hardware capability matrix is read-only evidence. Fan discovery/profile match never authorizes writes; the existing pinned production daemon gate remains the only write authority.
- `--io-preflight` must perform no fan writes, persistence writes, notification prompt, subprocess execution, or privileged telemetry.
