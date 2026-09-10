# Phase 2 — Read-Only Telemetry Foundation

The original diagnostic UI described here is superseded by [Phase 2.1 presentation polish](PHASE2_1.md). Its providers and acquisition semantics remain unchanged.

Validated on 2026-09-06 against Apple M4, macOS Tahoe 26.6.2 (25G83), using Xcode 26.6, Swift 6.3.3, and the installed macOS 26.5 SDK. The deployment floor remains macOS 13.0. Only HeliosApp gains telemetry; the Phase 1 daemon and its rejected-connection behavior are unchanged.

## Providers and semantics

| Provider | Native interface | Result |
| --- | --- | --- |
| CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | Differences between unsigned per-processor tick counters, aggregated into user/system/nice/idle percentages; first sample and post-wake sample need a baseline |
| Memory | `host_statistics64(HOST_VM_INFO64)`, `host_page_size` | Physical, active, inactive, wired, compressor-storage, and free bytes; free already includes speculative pages |
| Memory pressure | Darwin `sysctlbyname("kern.memorystatus_vm_pressure_level")` | Kernel Normal/Warning/Critical state; unsupported query or unknown value is unavailable, independently of VM statistics |
| Battery | `IORegistryEntryCreateCFProperties` on `AppleSmartBattery` | Raw design/full/current mAh, health, cycle count, cell temperature, signed battery power; each field has its own typed result |
| Thermals | `IOServiceOpen` on `AppleSMC`, `IOConnectCallStructMethod` | Dynamic `#KEY` enumeration, metadata caching, `sp78`/`flt ` decoding, per-sensor failures, and maximum identified SoC temperature |

CPU counters use wrapping UInt32 subtraction and aggregate across all returned processors. An unavailable CPU read or processor-count change resets the baseline. Mach host ports and allocated processor buffers are released after every sample.

Memory pressure is not inferred from free RAM. Compressor bytes describe physical compressor storage, not the uncompressed size of those pages. The displayed page categories are diagnostic values, not a fabricated Activity Monitor “Memory Used” total.

Battery capacity parsing prioritizes `AppleRawMaxCapacity` and `AppleRawCurrentCapacity`; raw nested charge-capacity fields provide fallbacks. Normalized `MaxCapacity`/`CurrentCapacity` percentages are never treated as mAh. Cell `Temperature` is converted from hundredths of a degree Celsius. Health uses raw full-charge capacity / design capacity and may exceed 100% for a new battery.

Battery watts use voltage in mV × signed current in mA / 1,000,000. Positive current is charge, negative is discharge, and zero is idle. The UI explicitly labels instantaneous current, or averaged current when only `Amperage` is available. Signed and unsigned two's-complement 32-/64-bit current representations are supported. Missing or invalid current is unavailable rather than zero. **Total System Power is always separately labeled unavailable in Phase 2**, including when battery data is unavailable.

## AppleSMC boundary

The transport exposes only commands 5 (read bytes), 8 (key by index), and 9 (key metadata), through selector 2. It contains no write command or fan control interface. Discovery enumerates exactly `0..<count`, bounds the key count and payload sizes, validates response length and firmware result, and then reads supported `T...` keys. It does not read fan values.

The 80-byte SMC frame uses explicit C ABI offsets instead of relying on Swift struct layout. `sp78` is signed big-endian fixed point / 256; `flt ` is a little-endian IEEE Float. Truncated, non-finite, zero/inactive, and implausible temperatures fail independently. A failing sensor's previous value is not reused in the maximum. Zero/inactive and the 150°C plausibility bound are data validation only; they are not fan thresholds or thermal protection logic.

On the M4 family, `Tp`/`Te`/`Tg` prefixes classify P-core/E-core/GPU sensor groups. **This is an inference from observed SMC conventions and Stats' M4 sensor mappings, not a documented Apple API or an exact count of physical cores.** Every raw key is discovered from the current machine. Other temperature keys remain unclassified and do not affect Max SoC; an unknown CPU model keeps all sensors unclassified. The popover retains the hottest raw key and count for each identified group.

Primary implementation references consulted:

- [Stats' SMC implementation](https://github.com/exelban/stats/blob/master/SMC/smc.swift) — SMC transport conventions and data encoding.
- [Stats' M4 sensor mappings](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift) — empirical P/E/GPU family classification.
- [Apple XNU VM statistics definitions](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/vm_statistics.h) — VM page semantics and revisions, also checked in the installed SDK.
- [Apple XNU memory-pressure implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c) — native pressure-level query.

## Scheduling and degradation

Four provider actors run in independent sampling tasks, keeping synchronous native reads off the main actor. CPU and memory sample at roughly 1 second, thermals at 2 seconds, and battery at 5 seconds plus IOKit power-source notifications. Delays have a small scheduling tolerance. A separate 1-second main-actor task updates the UI even if a reader stalls. Sensor failures are logged with OSLog when their details change.

The status item shows `CPU 25% · SoC 55°C`; unavailable or stale values use an em dash. CPU/memory freshness is 5 seconds, thermals 6 seconds, and battery 15 seconds. A whole thermal-module failure closes its SMC connection and backs off for 30 seconds; successful sensors continue to refresh when only individual keys fail.

Sleep notifications cancel sampling and invalidate displayed samples. Wake resets the CPU baseline, reacquires the battery registry service, and reopens/re-enumerates AppleSMC. Battery notifications are coalesced, with periodic sampling retained for current and temperature changes. This phase uses the read-only 2-second thermal baseline; the future aggressive watch cadence and lease engine are not implemented.

## Reproducible verification

```sh
./scripts/check-telemetry.sh
./scripts/check-telemetry.sh --live

xcodebuild -project Helios.xcodeproj -scheme HeliosApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build
xcodebuild -project Helios.xcodeproj -scheme HeliosApp \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build

codesign --verify --strict --verbose=2 .build/DerivedData/Build/Products/Release/Helios.app
codesign --verify --strict --verbose=2 \
  .build/DerivedData/Build/Products/Release/Helios.app/Contents/Library/HelperTools/HeliosDaemon
```

The standalone checks compile the production telemetry sources with Swift 6 complete concurrency checking and warnings treated as errors; there is no extra Xcode target or dependency. Fixtures cover CPU rollover/reset/warm-up, raw capacity versus normalized percentages, signed current encodings, direction/units, per-field failure, malformed SMC frames/counts/types, partial enumeration, missing hottest-sensor recovery, unsupported CPU grouping, and stale readout behavior.

The optional live check requires a non-root user and samples the actual providers three times, then exercises explicit wake-style resets. It prints metric values and sensor keys, not serial numbers or the entire battery registry dictionary. An SMC denial inside the development-tool sandbox was resolved by running the same binary outside that sandbox as user 501; no root privileges, entitlements, security setting changes, or helper service were needed.

Observed during the live check:

- Apple M4 identity and macOS 26.6.2 (25G83) matched the target.
- CPU samples were 7.9–9.8%; memory pressure was Normal.
- 186 valid thermal readings and 36 unavailable/unsupported keys were reported independently; P/E/GPU groups were present. Max SoC varied from 56.0°C to 70.8°C during the check.
- Battery design/full/current capacities were 6249/6348/4962 mAh, cycles 4, cell temperature 30.53°C.
- Instantaneous battery current was zero, correctly yielding Battery Idle at 0 W. Charge/discharge directions were verified with fixtures, not by changing the power connection.

Both Debug and Release build and strict signature verification passed for the app and embedded daemon with the approved ad-hoc identity. The Xcode project plist and whitespace checks also passed. Xcode's non-fatal App Intents/simulator diagnostics remain as recorded in Phase 1.

## Remaining validation limits

The computer-use service timed out while attaching to the built menu-only app and did not provide a usable screenshot. Actual menu-bar/popover visual inspection remains manual; compilation, formatting fixtures, and native-provider checks succeeded. No GUI appearance validation is claimed.

A real sleep/wake cycle and AC cable transition were not triggered on the user's active Mac; reset logic was exercised directly. Older supported macOS releases and other hardware were not tested. Battery charge/discharge under changing load, long-duration recovery, CPU/RAM/wakeup performance targets, and exact physical sensor mapping still need measurement.

There is no daemon IPC, registration, fan write, curve engine, lease implementation, app attribution, GPU utilization, or total-system-power provider in this phase. Ad-hoc signing continues to verify local integrity only; privileged service registration and distribution signing remain separate work.
