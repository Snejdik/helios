# Helios roadmap

Helios 0.3.0 **Beta 1** turns Helios into a Mac doctor: it explains *why*, watches how the
Mac holds up over months, runs on every Apple Silicon Mac and adds a few tools that save
clicks. The 0.3.0 betas lead to one 0.3.0 release; marketing waits until it is solid.

## Done

- [x] Native menu-bar app, popovers and a main window with Overview, Activity, History and Diagnostics
- [x] CPU, memory, GPU, thermal, fan, battery, power, storage, network and process telemetry
- [x] Battery health over time and an Energy page with period comparison
- [x] Hardware page and a goal-driven welcome
- [x] Local history, health events and optional notifications
- [x] Authenticated fan-only privileged helper
- [x] Experimental cool-only fan layer: System, Boost, Manual and Automatic curve, speed limit and handback to macOS
- [x] Optional, opt-in diagnostics with a preview, including optional fan-control statistics
- [x] Full regression, presentation and fixture-render gates
- [x] PolyForm Noncommercial 1.0.0 license
- [x] DMG and ZIP packaging for beta testing; GitHub Releases update check with manual download
- [x] Read-only CPU/GPU temperature display maps for M1, M2, M3, M5 and M6 (0.2.1; catalogue-derived, fan control unchanged)
- [x] Compatibility reports no longer count unsupported sensor formats as errors (0.2.1)
- [x] One-click uninstall that moves the app to the Trash, and a What's New window after updates (0.2.1)
- [x] Mac profile for every Apple Silicon chip and 59 models; sensor maps checked on each Mac at run time, with their status shown (0.3.0)
- [x] Experimental fan control on every Apple Silicon Mac with fans: consent per model and macOS build, a 20-second fan test, 70 % limit and no Boost outside the validated Mac (0.3.0)
- [x] "Why?" engine: slow, hot or loud, battery drain, cannot sleep, unexpected restart, slow Wi-Fi, disk filling up (0.3.0)
- [x] Network check (Wi-Fi, router, DNS, internet), Wi-Fi channel crowding and drops, optional data usage per app (0.3.0)
- [x] Longevity: battery, power adapter and cable, SSD, cooling against the Mac's first weeks, memory; word grades and an exportable weekly report (0.3.0)
- [x] Keep Awake, command palette, rules, "tell me when it's done", `helios://`, command line and Shortcuts (0.3.0)
- [x] The original 0.1 interface removed; one interface (0.3.0)
- [x] Latency history (optional, every five minutes, seven days) used by the network "Why?" (0.3.0)
- [x] Mouse settings as an experimental, off-by-default module: reverse only the scroll wheel, scroll distance (0.3.0)

## Next

- [ ] Fan test results and sensor-map confirmations from testers on M1, M2, M3, M5, M6, Pro/Max (two fans) and desktops
- [ ] Correct the catalogue maps from compatibility reports (base M5 efficiency cores are unknown)
- [ ] Remaining physical fan tests on the M4 (sleep and lid close while holding, reboot with ownership, macOS reclaiming the fans)
- [ ] Older supported macOS versions

## Distribution

- [ ] Developer ID Application signing
- [ ] Notarization and stapling
- [ ] Clean-machine helper install and approval test
- [ ] Release automation
- [ ] Secure automatic update installation after Developer ID signing and notarization

## Ideas — not planned yet

These are directions, not commitments; none has a date.

- **Mouse controls:** pointer speed and acceleration per device, beyond the 0.3.0 scroll-wheel settings.
- **Clipboard history and drag-and-drop helpers.**
- Widgets and automatic updates need a paid Apple Developer ID and are out of scope while Helios has none.

None of these may widen the fan-only helper or the existing privacy and security boundaries.

## Non-goals / constraints

- no Intel/x86_64 target
- no privileged battery policy path and no charge limiting
- no file deletion or "cleaner" without a separately designed safety model
- no arbitrary scripts from rules
- no fan writes on a Mac the user has not opted in for, and none before its fan test passes
- no fake high-frequency WidgetKit telemetry
