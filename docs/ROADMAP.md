# Helios roadmap

Helios 0.2.1 **Beta 1** follows the first external beta (0.2.0 Beta 1). Near-term work
favours testing, compatibility and distribution over large rewrites.

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

## Next

- [ ] Smoke tests on more Macs (M1, M2, M3, M5; fanless MacBook Air; dual-fan; desktop)
- [ ] Confirm the 0.2.1 display maps against testers' compatibility reports and correct them
- [ ] Older supported macOS versions
- [ ] Trusted thermal maps beyond the M4 family, so fan control can reach more Macs
- [ ] Remaining physical fan tests (sleep and lid close while holding, reboot with ownership, macOS reclaiming the fans)
- [ ] Define the public support matrix
- [ ] Collect beta crash and compatibility feedback
- [ ] Optional: engage cooling earlier when the temperature climbs fast, always within the speed limit

## Distribution

- [ ] Developer ID Application signing
- [ ] Notarization and stapling
- [ ] Clean-machine helper install and approval test
- [ ] Release automation
- [ ] Secure automatic update installation after Developer ID signing and notarization

## ROADMAP / PLANNED — not implemented

These are future product directions, not currently available modules, first-beta
commitments or release blockers. No delivery dates are promised.

- **LinearMouse-style mouse controls/customization:** pointer and scrolling preferences.
- **Keep Awake:** a dedicated utility; the existing sleep-blocker inventory does not keep the Mac awake.
- **Drag-and-drop utilities/workflows.**
- **Clipboard / copy-paste history and tools:** existing Copy/export actions are not a clipboard-history module.
- **Future unified Mac utility modules:** scoped and independently disableable.

Other exploratory ideas include a command/search palette, unified exports,
a meaningful-event timeline and named UI profiles. Each requires separate
design, implementation and validation. None authorizes broadening the fan-only
helper or existing privacy/security boundaries.

## Non-goals / constraints

- no Intel/x86_64 target
- no destructive Cleanup Scout behavior without a separately designed safety model
- no privileged battery policy path
- no guessed universal Apple-Silicon fan writes
- no fake high-frequency WidgetKit telemetry
