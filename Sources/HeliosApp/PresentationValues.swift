import Foundation

/// Short display text, with the original typed failure retained for help/accessibility.
struct DisplayValue {
  let text: String
  let failure: String?

  init<Value>(_ result: MetricResult<Value>, format: (Value) -> String) {
    switch result {
    case .success(let value):
      text = format(value)
      failure = nil
    case .failure(let error):
      text = "—"
      failure = error.localizedDescription
    }
  }
}

struct ThermalGroupSummary: Sendable {
  let average: Double
  let maximum: Double

  static func summarize(_ metrics: ThermalMetrics, group: ThermalGroup) throws -> Self {
    let values = metrics.readings.filter { $0.group == group }.map(\.celsius)
    guard group != .unclassified, let maximum = values.max(), !values.isEmpty else {
      throw TelemetryError.unavailable("No temperature readings available for this sensor group")
    }
    return Self(average: values.reduce(0, +) / Double(values.count), maximum: maximum)
  }
}

struct OverviewPresentation {
  let cpu: MetricResult<CPUMetrics>
  let memory: MetricResult<MemoryMetrics>
  let gpu: MetricResult<GPUMetrics>
  let systemPower: MetricResult<SystemPowerMetrics>
  let system: MetricResult<SystemMetrics>
  let network: MetricResult<NetworkMetrics>
  let wifi: MetricResult<WiFiMetrics>
  let processes: MetricResult<ProcessMetrics>
  let battery: MetricResult<BatteryMetrics>
  let storage: MetricResult<StorageMetrics>
  let thermals: MetricResult<ThermalMetrics>
  let fans: MetricResult<FanInventory>
  let fanOwnershipPreflight: MetricResult<FanOwnershipPreflightSnapshot>
  let displays: MetricResult<DisplayMetrics>
  let volumes: MetricResult<VolumeMetrics>
  let usb: MetricResult<USBMetrics>
  let bluetooth: MetricResult<BluetoothMetrics>
  let audio: MetricResult<AudioMetrics>
  let powerAssertions: MetricResult<PowerAssertionsMetrics>
  let clock: MetricResult<ClockMetrics>

  init(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    cpu = TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now)
    memory = TelemetryFormatting.fresh(snapshot.memory, maxAge: 5, now: now)
    gpu = TelemetryFormatting.fresh(snapshot.gpu, maxAge: 5, now: now)
    systemPower = TelemetryFormatting.fresh(snapshot.systemPower, maxAge: 5, now: now)
    system = TelemetryFormatting.fresh(snapshot.system, maxAge: 30, now: now)
    network = TelemetryFormatting.fresh(snapshot.network, maxAge: 5, now: now)
    wifi = TelemetryFormatting.fresh(snapshot.wifi, maxAge: 15, now: now)
    processes = TelemetryFormatting.fresh(snapshot.processes, maxAge: 12, now: now)
    battery = TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now)
    storage = TelemetryFormatting.fresh(snapshot.storage, maxAge: 8, now: now)
    thermals = TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now)
    fans = TelemetryFormatting.fresh(snapshot.fans, maxAge: 5, now: now)
    fanOwnershipPreflight = TelemetryFormatting.fresh(
      snapshot.fanOwnershipPreflight, maxAge: 30, now: now)
    displays = TelemetryFormatting.fresh(snapshot.displays, maxAge: 90, now: now)
    volumes = TelemetryFormatting.fresh(snapshot.volumes, maxAge: 90, now: now)
    usb = TelemetryFormatting.fresh(snapshot.usb, maxAge: 150, now: now)
    bluetooth = TelemetryFormatting.fresh(snapshot.bluetooth, maxAge: 150, now: now)
    audio = TelemetryFormatting.fresh(snapshot.audio, maxAge: 90, now: now)
    powerAssertions = TelemetryFormatting.fresh(snapshot.powerAssertions, maxAge: 45, now: now)
    clock = TelemetryFormatting.fresh(snapshot.clock, maxAge: 150, now: now)
  }

  func temperatures(_ group: ThermalGroup) -> MetricResult<ThermalGroupSummary> {
    thermals.flatMap { metrics in
      captureMetric { try ThermalGroupSummary.summarize(metrics, group: group) }
    }
  }
}
