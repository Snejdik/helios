# Phase 7 — System, network and live history

## Next19 utility expansion

Next19 grows Helios from a hardware/fan monitor into a broader all-in-one Mac
utility while preserving the validated Next18 fan-control backend unchanged.
All additions in this phase are read-only and run in the unprivileged app.

### System

A native system provider exposes model identifier, chip/CPU identity, macOS
version, uptime, logical CPU count, physical memory, 1/5/15-minute load
averages, ProcessInfo thermal state and Low Power Mode. Kernel values use
in-process Darwin/Foundation APIs only.

### Network

Network telemetry uses SystemConfiguration's dynamic store to identify the
current primary interface and its IPv4/IPv6 addresses. `getifaddrs()` AF_LINK
records provide link metadata and counters. The public `if_data` counters are
32-bit, so the rate calculator explicitly handles modulo-2^32 rollover and
warms up again when the primary interface changes. It does not present these
volatile counters as lifetime totals.

Exposed fields include:

- primary interface and active-interface count;
- IPv4 and IPv6 address;
- running state, MTU and reported link rate;
- download/upload bytes per second;
- receive/transmit packets per second;
- receive/transmit error counters.

### Battery time remaining

Battery time remaining uses IOKit's native `IOPSGetTimeRemainingEstimate()`.
Its special unknown and unlimited results remain distinct UI states; Helios
does not derive a synthetic estimate from instantaneous watts.

### Live history and energy

The menu-bar popover retains at most 3,600 one-second samples (~60 minutes) in
memory. Lightweight SwiftUI sparklines show CPU, GPU, Max SoC, PSTR system
power, fan RPM and network download/upload rates.

Session energy is integrated from consecutive successful PSTR samples using a
trapezoid. Only gaps of at most five seconds count toward energy and measured
coverage. Sleep, stale samples or longer gaps are not interpolated, so Helios
never invents watt-hours for an interval it did not measure. History is
in-memory only in Next19; persistence remains a later milestone.

### Storage presentation

The existing physically validated NVMe SMART source is unchanged. Next19
surfaces more already-parsed fields: boot-scoped operation/error counters,
SMART spare threshold, error-log entries, host read/write commands, controller
busy minutes and raw critical-warning bits. Boot counters remain clearly
separate from lifetime SMART counters.

### Diagnostic probe

A Debug build adds:

```text
Helios.app/Contents/MacOS/Helios --utility-preflight
```

It performs live SystemConfiguration/getifaddrs, system and battery-time reads
as the normal user. It performs no fan writes, subprocesses or privileged
telemetry.

### Safety / architecture boundary

- `Sources/HeliosDaemon/*`, fan control models, XPC control protocol, cooling
  rules, leases, journal recovery and the 95°C emergency floor are unchanged;
- no new writable SMC key or privileged telemetry operation is introduced;
- network/system/history failures are isolated from cooling control;
- app/runtime code continues to reject Process/NSTask/popen/posix_spawn;
- persistent history, notifications and per-process attribution are not faked
  in this milestone and remain explicit future work.
