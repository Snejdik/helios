# Helios roadmap / progress

Status after **Next21-fixed physical M4 validation** and the **Next22 functional-freeze implementation**. Next21-fixed passed the canonical regression/Xcode gate, live UI validation and `--io-preflight` on Mac16,1 / 25G83. Next22 percentages below are engineering estimates **conditional on the target Mac passing `check-all.sh` plus the new read-only feature/SMC/maintenance preflights**; they are not marketing claims.

| Area | Progress | Current state |
| --- | ---: | --- |
| Native app / menu-bar foundation | 97% | Native AppKit/SwiftUI lifecycle, typed unavailable states, diagnostics/capability export, persistent observability and modular cards are present; settings/final UI polish remain. |
| Secure privileged helper / XPC | 92% | Signed authenticated typed XPC, lifecycle, leases and fail-closed trust are validated; distribution signing/notarization remain. |
| CPU / Memory / system telemetry | 98% | CPU and Memory are independent domains; aggregate/per-core CPU plus logical/physical/P/E topology, rich VM accounting/pressure/swap, system identity/load/thermal state and persistent self-overhead are implemented. Reliable public CPU frequency/cluster residency remains intentionally unclaimed. |
| Thermals / sensor discovery | 92% | Trusted M4 P/E/GPU zones, Max SoC, dynamic thermal discovery, curated safety inputs and on-demand display-only raw numeric SMC inventory are implemented; wider Mac-family characterization remains. |
| Battery observability | 98% | System-normalized SoC is separated from raw mAh SoC; health/capacity/cycles/temp, signed power/source, cell/adapter/charger diagnostics, time remaining and persistent trends are implemented. Battery policy is deliberately out of scope and remains owned by macOS. |
| Fan control & cooling safety | **95%** | Boost, Manual, Auto Rules, journal recovery, SIGKILL, sleep/wake, soft release and 95°C daemon floor are physically validated on Mac16,1/25G83. Next20 does not widen this write surface. |
| Cooling Rules / TG-style automation | **84%** | Adapter/Battery profiles, per-fan schema, normalized speed, trusted sensors, highest-rule-wins, persistence/copy/reorder, hysteresis, emergency guard and SSD temperature source are implemented. |
| GPU performance telemetry | **60%** | Native IOKit device/renderer/tiler utilization, model/core count and unified-memory counters are physically validated. Frequency and component GPU power remain. |
| SSD / storage / SMART / TBW | **96%** | Native inventory/capacity/throughput/IOPS, boot counters, verified M4 NVMe SMART, external physical drives, since-Helios device deltas, boot averages, 24-hour physical/process I/O audit and lifetime SMART deltas are implemented. |
| Total system power / energy | **80%** | Verified read-only PSTR, session/24-hour Wh, signed battery Wh and direct per-task/P-core kernel energy are gap-safe and persisted. Reliable CPU/GPU/ANE/DRAM component rails/frequencies remain. |
| Network / Wi-Fi | **94%** | Primary/active interfaces, IP/link/rates/errors/session totals, CoreWLAN radio/security, gateway, DNS and search-domain diagnostics are implemented. Persistent per-interface long-term breakdown remains optional future work. |
| History / alerts / diagnostics | **96%** | Live + crash-tolerant 24-hour telemetry, CSV exports, gap-safe energy, I/O audit, seven-day health transitions, opt-in notifications, capability diagnostics and seven-day per-app energy history/trends are implemented. User-configurable policies move to the UI/settings phase. |
| Per-process / per-app attribution | **96%** | Native libproc CPU/energy/memory/I/O/wakeup/instruction/IPC/ANE attribution includes current/session leaders, Helios self-overhead and bounded seven-day per-app aggregate history with on-battery and recent-period comparisons. Cross-OS/Mac validation remains. |
| Multi-Mac capability discovery | 58% | A read-only capability matrix plus independent provider degradation now covers CPU topology, displays/peripherals/network/storage and core telemetry. Production fan writes remain pinned to the validated M4 profile; physical validation on more Macs remains mandatory. |
| System utilities / devices / maintenance | **93%** | Displays, mounted volumes, USB, Bluetooth, CoreAudio, sleep blockers, clocks, installed-app architecture/size inventory and read-only cleanup estimates are implemented. Final organization/actions belong to the UI phase; destructive cleanup is intentionally not implemented. |
| Distribution / notarization / updater | 10% | Development signing works; Developer ID, notarization, packaging and updater remain. |

## Overall

Validated Next21-fixed baseline: **~85% overall project completion**. If Next22 passes the target-Mac regression/build and live preflights, the **monitoring/fan functional core is approximately 94–95% complete**. Whole-product completion remains lower because the UI redesign, measured optimization, cross-Mac QA and release engineering are intentionally still ahead.

After Next22 validation the broad feature set freezes. Missing undocumented/private frequency or component-rail numbers are not blockers and will not be fabricated merely to reach 100%. Next phases are: Simple / Advanced / All UI and settings, measured CPU/RAM/wakeup/I/O/energy optimization, whole-codebase security/safety audit, cross-Mac validation, then signing/notarization/updater/release work.

## Next22 functional-freeze candidate

- [x] CPU and Memory are separate telemetry domains/cards.
- [x] Logical/physical/P-core/E-core topology and per-core activity.
- [x] Rich VM/memory accounting, pressure and swap counters.
- [x] System-normalized battery SoC separated from raw mAh SoC; charger/cell/adapter diagnostics remain read-only.
- [x] Displays, mounted volumes, USB, Bluetooth and CoreAudio inventories.
- [x] Sleep-blocking power assertions and richer network route/DNS/interface diagnostics.
- [x] World-clock/calendar backend.
- [x] Installed-app inventory with bundle/version/size/Mach-O architecture classification.
- [x] Read-only Cleanup Scout for selected caches/developer artifacts.
- [x] Seven-day bounded per-app energy/CPU/wakeup/memory attribution, one-minute aggregate persistence, CSV export and recent-hour trend comparison.
- [x] On-demand display-only raw numeric SMC inventory.
- [x] Explicit battery telemetry-only regression gate; privileged helper remains fan-only.
- [ ] Physical Next22 validation on target M4 (`check-all.sh`, feature/SMC/maintenance preflights).
- [ ] Feature freeze after target validation.
- [ ] Simple / Advanced / All information architecture and UI redesign.
- [ ] Post-freeze CPU/wakeup/I/O/energy optimization using Helios self-observability.
- [ ] Cross-Mac physical QA, release signing/notarization/updater work.

