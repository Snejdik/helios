# Apple Silicon compatibility contract

Helios ships for **Apple Silicon only (`arm64`)** with macOS 13.0 as the deployment floor.

## Read-only telemetry

The unprivileged monitoring layer is capability-based. CPU, memory, GPU, battery, storage, network, device and system providers must either return the data exposed by the current Mac/macOS combination or fail that field/module independently as `Unavailable`. A missing sensor or registry property must never prevent Helios from launching.

Fanless Macs are valid telemetry-only systems. Multi-fan inventory is represented dynamically; read-only fan telemetry must not assume a single fan.

Apple does not document most Apple-Silicon SMC thermal keys. Helios therefore keeps unknown/unmapped keys advisory/unclassified. Only the physically validated trusted map may enter Cooling Rules or privileged fan safety.

**Display maps (0.2.1).** So that a Mac outside the M4 family still shows CPU and GPU temperatures, Helios also carries exact per-generation key lists for M1, M2, M3, M5 and M6, derived from the MIT-licensed Stats sensor catalogue (THIRD_PARTY_NOTICES.md). They are read-only and display-only: they feed the headline temperature, the P/E-core and GPU summaries, the sensor lists and the informational temperature alerts, and they never reach fan control, Cooling Rules or the privileged helper, which keep using the M4-only trusted map. A key is matched exactly for the detected chip generation (the same key means different things on different chips), M5/M6 "super" cores are shown with the performance cores, and a display-only sensor reading 10 °C or less is ignored because some chips report constant low values from inactive channels. Only the M4 family has been checked on real hardware; the other maps come from the catalogue and are corrected from compatibility reports.

## Fan control

Public compatibility does **not** mean guessing writable SMC behavior on every Mac. Production fan writes remain pinned to the exact validated Mac16,1/25G83 profile. That profile requires one fan (`fan 0`), permits integral targets only from 2317 through 6550 RPM, and fixes Boost at 6550 RPM. Every other Apple Silicon Mac, macOS build and fan topology remains System/read-only until a separate profile is physically validated, **unless the user explicitly turns on the experimental fan layer for that exact model and macOS build** (below).

### Experimental cool-only fan layer (opt-in)

How it works: [HOW_IT_WORKS.md](HOW_IT_WORKS.md). Off by default. A read-only probe classifies each Mac as **Validated**, **Experimental** or **Unsupported** (no fans, Intel, a chip without a verified trusted-temperature map — today only the M4 family has one — unexpected keys, types or attributes, `Ftst` already set, a fan not under macOS, or another fan controller running).

On an Experimental Mac you accept a risk notice ("experimental, no warranty, no liability") in Settings › Cooling. The helper stores that consent per model **and** macOS build, so a macOS update asks again.

With the layer on, Helios never commands less cooling than macOS:

- It takes the fans only when your request is above what macOS is doing, and keeps every target at or above a fixed safety curve, the macOS level at takeover and the learned macOS envelope.
- Targets are clamped to the live factory range and to your speed limit, 90 % of the factory maximum unless you unlock the full maximum in Settings › Cooling.
- When more cooling than the limit is needed, Helios hands the fans back to macOS instead of commanding them itself; with the full maximum unlocked, the helper forces maximum at 95 °C.
- Control returns to macOS on any error, lease expiry, disconnect, sleep, quit and helper restart. Recovery runs at helper start-up on any build.

Physically checked on a Mac16,1 running macOS 27.0.1 (26A434), with the factory minimum and above, and with every return to macOS verified by readback.

The privileged helper's independent 95°C emergency guard remains authoritative for every accepted fresh control calculation. Compatibility work must not weaken the helper authentication, leases, ownership/recovery journal, SMC write allowlist or System-restoration behavior.

This boundary is deliberate: launching and observing safely across Apple Silicon is a release requirement; broadening fan writes without hardware validation is not.

## Validation

The primary physical validation machine is a base-M4 14-inch MacBook Pro. Before calling a public build broadly validated, run beta smoke tests on real M1, M2 and M3 hardware as well. Untested generations should be described as capability-compatible, not physically validated.
