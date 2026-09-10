# Helios RC8 — Targeted Release Performance Test

This is the second, targeted performance test. It isolates the runtime cost of
GPU, Network, Processes & Energy, and Storage relative to the Simple baseline.
It is development-only and does not modify production `Sources/`.

## What “Simple + System” means

`Simple` means the **global preset** in Helios Settings.

`System` means **Cooling -> fan control mode -> System**.
It does **not** mean the `System Power` collector.

The `System Power` collector remains exactly as the Simple preset configures it.
Do not toggle it manually during this suite.

When you select Simple and then enable one extra collector, the preset label will
change to `Custom`. That is expected and is exactly how the isolated test works.

## Step 1 — Build and launch the Release app

From the project root:

```bash
./scripts/perf-prepare-release.sh
```

The helper is deliberately left alone. The script quits only the Helios app,
builds `HeliosApp` in Release, launches the exact Release product, and verifies
that the running executable path contains:

```text
/Build/Products/Release/Helios.app/Contents/MacOS/Helios
```

After launch, make sure Helios works normally and the helper is connected.

## Step 2 — Run the targeted suite

```bash
./scripts/perf-targeted-suite.sh 90
```

The six captures are 90 seconds each. The script automatically waits 15 seconds
after each Enter before starting measurement. Total wall time is roughly 11 minutes
plus the time you need to change settings between scenarios.

Keep the Mac on the same power source, at the same brightness, and avoid Xcode
builds, benchmarks, large copies, or other heavy activity during the suite.

Before pressing Enter for every scenario, close **all** Helios windows and popovers,
including Settings.

## Exact scenario states

### R-SIMPLE

1. Select global preset `Simple`.
2. Cooling -> fan mode `System`.
3. Do not manually change any collector.
4. Close Settings and all Helios UI.
5. Press Enter in Terminal.

Simple should leave the normal Simple baseline collectors enabled, including
CPU, Memory, System Power, Battery and Fan telemetry. Do not manually change them.

### R-GPU

1. Select `Simple` again to reset the baseline.
2. Enable **only `GPU`** as the one extra collector.
3. The preset changing to `Custom` is correct.
4. Leave Network, Wi-Fi details, Processes & Energy, Storage, and Devices & peripherals OFF.
5. Cooling remains `System`.
6. Close all Helios UI and press Enter.

### R-NETWORK

1. Select `Simple` again.
2. Enable **only `Network`** as the one extra collector.
3. `Custom` is expected.
4. Leave GPU, Wi-Fi details, Processes & Energy, Storage, and Devices & peripherals OFF.
5. Cooling remains `System`.
6. Close all Helios UI and press Enter.

### R-PROCESSES

1. Select `Simple` again.
2. Enable **only `Processes & Energy`** as the one extra collector.
3. `Custom` is expected.
4. Leave GPU, Network, Wi-Fi details, Storage, and Devices & peripherals OFF.
5. Cooling remains `System`.
6. Close all Helios UI and press Enter.

### R-STORAGE

1. Select `Simple` again.
2. Enable **only `Storage`** as the one extra collector.
3. `Custom` is expected.
4. Leave GPU, Network, Wi-Fi details, Processes & Energy, and Devices & peripherals OFF.
5. Cooling remains `System`.
6. Close all Helios UI and press Enter.

### R-RECOMMENDED

1. Select global preset `Recommended`.
2. Do not manually change collectors.
3. Cooling remains `System`.
4. Close all Helios UI and press Enter.

## What the scripts collect

For every scenario the existing baseline harness records:

- Helios and HeliosDaemon CPU samples
- RSS and boundary `vmmap` summaries
- powermetrics process CPU/energy/wakeup/I/O signals
- local Helios persistence growth
- available system power/thermal scalars
- exact `Sources/` fingerprint

The targeted suite automatically creates comparisons of each scenario against
`R-SIMPLE` and writes a `perf-baseline/TARGETED-SUITE-*.md` roll-up.

## After the suite

Zip the entire results directory:

```bash
zip -r perf-baseline-targeted.zip perf-baseline
```

Upload `perf-baseline-targeted.zip` for analysis.

Do not reinstall or stop HeliosDaemon between scenarios. Do not switch fan control
away from System. Do not manually toggle `System Power`.
