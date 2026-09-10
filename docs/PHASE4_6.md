# Phase 4.6 — Production fan control: Boost, Auto Max, Override (Next14)

## Scope

Phase 4.6 connects the physically validated M4 ownership state machine to the real signed `HeliosDaemon`. Production control remains pinned to one exact validation profile:

- model: `Mac16,1`
- OS build: `25G83`
- fan count: 1
- fan: 0
- global ownership key: `Ftst`, `ui8 ` / 1 byte
- mode key: `F0Md`
- target key: `F0Tg`, exact `flt ` encoding
- validated factory range: 2317–6550 RPM
- Boost target: exactly 6550 RPM
- Override target: integral daemon-clamped 2317–6550 RPM

`Auto Max` remains an unprivileged thermal policy that decides when to request/release `.boost`; it does not add a new root mode or raw write surface. Next14 adds `.override` only on the same pinned profile. XPC never accepts raw SMC keys, encodings, hardware bounds, byte payloads, or lease durations.

## Evidence inherited from Phase 4.5

The pinned profile has physically demonstrated:

1. delayed `Ftst` visibility after successful writes,
2. bounded `F0Md=1` arbitration with several retryable `SMCResult=0x82` responses before acceptance,
3. target write/readback and real fan response at a 3000 RPM validation target,
4. deterministic graceful release to Apple control,
5. intentional SIGKILL of an owning process followed by fresh-process durable-journal recovery,
6. pre-sleep restoration before power acknowledgement,
7. fresh AppleSMC reprobe after wake,
8. both a near-immediate/aborted sleep transition and a real ~20-second sleep cycle.

The last live Step-5 daemon logs confirmed `SystemWillSleep` -> pre-sleep restoration -> `SystemHasPoweredOn` -> clean journal bootstrap -> fresh SMC reprobe -> post-wake safety completion.

## Production gate before XPC advertises fan control

Daemon startup performs, in order:

1. normal peer-signing requirement construction,
2. production v2 recovery bootstrap from `/var/db/com.snejda.Helios.fan-ownership-v2`,
3. an exact **read-only** `ProductionFanTakeoverGate`,
4. only then construction of a coordinator that may advertise `.boost` and `.override`.

A clean recovery journal does not construct recovery hardware. Passing the read-only takeover gate also does not construct the production writer. `ProductionM4FanControlEngine` and its AppleSMC write connection are created lazily only after an authenticated fresh calculation arrives.

Any model/build/fan-count/key/type/factory-bound drift keeps production takeover unavailable.

## External-controller arbitration rule

`Ftst` has no owner identity. Helios therefore cannot safely infer who owns an already-active global flag.

The acquisition executor now performs the complete read-only clean-baseline check **before** it marks the durable Helios journal as possibly owning `Ftst`. If that check detects `Ftst=1`, manual mode, or another profile mismatch, acquisition stops while the journal is still clean. That failure therefore does **not** authorize a Helios recovery write that could clear another controller's state.

Only after the clean read-only check succeeds does Helios:

1. persist/fsync `acquiringGlobal` risk,
2. re-check the live control lease,
3. attempt `Ftst=1`.

There is no atomic owner/CAS primitive for `Ftst`; a controller that starts in the tiny interval after the clean baseline remains fundamentally indistinguishable. The pilot therefore still requires TG Pro, Stats fan control, Macs Fan Control and similar controllers to be closed during testing.

## Production write allowlist

`ProductionM4FanControlHardware` can represent only:

- `Ftst = 1` — acquire global arbitration,
- `Ftst = 0` — release global arbitration,
- `F0Md = 1` — request manual fan mode,
- `F0Md = 0` — request Apple automatic mode,
- `F0Tg` — an integral target in the validated `flt ` encoding and validated 2317–6550 RPM range.

The app slider is not trusted. The privileged profile clamps and rounds `.override` requests before the hardware layer sees them, and the hardware layer independently rejects non-integral or out-of-range targets. It cannot write `F0Mn`, `F0Mx`, `FS!`, another fan, a caller-provided byte payload, or any target outside the pinned factory range. Same-target fresh calculations are write-free and verify `Ftst`, `F0Md`, and `F0Tg`; target changes while already owned use `FanOwnershipTargetUpdateExecutor` and do not repeat global/manual acquisition.

## Lease and recovery semantics

The app still owns temperature calculation, and only a completed calculation based on a strictly newer thermal sample can renew steady-state control. Samples may be at most three seconds old. The steady-state hardware lease remains five seconds. Initial takeover is the only exception: after a fresh calculation is accepted, the coordinator may arm a separately bounded 12-second acquisition transaction so the physically observed Ftst/F0Md arbitration can complete without pretending the original thermal sample is still fresh. Cancellation/revocation remains active throughout that transaction. On successful ownership, the coordinator returns to a five-second steady lease and requires subsequent newer thermal samples to renew it. Heartbeats, status reads and UI activity never renew control.

Every first acquisition uses the v2 journal-before-hardware sequence. Any ambiguity after durable risk exists moves the record to `recoveryRequired`. System selection, lease expiry, XPC disconnect, daemon shutdown and pre-sleep handling all use the same validated recovery executor. Recovery continues independently of a revoked control lease because cleanup must still be possible after the app disappears.


## First integrated production finding — 2026-09-07

The first real-daemon Boost pilot did **not** reach manual ownership. The clean preflight and recovery path both behaved correctly, but the production arbitration cadence was too aggressive and the steady 5-second control lease was incorrectly reused as the acquisition deadline.

Live evidence from the signed helper showed:

- `Ftst=1` was accepted immediately,
- `F0Md=1` then returned repeated retryable `SMCResult=0x82`,
- production retried roughly every 0.1–0.2 seconds instead of the slower cadence that succeeded in the standalone physical validator,
- the ordinary lease expired after five seconds and recovery wrote `Ftst=0`, returning the Mac to a clean System baseline,
- later attempts reproduced the same failure, including one explicit bounded manual-mode timeout.

This was therefore a fail-closed integration failure, not a stuck fan-control state. The UI returned to System because the daemon intentionally restored after the failed acquisition.

`Next12-fixed2` corrects the mismatch without broadening the steady-state lease:

1. a fresh thermal sample is still required at takeover start and may be at most three seconds old,
2. the ordinary steady-state control lease remains five seconds,
3. only the initial takeover may arm a separate, generation/revocation-aware **12-second acquisition transaction**,
4. `F0Md` writes are paced at most once per second while read-only mode is polled between attempts, matching the successful physical validation behavior,
5. manual-mode arbitration has its own eight-second bound; global `Ftst` and target-readback bounds remain four seconds,
6. after successful acquisition, the coordinator returns to the ordinary five-second lease and waits for the next genuinely newer thermal sample; sample and sequence replay history are not cleared,
7. the app waits up to 13 seconds only for that initial takeover request, while steady-state control requests retain the 4.5-second client timeout.

Any XPC disconnect, explicit System selection, watchdog expiry, sleep, shutdown, or generation change still revokes the acquisition permit and routes through the same durable recovery path.

## Next12 live pilot

The first integrated test is deliberately staged:

### A. Graceful real-daemon Boost

1. close all other fan controllers,
2. install/reinstall the Next12 helper and require `Installed` + `Connected`,
3. select Boost once,
4. observe target 6550 and a real upward RPM response for only a few seconds,
5. select System,
6. require a clean read-only preflight (`Ftst=0`, mode 0/3, exact profile),
7. inspect `FanSMC`, `FanControl`, `FanRecovery` and `Lifecycle` logs.

### B. Real-daemon owned sleep/wake

Only after A succeeds:

1. select Boost and wait for ownership/fan response,
2. put the Mac to sleep normally for roughly 10 seconds,
3. wake it,
4. require System control and a clean fresh preflight,
5. inspect daemon lifecycle/recovery logs.

This second test closes the remaining integration gap left by Next11: the standalone validator physically owned the fan during sleep testing, while the daemon's lifecycle path was independently verified on a clean journal. Next12 tests those two pieces together with the real daemon as owner.

## What a successful Next12 does not authorize

A successful pilot does not yet enable:

- Override/custom curves,
- Auto Max acquisition,
- support for any other Mac model,
- support for another macOS build,
- concurrent use with another fan controller,
- removal of journal/lease/profile checks.

Those remain separate review and validation steps.

## Successful integrated production evidence — 2026-09-07

`Next12-fixed2` passed the real signed-daemon pilot after the arbitration cadence/acquisition-lease fix:

- `Ftst=1` succeeded,
- five one-second-spaced `F0Md=1` attempts returned retryable `0x82`,
- the next `F0Md=1` succeeded,
- the daemon wrote `F0Tg` as exactly 6550 RPM,
- the UI confirmed `Owned by Helios` and the fan reached the commanded maximum region,
- the tachometer briefly peaked around **6630 RPM** while the target remained **6550 RPM** (about +1.2% observed transient overshoot; Helios did not command above 6550),
- explicit System release wrote `F0Md=0` and `Ftst=0` and returned a clean read-only preflight.

The production-owned sleep integration also passed: while Boost was owned, `SystemWillSleep` revoked the control session, wrote `F0Md=0` / `Ftst=0`, verified restoration before allowing sleep, then `SystemHasPoweredOn` performed a clean journal bootstrap and fresh AppleSMC reprobe. This closes the integration gap between the standalone sleep validator and the actual owning daemon.

## Next13 Auto Max gate and physical result

Auto Max does not add a daemon write capability. The policy lives in `FanControlModel` and may only decide when to call authenticated Boost/release APIs from a fresh trusted thermal batch.

Current policy after physical retuning:

- fast thermal polling begins at Max SoC >= 75°C while Auto Max is armed,
- normal engage candidate: Max SoC >= 80°C for at least 1 second,
- emergency engage: any fresh trusted Max SoC sample >= 95°C engages immediately,
- release candidate: Max SoC <= 72°C for at least 5 seconds,
- stale, incomplete, future-dated or non-M4-trusted thermal batches disarm control immediately,
- arming Auto Max during an in-flight manual Boost does not cancel the acquisition; after ownership is confirmed, the next fresh cool sample may release to System and arm the automatic policy.

The first 85°C/3 s pilot peaked at 101.1°C under Minecraft even though daemon acquisition itself completed in about 0.72 s. The revised 80°C/1 s policy was then validated with the same workload: Auto Max became active, ownership was `Owned by Helios`, target stayed exactly 6550 RPM, observed actual RPM reached the mid-6600s transiently, and the workload peaked around 95°C. After load removal the policy released to System and a final read-only preflight showed `Ftst=0`, automatic mode, target/actual 0, and `Ready for validation`.

## Next14 Override + soft-release boundary

Next14 widens only the target value, not the SMC key surface or ownership protocol:

- Boost remains fixed at exactly 6550 RPM.
- Override is allowed only on the same `Mac16,1` / `25G83` / fan-0 profile.
- The app slider uses 50 RPM steps for UX, but the daemon independently clamps and rounds every request to 2317–6550 RPM.
- A first Override acquisition uses the same journaled `Ftst`/`F0Md` sequence as Boost.
- Switching Boost ↔ Override or moving the slider while already owned uses the owned-target update executor; global/manual acquisition is not repeated.
- Protocol v3 adds a single `graceful` boolean to the typed System-release XPC method. No SMC details cross XPC.

Explicit app-requested System release may use a cosmetic deceleration sequence derived from the currently owned target: 5200 → 4300 → 3400 → 2800 RPM, skipping points that are not below the current target, with about 600 ms between steps. The sequence is cancellable and each step still goes through the owned-target verifier. After the final step, the normal durable recovery executor restores `F0Md=0`, `Ftst=0`, and a clean System baseline.

This soft ramp is **never a safety dependency**. Lease expiry, stale telemetry, XPC disconnect, session invalidation, daemon shutdown, system sleep, wake recovery, or any ambiguous hardware state cancels the cosmetic permit and queues immediate normal recovery. A currently executing single SMC operation cannot be pre-empted inside the kernel, but no multi-second sleep occurs on the writer queue; future cosmetic steps are dropped as soon as safety restoration is requested.

Next14 does not yet authorize custom temperature curves, another fan, another Mac model/build, or concurrent ownership with another controller.
