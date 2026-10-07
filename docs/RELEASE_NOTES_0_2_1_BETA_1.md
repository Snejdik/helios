# Helios 0.2.1 Beta 1 — release notes

Bundle version 0.2.1, build 5, tag `v0.2.1-beta.1`. A focused update to
[0.2.0 Beta 1](RELEASE_NOTES_0_2_0_BETA_1.md) for what testers on other Macs see first.
What was verified before release is in [VALIDATION_0_2_1_BETA_1.md](VALIDATION_0_2_1_BETA_1.md).

The build is **not notarized**. macOS asks you to confirm the first launch; see the
[installation guide](INSTALLATION.md).

## Temperatures on more Macs

- CPU and GPU temperatures, the P-core, E-core and GPU summaries and the menu-bar
  temperature now also work on **M1, M2, M3, M5 and M6** Macs. Before, those Macs showed
  only raw sensors.
- The sensor maps for these chips come from the public Stats sensor catalogue (MIT
  licensed) and have **not** been checked on real hardware yet. Helios says so on the
  Thermals page. Only the M4 family is verified.
- They are display-only. **Fan control, Cooling Rules and the helper are unchanged** and
  still use only the verified M4 map.
- Temperature alerts (90 °C / 95 °C by default) now also work on those Macs. They only
  inform you; they never change the fans.
- Sensor sections that used to say *Trusted* now say *Identified*, because on most Macs
  the identity comes from the catalogue.

## Fan control

- **Fixed:** Automatic, Manual and Boost no longer fall back to System whenever the GPU goes
  to sleep. Its temperature sensors switch off then, and Helios treated that as untrusted
  telemetry. Every other sensor problem still hands the fans back to macOS at once, and the
  helper's own safety checks are unchanged.

## Diagnostics

- The manual compatibility report no longer lists sensors stored in a format Helios does
  not read (`ioft`, `si32`) as decode errors. They still appear in the sensor inventory with
  their type. Genuinely broken readings are still reported.
- A temperature sensor that is switched off (the GPU sensors read about −4.5 °C while the GPU
  sleeps) is now reported as *not measuring* instead of as a failure, so the failure counter in
  diagnostics no longer climbs during normal use.
- Several sensors failing at the same moment count as one failure episode, not one per sensor.
  The report format is unchanged.

## Welcome and sharing

- A shorter welcome: what Helios can do for you as cards you tap, instead of behind
  *Customize…*. Fan control (and the helper step) appears only if you pick *Keep my Mac cool*,
  and is skipped when the helper is already installed.
- The welcome always asks about anonymous reports, with two checkboxes, both off until you
  tick them: a **daily health report** and the new **weekly compatibility report** (which
  sensors and fans the Mac has and what they read, sent automatically once a week). Each has
  a preview built from your Mac. The same choices are in Settings › Privacy & Diagnostics and
  in the What's New window.
- The DMG window now tells you to drag Helios onto the Applications folder.

## Uninstall and updates

- **Settings → Advanced → Uninstall Helios** now does everything: returns the fans to macOS,
  turns off Launch at Login, unregisters the helper, optionally erases local data, then moves
  Helios.app to the Trash and quits. If any step before the Trash fails, nothing else is
  touched. If the app cannot move itself (disk image, a temporary location chosen by macOS),
  Helios shows it in Finder.
- After an update a short **What's New** window appears once, with a °C / °F choice and the
  fan helper's status. A fresh installation sees the welcome setup instead.
- °F now applies everywhere it was missing: the fan curve editor, the notification
  thresholds in Settings, notification texts, the Expert thermal map and the Legacy window.
- Sensors that are switched off for a moment are listed under *Not measuring right now*, and
  sensors in a format Helios does not read under *Not readable by Helios*, instead of under
  *Read failures*. They no longer fill the log.
- The cooling option *Restore Auto when Helios starts* is now called *Keep Auto after sleep and
  restart*, which is what it always did.

## Upgrading from 0.2.0 Beta 1

- Replace the app in Applications. Settings, history and fan-control consent are kept.
- If you use fan control, reinstall the helper once: the What's New window shows
  **Reinstall Helper** (also in **Settings → Cooling**), and macOS may ask you to approve it.
  A new app version changes the helper's signature, so the old helper does not answer it.
- Beta 1 offers this release in its update check.

## Known limitations

- The display maps for M1, M2, M3, M5 and M6 are unverified; a compatibility report from
  such a Mac (Settings → Privacy & Diagnostics) is the fastest way to correct them.
- Fan control is still limited to Macs with a verified thermal map (M4 family).
- Everything listed under *Known limitations* for 0.2.0 Beta 1 still applies.
