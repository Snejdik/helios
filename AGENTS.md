# Helios - Agent Guidelines

## Role & Mission
You are building **Helios**, a lightweight, high-performance macOS Menu Bar system monitoring and fan control utility written natively in Swift.

## Strict Engineering Constraints
- **Language & Stack:** Pure Swift (Swift 5.9+ / Swift 6), AppKit / SwiftUI for UI, native system APIs.
- **No External CLI Spawning:** Never use `Process()` or shell invocations (`top`, `sysctl`, `sudo`, `powermetrics`, `pmset`) for runtime metrics or fan control. All operations must use native C/Darwin APIs, Mach kernel calls, or IOKit.
- **Privilege Separation:** 
  - UI runs as an unprivileged Menu Bar app.
  - SMC fan write operations must be delegated to a privileged LaunchDaemon registered via `SMAppService` (macOS 13+).
  - Communication happens strictly via `NSXPCConnection`.
- **Target OS:** macOS 13.0 (Ventura) and newer.
- **Code Style:** Idiomatic Swift, clean modular separation (Data Source / Telemetry / IPC / UI), thread-safe concurrency (Swift Concurrency `async`/`await` or dedicated dispatch queues).
- **Error Handling:** Graceful degradation. If sensors cannot be read or permissions are missing, present a clean empty/fallback state rather than crashing.

## Architecture Guidelines
1. **HeliosApp (Main Menu Bar App):**
   - Host `NSStatusItem` via SwiftUI / AppKit.
   - Handles real-time polling of CPU, GPU, RAM, thermals via IOKit/Mach APIs.
   - Handles IPC client for daemon commands.
2. **HeliosDaemon (Privileged Helper):**
   - Headless LaunchDaemon managed by `SMAppService.daemon(plistName:)`.
   - Validates XPC clients (Team ID / Entitlements).
   - Direct Apple SMC write operations for target fan RPM / manual override.