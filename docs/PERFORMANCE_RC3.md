# RC3 UI allocation / memory-recovery revision

> **Later live-app result:** after this fixture analysis, the exact Release interactive memory protocol was completed manually. The repeated-cycle physical footprint plateaued and finished at **+15.0 MiB vs. its warm baseline** after cleanup. This does not invalidate the colder fixture data below; it resolves the previously missing live-app acceptance measurement for external-beta purposes. See [`RELEASE_READINESS.md`](RELEASE_READINESS.md).


RC2 confirmed that explicit NSWindow/NSHostingController teardown alone was not sufficient. On the validated Mac16,1 after the repeated UI stress, physical footprint rose from 46.10 MiB to 82.80 MiB (+36.70 MiB) even after 60 seconds with every Helios surface closed.

RC3 keeps the accepted RC1 collector/performance core and the RC2 window teardown, then removes two avoidable presentation allocation sources:

1. **Collapsed diagnostics are now truly lazy.** `HeliosDiagnosticDisclosurePanel` stores its `@ViewBuilder` closure instead of eagerly constructing the complete child `Content` value in `init`. Detailed/Expert diagnostics still expose the same backend fields, but collapsed sections do not instantiate their potentially large row/grid trees until the user expands them.
2. **Application icons are bounded thumbnails.** `HeliosAppIconCache` no longer retains the full multi-resolution `NSWorkspace` icon object after setting only its logical size. Each icon is rasterized transiently to a 64×64 2x backing image for a 32-point UI icon, the cache is bounded to 64 entries/~1 MiB declared cost, and reconstructible icon cache state is purged when a heavy window or popover closes.

No telemetry provider, sampler cadence, persistent history format, privileged helper, XPC contract, fan safety path, battery policy, or 462-field UI coverage is changed by RC3.

`perf-ui-memory-check.sh` now isolates Full Monitor, Energy Inspector, and popovers before the final repeated stress so any remaining physical-footprint growth can be attributed to a presentation group without another build.

Acceptance remains runtime-based on the validated M4: `./scripts/check-all.sh` must pass, the Release build must run normally, and the final post-close physical-footprint delta should be small enough for a background menu-bar utility rather than retaining tens of MiB after reconstructible UI is closed.


## Engineering audit — 2026-09-09

The supplied RC3 snapshot did not compile: the lazy disclosure stored a closure but used `content` instead of `content()` in its expanded branch. The corrected branch remains lazy. A compiled focused probe now verifies that collapsed content is not constructed and expanded content is constructed.

The new `scripts/check-ui-memory-runtime.sh` is an optimized, **fixture-only** lifecycle harness over the production UI. It uses isolated preferences, disables runtime history/notifications and helper connection, opens/closes the real window coordinator, asserts weak controller/hosting references become nil, and reports five memory cycles. It is not a replacement for exact Release menu-bar interaction testing or a footprint acceptance gate. `perf-ui-memory-check.sh` now records at least three individual stress cycles and retains each run's measurements/vmmap summaries.

The final five-cycle run uses a normal `NSApplication.run()` event loop and 3,600 valid historical samples. It released every tested window/hosting controller and largely plateaued, but physical footprint increased from 9.704 MiB to 54.704 MiB (+45.000 MiB); RSS increased from 35.312 to 115.875 MiB. This cold fixture baseline is not comparable to the historical full-app RC2 baseline. It does **not** establish memory acceptance. Native heap/vmmap evidence showed approximately 21.4 MiB live allocations and 22.2 MiB allocator fragmentation; the application-owned shared model remained singular. No speculative UI redesign or allocator-pressure trick was introduced. The earlier async-main fixture run is superseded because its event-loop and historical-sample fidelity differed.

Final 90-second exact Release CPU measurements were Simple 14.52, Recommended 17.31 and Detailed 21.49 ms/s. Idle wakeups were 1.24, 1.76 and 1.27 per second. The parser now excludes cumulative powermetrics summaries from interval statistics; raw captures are unchanged. These are individual controlled captures, not proof that every difference from historical baselines is caused by one optimization.

The audit also reproduced and fixed stale descriptor appends after atomic replacement in all three unprivileged history stores, handled in-place truncation/recreation, and repaired a valid JSON tail missing its final newline. Append cadence and schemas stay unchanged; these files are best-effort local observability, not crash-durable journals.

Independent CPU measurement exposed that `proc_pid_rusage` user/system CPU durations are Mach ticks, whereas direct energy counters are nanojoules. Process CPU conversion now uses the native timebase; energy conversion is unchanged. On the audited M4, the timebase is 125/3 nanoseconds per tick. The initially unscaled diagnostic sampler reported 0.6621 ms/s; conversion gives 27.5875 ms/s, consistent with the overlapping powermetrics result of about 27.7 ms/s. The unscaled readings are invalid and must not be used as performance claims. Previously persisted per-app CPU-core-second attribution remains historical and has not been rewritten; older buckets can understate CPU time. CPU aggregate history and direct energy counters do not use that faulty conversion.

Apple kernel evidence: [rusage field assignment](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) and [Mach-time task power accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c).

See `docs/validation/ENGINEERING_AUDIT_2026-09-09.md` for the final verdict, measurements, coverage, and remaining limitations.

A short native stack profile also identified AppKit status-item redraw work. Each `MenuBarView` previously compared all telemetry strings, causing a CPU change to redraw unrelated metric items and the static dashboard hub. Invalidation now compares only configured, visible values. Appearance/configuration invalidation, stale-value redraw, live data and geometry remain intact. Presentation regressions cover unrelated-metric suppression, static hub stability, and stale-value updates.
