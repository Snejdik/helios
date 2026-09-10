# Next20 — Observability milestone

Next20 expands Helios around the physically validated Next19-fixed baseline. It deliberately does **not** widen the privileged fan-control surface.

## Added

- Per-logical-CPU Mach tick deltas in addition to aggregate CPU use.
- Native Darwin/libproc process telemetry using `proc_listallpids`, `proc_pid_rusage`, `proc_name` and `proc_pidpath`.
  - `RUSAGE_INFO_V6` task CPU time, physical footprint, Neural Engine footprint, disk I/O, wakeups, instructions/cycles and IPC.
  - cumulative `ri_energy_nj` and `ri_penergy_nj` are converted to direct task/P-core watts only after a monotonic validated delta.
  - PID reuse is detected with `ri_proc_start_abstime`; counter rollback and invalid intervals discard a rate sample.
  - inaccessible processes are omitted and are never queried through the root helper.
  - broad enumeration resolves only rusage; names/paths are resolved for the small displayed top-N union.
  - normal monitor cadence is ~5 seconds to bound idle overhead.
- CoreWLAN Wi-Fi details: power/service state, best-effort SSID, RSSI, noise, SNR, TX rate/power, channel, band, width, PHY and security.
  - Helios does not automatically request Location permission solely to reveal SSID.
- Persistent 24-hour telemetry at approximately 30-second cadence in `~/Library/Application Support/Helios/history-v1.ndjson`.
  - append-friendly NDJSON, atomic initial write/compaction, 3,000-point and ~2 MB compaction bounds.
  - truncated/malformed records are dropped and compacted before later appends.
  - wall-clock rollback starts a new ordered timeline.
  - PSTR Wh integration bridges only valid gaps <=90 seconds.
- Health evaluator for fresh trusted SoC/system thermal/memory/battery/NVMe conditions.
  - Notification authorization is never requested at launch; user action is required.
  - alerts are observability-only and cannot affect fan control.
- Raw thermal sensor browser. Unclassified SMC keys are display-only and excluded from Max SoC/Cooling Rules trust.
- Physical external-storage list while virtual Disk Images are filtered.
- `--observability-preflight` for read-only target-Mac validation without persistent writes or notification prompts.

## Frozen safety boundary

Byte-for-byte unchanged from Next19-fixed before packaging:

- `Sources/HeliosDaemon/*`
- `Sources/HeliosApp/FanControlModel.swift`
- `Sources/HeliosApp/CoolingRules.swift`
- `Sources/HeliosApp/DaemonClient.swift`
- `Sources/Shared/FanModels.swift`
- `Sources/Shared/FanOwnershipPreflight.swift`
- `Sources/Shared/HeliosXPCProtocol.swift`
- `Sources/Shared/XPCTrustRequirement.swift`
- `Sources/Shared/SMCClient.swift`

Therefore Next20 adds no SMC write key, fan target, lease path, ownership state, root telemetry command or XPC fan-control capability.

## Failure isolation

Every new module can independently become unavailable. Process access failures omit that process; CoreWLAN privacy may hide SSID; filesystem errors leave in-memory history running; notification denial only changes notification state. None of these paths are allowed to issue fan commands or weaken the 95°C daemon guard.

## Validation order

```sh
cd ~/Downloads/Helios-next20
./scripts/check-all.sh
```

Only after the full gate is green:

```sh
.build/DerivedData/Build/Products/Debug/Helios.app/Contents/MacOS/Helios --observability-preflight
```

The preflight is expected to be read-only and to perform no fan writes, notification prompt, persistent-history write, subprocess execution or privileged telemetry.
