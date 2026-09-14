# Helios roadmap

Helios is now in **release engineering / external-beta preparation**. The monitoring and UI feature set is intentionally much more stable than during the earlier implementation phases; near-term work should favor validation, compatibility and distribution over large rewrites.

## Now

- [x] Native menu-bar architecture
- [x] Quick Dashboard and Full Monitor
- [x] CPU / Memory / GPU / thermal telemetry
- [x] Battery and system-power observability
- [x] Storage, volumes and read-only NVMe SMART
- [x] Network / Wi-Fi diagnostics
- [x] Process and per-app energy attribution
- [x] Persistent telemetry/history and health events
- [x] Devices, system information and read-only maintenance inventory
- [x] Authenticated fan-only privileged helper
- [x] Exact-profile Manual / Boost / Automatic Rules safety model
- [x] Full regression and native presentation gates
- [x] Measured CPU/wakeup/persistence optimization
- [x] Repeated UI lifecycle/memory plateau validation on the primary M4 host

## External beta preparation

- [ ] Read-only smoke tests on additional M1/M2/M3/M4/M5-class Macs
- [ ] Fanless MacBook Air validation
- [ ] Dual-fan Mac read-only topology validation
- [ ] Desktop/no-battery validation
- [ ] Older supported macOS smoke testing
- [x] Adopt the PolyForm Noncommercial License 1.0.0 for Helios original material
- [ ] Define the public support matrix
- [ ] Collect beta crash/compatibility feedback

## Distribution

- [ ] Developer ID Application signing
- [ ] Notarization
- [ ] Stapling
- [ ] Clean-machine helper install/approval test
- [x] DMG/ZIP packaging for public pre-beta testing
- [ ] Release automation
- [x] Pre-beta update strategy: GitHub Releases checker with manual download
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
