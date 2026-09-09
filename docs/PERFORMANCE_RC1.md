# Near-final performance core — RC1

RC1 consolidates the accepted P1B storage fast path with the remaining low-risk core optimizations while preserving the frozen fan/XPC/SMC/Battery boundary and UI telemetry coverage.

## Runtime changes

- Process sampling reuses its current-counter dictionary capacity, avoids session-ledger entries for processes with zero I/O, keeps session totals incrementally, and uses bounded Top-K selection instead of repeatedly sorting the full process population for every ranking.
- GPU identity is cached from the first accelerator read; the 1 Hz hot path reads only `PerformanceStatistics`.
- Network throughput remains 1 Hz, while route/IP/DNS metadata is cached for five seconds and refreshed immediately when the cached primary interface disappears.
- App-energy aggregation no longer recomputes/publishes the unchanged seven-day summary every five-second process tick; a new long-term summary is produced when the one-minute bucket changes.
- Persistent history, I/O audit and app-energy persistence keep append handles and cached file sizes instead of open/seek/write/close/stat churn on every append. Retention, NDJSON format and crash-tail recovery remain unchanged.
- Closed menu popovers release their SwiftUI trees. Closed Full Monitor, Energy Inspector and Settings windows release their controllers; small navigation/range state is retained separately. Energy Inspector range aggregation is memoized and its derived cache is dropped when the window closes.

## Expected impact

- CPU: lower in Recommended/Detailed, especially process/GPU/network workloads.
- Energy impact/temperature: lower indirectly through reduced CPU/IOKit/SystemConfiguration work.
- RAM churn: lower; closed UI should return substantially more presentation memory.
- SSD/filesystem overhead: fewer metadata/open/close/stat operations without reducing persisted telemetry fidelity.
- Wakeups: no safety cadence is weakened; timer cadence is intentionally unchanged in this RC.

## Acceptance

RC1 is accepted only after the real-Mac `./scripts/check-all.sh` passes and `./scripts/perf-final-core-suite.sh 90` shows no regression against the normalized P1B baseline.

> RC2 follow-up: the RC1 UI stress test showed elevated post-close physical memory. See `PERFORMANCE_RC2.md`; collector-performance results remain the RC1 baseline while RC2 changes presentation teardown only.
