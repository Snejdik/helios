# Apple Silicon RC1 — change summary

Baseline: accepted P1B Storage optimization over the RC8 UI/backend freeze.

## Production source changes in RC1

- `Telemetry/ProcessProvider.swift` — bounded Top-K rankings, scratch counter dictionary, incremental session totals, no zero-I/O session rows, no full candidate lookup dictionary.
- `Telemetry/GPUProvider.swift` — accelerator identity cached once; 1 Hz reads only `PerformanceStatistics`; Macs without that property remain stable partial-success rather than rediscovering every second.
- `Telemetry/NetworkProvider.swift` — live counters stay 1 Hz; route/IP/DNS metadata cached for 5 s with immediate invalid-primary recovery.
- `Telemetry/AppEnergyHistory.swift` — unchanged summaries are cached; persistent append handle/file-size cache.
- `Telemetry/PersistentHistory.swift` — persistent append handle/file-size cache.
- `Telemetry/IOActivityAudit.swift` — persistent append handle/file-size cache.
- `OverviewViewController.swift` — unchanged app-energy summaries no longer trigger a published UI invalidation.
- `StatusItemController.swift` — closed transient popovers release their SwiftUI content trees.
- `HeliosWindows.swift` — closed heavy windows release controllers; monitor route and Energy Inspector selection state survive separately; expensive Energy Inspector range aggregation is memoized and released on close.

The privileged daemon, XPC contracts, SMC write transport, fan ownership/leases, Cooling Rules, BatteryProvider, fan-control view/model and the 95 °C safety floor are unchanged by RC1.

## Expected performance effect

The RC1 measurement target is **not** a promise of a specific percentage until measured on the M4. Relative to the normalized P1B baseline we expect:

- Recommended/Detailed CPU: lower, with the largest savings from process ranking/energy, GPU and network metadata paths.
- Energy impact: lower in proportion to CPU and native API work removed.
- RAM churn/high-water after UI use: lower because hidden presentation trees are no longer intentionally retained.
- SSD bytes: broadly similar because telemetry fidelity is preserved.
- SSD/filesystem operations: lower because persistent stores no longer open/seek/close/stat on each append.
- Wakeups: similar or modestly lower; safety and live sampling cadences are deliberately not weakened in this RC.

## Acceptance path

1. `./scripts/check-all.sh`
2. `./scripts/check-storage.sh --live`
3. `./scripts/perf-prepare-release.sh`
4. `./scripts/perf-final-core-suite.sh 90`
5. Optional UI-memory smoke: `./scripts/perf-ui-memory-check.sh`

Only a real-Mac Xcode build/test can convert RC1 from portable/static PASS to full release-candidate PASS.
