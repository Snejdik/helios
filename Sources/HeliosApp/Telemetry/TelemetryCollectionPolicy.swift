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

  /// First sentence of `detail`, for dense lists.
  var shortDetail: String {
    let first = detail.split(separator: ".", maxSplits: 1).first.map(String.init) ?? detail
    return first.hasSuffix(".") ? first : first + "."
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

/// Demand describes expensive presentation detail, never safety or alert inputs.
struct TelemetryDetailDemand: OptionSet, Sendable, Equatable {
  let rawValue: Int
  static let processes = Self(rawValue: 1 << 0)
  static let devices = Self(rawValue: 1 << 1)
  static let rawSensors = Self(rawValue: 1 << 2)
  static let all: Self = [.processes, .devices, .rawSensors]
}

/// Pure cadence policy shared by the runtime scheduler and offline fixtures.
enum TelemetryDetailPolicy {
  static func interval(visible: Bool, foreground: Duration, background: Duration) -> Duration {
    visible ? foreground : background
  }

  // Keep process counter deltas inside their 15-second validity window and
  // preserve session attribution/energy history even without a visible surface.
  static let backgroundProcessInterval: Duration = .seconds(10)
  static let backgroundDeviceInterval: Duration = .seconds(60)
  static let backgroundRawSensorInterval: Duration = .seconds(60)
}

/// Stable owner keys keep closing one surface from clearing another's demand.
struct TelemetryDetailDemandRegistry: Sendable {
  private var owners: [String: TelemetryDetailDemand] = [:]
  private(set) var demand: TelemetryDetailDemand = []

  @discardableResult
  mutating func set(_ value: TelemetryDetailDemand, owner: String) -> Bool {
    if value.isEmpty { owners.removeValue(forKey: owner) }
    else { owners[owner] = value }
    let combined = owners.values.reduce(TelemetryDetailDemand()) { $0.union($1) }
    guard combined != demand else { return false }
    demand = combined
    return true
  }
}
