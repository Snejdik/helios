# Performance P1b — Storage fast path correction

## Why P1 was rejected

The first P1 build remained functionally green, but the real-Mac performance capture was not acceptable:

- the control `P1-SIMPLE` run was much hotter than the earlier Release `R-SIMPLE`, so the test had a changed runtime/UI state and could not be used as a clean before/after baseline;
- more importantly, Storage's incremental cost inside the same P1 session increased sharply.

The rejected implementation cached registry IDs but resolved every device again on each 2-second sample with `IORegistryEntryIDMatching` + `IOServiceGetMatchingService`. That assumption was wrong: repeated matching-service lookup can be more expensive than the discovery work it replaced.

P1 is therefore not accepted as an optimization.

## P1b architecture

P1b keeps the same safety/UI/data contracts but changes only the counter-source fast path:

- full storage metadata discovery remains slow-cadence;
- topology probing remains separate from static metadata discovery;
- the exact IOKit service object that publishes `Statistics` is retained during discovery;
- every 2-second live sample reads only the `Statistics` property from that retained service handle;
- no per-device `IORegistryEntryIDMatching` / `IOServiceGetMatchingService` lookup occurs in the live hot path;
- if a retained source disappears or becomes invalid, the existing bounded rediscovery path rebuilds the inventory and handles;
- SMART, root-volume, throughput, IOPS, device telemetry and UI fields remain available with the existing contracts.

## Measurement normalization

`perf-p1-storage-suite.sh` now clean-relaunches Release Helios after each scenario is configured and waits 25 seconds before capture. This intentionally clears previously-opened Full Monitor / Storage UI state so hidden/retained UI cannot contaminate the idle comparison.

The three cases remain:

1. `P1B-SIMPLE`
2. `P1B-STORAGE` (Simple + only Storage)
3. `P1B-RECOMMENDED`

## Expected effect

Primary expected improvement:

- lower incremental CPU and energy cost when Storage is enabled;
- lower transient allocation churn from storage discovery;
- no change to 2-second live counter freshness;
- no change to fan/helper/battery/UI boundaries;
- no intentional change to persistence volume in this phase.

P1b is accepted only after real-Mac `check-all.sh`, `check-storage.sh --live`, and the normalized Release before/after capture pass.
