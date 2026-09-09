# Apple Silicon compatibility contract

Helios ships for **Apple Silicon only (`arm64`)** with macOS 13.0 as the deployment floor.

## Read-only telemetry

The unprivileged monitoring layer is capability-based. CPU, memory, GPU, battery, storage, network, device and system providers must either return the data exposed by the current Mac/macOS combination or fail that field/module independently as `Unavailable`. A missing sensor or registry property must never prevent Helios from launching.

Fanless Macs are valid telemetry-only systems. Multi-fan inventory is represented dynamically; read-only fan telemetry must not assume a single fan.

Apple does not document most Apple-Silicon SMC thermal keys. Helios therefore keeps unknown/unmapped keys advisory/unclassified. Only the physically validated trusted map may enter Cooling Rules, health thresholds or privileged fan safety.

## Fan control

Public compatibility does **not** mean guessing writable SMC behavior on every Mac. Production Boost/Manual/Auto writes remain pinned to the physically validated `Mac16,1` / macOS `25G83` profile. Every other Apple Silicon Mac remains System/read-only until a separate profile is physically validated.

This boundary is deliberate: launching and observing safely across Apple Silicon is a release requirement; broadening fan writes without hardware validation is not.

## Validation

The primary physical validation machine is a base-M4 14-inch MacBook Pro. Before calling a public build broadly validated, run beta smoke tests on real M1, M2 and M3 hardware as well. Untested generations should be described as capability-compatible, not physically validated.
