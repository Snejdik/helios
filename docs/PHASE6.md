# Phase 6 — Performance, GPU and whole-system power

## Next18 Step 1 — native performance expansion

Next18 starts the broader Stats/coconutBattery-style telemetry layer without
changing the privileged fan-control backend.

### GPU

The unprivileged app reads the Apple graphics accelerator through IOKit and
parses its `PerformanceStatistics` dictionary. Values are independent typed
fields so a missing renderer, tiler, memory or identity property does not erase
other valid GPU data.

Exposed fields:

- device utilization percent;
- renderer and tiler utilization percent;
- GPU model/driver identity when exposed;
- GPU core count when exposed;
- mapped/allocated unified memory;
- currently in-use GPU system memory.

No `ioreg`, `system_profiler`, Metal benchmark, subprocess, root helper or GPU
mutation is used. The provider is reset on sleep and reprobed after wake.

### Whole-system power

Battery charge/discharge remains a separate signed `Voltage × Current` metric.
Next18 adds an independent whole-system power probe from the read-only AppleSMC
`PSTR` rail. `PSTR` is decoded only through the read-only SMC client; no SMC
write primitive is added to HeliosApp or to the shared transport.

The generic read decoder accepts finite Apple SMC float, signed/unsigned
integer and 16-bit fixed-point numeric formats. `PSTR` is rejected outside a
conservative 0–500 W plausibility range. If the key/type is absent or changes,
Total System Power displays unavailable rather than substituting battery flow
or adapter rating.

### Memory and battery detail

- `vm.swapusage` is read in-process with Darwin `xsw_usage` for swap used/total;
- battery voltage and signed current are shown independently from calculated
  battery watts;
- raw-capacity state-of-charge is shown without replacing raw mAh values;
- power-adapter rated wattage and charging state are parsed when
  `AppleSmartBattery` exposes them.

### Diagnostic probe

A Debug build adds:

```text
Helios.app/Contents/MacOS/Helios --performance-preflight
```

It performs GPU, total-system-power, swap and battery-detail reads as the normal
user and prints their typed success/unavailable states. It performs no fan
writes and uses no subprocess.

### Safety / architecture boundary

- `Sources/HeliosDaemon/*` is intentionally unchanged in Next18;
- no XPC method, writable SMC key, lease rule, recovery state or fan bound is
  added or widened;
- all new telemetry runs in the unprivileged app;
- every new provider is failure-isolated and stale readings expire;
- existing 95°C Max-SoC emergency cooling remains independent and authoritative;
- GPU frequency, per-component CPU/GPU/ANE power, network, per-process energy,
  history/graphs and notifications remain later work rather than fabricated
  approximations.

## Next18-fixed physical validation — 2026-09-07

The target Mac16,1 / 25G83 passed the full canonical regression/Xcode gate.
The read-only `--performance-preflight` then physically returned Apple M4 with
10 GPU cores, live Device/Renderer/Tiler utilization, unified-memory counters,
PSTR Total System Power, native swap state, and battery charge/voltage/current/
power-source/adapter telemetry. This closes the Next18 backend validation
milestone; UI/presentation remains independently regression-tested.
