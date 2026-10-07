# Helios 0.2.1 Beta 1 — validation

Identity: tag `v0.2.1-beta.1`, bundle version 0.2.1, build 5. Date 2026-10-07.
This page records what was verified for 0.2.1 Beta 1 and what was not. The gates are the
same as for [0.2.0 Beta 1](VALIDATION_0_2_0_BETA_1.md).

## Automated gates

| Gate | Result | New for 0.2.1 |
|---|---|---|
| `git diff --check` | pass | — |
| `scripts/check-all.sh` | pass, ends with `PASS full Helios regression gate and Xcode build` | — |
| `scripts/check-next23-ui-boundary.sh` | pass, 31 protected fingerprints | One reviewed manifest update: `FanControlModel.swift` (switched-off sensors no longer release the fans); uninstall texts tracked under their new names |
| `scripts/check-telemetry.sh` | pass | Display maps per chip generation, key collisions between generations, `Apple M10`, fan-control identity untouched, M4 unchanged, M2 end to end |
| `scripts/check-diagnostics.sh` | pass | `ioft`/`si32` no longer reported as decode errors; corrupt `flt ` still is; several sensors failing together count one episode; GPU power gating (−4.5 °C) counts none and stays visible to the fan guard |
| `scripts/check-presentation.sh` | pass | Uninstall order and Trash blockers; What's New decision table and renders |
| `scripts/check-updates.sh` | pass | Checked-in tag matches `MARKETING_VERSION`; Beta 1 offers this release |
| `scripts/check-ipc.sh` | pass | Auto keeps the fans when a GPU sensor is switched off and still releases them on an invalid reading |
| Debug build (warnings as errors) | pass | — |
| Release build (warnings as errors) | pass; bundle reports 0.2.1 (5), `v0.2.1-beta.1`, arm64, signature verifies | — |
| `scripts/package-release.sh --build` | pass; DMG (with an Applications link), ZIP and checksums verified, helper version matches | New script |

The web backend needs no change: the report schema is still version 1.

## Run on a real Mac (Mac16,1, macOS 27.0.1)

- Read-only SMC sampling of the 20 trusted M4 keys and `Te06`/`Te0T` every 2 s, and of 186
  other temperature keys every 15 s, during normal use: no read errors. Four trusted GPU keys
  (`Tg0G`, `Tg0K`, `Tg0d`, `Tg0j`) read **−4.5 °C together whenever the GPU cluster sleeps**
  (power gating); the other GPU keys stay valid. Beta 1 counted each such moment as four
  failure episodes, which explains the `6-20` count in a Beta 1 report. 0.2.1 treats an
  inactive reading as unavailable and counts no episode. The unified log also shows sensor
  changes right after wake from sleep.
- The real 0.2.1 thermal provider and diagnostics tracker, run read-only against the SMC for
  20 + 30 minutes (1,441 samples): thermal state `available`, failure count `0`, no Tp/Te/Tg
  read failures. The GPU did not sleep during these runs, so the fan-guard fix itself was
  exercised in simulation only.

## Owner tests on the same Mac (2026-10-07, build 5 from the DMG)

- **Update from 0.2.0 Beta 1:** the What's New window appeared once. The helper from Beta 1 did
  not answer the new app; **Reinstall Helper** in that window fixed it (Connected afterwards).
  Expected: the new bundle changes the helper's code signature. °F applied everywhere and
  survived a restart; About shows *Helios 0.2.1 Beta 1 · Build 5*; the update check reports
  "up to date".
- **Auto with an idle Mac for 10 minutes:** stayed on Auto (in Beta 1 it fell back to System).
- **Thermals:** *Identified sensors*, °F in the curve editor, rules and summaries.
- **Diagnostics:** manual health and automatic reports show `failure_count` `0` everywhere; the
  compatibility report has no `provider_diagnostics` entries.
- **Lid closed for 2 minutes:** Helios resumed at once; Auto went to System before sleep, which is
  intended while *Keep Auto after sleep and restart* is off.
- **Uninstall:** the app went to the Trash, `launchctl print system/com.snejda.Helios.Daemon`
  reports the service gone, no Login Items entry; reinstalling from the DMG showed neither the
  welcome nor What's New.

## Not verified

- **Fan control while the GPU actually sleeps** was confirmed by the owner's idle run and in
  simulation; the exact −4.5 °C moment was not logged during that run.
- The display maps for M1, M2, M3, M5 and M6 on real hardware (catalogue only).
- One-click uninstall on a real installation in `/Applications` (logic tested with simulated
  steps only).
- What the SMC returns in the first minute after wake (a read-only probe is waiting for the
  next wake).
- Everything listed as not verified for 0.2.0 Beta 1.
