# Performance P1 — Storage hot-path caching

## Scope

P1 changes only the unprivileged read-only `StorageProvider` implementation and its tests/development tooling. It does not change HeliosDaemon, XPC, fan control, thermal safety, battery policy, UI layout, storage telemetry fields, or the 2-second live storage sampling cadence.

## RC8 measured motivation

Targeted Release baseline on Mac16,1 / macOS 26.6.2:

- Simple: ~42.18 ms Helios CPU time / second.
- Simple + Storage: ~50.05 ms/s.
- Incremental signal: ~7.87 ms/s in that 90-second capture.
- Storage also raised P95 CPU in the capture. Short captures are noisy, so P1 is accepted only after same-Mac before/after measurement.

## Before P1

Every 2-second storage sample performed a full `IOMedia` enumeration and, for every whole device, repeatedly:

- walked up to 12 IORegistry ancestors,
- read model/product/protocol metadata,
- classified controller classes,
- searched SMART capability,
- searched the lineage for the I/O Statistics publisher,
- read root filesystem capacity.

Most of those values are static or slow-changing.

## P1 architecture

The 2-second contract remains only for genuinely live counters:

- bytes read/written,
- read/write operations,
- errors,
- derived throughput and IOPS,
- process-lifetime physical-device deltas.

Full discovery now caches slow/static device metadata plus the registry ID of the entry publishing live `Statistics`.

Steady-state cadence:

- Live counters: 2 s, unchanged, direct lookup by cached IORegistry entry ID.
- Lightweight topology identity probe: 5 s.
- Root volume capacity/free-space refresh: 2 s, unchanged.
- Full metadata fallback refresh: 300 s.
- NVMe SMART: 30 s, unchanged.
- Cached counter-source failure: immediate one-shot full rediscovery.
- Collector re-enable and sleep/wake: force fresh discovery.

No IORegistry handles are retained across samples; only value metadata and stable registry IDs are cached, reducing lifecycle risk when devices disappear/reprobe.

## Expected impact

These are architectural expectations, not claimed measured results:

- Full ancestor-walking metadata discovery in a steady 90-second run: about 45 passes before -> normally 1 initial pass after (>95% reduction).
- Full `IOMedia` enumerations: every 2 s before -> lightweight topology enumeration every 5 s after (about 60% fewer, and much less work per enumeration).
- Root-volume filesystem attribute reads remain at 2 s to preserve existing free-space freshness semantics.
- CPU / Energy Impact: should fall most noticeably in `Simple + Storage` and Recommended.
- Allocation churn / transient memory: should fall because large metadata arrays/strings/classification work are no longer rebuilt every 2 s.
- Steady RSS: may be roughly neutral because a small metadata cache is intentionally retained.
- SSD writes: only a small direct improvement is expected from P1; major persistence-write reduction belongs to Processes/Energy/Persistence phases.
- Temperature/battery: any benefit is indirect from lower CPU/wakeup work; no thermal-control behavior changes.

## Behavioral impact

- Live I/O throughput/IOPS remain on the same 2-second cadence.
- SMART freshness remains 30 seconds.
- Root free-space freshness is unchanged.
- A newly attached storage device may take up to ~5 seconds to appear in storage inventory; disappearance/driver failure can trigger immediate rediscovery when a cached live counter source fails.
- Full metadata is refreshed at least every 5 minutes even if topology identity remains unchanged.

## Acceptance

P1 is accepted only if:

1. `./scripts/check-all.sh` passes on the M4.
2. `./scripts/check-storage.sh --live` passes as normal user.
3. 462-field UI coverage remains PASS.
4. Frozen Next22 boundary remains PASS.
5. Storage UI shows the same devices/SMART/live counters.
6. `./scripts/perf-p1-storage-suite.sh 90` shows a reproducible reduction in Storage incremental CPU/energy without a material regression in wakeups/RSS/writes.
