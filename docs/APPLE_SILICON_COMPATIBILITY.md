# Apple Silicon compatibility contract

Helios ships for **Apple Silicon only (`arm64`)** with macOS 13.0 as the deployment floor.

## Read-only telemetry

The unprivileged monitoring layer is capability-based. CPU, memory, GPU, battery, storage, network, device and system providers must either return the data exposed by the current Mac/macOS combination or fail that field/module independently as `Unavailable`. A missing sensor or registry property must never prevent Helios from launching.

Fanless Macs are valid telemetry-only systems. Multi-fan inventory is represented dynamically; read-only fan telemetry must not assume a single fan.

Apple does not document most Apple-Silicon SMC thermal keys. Helios therefore keeps unknown/unmapped keys advisory/unclassified. Only the physically validated trusted map may enter Cooling Rules, health thresholds or privileged fan safety.

## Fan control

Public compatibility does **not** mean guessing writable SMC behavior on every Mac. Production fan writes remain pinned to the exact validated Mac16,1/25G83 profile. That profile requires one fan (`fan 0`), permits integral targets only from 2317 through 6550 RPM, and fixes Boost at 6550 RPM. Every other Apple Silicon Mac, macOS build and fan topology remains System/read-only until a separate profile is physically validated.

The privileged helper's independent 95°C emergency guard remains authoritative for every accepted fresh control calculation. Compatibility work must not weaken the helper authentication, leases, ownership/recovery journal, SMC write allowlist or System-restoration behavior.

This boundary is deliberate: launching and observing safely across Apple Silicon is a release requirement; broadening fan writes without hardware validation is not.

## Validation

The primary physical validation machine is a base-M4 14-inch MacBook Pro. Before calling a public build broadly validated, run beta smoke tests on real M1, M2 and M3 hardware as well. Untested generations should be described as capability-compatible, not physically validated.
