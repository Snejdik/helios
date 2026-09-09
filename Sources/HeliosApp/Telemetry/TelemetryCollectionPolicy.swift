import Foundation

/// Read-only telemetry collection groups that may be disabled independently by the user.
/// Trusted thermal safety sampling is intentionally not represented here and remains always-on.
enum HeliosTelemetryModule: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case gpu
  case power
  case network
  case wifi
  case processes
  case battery
  case storage
  case fans
  case devices

  var id: String { rawValue }

  var label: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .gpu: "GPU"
    case .power: "System Power"
    case .network: "Network"
    case .wifi: "Wi-Fi details"
    case .processes: "Processes & Energy"
    case .battery: "Battery"
    case .storage: "Storage"
    case .fans: "Fan telemetry"
    case .devices: "Devices & peripherals"
    }
  }

  var detail: String {
    switch self {
    case .cpu: "CPU usage and per-core activity."
    case .memory: "Memory usage, pressure and composition."
    case .gpu: "GPU utilization and renderer/tiler statistics."
    case .power: "System power telemetry used by power and energy views."
    case .network: "Interface throughput counters. Disable this to stop 1 Hz network sampling."
    case .wifi: "Wi-Fi radio details such as RSSI/SNR, sampled less frequently than throughput."
    case .processes: "Per-process CPU, memory, wakeups and bounded app-energy attribution."
    case .battery: "Read-only battery state, health, electrical and time-remaining telemetry."
    case .storage: "Capacity, read/write throughput, IOPS and supported SMART health."
    case .fans:
      "Fan RPM and ownership preflight. Trusted thermal safety sampling remains independent."
    case .devices: "Displays, volumes, USB, Bluetooth, audio, sleep assertions and clock metadata."
    }
  }

  var monitoringCost: String {
    switch self {
    case .cpu, .memory, .power, .battery: "Low"
    case .gpu, .network, .wifi, .storage, .fans: "Low–moderate"
    case .processes: "Moderate"
    case .devices: "Low / infrequent"
    }
  }
}
