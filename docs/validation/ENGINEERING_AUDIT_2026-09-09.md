# Helios RC3 final engineering audit — 2026-09-09

> **Superseded memory-status note (later on 2026-09-09):** the manual exact-Release live-app memory protocol was completed after this autonomous audit. Across three repeated UI cycles the physical footprint plateaued and finished at **+15.0 MiB vs. the warm baseline** after final cleanup. The historical `NO-GO` below accurately records the state *at the end of the autonomous audit*, before that missing manual acceptance step. See [`../RELEASE_READINESS.md`](../RELEASE_READINESS.md) for the current project status.

## 1. Verdict

**NO-GO — BLOCKER REMAINS**

The supplied snapshot is now compilable, the full regression suite passes, and measured closed-UI CPU is below the supplied historical baselines. The frozen backend is unchanged. Memory acceptance remains unresolved: a five-cycle native fixture test releases the tested controllers but retains about 45 MiB additional physical footprint. The exact running application's complete interactive memory stress could not be completed through the available computer-use interface. A passing build and a plateau do not establish the requested low-memory release criterion.

This is a local engineering candidate, not a published or notarized release.

## 2. Root causes found

- **Compile failure:** the lazy diagnostic panel stored a builder closure but supplied the closure itself as View content. Calling `content()` in the expanded branch fixes compilation and retains laziness.
- **Unnecessary status-item redraws:** each native metric item compared every formatted telemetry value. Changes to unrelated metrics invalidated static/unaffected items. Invalidation now follows only configured visible values.
- **Incorrect process CPU units:** `proc_pid_rusage` user/system CPU counters were treated as nanoseconds. They are Mach time values. On this M4 the timebase is 125/3 ns per tick; the old conversion substantially understated per-process CPU and derived CPU-core-second attribution. Energy counters remain nanojoules.
- **Persistence data loss:** cached descriptors continued appending to an unlinked inode after atomic file replacement. Truncation could also leave the descriptor offset beyond the visible end. All three stores now detect identity/size changes at their existing append cadence and reopen at the real end.
- **Unterminated valid JSON tail:** a valid last record without a newline survived startup repair and could be concatenated with the next record. Startup repair now restores the record delimiter.
- **Memory remains partly attributed:** repeated controller release succeeds; most remaining footprint is live heap plus allocator fragmentation. No demonstrated production retain cycle accounts for the large residual footprint. It would be speculative to claim the remaining memory is harmless or fully reclaimable.

Apple kernel evidence for CPU units: [`fill_task_rusage`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) and [task power accounting using Mach time](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c). A corrected independent native sampler measured 27.59 ms/s during an earlier run, agreeing with overlapping powermetrics at about 27.7 ms/s. The original unscaled diagnostic CSV is explicitly marked invalid.

## 3. Production files changed

| File | Change and reason |
|---|---|
| `Sources/HeliosApp/HeliosWindows.swift` | Invoke the stored diagnostic builder only when expanded; repair the supplied compile failure. |
| `Sources/HeliosApp/MenuBarView.swift` | Suppress unrelated/static-item redraws while updating cached values; return the invalidation decision for focused regression coverage. |
| `Sources/HeliosApp/Telemetry/ProcessProvider.swift` | Convert process CPU Mach ticks using the native timebase; add separate floating-point deltas to avoid integer-sum overflow. |
| `Sources/HeliosApp/Telemetry/PersistentHistory.swift` | Verify cached descriptor identity/size, reopen after replacement/truncation, and repair missing final newline. |
| `Sources/HeliosApp/Telemetry/IOActivityAudit.swift` | Same persistence lifecycle repair for I/O audit. |
| `Sources/HeliosApp/Telemetry/AppEnergyHistory.swift` | Same persistence lifecycle repair for app-energy history. |

No collector cadence, preset composition, chart geometry, privilege boundary, or history schema changed. Correct process CPU values can visibly differ from the previously understated values; this is an intentional correctness repair.

Because this directory has no `.git`, comparison uses a pre-edit copy of the original sources, tests, scripts and configuration. The complete production diff is saved at `.build/EngineeringAudit/production.diff`. No Git repository was initialized.

## 4. Tests, tooling and documentation changed

| File | Purpose |
|---|---|
| `Tests/PresentationChecks.swift` | Verify unrelated-value suppression, static hub stability, and stale-value invalidation. |
| `Tests/TelemetryChecks.swift` | Native-timebase CPU fixtures; independent disk verification for replacement/truncation/recreation/missing newline in all three stores; focused persistence mode. |
| `Tests/UIMemoryChecks.swift` (new) | Optimized native AppKit fixture lifecycle stress, five cycles, weak-controller assertions and RSS/physical measurements. |
| `scripts/check-ui-memory-runtime.sh` (new) | Compile/run the test-only harness against production UI sources with Swift 6 strict checks. |
| `scripts/check-ui-memory-lifecycle.sh` | Add a compiled builder-construction probe proving lazy collapsed diagnostics. |
| `scripts/check-ui8-portable.sh` | Extract the persisted-point declaration by type boundaries rather than brittle line count. |
| `scripts/check-perf-tooling.sh` | Check exact executable verification, cumulative-summary exclusion and additional performance scripts; clean test temporaries. |
| `scripts/perf-report.py` | Exclude explicitly cumulative powermetrics records from interval summaries; preserve unmarked older captures. |
| `scripts/perf-prepare-release.sh` | Reject another checkout's Release executable. |
| `scripts/perf-ui-memory-check.sh` | Exact path, locale-independent values, 3–10 repeat cycles, timestamped output, individual stage measurements and vmmap files. |
| `scripts/perf-baseline.sh` | Skip a blocking generic `sudo -v` preflight when stdin is noninteractive; actual privileged measurement commands still require authorization. |
| `.gitignore` | Ignore generated Python bytecode caches. |
| `docs/PERFORMANCE_RC3.md` | Record evidence, methodology limitations, and correctness repairs. |
| `docs/RELEASE_READINESS.md` | Link the current audit and unresolved memory acceptance. |
| This report | Consolidate the required release verdict and evidence. |

Temporary profiling/sampling/preset helpers and the original preference backup live under ignored `.build/EngineeringAudit`. They are not linked into the app.

## 5. Frozen backend status

**No frozen helper/fan/XPC/SMC/BatteryProvider production file changed.** The original protected hashes remain in place and the Next22 boundary gate passes. No golden baseline was regenerated. Helper registration, trust, acquisition/release, journal, leases, stale/replay rejection and emergency behavior remain unchanged. The existing root daemon stayed running; this pass did not reinstall it or exercise physical Manual/Auto/Boost writes.

## 6. Frontend freeze status

The production UI changes preserve existing hierarchy, dimensions, typography, colors, fields, navigation and chart semantics. The new redraw decision changes only whether unchanged visible content is repainted; configuration/appearance changes and stale values retain their update paths. The lazy disclosure fix makes the intended existing panel compile.

Native light/dark fixtures and geometry checks passed, including fixed 420×600 dashboard, 720×520 Settings, 720×560 onboarding, metric popovers, Full Monitor and Energy Inspector. Selected rendered PNGs were visually inspected. All **462** published fields remain reachable according to the existing coverage gate.

Limits: the supplied snapshot failed to compile, so there is no exact freshly rendered before/after pixel comparison. Fixture rendering is not proof of every live AppKit interaction. The computer-use interface could not attach reliably to this menu-bar-only Helios instance, so real status-pill/highlight and exhaustive interactive diagnostics stress remain unverified in this pass.

## 7. Memory

Historical user-supplied RC2 live-app result: RSS **79.78 → 146.98 MiB**, physical **46.10 → 82.80 MiB**, physical delta **+36.70 MiB**. This was not rerun as a comparable baseline.

Final native fixture run uses `NSApplication.run()`, optimized production UI sources, one shared model, 3,600 valid chart samples, six hours of synthetic app-energy buckets, isolated Detailed preferences and no live collectors/helper/persistence. It navigates Overview/Storage/Processes/Expert, opens Energy Inspector at 1h/6h/24h and Settings, and constructs/destroys dashboard/metric roots. It does not automate every disclosure or actual native status popover interaction.

| Stage | RSS MiB | Physical MiB |
|---|---:|---:|
| Cold fixture baseline | 35.312 | 9.704 |
| Cycle 1 closed | 112.953 | 54.142 |
| Cycle 2 closed | 115.156 | 54.048 |
| Cycle 3 closed | 115.641 | 58.329 |
| Cycle 4 closed | 115.859 | 58.532 |
| Cycle 5 closed | 116.047 | 58.595 |
| Final, another 45 seconds closed | 115.875 | 54.704 |
| Final minus baseline | **+80.563** | **+45.000** |

Every tested window-controller and hosting-controller weak reference became nil. Growth largely plateaus after first use rather than repeating the initial increase each cycle. This still fails to demonstrate the required small post-close footprint delta.

Native attribution sampled during cleanup: footprint 58.6 MiB, peak 118.8 MiB; about 21.4 MiB allocated heap and 22.2 MiB allocator fragmentation. Heap classification includes approximately 9.7 MiB unclassified non-object storage, 2.6 MiB Swift metadata, 1.4 MiB Objective-C method caches, symbol/CoreSVG allocations and the bounded shared history array. Exactly one shared model and coordinator were present; no closed Helios window-controller class remained. `leaks` reported 208 allocations / 11,024 bytes, with framework AppIntents XPC cycles among its output; this is not an explanation for tens of MiB and is not proof of a completely leak-free app.

The earlier async-CLI fixture run is retained as superseded diagnostic evidence; it had different event-loop/history fidelity and must not be used as the final comparison. Native diagnostic inspection itself may perturb memory. The exact Release live-memory script reached a baseline of RSS 69.30 MiB / physical 29.80 MiB but could not proceed through the required interactive stages. **Live-app memory acceptance remains open.**

## 8. Performance

`./scripts/perf-final-core-suite.sh 90` completed all three scenarios on the final exact Release. Each used the same Mac, AC, original preset definitions, clean relaunch, 25-second warmup, UI closed and startup System policy. Each capture contains 18 delta intervals; this table excludes powermetrics' final cumulative summary.

| Preset | CPU ms/s | Idle wakeups/s | Interrupt wakeups/s | Energy impact/s proxy | Average RSS MiB | Physical before → after |
|---|---:|---:|---:|---:|---:|---|
| Simple | 14.52 | 1.24 | 7.64 | 2.51 | 75.99 | 43.7 → 27.7 MiB |
| Recommended | 17.31 | 1.76 | 8.49 | 3.37 | 71.30 | 41.9 → 24.9 MiB |
| Detailed | 21.49 | 1.27 | 9.52 | 7.22 | 75.75 | 43.7 → 25.0 MiB |

Daemon CPU was respectively 1.15 / 1.21 / 1.16 ms/s, with average RSS about 11.1 MiB and physical footprint about 4.3 MiB. It was not an optimization target.

The supplied historical CPU baselines were 15.50 / 22.43 / 24.34 ms/s. These final single captures show no CPU regression against those values. Recommended RSS is about 5 MiB higher than the supplied approximate 66 MiB baseline, while current physical footprint falls during warmup. Different system/cache/history conditions prevent attributing all differences to the redraw optimization. The initial comparable local Simple capture before that optimization was about 27.7 ms/s, but this is not a repeated statistical experiment.

Energy impact is a relative process optimization signal, **not watts or physical energy**. Whole-system power was collected but is influenced by unrelated applications and is not attributed to Helios. BSD `ps` percentage is also retained in raw reports, but the interval powermetrics CPU-time measure is used above.

Raw captures:

- `perf-baseline/20260909-215953-RC1-SIMPLE`
- `perf-baseline/20260909-220249-RC1-RECOMMENDED`
- `perf-baseline/20260909-220629-RC1-DETAILED`

The report parser originally mixed powermetrics cumulative summaries with interval records. It now excludes explicitly cumulative records, with a regression fixture; final reports were regenerated from unchanged raw captures. All powermetrics exit statuses are zero. Source hashes and exact executable paths are included in each capture; all 64 recorded production-source hashes still match the final files. `.build/EngineeringAudit/performance-summary.json` contains the delta-only aggregation above.

## 9. SSD / persistence

All three unprivileged history actors retain their existing bounded, best-effort persistence semantics. They use cached append handles and existing cadence; identity/size checks add one `fstat` and one path `stat` only when appending. This is a deliberate correctness cost, not a return to per-second open/close churn. Atomic rewrite remains the compaction/repair path.

Focused tests first reproduced an append disappearing after file replacement, then passed after the fix. All three stores now pass independent on-disk checks for atomic replacement, truncation, removal/recreation and missing final newline. Existing malformed-tail, retention, timestamp ordering, sleep/gap, rollover and CSV tests also pass.

These are not transactional multi-writer databases or crash-durable control journals. A concurrent external writer can still race a check/append; the app's store actor is the intended owner. Filesystem failures remain isolated from telemetry and fan control. No fsync guarantee was added. Cached in-memory history is not a live editor of externally changed files.

Detailed's 90-second capture appended 10,102 bytes app-energy, 2,816 bytes telemetry history and 1,527 bytes I/O audit; health-event growth was zero. Process disk-write counters reported zero in that interval, which does **not** mean zero eventual SSD writes. Logical file growth and kernel/physical write timing are distinct.

Old persisted per-app CPU-core-second values were not migrated or deleted; buckets recorded with the previous units can understate CPU. New intervals are corrected. Direct energy values and aggregate CPU history did not use the faulty scale.

## 10. Apple Silicon compatibility

Architecture/build contract passes: arm64 only, macOS 13 minimum, native APIs and independently unavailable fields. CPU/Memory/GPU/Network/Storage/System read-only providers are not gated to this specific M4 model. Unknown thermal keys stay advisory/unclassified and cannot become trusted cooling sources.

The design supports capability-driven absence of battery, fans, GPU statistics, SMART or other hardware fields. Fan collections and codecs are array-based; discovery tests cover unavailable/variable topology rather than inventing symmetric limits. Laptops/desktops and fanless devices are architectural targets, not physically tested claims. Unknown/future SoCs may have partial telemetry; they do not gain write authorization.

This pass validated current SDK compilation at the macOS 13 deployment target and synthetic capability/failure tests. It did not boot macOS 13 or run on M1/M2/M3/M5, Air, mini, Studio, iMac or dual-fan hardware. Cross-device/API behavior still needs physical beta coverage.

## 11. Real hardware validation

Only **Mac16,1, base M4 14-inch MacBook Pro, one fan, macOS Tahoe 26.6.2 (25G83)** was used in this pass. Builds used Xcode 26.6 (17F113). Performance measurements were on AC. Validation here covers compilation, native read-only telemetry, authenticated helper connection, performance, fixture UI lifecycle and the recorded soak. It does not repeat historical fan-write validation.

## 12. Fan-control limitations

The unchanged production write gate remains exact **Mac16,1 / 25G83 / fan 0** after recovery/profile checks. Existing Manual bounds remain integral 2317–6550 RPM, Boost remains 6550, and the independent 95°C guard remains authoritative. No new keys, commands, XPC fields or privilege capabilities were introduced.

The repository's prior physical evidence covers this pinned configuration; this pass exercised simulated safety tests only. Other models, OS builds and fan topologies remain System/read-only for production writes unless separately validated. Successful telemetry discovery is not fan-write authorization.

## 13. Full test matrix

| Gate / evidence | Result |
|---|---|
| `scripts/check-all.sh` on final production sources | **PASS**, exact final line: `PASS full Helios regression gate and Xcode build` |
| Runtime subprocess prohibition, battery read-only, helper fan-only | PASS |
| Frozen Next22 hashes and presentation isolation | PASS |
| UI9, UI10, RC4, RC5, RC6, RC7, RC8 boundaries | PASS |
| Preferences, reachability, reversible collection, cooling gates, migration | PASS |
| 462-field coverage | PASS |
| Swift 6 strict concurrency / warnings as errors | PASS |
| Native presentation fixtures, menu geometry, stale values, redraw isolation | PASS |
| Fan lifecycle, journal/restart/wake recovery simulations | PASS |
| XPC peer authentication/rejection, callbacks, replay/stale sample rejection | PASS |
| Independent leases, heartbeat expiry, hung-client/disconnect restoration | PASS |
| Auto Rules edits/retry/backoff/inactive profile/System handoff | PASS |
| Manual bounds, Boost gate, 95°C floor, preemptible soft release | PASS |
| Storage P1b caching, SMART parser/ABI/capability and throughput/rollover | PASS |
| CPU, Battery, GPU, Process, Energy | PASS |
| Network, Wi-Fi, Bluetooth and native maintenance fixtures | PASS |
| Rolling/persistent history, gap-safe energy, I/O audit, all three persistence lifecycles | PASS |
| Capability reports, health events, thermal, SMC, pressure | PASS |
| Compiled collapsed-builder laziness probe | PASS |
| Performance tooling / exact path regression checks | PASS |
| Five-cycle optimized UI fixture controller/hosting release | PASS |
| Low post-UI memory acceptance | **NOT ESTABLISHED — blocker** |
| Exact live-app interactive memory stress | **INCOMPLETE — computer-use attachment unavailable** |
| Exact Release build | PASS |
| 900-second Recommended/System Release soak | PASS within the recorded interval |
| Three final 90-second performance captures | PASS |
| Other physical Apple Silicon models / macOS versions | NOT RUN |
| Real Manual / Auto / Boost writes | NOT RUN, intentionally outside this pass |

The initial supplied compile failure and original persistence failure are saved as before-fix evidence. Intermediate AppKit dirty-flag assertions proved unsuitable for the detached/manual-render fixture and were replaced with tests of the actual invalidation decision. No safety deadline or protected baseline was weakened to pass testing.

## 14. Release build status

The exact workflow `./scripts/perf-prepare-release.sh` completed with `BUILD SUCCEEDED`. The measured binary is:

`.build/DerivedData/Build/Products/Release/Helios.app/Contents/MacOS/Helios`

The final performance suite verified the running command against the absolute executable path in this checkout. The app remained unprivileged and established authenticated protocol-v3 communication with the existing root daemon. Original user preferences were backed up before temporary preset changes; final restoration is recorded below.

## 15. Soak test result

**PASS for the observed 15-minute interval; not a multi-day stability claim.** The exact Release ran Recommended/System on AC with UI closed and no deliberate load, 2026-09-09 approximately 22:15:32–22:30:36 local time. A separate native read-only sampler took 180 samples at five-second intervals, checked process-start identity and converted CPU Mach ticks using the host timebase.

- Whole-interval CPU: **18.3978 ms/s**; idle wakeups **1.2025/s**; interrupt wakeups **8.5572/s**.
- First sampled RSS/physical: **70.1094 / 28.8445 MiB**; final: **73.9062 / 22.5320 MiB**.
- Approximate five-minute CPU means: **17.28 / 19.25 / 18.66 ms/s**. Five-minute physical means: **24.55 / 22.45 / 22.66 MiB**; RSS means: **72.42 / 73.54 / 73.88 MiB**. This shows warmup followed by a stable physical footprint within this interval.
- Logical growth: app-energy **143,004 B**, telemetry history **28,139 B**, I/O audit **15,055 B**, health events **0 B**. Live tail records parsed successfully. Native process counters charged 131,072 B read and 0 B written; this does not negate file growth or imply zero eventual SSD writes.
- Same app process survived all samples. The existing daemon remained PID 563. No app-owned Helios log entries appeared in the collected soak window; a post-restoration launch again authenticated v3 to daemon PID 563 / UID 0.
- Native framework logging was noisy: SkyLight display-timing errors and FrontBoard/SMAppService messages were attributed to Helios. A comparison showed the same timing errors in Control Center, Finder, Music, Discord, Code and other processes. This host-wide issue prevents claiming universally quiet Console output; no product log was suppressed to conceal it.

Sampling and a few read-only native diagnostic queries add small observer overhead. Closed-UI progress and fresh persistence are verified; exhaustive interactive responsiveness, sleep/wake under this exact build, battery endurance and multi-day behavior are not established by this soak.

Afterward, the original 28-key preference domain was restored and independently compared equal to the backup before relaunch. The final exact Release is running with the original Detailed configuration and a fresh authenticated helper connection. Startup remains System by the unchanged product policy. The bundled and installed helper were not replaced.

## 16. GitHub beta blockers

The engineering blocker is unresolved UI memory acceptance and the incomplete exact-app interactive stress. A controlled investigation build can be shared privately at the owner's discretion, but this audit does not approve a beta milestone.

Publication also needs an owner-selected license, repository initialization/review (this folder is not a Git checkout), and a clear beta hardware/support matrix. No repository or release was published. Generated captures are ignored because they contain local process/path/device information; review them before deliberate sharing. A limited source/configuration scan found no obvious embedded private-key/token patterns, but this is not a credential audit of an unknown Git history.

## 17. Public notarized release blockers

Resolve the memory criterion, obtain external Apple Silicon and older-supported-macOS coverage, choose licensing, configure Developer ID credentials, sign the app and helper consistently, notarize/staple, then validate installation and authenticated helper behavior on a clean external Mac. Current Apple Development signing is not the intended public distribution pipeline. No credentials, notarization submission or publication was attempted.

## 18. Signing status

The repository retains Apple Development signing with Team **<LOCAL_TEAM_ID>**, hardened runtime, empty base entitlements and disabled debug-entitlement injection. No unsigned/debugger/injection fallback was added. Final app verification passed `codesign --verify --deep --strict`, and the bundled helper passed separate strict verification. Both executables are arm64 with runtime flag `0x10000`, matching Team ID and empty entitlement dictionaries. Developer ID and notarization remain owner-controlled distribution work.

## 19. License status

No root LICENSE file is present. No license was chosen or added on the owner's behalf. Choosing the intended source license and reviewing any applicable acknowledgements remain publication decisions. No AGPL OpenMacBattery code was introduced.

## 20. Exact manual actions still required from the owner

1. Complete the exact-app interactive memory protocol with `./scripts/perf-ui-memory-check.sh 3`, following its stage prompts on this Release, with Cooling in System. The available computer-use interface could not reliably attach to the menu-bar-only app; the fixture harness cannot replace this acceptance measurement. Preserve the generated vmmap and measurements. A large residual delta needs allocation investigation before approval, not a relaxed threshold.
2. Arrange read-only beta coverage on additional Apple Silicon/device classes and supported macOS versions. Do not broaden fan writes through those tests.
3. Choose the source license before GitHub publication.
4. Supply/authorize the intended Developer ID signing and notarization workflow when ready for distribution.
5. Authorize repository/public release publication separately after the engineering blocker is resolved.

The full suite and final three preset captures are completed; their logs are saved. The final fixture cleanup also explicitly removes its isolated defaults before `exit()`; Swift defers do not run when the process exits directly. No frozen backend modification requires approval because none was proposed or made.

### Adversarial self-review

The most likely accidental regression was **suppressing a required native metric redraw**. The review followed configuration changes, hidden values, grouped Cooling, stale transitions and appearance changes. The value cache always updates; configured visible-value changes return true; configuration/appearance paths retain their own invalidation. Focused tests and the full presentation suite pass.

The other high-risk hypothesis was **fixing cached persistence handles while still appending to the wrong position**. The regression reads the on-disk file independently after replacement, truncate, removal/recreation and missing-newline startup in all three actors; no NUL holes or lost expected appended records remain in those tested sequences. External concurrent multi-writer atomicity is not claimed.

CPU fixtures independently convert their target durations into Mach ticks; energy expectations remain unchanged. The timebase correction is also checked against independent powermetrics evidence. Production diffs add no tasks, observers, timers or ownership relationships. The memory harness itself was reviewed and corrected to use a normal AppKit event loop and genuinely valid historical sample geometry. Closed-controller release and a footprint plateau are explicitly not promoted into a memory acceptance claim.

### Local evidence index

- `.build/EngineeringAudit/check-all.log`
- `.build/EngineeringAudit/release-final.log`
- `.build/EngineeringAudit/final-core-suite-final.log`
- `.build/EngineeringAudit/production.diff`
- `.build/EngineeringAudit/persistence-before.log` / `persistence-lifecycle.log`
- `.build/EngineeringAudit/ui-memory-runtime.log`
- `.build/EngineeringAudit/harness-final-vmmap.txt` / `harness-final-heap.txt` / `harness-final-leaks.txt`
- `.build/EngineeringAudit/performance-summary.json`
- `.build/EngineeringAudit/soak.csv` and adjacent soak evidence
- `.build/EngineeringAudit/signing.txt` / `entitlements.plist`
- `.build/Presentation/`
