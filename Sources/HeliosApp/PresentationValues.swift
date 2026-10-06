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
    guard group != .unclassified else {
      throw TelemetryError.unavailable("No temperature readings available for this sensor group")
    }
    var count = 0
    var total = 0.0
    var maximum = -Double.infinity
    for reading in metrics.readings where reading.group == group {
      guard reading.celsius.isFinite else {
        throw TelemetryError.invalidData("Non-finite sensor group temperature")
      }
      count += 1
      total += reading.celsius
      maximum = max(maximum, reading.celsius)
    }
    guard count > 0 else {
      throw TelemetryError.unavailable("No temperature readings available for this sensor group")
    }
    guard total.isFinite else {
      throw TelemetryError.invalidData("Sensor group temperature total is not finite")
    }
    return Self(average: total / Double(count), maximum: maximum)
  }
}

/// Value-only expert inventory partitioning. Classification labels do not confer
/// trust; the provider's canonical group remains the source of truth.
struct ThermalInventoryPresentation: Sendable {
  struct GroupSummary: Sendable, Identifiable {
    let group: ThermalGroup
    let values: ThermalGroupSummary
    var id: String { group.rawValue }
  }

  let identified: [ThermalReading]
  let raw: [ThermalReading]
  let auxiliary: [ThermalDisplayReading]
  let unknown: [ThermalDisplayReading]
  let advisoryFailures: [String: TelemetryError]
  let summaries: [GroupSummary]

  init(_ metrics: ThermalMetrics) {
    identified = metrics.readings.filter { $0.group != .unclassified }.sorted { $0.key < $1.key }
    let raw = metrics.readings.filter { $0.group == .unclassified }.sorted {
      $0.celsius == $1.celsius ? $0.key < $1.key : $0.celsius > $1.celsius
    }
    self.raw = raw
    let classified = ThermalDisplayClassifier.classify(raw)
    auxiliary = classified.filter { $0.info.kind == .knownAuxiliary }
    unknown = classified.filter { $0.info.kind == .unknown }
    advisoryFailures = metrics.failures.filter { metrics.trustedFailures[$0.key] == nil }
    summaries = ThermalGroup.allCases.compactMap { group in
      guard let values = try? ThermalGroupSummary.summarize(metrics, group: group) else { return nil }
      return GroupSummary(group: group, values: values)
    }
  }
}

/// Derived once when an explicit inventory completes, not on each telemetry redraw.
struct ApplicationsInventoryPresentation: Sendable {
  let appleSiliconCount: Int
  let universalCount: Int
  let intelCount: Int
  let largestFirst: [InstalledApplicationMetrics]

  init(_ metrics: ApplicationsMetrics) {
    var arm = 0, universal = 0, intel = 0
    for application in metrics.applications {
      switch application.architecture {
      case .appleSilicon: arm += 1
      case .universal: universal += 1
      case .intel: intel += 1
      case .unknown: break
      }
    }
    appleSiliconCount = arm
    universalCount = universal
    intelCount = intel
    // Preserve the existing order policy, without converting absent sizes to data.
    largestFirst = metrics.applications.sorted {
      ($0.estimatedSizeBytes ?? 0) > ($1.estimatedSizeBytes ?? 0)
    }
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
    // Hidden device detail is sampled every 60 seconds; allow the same 90-second
    // envelope as other 60-second inventories rather than expiring between polls.
    powerAssertions = TelemetryFormatting.fresh(snapshot.powerAssertions, maxAge: 90, now: now)
    clock = TelemetryFormatting.fresh(snapshot.clock, maxAge: 150, now: now)
  }

  func temperatures(_ group: ThermalGroup) -> MetricResult<ThermalGroupSummary> {
    thermals.flatMap { metrics in
      captureMetric { try ThermalGroupSummary.summarize(metrics, group: group) }
    }
  }
}
