# Helios RC8 Performance Baseline

This tooling is development-only. It does **not** alter Helios runtime code,
polling cadence, fan control, XPC protocol, battery behavior, or UI semantics.

## Goal

Measure the real Mac cost of Helios before optimization:

- CPU usage and CPU time proxy
- interrupt/package wakeup signals from `powermetrics`
- resident memory (RSS) plus before/after `vmmap -summary`
- per-process energy-impact proxy when supported
- per-process I/O when supported
- local `Application Support/Helios` persistence growth
- system thermal/SMC/power scalar candidates when the Mac exposes the matching
  `powermetrics` samplers

The report intentionally calls energy values a **proxy**. `powermetrics` documents
its process energy number as an optimization signal rather than a physical,
billing-grade energy meter.

## Initial high-signal run

Build/run the exact RC8 candidate you want to measure. Use **Release/Profile** for
performance comparisons; retain the already validated Debug build for functional
regression testing.

Then from the project root:

```bash
./scripts/perf-suite.sh 300
```

The script guides four scenarios:

- `0` — Helios app quit, installed `HeliosDaemon` still running
- `A` — Recommended preset, System fan mode, all Helios windows/popovers closed
- `B` — Simple preset, System fan mode, all Helios windows/popovers closed
- `C` — Detailed preset, System fan mode, all Helios windows/popovers closed

Five minutes per scenario is the fast first pass. Repeat important before/after
comparisons for 10–30 minutes once a candidate optimization exists.

## Keep the comparison controlled

For A/B/C keep these conditions stable:

1. Same Mac and same Helios build.
2. Same power source.
3. Same display brightness and external displays.
4. Fan mode `System`.
5. No Xcode build, benchmark, large file copy or other heavy background work.
6. Keep Helios windows/popovers closed unless the scenario specifically says otherwise.
7. After changing a preset, wait about 15 seconds before starting capture.

For thermal comparisons, ambient temperature and charging activity can affect the
whole system. Prefer relative before/after comparisons, not absolute temperature
claims from one short run.

## One scenario only

```bash
./scripts/perf-baseline.sh A 300
```

Results are written under `perf-baseline/<timestamp>-<scenario>/` and include:

- `REPORT.md` — compact human-readable summary
- `powermetrics.plist` — raw machine-readable capture
- `powermetrics-helios-records.json` — decoded Helios process records
- `process-samples.tsv` — 5-second CPU/RSS samples
- `persistence-before.tsv` / `persistence-after.tsv`
- `vmmap-*-before.txt` / `vmmap-*-after.txt` when available
- `source-hashes.sha256` and a single source fingerprint
- environment metadata

## Acceptance model for optimizations

An optimization is only accepted when it has a measurable or clearly quantified
benefit **and** preserves:

- the Next22 frozen boundary unless an explicitly approved safety-sensitive change is made
- fan safety and System fallback
- 462-field UI coverage
- current UI behavior
- portable regression gates
- full `./scripts/check-all.sh` PASS on the real M4/Xcode environment

Lower CPU time, wakeups, RSS, process I/O and local history write volume are better.
For any available idle-residency metric, higher idle residency is better.

## Later targeted profiling

After 0/A/B/C identifies the expensive side of the architecture, use Instruments
Time Profiler on the selected scenario rather than profiling every screen blindly.
Use File Activity if persistence or storage enumeration emerges as a hotspot.
Do not run heavy Instruments recording simultaneously with the baseline
`powermetrics` capture when making fine before/after comparisons.

## Before / after comparison

After an optimization, capture the same scenario again and compare the two run directories:

```bash
./scripts/perf-compare.py perf-baseline/<before-run> perf-baseline/<after-run>
```

The comparator reports CPU, RSS, local persistence growth and common decoded
`powermetrics` scalar keys. Keep the raw captures for any metric whose key naming
changes across macOS releases.

## Performance P1 validation

For the targeted Storage hot-path optimization, use `./scripts/perf-p1-storage-suite.sh 90` after a Release build. See `docs/PERFORMANCE_P1_STORAGE.md` for architecture, expected impact and acceptance criteria.
