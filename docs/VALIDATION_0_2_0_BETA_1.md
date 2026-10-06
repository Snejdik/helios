# Helios 0.2.0 Beta 1 — validation

Identity: tag `v0.2.0-beta.1`, bundle version 0.2.0, build 4. Date 2026-10-05.
This page records what was verified for Beta 1 and what was not.

## Automated gates

Each gate runs once, in this order, from a clean derived-data directory for the
builds. All pass.

| Gate | Command | What it checks |
|---|---|---|
| diff | `git diff --check` | No whitespace errors |
| runtime-policy | `scripts/check-runtime-policy.sh` | No forbidden runtime behaviour in the sources |
| battery-readonly | `scripts/check-battery-readonly.sh` | The battery path stays read-only |
| ui-boundary | `scripts/check-next23-ui-boundary.sh` | Protected fan, XPC and battery files match their fingerprints |
| preferences | `scripts/check-preferences-semantic.sh` | Preference defaults, migrations and semantics |
| detailed-ui-coverage | `scripts/check-detailed-ui-coverage.sh` | Every UI module is reachable and accessible |
| ui8-portable | `scripts/check-ui8-portable.sh` | UI contract |
| perf-tooling | `scripts/check-perf-tooling.sh` | Performance scripts are consistent |
| storage-p1 | `scripts/check-storage-p1.sh` | Storage provider contract |
| performance-core | `scripts/check-performance-core.sh` | No per-tick I/O or allocation regressions in the core |
| ui-memory-lifecycle | `scripts/check-ui-memory-lifecycle.sh` | Windows and popovers release their view trees |
| apple-silicon-release | `scripts/check-apple-silicon-release.sh` | arm64, macOS 13, fan writes stay gated |
| updates | `scripts/check-updates.sh` | Release-tag parsing, ordering and the update checker |
| diagnostics | `scripts/check-diagnostics.sh` | Report schemas, `fan_layer`, consent, transport, native contract fixtures |
| presentation | `scripts/check-presentation.sh` | The full UI surface compiles under Swift 6 strict concurrency, redraw isolation, fixtures |
| ownership | `scripts/check-ownership.sh` | Fan ownership and recovery state machine (simulated) |
| fans | `scripts/check-fans.sh` | Fan control engine, leases and recovery (simulated) |
| fan-layer | `scripts/check-fan-layer.sh` | Policy, probe tiers, journals, engine failure matrix (simulated) |
| ipc | `scripts/check-ipc.sh` | XPC authentication and protocol |
| telemetry | `scripts/check-telemetry.sh` | Providers, persistence, history compaction |
| storage | `scripts/check-storage.sh` | Storage and SMART |
| ui-fixtures | `scripts/check-ui-fixtures.sh` | 24 UI scenarios and the health assessment and Activity logic |
| build-debug | `xcodebuild … Debug` with warnings as errors | Clean build |
| build-release | `xcodebuild … Release` with warnings as errors | Clean build |

`scripts/check-all.sh` runs the scripted gates (everything above except the diff check and the two warnings-as-errors builds) and ends with `PASS full Helios regression gate and Xcode build`.

## Web backend

The diagnostics backend validates the same report formats. Its tests (77, one
skipped when no native fixtures are supplied) pass, and with the report files
produced by the app's own gate (`HELIOS_NATIVE_CONTRACT_FIXTURES`, including the
`fan_layer` report) all 29 diagnostics tests pass. `tsc --noEmit` and ESLint are clean.

## Run on a real Mac (Mac16,1, macOS 27.0.1)

- The signed Release builds and starts; the helper handshake (protocol v5) succeeds.
- Fans are under macOS control after start-up and during idle use (read-only
  readback: `Ftst=0`, fan mode 3).
- Fan layer at the factory minimum only: acquire, hold and release with verified
  readback; the lease expiring, the app being killed and the helper being updated or
  killed while holding all returned the fans to macOS (within milliseconds to seconds).
- Battery with and without Low Power Mode: takeover worked in both.

## Not verified

- Fan control above the factory minimum and Boost on a real Mac, other than through
  the simulated gates.
- Sleep or lid close while holding the fans, and reboot with ownership.
- Macs other than the Mac16,1; macOS versions other than 27.0.1.
- Clean-machine installation and helper approval, VoiceOver, and long-term resource use.
- Notarization (the build is not notarized).
