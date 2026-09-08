# Phase 4.1 — Controlled physical fan validation

## Result: stopped at firmware rejection

On 2026-09-06, the user explicitly authorized physical fan writes on this Mac and accepted **recovery on daemon restart** after SIGKILL, rather than instantaneous cleanup by a dead process. The first conservative takeover attempt failed at the manual-mode write. In accordance with the stop condition, no additional targets, Boost, disconnect-under-override, graceful-termination-under-override, or forced-termination recovery tests were attempted. **No production hardware profile was enabled.**

## Exact machine and preflight

- Apple M4 MacBook Pro, model `Mac16,1`.
- macOS Tahoe 26.6.2, build `25G83`.
- One fan; factory range 2317–6550 RPM.
- The temporary validation build checked this machine's SHA-256 platform-UUID fingerprint and exact OS build before constructing the native writer, and checked the fan count and factory bounds again. The fingerprint is retained only in ignored local artifacts.

Native read-only discovery found the uppercase mode key `F0Md`; lowercase `F0md` is absent. The metadata attributes below are raw observations, not a guarantee of write authorization.

| Key | Type | Size | Attributes | Initial value |
| --- | --- | ---: | --- | ---: |
| `FNum` | `ui8 ` | 1 | `0x80` | 1 |
| `F0Ac` | `flt ` | 4 | `0x84` | 0 RPM |
| `F0Tg` | `flt ` | 4 | `0xd4` | 0 RPM |
| `F0Mn` | `flt ` | 4 | `0x84` | 2317 RPM |
| `F0Mx` | `flt ` | 4 | `0x85` | 6550 RPM |
| `F0Md` | `ui8 ` | 1 | `0xd0` | 3 (automatic) |

The `flt ` values are little-endian Float32. TG Pro and Stats were temporarily quit before the trial. The separately installed TG Pro privileged helper was not uninstalled or reconfigured. Helios's normal app was stopped and its daemon asynchronously unregistered before replacing the executable.

## Physical trial and exact result

The staged build retained Apple Development signing, Team `3J76KPDS9C`, both Foundation signing requirements, protocol v2, the original five-second calculation lease, fresh thermal timestamps, clamping, the root-owned journal, rollback and readback. Its write sink was additionally restricted to this fan's 3000 RPM target and automatic restoration. The staged app exposed only the explicit diagnostic invocation and registration operations, with no normal fan-control UI.

App PID `21376` authenticated installed root daemon PID `21356`. A fresh complete SoC sample measured **68.640625°C**. At **20:04:24.482 CEST**, the daemon issued these writes, in order:

| Operation | Key / type | Payload bytes | IOReturn | SMC result | SMC status | Reply size |
| --- | --- | --- | --- | --- | --- | ---: |
| Request 3000 RPM | `F0Tg` / `flt ` | `00 80 3b 45` | `0x0` | `0x0` | `0x0` | 80 |
| Request manual mode | `F0Md` / `ui8 ` | `01` | `0x0` | **`0x82`** | `0x0` | 80 |

The target transaction returned success, but a nonzero target was not observed afterward. The manual-mode transaction was explicitly rejected by SMC; a successful IOKit transport return did not mean the firmware accepted it. No interpretation of the undocumented `0x82` result beyond rejection is assumed here. There were exactly two hardware write calls in the captured trial; no further takeover request was sent after rejection.

Readback immediately after failure and again during cleanup:

```text
BEFORE:   F0Md=3 F0Tg=0.0 RPM F0Ac=0.0 RPM
REJECTED: F0Md=3 F0Tg=0.0 RPM F0Ac=0.0 RPM
FINAL:    automatic=true, target=0, actual=0, minimum=2317, maximum=6550
```

The fan stayed stopped and automatic. This does **not** constitute a successful takeover/release test: manual control was never established. Restoration found mode 3 and target 0 already in place, verified them, and avoided redundant hardware writes. The engine reported System through its journal-clearing success path. The recovery file was observed as a one-byte, root-owned, mode-0600 file; direct byte inspection was not available without interactive administrative authentication.

## Cleanup and retained changes

The validation helper was unregistered. All temporary compilation branches, machine-pin allowances and physical-probe entry points were removed from production sources. The normal signed Debug/Release builds retain the original closed hardware gate and unchanged IPC authentication. No minimum/maximum keys, arbitrary keys, firmware unlock/test keys, SIP settings or macOS security settings were changed.

Two daemon-only improvements remain: write diagnostics record exact key/type/payload and both IOKit/SMC results, and automatic restoration first reads existing state, skips unnecessary writes, and confirms both automatic mode and a cleared target before success. Factory clamping, lease revocation, journal persistence and rollback remain in place.

The restored normal Debug and Release builds passed Swift 6 strict compilation and deep/strict signature verification. Simulated fan safety regression checks passed. SMAppService returned Installed, and the normal client authenticated root daemon PID `21760` with v2 and 11 heartbeats over twelve seconds after cleanup. Helios, Stats and TG Pro were reopened. The normal hardware gate is closed; the temporary physical-validation branches are absent from `Sources`.

The previous Phase 4 record's absent-certificate and instantaneous-restoration requirements are historical: signing and real installed IPC were resolved in Phase 3's live follow-up, and the user revised the SIGKILL contract for this phase. The current blocker is the actual `F0Md` rejection. Removing a UI gate cannot make that write succeed within the approved constraints.

## Evidence

Ignored local artifacts:

- `.build/Verification/phase4_1-preflight.log`
- `.build/Verification/phase4_1-physical-3000.log`
- `.build/Verification/phase4_1-physical-stream.log`
- `.build/Verification/phase4_1-after-rejection.log`
- `.build/Verification/phase4_1-validation-unregister.log`
- `.build/PhysicalValidationSources/` — preserved staged source snapshots, excluded from production builds.

The read-only format cross-check used the upstream [Stats SMC implementation](https://github.com/exelban/stats/blob/master/SMC/smc.swift); the result above comes from this Mac's actual native IOKit transactions. No upstream unlock path was used. Further physical trials require a separately authorized approach compatible with the user's restrictions; this failed trial does not validate Boost, Override, sleep/wake, or crash recovery.
