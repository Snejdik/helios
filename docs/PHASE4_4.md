# Phase 4.4 — Asynchronous M4 Ownership & Recovery Architecture

## Objective

Convert the Phase 4.3 delayed-`Ftst` observation into a deterministic, testable ownership protocol before any additional physical write validation.

## Current implementation boundary

The first Phase 4.4 patch is intentionally simulation-only:

- production fan takeover remains gated,
- `SMCFanHardware` gains no `Ftst` write path,
- XPC surface is unchanged,
- existing per-fan engine behavior is unchanged,
- no new physical validation procedure is enabled.

## Step 1 — Delayed transition primitive

Add a pure ownership-transition tracker/poller that models the observed firmware behavior:

- acquisition may read `0` after the `Ftst = 1` request before later reading `1`,
- release may read `1` after the `Ftst = 0` request before later reading `0`,
- only `0` and `1` are accepted observations,
- completion requires configurable consecutive stable reads,
- waiting is bounded by a configurable deadline,
- each iteration requires an injected permit so lease revocation/cancellation can stop progress,
- all timing/read/wait behavior is injected for deterministic tests.

The primitive performs no SMC I/O itself. Hardware integration, journal v2, wake reprobe, and a second physical validation remain later steps within Phase 4.4/4.5.

## Step 2 — Recovery journal v2 model

The second patch remains simulation-only and adds the durable state model required before a future global-ownership implementation can touch `Ftst`.

### Record semantics

A v2 record tracks:

- a monotonic journal generation,
- the acquisition/release phase,
- whether global ownership **may** be active,
- the set of fans that **may** have been touched.

The wording is intentionally conservative. A bit/flag is set before its corresponding future hardware write, so a crash cannot make the journal less conservative than the hardware.

### Required ordering

Future hardware integration must preserve this ordering:

1. persist `acquiringGlobal` with `globalOwnershipMayBeActive = true`,
2. only then request `Ftst = 1`,
3. retain that flag while immediate readback still shows the old value,
4. after stable global readback, journal each fan before touching it,
5. retain each fan until System/automatic restoration is independently verified,
6. persist `releasingGlobal` while `Ftst = 0` is pending,
7. clear global risk only after consecutive stable `Ftst == 0` observations,
8. only the final clean System record permits a new takeover.

A persistence failure never advances the in-memory state machine, so a caller cannot use failed journaling as authorization for a future hardware write.

### Crash cases covered by simulation

The fan checks now cover:

- crash after durable global acquisition intent but before/while delayed `Ftst = 1` becomes visible,
- daemon restart from that ambiguous acquisition record,
- crash with one or more fans journaled as possibly touched,
- partial verified fan restoration,
- refusal to release global state while any fan remains unverified,
- crash after a future `Ftst = 0` transport success but before stable `0` readback,
- journal persistence failure before acquisition,
- fixed-width v2 record round-trip and corruption detection,
- structurally impossible/corrupt recovery records failing closed.

### Durable format boundary

`FanOwnershipRecoveryCodec` defines a fixed-width, versioned, checksummed v2 record (`HLF2`). It is not yet connected to `/var/db` and does not replace the existing production per-fan journal. Actual root-owned disk activation is deferred until the new ownership engine and recovery executor are both defined and tested together.

## Current gate status

No production SMC behavior changes in Step 2:

- no `Ftst` write API exists in `SMCFanHardware`,
- no new XPC command exists,
- the current production takeover gate remains closed,
- the existing per-fan production engine/journal remains unchanged,
- no physical validation is authorized by this patch.


## Step 3 — Simulation-only recovery executor

Step 3 connects the delayed-transition primitive to the conservative v2 recovery state machine through a fully injected recovery executor. It still adds no production SMC write path.

### Recovery execution ordering

For any non-clean v2 record, the executor now models this fail-closed order:

1. persist `recoveryRequired` before the first recovery hardware action,
2. enter the release phase without clearing any risk bits,
3. for every journaled fan, request System restoration and independently verify it,
4. remove that fan from the durable record only after verification succeeds,
5. refuse global release while any fan remains unverified,
6. persist `releasingGlobal` before the injected global-release request,
7. after the request returns, poll delayed global ownership readback through `FanOwnershipTransitionPoller`,
8. require consecutive stable `0` observations,
9. only then persist the clean System record.

A transport-success return therefore never clears global ownership risk by itself.

### Failure semantics covered by simulation

The checks now prove that:

- delayed global release (`1, 1, 0, 0`) remains journaled until stable readback,
- `releasingGlobal` is durable before the simulated global-release hardware action,
- partial fan recovery keeps only unresolved fan IDs and blocks global release,
- a global-release timeout returns to `recoveryRequired` with global risk preserved,
- persistence failure after a fan has physically verified System still keeps its conservative risk bit on disk,
- a clean journal is a strict no-op.

### Production boundary remains unchanged

`FanOwnershipRecoveryHardware` has no production conformer. `SMCFanHardware` still has no global/Ftst write API, the current per-fan production engine is unchanged, XPC is unchanged, and the production takeover gate remains closed. Step 3 authorizes no physical fan validation.

## Step 4 — Simulation-only acquisition executor and thermal-input hardening

Step 4 adds the acquisition-side counterpart to the recovery executor. It remains fully injected and cannot reach AppleSMC.

### Acquisition ordering now modeled

A future M4 takeover must satisfy this sequence:

1. persist `acquiringGlobal` with global risk set,
2. only then request the candidate global ownership transition,
3. wait for bounded, consecutive stable global readback of `1`,
4. persist `globalOwned`,
5. before each fan is touched, persist that fan ID as possibly modified,
6. request the candidate per-fan manual transition,
7. apply the already bounded per-fan target,
8. verify manual ownership and target readback,
9. persist `owned` only after every requested fan verifies.

Any timeout, cancellation, transport error, target error, or verification failure preserves the conservative record as `recoveryRequired`. Acquisition does not silently continue to later fans after a failure. A failed pre-write journal save performs no hardware action.

`FanOwnershipAcquisitionHardware` deliberately has no production conformer. This step does not authorize a physical test.

### Thermal input trust hardening

The primary M4 showed fast hotspot changes during builds, while TG Pro may display a slower or differently aggregated value. Helios must not hide a real hotspot merely to visually match another utility, but fan policy also must not trust an arbitrary newly discovered SMC key.

The M4 classifier therefore no longer promotes every `Tp*`, `Te*`, or `Tg*` temperature key into a trusted SoC group. Only the currently source-visible M4-family thermal-zone keys are trusted; unknown keys remain readable as unclassified diagnostics and cannot inflate `Max SoC` or drive fan policy. The UI exposes the hottest trusted zone group, while the exact raw key stays in help/diagnostics.

The fan-control path continues to use the raw trusted maximum with no smoothing. Short real hotspot spikes are intentionally preserved for safety; display smoothing, if ever added, must be presentation-only and must never feed control decisions.

## Current gate status after Step 4

Still unchanged:

- no production `Ftst` write API,
- no production acquisition/recovery conformer,
- no v2 root disk activation,
- no XPC expansion,
- no physical fan test authorized,
- production takeover remains gated.


## Step 5 — Steady-state target updates and faster iteration checks

Step 5 fills the runtime gap between acquisition and release. A real Override/Auto-Max session cannot reacquire global ownership and per-fan manual mode for every fresh thermal sample; once ownership is verified, subsequent calculations must update only the already owned fan targets.

`FanOwnershipTargetUpdateExecutor` therefore models the steady-state path with these invariants:

1. target updates are accepted only from durable `.owned`,
2. global ownership risk must still be set,
3. the active fan set is immutable for that ownership session,
4. every target write is preceded by the injected lease/cancellation permit,
5. every target write is followed by ownership/target verification,
6. no global acquisition or per-fan manual transition is repeated during a normal update,
7. invalid targets or a changed fan set fail before hardware access,
8. cancellation, write failure, or verification failure persists `recoveryRequired`; the next legal operation is release/recovery.

Successful target-only updates do not rewrite the ownership journal because the set of possible hardware ownership side effects has not changed. Avoiding an fsync on every thermal sample is both semantically cleaner and important for a lightweight utility.

`FanOwnershipTargetHardware` has no production conformer. Step 5 still adds no AppleSMC write path and authorizes no physical fan test.

### Focused verification workflow

The broad development scripts are intentionally strong but slow because each compiles a standalone binary with overlapping source files. Phase 4.4 now includes:

```sh
./scripts/check-ownership.sh
```

This compiles only the ownership transition/recovery sources and a focused lifecycle fixture. It validates delayed global acquisition, durable acquire, steady-state target update, delayed release, and fail-closed update behavior without launchd, XPC, privileged execution, or physical SMC writes.

During normal Phase 4.4 iteration use the focused ownership check plus an incremental `xcodebuild`. Run the full fan/telemetry/IPC/presentation regression sweep at milestone boundaries or when those subsystems change. Clearing DerivedData is not part of the normal loop.

### Signing diagnostics

The app still enforces the same production trust requirement. Step 5 only makes local signing failures more specific: identifier mismatch and self-requirement rejection now report distinct diagnostic messages instead of collapsing into one generic `invalidIdentity` message. No trust condition was relaxed.

## Current gate status after Step 5

Still unchanged:

- no production `Ftst` write API,
- no production acquisition/target-update/recovery conformer,
- no v2 root disk activation,
- no XPC expansion,
- no physical fan test authorized,
- production takeover remains gated.

Step 5 completes the simulation model for acquire → repeated target updates → release. The next phase should prepare the read-only capability/preflight evidence required before a narrowly scoped second physical ownership validation.

## Phase 4.5 live recovery correction (2026-09-06)

The first physical takeover reached `Ftst=1`, eventually acquired `F0Md=1`, and
accepted `F0Tg=3000`. During release, requesting automatic mode caused live
readback to settle at `F0Md=0`, `F0Tg=2317`, `F0Ac=2317` while `Ftst` remained
`1`. The previous recovery executor incorrectly required `F0Tg==0` and final
per-fan System verification *before* allowing `Ftst=0`, creating an ordering
deadlock.

Corrected invariant:

1. Durable fan/global risk is retained.
2. Request per-fan automatic mode while global ownership may still be active.
3. Persist `releasingGlobal` **with pending fan bits intact**.
4. Request `Ftst=0` and require stable delayed readback.
5. Clear only global risk after stable `Ftst==0`.
6. Verify each pending fan under released global ownership using consecutive
   automatic-mode observations; `F0Tg==0` is **not** a System invariant because
   Apple may legitimately repopulate the target with the factory minimum.
7. Clear the journal only after all pending fan verification succeeds.

This correction remains confined to the Phase 4.5 validation/recovery path;
production takeover remains gated.


## Phase 4.5 Step 3 — SIGKILL / fresh-process recovery validation

The graceful Step 2b trial physically validated the complete live sequence on
Mac16,1 / 25G83: delayed `Ftst=1`, bounded `F0Md=1` arbitration, delayed
`F0Tg=3000` verification, physical rotation to at least 2700 RPM, then
`F0Md=0 -> Ftst=0` and a clean read-only System baseline.

Step 3 validates the property that graceful cleanup cannot prove: recovery after
the process that owns the fan state is unconditionally killed.

The standalone validator now has an internal `--arm-crash` mode that is not
intended for direct use. It requires both the exact machine confirmation token
and a second harness-only token. Once it has:

1. persisted the v2 ownership journal,
2. acquired stable `Ftst=1`,
3. acquired `F0Md=1`,
4. verified `F0Tg=3000`, and
5. observed a material physical RPM response,

it creates a private root-owned ready marker and deliberately performs no
cleanup. `scripts/run-phase45-crash-validation.sh`, run as root, waits for that
marker, sends `SIGKILL`, waits for the old process to disappear, and starts a
fresh `--restore-only` process. The new process has to reconstruct recovery from
the durable journal and live SMC readback, return `Ftst` to 0, verify automatic
fan state, clear the journal, and pass a final read-only preflight.

The harness fails closed: if the child exits or never reaches the ready marker,
it terminates any surviving child and invokes journal-gated recovery before
returning failure. The ready marker is not recovery authority; only the durable
checksummed journal authorizes SMC restoration writes.

This validates process-death persistence and fresh-process recovery, not yet
launchd auto-restart timing, sleep/wake reprobe, or production daemon wiring.
Production takeover remains gated.
