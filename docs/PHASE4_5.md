# Phase 4.5 — Read-only M4 ownership preflight and physical-validation gate

## Objective

Phase 4.4 established a simulation-only acquire → target-update → release lifecycle with delayed global-state handling and durable recovery semantics. Phase 4.5 begins the transition from simulation to hardware evidence, but **Step 1 is read-only**. It must prove that the live Mac still exposes exactly the capability surface the next physical validation expects before any write path is even considered.

The target profile is intentionally narrow: this project's current primary machine is `Mac16,1`, one fan, with the previously observed uppercase `F0Md` mode key and `Ftst` as a one-byte `ui8 ` diagnostic/global ownership candidate.

## Step 1 — Live read-only capability baseline

The new `SMCFanOwnershipPreflightReader` can represent only reads. It checks:

1. the machine model is the approved `Mac16,1` profile,
2. the OS build is the currently validated `25G83`,
3. the fan count is exactly one,
4. `Ftst` exists as `ui8 ` / 1 byte,
5. `Ftst == 0` before validation,
6. the fan mode key is exactly `F0Md`,
7. the fan is currently in Apple-managed automatic mode (`0` or `3`),
8. actual, target, minimum and maximum RPM are readable,
9. factory limits are sane,
10. target encoding is one of the already supported `fpe2` / `flt ` forms.

A nonzero automatic target is **not** a failure. macOS may legitimately request a fan target under thermal load, so `target == 0` is not used as a universal proof of System ownership.

## Meaning of `Ready for validation`

`Ready for validation` means only that the current read-only baseline matches the exact hardware profile expected by a future narrow experiment. It does **not** mean:

- crash restoration has been validated,
- `Ftst` is proven safe to write,
- Helios may enable Boost or Override,
- another controller cannot appear after the snapshot,
- the production gate may be removed.

Any active `Ftst`, manual fan mode, profile mismatch, unexpected key casing/type, invalid bounds or incomplete inventory fails closed as `Blocked`/`Unsupported`.

## Runtime behavior

The app samples the preflight slowly and independently from normal fan telemetry. It is read-only and is re-created after wake. The Fans UI exposes the result as a diagnostic line so the exact validation readiness is visible without enabling control.

A DEBUG command-line mode prints the complete live snapshot from the already-built app:

```sh
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --fan-preflight
```

This avoids compiling another standalone test binary just to inspect live SMC state.

## Gate status after Step 1

Still unchanged:

- no production `Ftst` write API,
- no production acquisition/recovery conformer,
- no v2 root disk activation,
- no XPC expansion,
- Boost/Override remain unavailable,
- no physical fan write is authorized by this step.

The next Step 2 should consume the captured live preflight evidence and define one explicit, narrowly bounded physical validation transaction with preconditions, deadlines, abort conditions and deterministic restoration. The transaction must remain separate from normal production fan control until it succeeds on this machine.

## Step 2 — Standalone bounded physical transaction (Next7)

Step 2 adds a **standalone validation executable**, not a production fan backend. `Tools/Phase45PhysicalValidation.swift` is intentionally absent from the Xcode application/daemon targets and therefore cannot make `Ftst` writable through normal Helios UI or XPC.

The executable is pinned to the live Step-1 profile (`Mac16,1`, build `25G83`, exactly one fan, `Ftst`=`ui8 `/1 byte, `F0Md`, target type `flt `/`fpe2`). Its write allowlist contains only:

- `Ftst` values `0` / `1`,
- `F0Md` values `0` / `1`,
- `F0Tg` using the already-read target encoding and a factory-bounded 3000 RPM validation target.

It cannot represent factory-limit writes, arbitrary SMC keys, `FS!`, or unrelated diagnostic keys.

### Durable validation recovery

Before the first `Ftst = 1` request the v2 recovery record is persisted and `fsync`ed to the root-owned, locked validation-only file:

```text
/var/db/com.snejda.Helios.phase45-validation-v2
```

The validation journal is separate from the current production fan journal. A stale/non-clean validation record blocks a new trial. `--restore-only` writes nothing when the journal is clean, specifically to avoid clearing a global flag that may belong to another controller.

### Transaction

The single Step-2 transaction is:

1. repeat the exact read-only live preflight,
2. require a clean durable validation journal,
3. persist global-acquisition risk,
4. request `Ftst = 1`,
5. require two stable `Ftst == 1` observations within 2.5 seconds,
6. persist fan-0 risk,
7. attempt the source-backed `F0Md = 1` transition with a strictly bounded 8-second window; only firmware result `0x82` is retryable,
8. write factory-bounded `F0Tg = 3000`,
9. verify `Ftst == 1`, `F0Md == 1`, and target readback,
10. observe actual RPM for at most 6 seconds (no additional fan write),
11. request fan 0 automatic mode without assuming Apple will expose a zero target,
12. persist global-release intent before `Ftst = 0`,
13. require two stable `Ftst == 0` observations,
14. only after global release, require stable automatic fan readback,
15. repeat the complete read-only baseline and require `Ready for validation` again.

The entire transaction has a 25-second ceiling. SIGINT/SIGTERM/SIGHUP request cancellation rather than intentionally bypassing cleanup. `SIGKILL` cannot execute process cleanup and is explicitly **not** part of Step 2.

### Failure rule

Any acquisition, target, readback, cancellation or physical-response failure enters recovery and attempts the already-tested release executor before returning the original failure. If restoration itself cannot be confirmed, the journal remains non-clean and the operator is instructed to run:

```sh
sudo .build/Validation/Phase45PhysicalValidation --restore-only
```

Step 2 can validate a normal acquire / physical response / graceful deterministic release only. It does **not** validate helper crash/SIGKILL recovery, sleep/wake restoration, reboot semantics, external-controller arbitration, or authorize removal of the production gate.


## Step 2b — Live-evidence corrections after the first physical transaction (Next8)

The first Step-2 live transaction produced two important pieces of hardware evidence before the production gate was changed:

- `Ftst = 1` succeeded and `F0Md = 1` was accepted only after several bounded `0x82` arbitration rejections;
- `F0Tg = 3000` returned transport/SMC success, but the transaction did not reach the durable `OWNED` print before recovery, showing that target readback must not be treated as synchronously visible.

Recovery then demonstrated that Apple-managed mode on this Mac may legitimately read as mode `0` with `F0Tg = 2317` and `F0Ac = 2317` after release. A zero target is therefore not a System invariant. The corrected recovery order is automatic request -> durable global release intent -> `Ftst = 0` -> stable global readback -> stable per-fan automatic verification. This corrected path was physically validated by `RESTORE-ONLY PASSED` and a final read-only `Ready for validation` baseline.

Next8 applies the same asynchronous rule to acquisition target verification. `FanOwnershipAcquisitionExecutor` now polls `verifyFanOwned` with the same bounded, cancellation-aware, stable-consecutive-read policy used for `Ftst` instead of checking the target once immediately after `F0Tg` write acknowledgement.

The physical-response criterion is also strengthened. The original `actual >= 1000 RPM` check could pass even when Apple was already idling the fan at the observed 2317 RPM factory minimum. Step 2b instead requires actual RPM to move materially toward the 3000 RPM command: at least the maximum of baseline+200 RPM, factory-min+200 RPM, and 90% of the requested validation target.

Step 2b still validates only a normal acquire -> physical response -> graceful release transaction. Intentional crash/SIGKILL validation is deferred until this corrected graceful transaction reaches `PHASE45 PHYSICAL VALIDATION PASSED`. Production Boost/Override remain gated.


## Step 3 — SIGKILL / fresh-process recovery evidence (Next9)

The corrected Step-2b transaction reached `PHASE45 PHYSICAL VALIDATION PASSED` on the pinned `Mac16,1` / `25G83` host. The standalone Step-3 harness then acquired durable ownership at a 3000 RPM target, observed the fan physically climb to 2765 RPM, intentionally SIGKILLed the owning process, and launched a fresh process that recovered solely from the durable v2 journal. Recovery returned `Ftst` to 0, restored automatic fan mode, and ended on a clean `Ready for validation` baseline.

This establishes hardware evidence for graceful release and for process-death -> fresh-process journal recovery. It does not establish sleep/wake semantics, reboot/boot-time persistence, or external-controller arbitration.

## Step 4 — Production daemon recovery-only bootstrap (Next10)

Next10 moves only the **recovery half** of the validated v2 design into `HeliosDaemon`; acquisition and target ownership remain gated. The daemon now owns a separate root-only journal at:

```text
/var/db/com.snejda.Helios.fan-ownership-v2
```

On daemon startup it constructs a v2 state machine first. A clean/empty record returns without constructing the AppleSMC recovery writer, proving that a normal launch cannot perform a fan write. Only a non-clean journal may instantiate the exact-profile recovery backend. That backend is pinned to `Mac16,1` / `25G83` / one fan and its complete write surface is restricted to `F0Md=0` and `Ftst=0`; it cannot acquire global ownership, enter manual mode, or write a target RPM.

Startup recovery runs before the XPC listener is exposed. If recovery cannot be verified, the journal remains non-clean and fan takeover stays unavailable. The normal production controller is still gated and the legacy per-fan engine remains unchanged.

The remaining blocker is sleep/wake: the daemon must restore before sleep, reopen/reprobe AppleSMC after wake, prove a clean System baseline, and never auto-resume the previous takeover. Only after that behavior is physically validated should the production acquisition backend be connected.

## Step 5 — Sleep/wake restoration and fresh SMC reprobe (Next11)

Next11 prepares the final hardware safety gate without enabling production acquisition. Two changes are intentionally separated:

1. **Production daemon wake safety infrastructure.** On `SystemHasPoweredOn`, the coordinator stays paused, revokes the control lease, destroys any pre-sleep fan engine, runs journal-gated production recovery, and then creates a brand-new read-only `SMCFanOwnershipPreflightReader`. Only a clean `Mac16,1` / `25G83` System baseline may complete the wake check. A clean production journal still opens no recovery writer and performs no SMC write. If the journal is dirty, the existing recovery-only allowlist remains `F0Md=0` and `Ftst=0`.
2. **Standalone physical sleep/wake validator.** The validator acquires the already-validated 3000 RPM ownership state, registers native `IORegisterForSystemPower` notifications, and waits for a normal user-initiated macOS sleep. On `SystemWillSleep` it restores System control *before* calling `IOAllowPowerChange`, confirms the durable journal is clean, then deliberately drops the pre-sleep SMC facade. On `SystemHasPoweredOn` it creates fresh AppleSMC readers, optionally performs journal-gated recovery if the pre-sleep release failed, and requires a complete `Ready for validation` baseline.

The sleep/wake validator does not spawn `pmset`, does not use `Process()`, and does not issue a private sleep command. The user triggers normal system sleep after the tool prints `SLEEP_WAKE_ARMED`. The arming window is bounded; cancellation before sleep attempts recovery before the validator exits.

A successful Step-5 physical run must show:

```text
SLEEP_WAKE_ARMED
SystemWillSleep
PRE-SLEEP RESTORE PASSED
SystemHasPoweredOn
WAKE RECOVERY: journal already clean; no recovery write required.
State: Ready for validation
PHASE45 SLEEP/WAKE RESTORATION PASSED
```

This was the Step-5 gate before the live result below; production acquisition remained disabled until the sleep/wake harness succeeded.

## Step 5 live result — 2026-09-07

The sleep/wake harness passed twice on the pinned `Mac16,1` / `25G83` host. In both runs it first acquired the validated 3000 RPM ownership path and observed a material physical response (2705 RPM and 2725 RPM respectively), then restored `F0Md` to automatic and `Ftst` to 0 before acknowledging `SystemWillSleep`.

The first power transition returned from `SystemWillSleep` to `SystemHasPoweredOn` in roughly 0.7 seconds, exercising an immediate/aborted wake shape. The second remained asleep for roughly 19.6 seconds and exercised a normal real sleep cycle. Both wake paths opened fresh AppleSMC state, found the recovery journal clean, and ended on `State: Ready for validation` with `Ftst=0` and automatic fan mode.

The installed production daemon independently logged both native power-notification cycles. For the real sleep it recorded pre-sleep restoration before power acknowledgement, then on wake a clean production-v2 bootstrap, a fresh read-only System baseline, disposal of stale pre-sleep SMC hardware, and completion of the post-wake safety reprobe. This closes the standalone Phase-4.5 sleep/wake gate for the pinned profile and permits the narrow Phase-4.6 production Boost integration. It does not validate Override, Auto Max, another Mac/OS profile, or concurrent ownership with another controller.
