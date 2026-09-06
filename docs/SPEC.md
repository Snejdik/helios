# Helios - Functional Specification

## Distribution
- Personal use for now; no Mac App Store, ever. May share via direct/notarized download later.
- Local dev/testing works fine with a free Apple ID (Personal Team). Upgrade to paid Developer ID only when ready to notarize/share.

## Core Modules

### 1. Telemetry Provider (Read-Only)
- CPU & Memory via Mach host statistics (`host_statistics64`, `processor_info`).
- Thermals via Apple SMC keys (`sp78`/`fpe2`/`flt` decoding) through `IOKit` (`AppleSMC` service) — dynamic key discovery, no hardcoded Intel-era arrays.
- GPU usage via `IOAccelerator` performance statistics.
- SSD: free/used storage, real-time throughput, NVMe SMART (TBW, wear %).

### 2. Privileged Fan Controller (SMAppService daemon + NSXPCConnection)
- Modes: **System** (Apple default) / **Boost** / **Auto Max** — all safe, no override.
- **Override System** (explicit opt-in only): app takes full responsibility for a custom temperature→RPM curve.
- Curve engine requires: hysteresis/debounce (no oscillation), dual-rate polling (~2s baseline, 250–500ms once a "watch" threshold is crossed), and an independent heartbeat/staleness check.
- Reacts to sleep/wake and AC/battery transitions via `NSWorkspace` push notifications (not polling); optional "aggressive curve only on AC" toggle.
- Hard RPM clamping to hardware min/max reported by SMC.

### 3. Battery & Power
- Raw metrics (CoconutBattery parity): design/max capacity (mAh), health %, cycle count, cell temp, charger wattage, real-time total system watts (V×A) — via `AppleSmartBattery` IOKit keys.
- **Per-App Power Attribution** (OpenMacBattery parity): periodic `proc_pid_rusage` sampling (in-process, no root needed for same-user processes) of CPU time/wakeups/energy-impact score per app; proportional *estimated* share of total system wattage per app, explicitly labeled as an estimate in the UI. Ranked top-N list over a selectable time window.

### 4. History & Alerts
- Rolling in-memory buffer (~60 min) for live graphs: temps, RPM, wattage, per-app drain.
- Optional persisted history (24h–7 days) in a lightweight local file, not a heavy DB.
- Threshold-based alerts via `UserNotifications`, rate-limited.

### 5. User Interface (Menu Bar)
- Status item: compact text readout (CPU % · RAM | Max/Avg Temp | Fan RPM).
- Popover: gauges for CPU/GPU/RAM/Temps, per-fan controls with mode selector, battery/power panel, history graphs, daemon status indicator.

### 6. Graceful Degradation & Compatibility
- macOS version gate: minimum macOS 13 (SMAppService requirement) — clear alert if unsupported.
- Each module independently probes required SMC/IOKit keys at launch/wake; missing or malformed data marks that module "unavailable" with an inline notice — never crashes or blocks other modules.
- XPC client/daemon exchange a protocol version on connect; mismatch triggers re-registration, not a silent failure.
- `OSLog` for all failure paths; simple "Copy diagnostics" UI action.

### 7. Failsafe & Watchdog
- Daemon disconnect/crash → automatic revert to Apple default fan management.
- Curve-engine staleness (heartbeat) independently monitored.
- Clean uninstall: `SMAppService.daemon.unregister()` + removal of installed files.