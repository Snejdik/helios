# M4 fan ownership — research-only review

Reviewed 2026-09-06. This review supersedes the earlier request to continue physical testing: **no new physical writes, mode changes, service restarts, sleep tests, or reboot tests were performed.** Production code, signing, authentication and the hardware gate remain unchanged.

## Decision

There is a credible, source-visible takeover mechanism for some M4 Macs. It uses the undocumented global `Ftst` diagnostic flag together with per-fan mode and target keys. Its full thermal-policy effects and crash/reboot recovery are not established for this `Mac16,1` on 26.6.2 (25G83). It is a research candidate, not an approved Helios backend or a physical-test recommendation. TG Pro's published behavior does not disclose its register sequence; equivalence of mechanism cannot be asserted.

## Evidence from this Mac

The previous physical attempt is recorded in [PHASE4_1.md](PHASE4_1.md): `F0Tg` accepted the 3000 RPM transaction, then `F0Md=1` returned firmware result `0x82`. Neither the target nor physical rotation persisted. That is consistent with the upstream protected-mode observations, but does not prove the proposed unlock will work safely here.

A new **unprivileged read-only** observation at 20:23:09 CEST used only Helios's shared SMC read transport, with no daemon writer linked:

| Key | Type / bytes | Value |
| --- | --- | --- |
| `Ftst` | `ui8 ` / 1 | 0; attributes `0xd0` |
| `FNum` | `ui8 ` / 1 | 1 |
| `F0Md` | `ui8 ` / 1 | 3 |
| `F0Tg` | `flt ` / 4 | 0 RPM |
| `F0Ac` | `flt ` / 4 | 0 RPM |
| `F0Mn` | `flt ` / 4 | 2317 RPM |
| `F0Mx` | `flt ` / 4 | 6550 RPM |

This establishes presence, format and idle baseline, **not writability or reset behavior**. Mode and global state agree with the prior automatic baseline. The observation was sequential, not an atomic hardware snapshot. TG Pro and Stats were not reconfigured or stopped.

The probe, log and downloaded source snapshots are in ignored `.build/Research/m4-ownership/`. The probe compiled under Swift 6 complete strict concurrency. No production rebuild was needed for this documentation-only review.

## TG Pro's actual public contract

The [official user guide](https://www.tunabellysoftware.com/support/tgpro_tutorial/) confirms that Apple Silicon Max and Auto Max take complete control and use maximum speed to avoid an insufficient manual setting. Optional Manual and Auto Boost replace those defaults with full user responsibility. The user's screenshots show these advanced options enabled; they do not show the internal takeover implementation.

The [official deployment settings](https://www.tunabellysoftware.com/support/remotely_deploy_tg_pro.php) expose a default-enabled sleep-release preference and default-disabled complete-override preferences. The [FAQ](https://www.tunabellysoftware.com/support/faq/) promises return to macOS defaults on quit/uninstall. It does not specify helper-SIGKILL recovery latency, `Ftst` reset ordering, or firmware persistence.

There is a documentation discrepancy: the FAQ still describes M4 fan control as unavailable when hardware has powered the fans off, while [release 2.95, March 3, 2025](https://www.tunabellysoftware.com/tgpro/releasenotes/) explicitly adds that capability. The dated release establishes vendor support; neither page establishes how it is implemented. No claim about TG Pro's exact SMC sequence is made here.

## What the modern implementations actually do

**Stats:** [PR 2924](https://github.com/exelban/stats/pull/2924) merged February 22, 2026. The inspected [SMC implementation](https://github.com/exelban/stats/blob/60e65d1454c647d9592550447757e509b01d5ebb/SMC/smc.swift) attempts manual mode directly, then falls back to `Ftst=1`, waits three seconds, and retries mode `1`. RPM commands follow the mode change. Release writes mode `0` and clears the target; a separate reset clears `Ftst`. The mode-retry loop can last roughly thirty seconds. Both transport and firmware results are checked, but readback is not equivalent to Helios's full safety verification.

The [Stats helper](https://github.com/exelban/stats/blob/60e65d1454c647d9592550447757e509b01d5ebb/SMC/Helper/main.swift) launches an SMC subprocess. Its connection invalidation handler removes the connection and asks the helper to quit when none remain; that handler does not perform a physical reset. The [sensor UI](https://github.com/exelban/stats/blob/60e65d1454c647d9592550447757e509b01d5ebb/Modules/Sensors/popup.swift) coordinates the global reset when displayed fans are automatic and can restore requested speeds after wake. These lifecycle choices must not be copied into Helios.

**macos-smc-fan:** the [controller](https://github.com/agoodkind/macos-smc-fan/blob/31a1feae0c4999ebd8cdddfbd90d2c98182091b8/Sources/SMCFanKit/FanController.swift) implements the diagnostic transition. Its [measurement table](https://github.com/agoodkind/macos-smc-fan/blob/31a1feae0c4999ebd8cdddfbd90d2c98182091b8/docs/testing.md) is for a two-fan M4 Max, not this one-fan M4. First acquisition took about 5–6.5 seconds and affected the other fan as well. It also reports operation outside advertised limits; Helios must retain its own strict bounds regardless of what firmware accepts.

The [research limitations](https://github.com/agoodkind/macos-smc-fan/blob/31a1feae0c4999ebd8cdddfbd90d2c98182091b8/docs/research.md) explicitly mark helper crash with `Ftst` active as untested, firmware sleep reset as inferred, and mode-0 thermal ramping as unverified. Broader assertions elsewhere in that document about automatic recovery cannot override those limitations. Its explanation of interactions with `LifetimeServoController` and `AppleCLPC` is reverse-engineering analysis, not an Apple API contract or independently established behavior on this OS build. Treat the possibility of effects beyond fan arbitration as unresolved.

The current [helper](https://github.com/agoodkind/macos-smc-fan/blob/31a1feae0c4999ebd8cdddfbd90d2c98182091b8/Sources/Helper/SMCFanHelper.swift) only removes arbitration ownership on disconnect; [arbitration expiry](https://github.com/agoodkind/macos-smc-fan/blob/31a1feae0c4999ebd8cdddfbd90d2c98182091b8/Sources/SMCFanKit/FanArbitrator.swift) allows another claimant and is not a physical restoration watchdog. Its automatic-release method logs some write errors but still replies success. Those are not suitable Helios guarantees.

**fanpro:** [unlock code](https://github.com/omar16100/fanpro/blob/7c69bf1ad9c0b9ea2b7103b875d04e1875d1dd7b/src/fan/unlock.c) illustrates polling for mode-3 exit, tracking a global flag, cleanup and startup recovery. Its [engineering log](https://github.com/omar16100/fanpro/blob/7c69bf1ad9c0b9ea2b7103b875d04e1875d1dd7b/docs/engineering-log.md) reports successful SIGTERM and SIGKILL/restart recovery on M3 Ultra **without `Ftst`**, explicitly leaving the `Ftst` path to simulated tests and reboot/sleep validation unperformed. This is useful design evidence, not M4 validation. Its [hardware reference](https://github.com/omar16100/fanpro/blob/7c69bf1ad9c0b9ea2b7103b875d04e1875d1dd7b/docs/smc_reference.md) cites a different M4 model, `Mac16,6`. Its speculation that key casing is an OS-generation change is insufficient here: this Tahoe machine still exposes uppercase `F0Md`.

**MacFanControl:** the [Rust controller](https://github.com/raminsharifi/MacFanControl/blob/1669877f01365fd1d948085ccbf4627691153c1b/src/control.rs) corroborates the same entry sequence and clamps targets. It offers an explicit quit-without-restoration path, automatically reasserts requested control after drift, and discards an error when releasing `Ftst` in `maybe_release_ftst`. It is not a recovery reference to adopt wholesale.

## Lifecycle evidence and remaining acceptance conditions

| Event | Established / unresolved | Consequence for Helios |
| --- | --- | --- |
| Enter takeover | Source-visible global diagnostic transition followed by per-fan manual/target writes; not exercised here | No speculative fallback or retries of this Mac's rejected writes |
| Return to System | Sources clear per-fan override and global diagnostic state; exact ordering/readback under load remains unvalidated here | Mode `0` alone cannot prove Apple's normal mode-3 ownership; verify the complete profile-specific state |
| XPC disconnect / app death | Reviewed upstream disconnect bookkeeping does not itself guarantee hardware reset | Existing daemon lease must revoke and restore the entire ownership transaction independently |
| Graceful helper exit | Cleanup is possible while the helper executes; no M4 `Ftst` physical proof found | Restore, read back and retain the journal if unconfirmed |
| Crash / SIGKILL / restart | Dead processes cannot clean up; M4 diagnostic-state recovery remains untested | Durable recovery must include global state before the first write; restore before accepting takeover after restart |
| Sleep / wake | Vendor sleep-release preference exists; upstream firmware-reset attribution is inferred | Explicit release before sleep, fresh read-only reprobe after wake, remain System; do not automatically rearm |
| Reboot | No reviewed evidence establishes **every** reboot restores Apple ownership on this exact build | Do not use reboot as a proven emergency-restoration guarantee |
| Persistent firmware state | Reviewed candidate paths do not explicitly write factory limits, NVRAM, firmware images or thermal preference files | This does not prove `Ftst` has no persistent or wider firmware effects; volatility remains unverified |

## Integration work that must precede any new test proposal

These are design requirements, not implemented changes:

1. Keep System / Max / Auto Max / advanced Override semantics. Mode selection cannot bypass capability checks. Manual RPM remains clamped to freshly read advertised limits, even where firmware permits more.
2. Extend the journal beyond fan-ID bits to versioned, machine-bound global ownership and acquisition/release stages. Persist intent before any global transition. Cover a crash between asserting the global flag and the first fan-mode write, as well as failed rollback. Do not clear recovery evidence on an acknowledgement alone.
3. Define profile-specific System verification. A cleared target at idle is useful evidence, but Apple may legitimately set a nonzero target under load. Neither zero actual RPM nor zero target universally proves ownership. Expected global state and Apple-managed mode matter.
4. Resolve acquisition timing before implementation: the published 5–6.5-second entry can outlast Helios's five-second sample-based lease. A blocking retry loop must not extend the lease or arm from stale data. Any staged acquisition needs independent cancellation, fresh calculations and rollback throughout; heartbeats remain insufficient.
5. Establish exclusive external-controller handling. `Ftst` is global and does not identify its owner. A Helios journal cannot coordinate TG Pro or Stats. Do not adopt unconditional startup resets of another tool's control, repeated write contests, or automatic reassertion after drift.
6. Obtain stronger evidence for `Ftst`'s broader thermal-policy role, failure/release behavior, and persistence on this hardware/OS before proposing physical validation. Vendor clarification or inspectable firmware/driver evidence would help; passive baseline reads alone cannot establish crash behavior. Leave remaining unknowns explicit.

The current production gate stays closed. Existing signed NSXPC authentication, the daemon-only native write boundary, and the prohibition on arbitrary-key commands remain appropriate. No new unlock/test-mode use has been authorized by this research request.
