# Phase 5 — Storage / SSD telemetry

## Next16 Step 1 — read-only storage foundation

Next16 established public/read-only IOKit inventory, root-volume capacity,
IOBlockStorage statistics, live throughput and SMART capability discovery. It
never inferred lifetime wear/TBW from boot-scoped driver counters.

## Next17 Step 2 — native NVMe SMART health log

Next17 adds a native, unprivileged and read-only NVMe SMART reader. It follows
the public macOS SMART plug-in path used by smartmontools and contemporary
native macOS SMART readers:

```text
BSD disk -> SMART-capable IORegistry parent
         -> IOCreatePlugInInterfaceForService
         -> IONVMeSMARTInterface
         -> SMARTReadData (read only)
         -> parse the 512-byte NVMe SMART/Health log
```

The COM vtable prefix intentionally includes the `version` and `revision`
fields between IUnknown and `SMARTReadData`; omitting those fields shifts the
function pointer layout and is unsafe.

### Values exposed

- Critical Warning and a conservative Verified / Attention / Critical state;
- composite SSD temperature;
- Available Spare and its threshold;
- Percentage Used and derived remaining-life display;
- lifetime Data Units Read/Written converted with the NVMe 512,000-byte unit;
- host read/write commands and controller busy minutes in diagnostics;
- power cycles, power-on hours, unsafe shutdowns, media errors and error-log
  entries;
- read/write throughput and read/write IOPS from boot-scoped IOKit counters.

SMART is sampled at most once every 30 seconds and cached between the existing
2-second storage samples. A failure is retained as a typed unavailable state;
Helios never substitutes runtime counters for SMART values.

### Cooling Rules

If a successful SMART sample includes a plausible SSD temperature, an `SSD`
source becomes available in Auto Cooling Rules. A SMART failure removes that
source. Storage is never used as a replacement for the trusted SoC emergency
safety path; the daemon's independent 95°C Max-SoC guard still wins.

### Safety boundary

- no `smartctl`, `diskutil`, `system_profiler`, `iostat` or runtime subprocess;
- no root privileges for storage;
- no NVMe admin write commands;
- the fan helper and its SMC write surface are unchanged;
- storage failure cannot revoke or extend a fan-control lease;
- sleep resets storage state and forces a fresh SMART probe after wake.

`--storage-preflight` performs one live read-only SMART probe and prints the
result or an explicit native-interface error.


## Next17 physical validation on Mac16,1

The Next17-fixed2 implementation was validated on the target Mac16,1 / macOS
25G83 after the canonical regression gate passed. The internal APPLE SSD
AP1024Z advertised native NVMe SMART and the read-only IONVMeSMARTInterface
probe returned a verified health log: zero critical warning, 100% available
spare, 0% wear used, a live SSD temperature, lifetime read/write counters,
power-on hours, power cycles, unsafe-shutdown count and zero media errors.
The live unprivileged StorageProvider then reproduced SMART state/temperature,
throughput and IOPS without root privileges or subprocesses. This closes the
Next17 hardware-validation uncertainty for the target M4; other Mac/controller
combinations remain capability-discovered and fail closed when unsupported.
