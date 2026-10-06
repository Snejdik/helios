# Helios 0.2.0 Beta 1 — release notes

Bundle version 0.2.0, build 4, tag `v0.2.0-beta.1`. Built on the 0.1.0 Pre-beta 2
baseline. What was verified before release is in
[VALIDATION_0_2_0_BETA_1.md](VALIDATION_0_2_0_BETA_1.md).

Beta 1 is **not notarized**. macOS asks you to confirm the first launch; see the
[installation guide](INSTALLATION.md).

## A new Helios

Helios now answers *Is my Mac OK?* before it shows numbers.

- **New main window.** Overview, then Components (CPU, GPU, Memory, Thermals,
  Battery, Energy, Storage, Network, Hardware) with live values in the sidebar, and
  Insights (Activity, History, Diagnostics). ⌘1…⌘9 open the pages. Helios shows in the
  Dock only while a window is open.
- **Overview and Why?** One answer for your Mac, four health areas, a live chart that
  follows what needs attention and an inline explanation of every status.
- **Menu-bar popover** with a compact summary and per-metric popovers in the same style.
- **Welcome.** Tell Helios what matters; it configures the menu bar and starts only the
  samplers you need.
- **Legacy interface.** The original 0.1 window stays available in Settings → Advanced.

## Cooling

- **Fan layer (experimental, off by default).** Helios adds cooling on top of macOS and
  never cools less. Modes: System, Boost (15 minutes), Manual (a minimum speed) and
  Automatic.
- **Fan curve.** Automatic follows an editable temperature → speed curve, separately for
  power adapter and battery, with presets, a Response slider and an optional step-rules mode.
- **Speed limit.** Helios stays at or below 90 % of the factory maximum and hands the fans
  back to macOS when more cooling is needed. You can unlock the full range in Settings.
- **Restore Auto when Helios starts** (off by default) re-arms Auto after launch and after
  the helper reconnects. Manual and Boost are never restored.
- **Safety.** Fan control returns to macOS on any error, before sleep, when Helios quits or
  the helper restarts, and recovers from a killed helper at the next start. It works on any
  Mac the read-only probe accepts, once you turn it on for that model and macOS version.
- **Menu bar.** The cooling item shows the fan state over `average/hottest` temperature.

## Battery and energy

- **Energy page.** Ranges from one hour to seven days or a custom range, an on-battery
  filter, apps using more than in the period before, unobserved (asleep) time, app actions
  (Quit, Force Quit, Show in Finder) and CSV or JSON export.
- **Battery page.** Health, cycles, capacity, power and condition, plus health over time,
  recorded once a day.
- **Hardware page** with what this Mac is and what Helios can read.

## Alerts and diagnostics

- Notifications you can tune per area; defaults warn at 90 °C and 95 °C chip temperature.
  Alerts only inform and never change fan control.
- Optional beta diagnostics gained an opt-in **fan-control statistics** section (off by
  default, in memory only, bucketed, visible in "View what is shared").

## Smaller changes

- The Thermals page shows average and hottest temperature; CPU, GPU, Memory and Network
  pages and popovers gained the missing detail (cores, swap, upload, Wi-Fi).
- Seven days of app-energy history use a fraction of the memory, and local history is
  no longer rewritten constantly.
- "Right now" groups helper processes under their app.
- The log no longer repeats the same fan message twice a second.

## Upgrading

- The helper protocol changed. After updating, **Settings → Cooling → Reinstall** if Helios
  asks for it.
- Fan control consent is stored per Mac model and macOS build; after a macOS update, turn
  it on again.
- The build is Apple Development signed, not notarized.

## Known limitations

- Fan control is experimental. Taking the fans from macOS needs several seconds, and fans
  cannot stop the chip from throttling during a short spike.
- Trusted temperature sensors are mapped for the M4 family only; other chips stay read-only
  for fan control until their maps are verified.
- Some physical fan tests (sleep or lid close while holding, reboot with ownership) are not
  finished.
- App-energy history is kept for seven days.
