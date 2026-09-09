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
- [ ] Choose the project license
- [ ] Define the public support matrix
- [ ] Collect beta crash/compatibility feedback

## Distribution

- [ ] Developer ID Application signing
- [ ] Notarization
- [ ] Stapling
- [ ] Clean-machine helper install/approval test
- [ ] DMG or equivalent packaging
- [ ] Release automation
- [ ] Update strategy

## Future product ideas

These are post-stabilization ideas, not current release blockers:

- Caffeine / Keep Awake utility
- pointer and scrolling controls where public macOS APIs make them reliable
- global Helios command/search palette
- unified export for current views and selected ranges
- meaningful-event timeline
- named UI profiles/presets
- additional low-overhead utility modules that remain modular and independently disableable

## Non-goals / constraints

- no Intel/x86_64 target
- no destructive Cleanup Scout behavior without a separately designed safety model
- no privileged battery policy path
- no guessed universal Apple-Silicon fan writes
- no fake high-frequency WidgetKit telemetry
