# Phase 4.3 — Safe M4 Fan Takeover Prototype

## Scope

Validation-only physical prototype on the primary machine (Mac16,1 / Apple M4 / macOS Tahoe 26.6.2). The production takeover gate remained closed. The experiment used only the previously researched `Ftst` candidate sequence and was required to stop at the first unexpected state transition.

## Preconditions

- Existing signed/approved privileged daemon and authenticated protocol-v2 XPC path were retained.
- `Ftst` was confirmed read-only before the trial as `ui8 ` and initially `0`.
- Fan 0 remained in the known System baseline: mode `3`, target `0`, actual `0`, with factory limits unchanged.
- No factory min/max keys, security settings, SIP/AMFI state, or unrelated SMC keys were modified.

## Physical observation

The single trial issued the source-backed global candidate transition `Ftst = 1`.

The SMC write transport returned success, but the immediately following readback still reported `Ftst = 0`. Approximately half a second later, readback changed to `Ftst = 1` without another write.

Because the validation prototype assumed immediate readback, this delayed transition invalidated its cleanup/verification assumption. The experiment aborted before any per-fan manual-mode write and before any 3000 RPM target write.

During restoration, clearing `Ftst` also exhibited delayed observable state. Restoration was allowed to settle and was verified by readback.

## Verified final state

- `Ftst = 0`
- fan mode = `3` (System/automatic baseline)
- target RPM = `0`
- actual RPM = `0`
- factory minimum/maximum unchanged
- no manual-mode write occurred
- no physical RPM target write occurred
- normal gated helper build restored

## New invariant

A successful SMC transport return is not proof that the global ownership state has already changed. On this M4, `Ftst` visibility is asynchronous in both acquisition and release directions.

Therefore future ownership logic must:

1. persist recovery intent before the first global write,
2. treat the previous readback value as a valid pending state for a bounded interval,
3. poll read-only state instead of assuming immediate visibility,
4. require consecutive stable observations before declaring acquisition or release complete,
5. remain cancellation/lease aware throughout the wait,
6. fail closed on any value outside the source-backed `0`/`1` states,
7. retain recovery state until release is stably confirmed,
8. never enable the production hardware profile from transport success alone.

## Exit status

Phase 4.3 established delayed global-state behavior but did **not** validate full takeover, RPM control, or deterministic crash restoration. Production fan takeover remains gated.
