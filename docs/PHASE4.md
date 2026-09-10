# Phase 4 — Fan Control Engine & Safety Policies

This is the original Phase 4 record. Signing and installed IPC were subsequently verified in `PHASE3.md`; the user later accepted restart recovery after SIGKILL and authorized physical testing. The first trial failed at `F0Md` with result `0x82`, so takeover remains gated. See [Phase 4.1](PHASE4_1.md) for the current hardware result.

## Delivered behavior

Fan telemetry remains unprivileged and works without the helper. An independent provider reads `FNum` and each fan's actual RPM, target RPM, and factory minimum/maximum. Both `fpe2` (big-endian quarter-RPM units) and `flt ` (little-endian Float32) are validated. Missing values remain typed per-field failures. Zero fans means passive cooling, and zero RPM means a stopped fan. Stale fan samples clear from the popover after three seconds.

The Thermals & Cooling card now includes fan readouts, System/Boost/Override selection, and a manual target slider. Boost requests every fan's own maximum. Override clamps the selected target separately to each fan's limits. An optional Auto Max trigger uses the approved 85°C on / 75°C off thresholds with a three-second debounce in both directions. The app computes policy decisions; the daemon receives bounded requests rather than arbitrary SMC keys or bytes.

Every app session begins in System. A selection or slider change takes effect only after a new complete thermal batch. Fresh identified P/E/GPU readings are required, and failures of identified SoC sensors disarm requested control. Thermal polling stays near two seconds normally, requesting 500 ms intervals while control is selected and SoC temperature is at least 80°C. Fan readout and UI refresh remain one second. Existing CPU, memory, battery, formatting, and menu-bar width behavior is preserved.

The shared SMC transport has moved to `Sources/Shared/SMCClient.swift` without gaining any write command. Only the daemon target compiles the write transport. It requires effective UID 0, probes mode/target formats, reads factory bounds before each calculation, encodes clamped RPM without rounding outside those bounds, and verifies mode and target after writing. It does not overwrite min/max limits, use Intel global force masks, or attempt firmware test-mode unlocks. Unsupported or locked firmware returns an error.

## Lease, ownership, and recovery

Protocol version 2 adds calculation, fan-status, and System-release calls alongside the existing authenticated bidirectional heartbeat. Each calculation includes the original thermal acquisition timestamp from the host-wide `mach_continuous_time` clock and an increasing control sequence. Samples over three seconds old, future samples, and repeated timestamps/sequences are rejected. UI refreshes never update that timestamp.

The hardware-control lease ends five seconds after the sample's acquisition, not five seconds after receipt of a possibly delayed request. A dedicated safety queue checks expiry every 100 ms, with 10 ms scheduling leeway. Its lock is never held during IOKit calls. Revocation invalidates the write permit; the hardware queue checks that permit before and after mutations. Diagnostic heartbeats and status requests have no path to renew the hardware lease. An expired lease stays revoked until an explicit System release completes; replay history survives that release within the same session.

Before first touching fans, the daemon records their IDs in `/var/db/com.snejda.Helios.fan-ownership`, using a fixed root-owned file, mode 0600, `O_NOFOLLOW`, an exclusive lock, and `fsync`. Existing ownership does not cause a disk write on each renewal. A partial failure restores every possibly touched fan, even if one reset fails. The journal clears only after all automatic-mode readbacks succeed; failures report Recovery Required rather than claiming System. Startup loads the journal and attempts restoration before accepting takeover. A new client cannot occupy the previous listener slot until disconnect cleanup finishes.

System release first requests automatic mode, then clears the target override, then verifies automatic mode. Target zero is an automatic-mode reset only, never a manual target that bypasses factory minimums. Existing manual ownership by another controller is rejected during initial takeover. The SMC does not provide an application-level ownership lock, so simultaneous use of multiple fan-writing utilities is not established as safe.

The daemon handles SIGTERM/SIGINT through dispatch signal sources, and system sleep through `IORegisterForSystemPower`. These paths revoke control and request restoration. If graceful termination cannot complete within four seconds, it exits unsuccessfully with the journal retained. The LaunchDaemon plist requests restart after unsuccessful exits and startup recovery through RunAtLoad. App disconnect/sleep also revokes its session.

## Why live takeover is gated

**No production hardware profile is enabled.** `FanControlCoordinator` reports that crash-restoration validation is required and does not construct a native writer. This has no UI, environment-variable, or XPC override. Simulated test backends explicitly inject an engine for verification.

The project specification requires verified physical restoration after a daemon crash before enabling takeover. SIGKILL and crashes cannot execute cleanup code; launchd restarts are subject to scheduling and throttling. Likewise, Swift cannot interrupt a blocked kernel driver call. Independent lease revocation prevents subsequent writes, but physical restoration must wait for an available driver/process. Consequently this implementation cannot honestly guarantee immediate restoration after every daemon termination, and live takeover remains disabled.

A development identity is also still absent: the local keychain reports zero valid code-signing identities. Ad-hoc compilation remains supported, while production XPC continues to fail closed under the existing Team ID/identifier/entitlement policy. A signing certificate and user approval are necessary but do not satisfy the separate hardware-safety gate.

Before enabling a production profile, controlled hardware validation must establish accepted mode/target formats, normal System restoration, rollback after partial failure, stale-calculation and disconnect behavior, sleep/wake restoration, and restoration after forced daemon termination. If immediate restoration cannot be established independently of a living daemon, the requested guarantee remains unmet; it must not be replaced with an assumption about launchd.

## Observed local readout

Read-only verification on the M4 MacBook Pro / macOS Tahoe 26.6.2 on 2026-09-06 returned:

| Metric | Observed value |
| --- | ---: |
| Fan count (`FNum`) | 1 |
| Current RPM (`F0Ac`) | 0 |
| Target RPM (`F0Tg`) | 0 |
| Factory minimum (`F0Mn`) | 2,317 RPM |
| Factory maximum (`F0Mx`) | 6,550 RPM |
| Mode readout | Automatic |

The check ran as the ordinary logged-in user outside the tool sandbox. These are observations at one point in time, not proof that firmware accepts takeover. **No physical SMC writes were performed.** No service registration, approval change, or root recovery-journal creation was performed in this phase.

## Verification and reproduction

```sh
./scripts/check-telemetry.sh
./scripts/check-presentation.sh
./scripts/check-fans.sh
./scripts/check-fans.sh --live
./scripts/check-ipc.sh
```

The development scripts compile Swift 6 with complete strict concurrency and warnings as errors. They are never launched by Helios. `--live` adds read-only fan access and refuses root execution; all fan writes in tests go to simulated hardware. For a tool sandbox, compile IPC/fan checks with `--build-only`, then run the resulting executable as the ordinary user outside that sandbox.

Debug and Release builds succeeded for both targets with the installed macOS 26.5 SDK, arm64, and the macOS 13 deployment floor. Both app bundles and embedded helpers passed strict ad-hoc signature verification. The compiler emitted no Swift warnings/errors; Xcode logged simulator-service environment diagnostics and skipped AppIntents metadata extraction.

Checks cover fanless and stopped-fan states, missing fields, invalid payloads, RPM encoding at boundaries, per-fan clamping, Boost maximums, foreign ownership rejection, partial-write rollback, journal persistence on failed restoration, startup recovery, journal failure before writing, stale/future/replayed calculations, exact lease boundaries, cancellation during an in-flight simulated driver call, and thermal hysteresis/debounce. A 5.8-second simulated driver stall verifies that the separate watchdog reaches Restoring before the blocked call returns, prevents the next manual-mode write, and rolls back the late target write. Graceful shutdown is tested with an active simulated override.

Real anonymous NSXPC tests use the production session, coordinator, and app client with simulated fans. They verify bounded control requests, replay rejection after System release, control expiry while normal one-second heartbeats continue, and disconnect restoration. Peer-rejection, version-mismatch, callback, reconnect, and registration-state tests remain included. This is real XPC serialization inside one process, not validation of a signed root daemon or physical SMC writes.

Native AppKit hosting-window captures verify the segmented picker, Auto Max toggle, manual slider, and the full popover. SwiftUI ImageRenderer alone cannot render these AppKit-backed controls. Layout fixtures remain under `.build/Presentation`; logs are under `.build/Verification/phase4-*`. Existing fixed 80-point widget and provider regression checks remain part of verification.

## References and limits

Mode keys and RPM formats were checked against the upstream [Stats SMC implementation](https://github.com/exelban/stats/blob/master/SMC/smc.swift). It demonstrates model-dependent mode keys and firmware unlock paths; those observations are not an Apple compatibility guarantee. Helios uses conservative capability checks and does not implement those unlock paths.

Apple's [launchd programming guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) describes SIGTERM on shutdown and restart/throttling behavior. Installed SDK headers (`IOMessage.h`, `IOPMLib.h`, and Mach time APIs) supply the native API definitions. Other hardware/OS releases, real SIGKILL restoration, root-daemon sleep/wake, physical target acceptance, and performance budgets remain unverified.
