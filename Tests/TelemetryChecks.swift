import AppKit
import Darwin
import Foundation
import IOKit.ps

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw CheckFailure(description: message) }
}

/// Owns only fixture task handles, including tasks canceled before their first turn.
@MainActor
private final class NotificationFixtureTasks {
  private(set) var tasks: [Task<Void, Never>] = []

  func observe(_ task: Task<Void, Never>) { tasks.append(task) }

  func drain() async {
    let pending = tasks
    tasks.removeAll()
    let deadline = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      fatalError("Notification fixture tasks did not complete within five seconds")
    }
    defer { deadline.cancel() }
    for task in pending { await task.value }
  }
}

@MainActor
private final class NotificationFixtureConfiguration {
  var value = HealthAlertConfiguration.defaults
}

@MainActor
private final class NotificationFixtureClock {
  var now: Date
  init(_ now: Date) { self.now = now }
}

private func expectTelemetryFailure<Value>(_ operation: () throws -> Value) throws {
  do { _ = try operation() } catch is TelemetryError { return }
  throw CheckFailure(description: "Expected a typed telemetry failure")
}

private func close(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.0001 }

private func word(_ value: UInt32, littleEndian: Bool = true) -> [UInt8] {
  let bytes = (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  return littleEndian ? bytes : bytes.reversed()
}

private struct SensorFixture {
  let key: String
  let type: String
  let bytes: [UInt8]
}

/// A deterministic firmware substitute. Production decoding and discovery are unchanged.
private final class FixtureTransport: SMCReadTransport {
  let sensors: [SensorFixture]
  var requests: [SMCReadRequest] = []
  var failingReads = Set<String>()
  var failingIndexes = Set<UInt32>()
  var countOverride: UInt32?
  var replyOverride: [UInt8]?
  var onExchange: ((SMCReadRequest) -> Void)?

  init(_ sensors: [SensorFixture]) { self.sensors = sensors }

  func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
    requests.append(request)
    onExchange?(request)
    if let replyOverride { return replyOverride }
    var reply = [UInt8](repeating: 0, count: 80)
    func put(_ bytes: [UInt8], at offset: Int) {
      reply.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
    switch request.command {
    case .keyAtIndex:
      guard request.index < sensors.count, !failingIndexes.contains(request.index) else {
        throw TelemetryError.smc("index", 0x84)
      }
      let key = sensors[Int(request.index)].key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      put(word(key), at: 0)
    case .keyInfo, .bytes:
      let sensor: SensorFixture
      if request.key == "#KEY" {
        sensor = SensorFixture(
          key: "#KEY", type: "ui32",
          bytes: word(countOverride ?? UInt32(sensors.count), littleEndian: false))
      } else if let fixture = sensors.first(where: { $0.key == request.key }) {
        sensor = fixture
      } else {
        throw TelemetryError.smc(request.key, 0x84)
      }
      if request.command == .keyInfo {
        put(word(UInt32(sensor.bytes.count)), at: 28)
        put(word(sensor.type.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }), at: 32)
      } else {
        guard !failingReads.contains(request.key) else {
          throw TelemetryError.smc(request.key, 0x84)
        }
        guard sensor.bytes.count <= 32, request.dataSize == sensor.bytes.count else {
          throw TelemetryError.invalidData("Invalid fixture read size")
        }
        put(sensor.bytes, at: 48)
      }
    }
    return reply
  }
}

@main
private struct TelemetryChecks {
  @MainActor static func main() async {
    do { try await run() } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }

  @MainActor private static func run() async throws {
    if CommandLine.arguments.contains("--persistence-only") {
      try await historyCompactionChecks()
      try appEnergyTieringChecks()
      try await batteryHealthChecks()
      try await persistentHistoryChecks()
      try await ioAuditChecks()
      try await persistenceLifecycleChecks()
      print("PASS focused persistence checks")
      return
    }
    if CommandLine.arguments.contains("--ui-history-only") {
      try historyChecks()
      try await persistentHistoryChecks()
      print(
        "PASS Next23 UI chart history: live + persistent 24h bounds, memory trend capture, gap-safe energy integration, and sample semantics"
      )
      return
    }

    try adaptiveDetailChecks()
    try cpuChecks()
    print("PASS CPU deltas, rollover, warm-up and reset")
    try batteryChecks()
    print(
      "PASS battery system SoC vs raw capacity, manufacture date, voltage/current/adapter/time-remaining telemetry and partial failures"
    )
    try gpuChecks()
    print("PASS GPU PerformanceStatistics parsing, partial fields and bounds")
    try processChecks()
    print(
      "PASS per-process delta attribution, PID-reuse protection, direct energy/IPC/ANE, exact I/O deltas and session-safe models"
    )
    try appEnergyChecks()
    print(
      "PASS bounded per-app energy aggregation, 1h trend comparison, retention and on-battery separation"
    )
    try maintenanceChecks()
    try await maintenanceCancellationChecks()
    print(
      "PASS read-only maintenance scanners, bounded cleanup discovery and Mach-O architecture classification"
    )
    try utilityProviderChecks()
    print("PASS Bluetooth raw-RSSI normalization and CFNumber-keyed power assertion parsing")
    try networkChecks()
    print("PASS native network counter deltas, 32-bit rollover, interface handoff and bounds")
    try wifiChecks()
    print("PASS Wi-Fi radio formatting, SNR validation and privacy-safe partial fields")
    try historyChecks()
    print("PASS 60-minute rolling history, gap-safe PSTR energy integration and sample bounds")
    try await historyCompactionChecks()
    try appEnergyTieringChecks()
    try await batteryHealthChecks()
    try await persistentHistoryChecks()
    print(
      "PASS 24-hour append-friendly persistent history, retention, battery trends, CSV export, clock ordering and gap-safe energy"
    )
    try await ioAuditChecks()
    print(
      "PASS 24-hour physical/process I/O audit, gap-safe device accounting, CSV export and malformed-tail recovery"
    )
    try await persistenceLifecycleChecks()
    try capabilityChecks()
    print(
      "PASS capability report states keep read-only discovery separate from fan write authorization"
    )
    try healthChecks()
    try await healthEventChecks()
    try await notificationDeliveryChecks()
    try await notificationObservationChecks()
    print(
      "PASS independent health thresholds, transition history, crash-tolerant event persistence and notification-free safety isolation"
    )
    try systemChecks()
    print("PASS system thermal-state mapping and utility formatting")
    try storageChecks()
    print(
      "PASS storage capacity/counters, throughput deltas, rollover rejection, and SMART capability classification"
    )
    try smcChecks()
    try displayThermalChecks()
    try await numericCancellationChecks()
    print("PASS SMC discovery, ABI, decoding, isolation and recovery")
    try formattingChecks()
    print("PASS pressure decoding and stale/unavailable display")
    if CommandLine.arguments.contains("--live") { try await liveChecks() }
  }

  private static func adaptiveDetailChecks() throws {
    var registry = TelemetryDetailDemandRegistry()
    try require(registry.set(.processes, owner: "monitor"), "First visible owner must request fresh detail")
    try require(!registry.set(.processes, owner: "inspector"), "Second consumer must share collection")
    try require(!registry.set([], owner: "monitor") && registry.demand == .processes,
      "Closing one consumer stopped another's sampler")
    _ = registry.set([.devices, .rawSensors], owner: "monitor")
    try require(registry.demand == .all, "Independent detail demands did not union")
    _ = registry.set([], owner: "inspector")
    try require(registry.demand == [.devices, .rawSensors], "Process demand leaked after closing final consumer")
    _ = registry.set([], owner: "monitor")
    try require(registry.demand.isEmpty, "Detail demand leaked after teardown")
    try require(registry.set(.processes, owner: "monitor"), "Reopen must establish fresh demand")
    try require(TelemetryDetailPolicy.backgroundProcessInterval < .seconds(15),
      "Hidden process cadence violates counter/energy integration freshness")
    try require(TelemetryDetailPolicy.interval(visible: false, foreground: .seconds(5),
      background: TelemetryDetailPolicy.backgroundProcessInterval) == .seconds(10), "Hidden process work did not relax")

    let transport = FixtureTransport([
      SensorFixture(key: "Tp01", type: "sp78", bytes: [60, 0]),
      SensorFixture(key: "Tzzz", type: "sp78", bytes: [110, 0]),
    ])
    let reader = SMCThermalReader(client: SMCClient(transport: transport),
      classifier: ThermalClassifier(cpuBrand: "Apple M4"))
    _ = try reader.read(rawDetailsVisible: false)
    transport.requests.removeAll()
    let hidden = try reader.read(rawDetailsVisible: false)
    try require(transport.requests.filter { $0.command == .bytes && $0.key == "Tp01" }.count == 1,
      "Hidden detail suppressed trusted safety sampling")
    try require(!transport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Hidden detail unnecessarily reread raw sensors")
    try require(try hidden.maximumSoCCelsius.get() == 60, "Unknown hot reading entered Max SoC")
    transport.requests.removeAll()
    _ = try reader.read(rawDetailsVisible: true)
    try require(transport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Newly visible raw surface waited for the background deadline")
    transport.requests.removeAll()
    _ = try reader.read(rawDetailsVisible: true)
    try require(!transport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Multiple visible consumers duplicated raw collection")

    // Advance only the injected advisory scheduler clock; no sleeping or hardware.
    let cadenceTransport = FixtureTransport([
      SensorFixture(key: "Tp01", type: "sp78", bytes: [60, 0]),
      SensorFixture(key: "Tzzz", type: "sp78", bytes: [110, 0]),
    ])
    let cadenceReader = SMCThermalReader(client: SMCClient(transport: cadenceTransport),
      classifier: ThermalClassifier(cpuBrand: "Apple M4"))
    let clock = ContinuousClock.now
    _ = try cadenceReader.read(rawDetailsVisible: false, now: clock)
    cadenceTransport.requests.removeAll()
    _ = try cadenceReader.read(rawDetailsVisible: false, now: clock.advanced(by: .seconds(59)))
    try require(!cadenceTransport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Hidden raw detail violated the relaxed deadline")
    _ = try cadenceReader.read(rawDetailsVisible: false, now: clock.advanced(by: .seconds(60)))
    try require(cadenceTransport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Hidden raw detail failed to refresh after its deadline")
    cadenceTransport.requests.removeAll()
    _ = try cadenceReader.read(rawDetailsVisible: true, now: clock.advanced(by: .seconds(61)))
    try require(cadenceTransport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Visible transition did not refresh immediately")
    cadenceTransport.requests.removeAll()
    _ = try cadenceReader.read(rawDetailsVisible: true, now: clock.advanced(by: .seconds(75)))
    try require(!cadenceTransport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Visible raw detail reread before its deadline")
    _ = try cadenceReader.read(rawDetailsVisible: true, now: clock.advanced(by: .seconds(76)))
    try require(cadenceTransport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Visible raw detail failed to refresh at its deadline")
    cadenceTransport.requests.removeAll()
    _ = try cadenceReader.read(rawDetailsVisible: true, forceRawRefresh: true,
      now: clock.advanced(by: .seconds(77)))
    try require(cadenceTransport.requests.contains { $0.command == .bytes && $0.key == "Tzzz" },
      "Rapid close/reopen demand failed to force a fresh shared raw batch")

    let fan = FanOwnershipPreflightFan(id: 0, modeKey: "F0Md", mode: 0,
      actualRPM: 2500, targetRPM: 2500, minimumRPM: 2000, maximumRPM: 6000, targetType: "fpe2")
    func evidence(model: String = "Mac16,1", build: String) -> FanOwnershipPreflightEvidence {
      FanOwnershipPreflightEvidence(modelIdentifier: model, osBuild: build, fanCount: 1,
        globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [fan])
    }
    let validated = FanOSValidationCandidate.assess(evidence(build: "25G83"))
    try require(validated.productionPreflightState == .readyForValidation && !validated.requiresPhysicalValidation,
      "Existing validated OS classification changed")
    let candidate = FanOSValidationCandidate.assess(evidence(build: "26A123"))
    try require(candidate.productionPreflightState == .blocked && candidate.requiresPhysicalValidation,
      "Offline candidate granted production write support")
    let unknown = FanOSValidationCandidate.assess(evidence(model: "Mac16,11", build: "26A123"))
    try require(unknown.productionPreflightState == .unsupported && !unknown.blockers.isEmpty,
      "Offline candidate broadened hardware support")
  }

  private static func cpuChecks() throws {
    var calculator = CPUUsageCalculator()
    let zero = CPUTicks(user: 0, system: 0, nice: 0, idle: 0)
    try expectTelemetryFailure { try calculator.consume([zero, zero]) }
    let first = CPUTicks(user: 20, system: 10, nice: 5, idle: 65)
    let second = CPUTicks(user: 40, system: 20, nice: 5, idle: 35)
    let metrics = try calculator.consume([first, second])
    try require(
      close(metrics.userPercent, 30) && close(metrics.systemPercent, 15),
      "CPU must aggregate all processors")
    try require(
      close(metrics.nicePercent, 5) && close(metrics.idlePercent, 50), "CPU state percentages")
    try require(close(metrics.usagePercent, 50), "Busy CPU includes nice time")
    try require(metrics.perCoreUsagePercent.count == 2, "CPU per-core count")
    try require(
      close(metrics.perCoreUsagePercent[0], 35) && close(metrics.perCoreUsagePercent[1], 65),
      "Per-core CPU deltas")
    try expectTelemetryFailure { try calculator.consume([first, second]) }
    try expectTelemetryFailure { try calculator.consume([first]) }
    calculator.reset()
    try expectTelemetryFailure { try calculator.consume([first]) }
    try expectTelemetryFailure { try calculator.consume([]) }
    calculator.reset()
    try expectTelemetryFailure {
      try calculator.consume([CPUTicks(user: UInt32.max - 4, system: 0, nice: 0, idle: 100)])
    }
    let wrapped = try calculator.consume([CPUTicks(user: 5, system: 0, nice: 0, idle: 110)])
    try require(close(wrapped.usagePercent, 50), "32-bit tick rollover must not become a spike")
  }

  private static func batteryChecks() throws {
    var properties: [String: Any] = [
      "DesignCapacity": 6000, "AppleRawMaxCapacity": 5700, "MaxCapacity": 100,
      "AppleRawCurrentCapacity": 3000, "CurrentCapacity": 52, "CycleCount": 0,
      "Temperature": 3050, "Voltage": 12000, "InstantAmperage": -1500,
      "ExternalConnected": false, "IsCharging": false,
      "AdapterDetails": ["Watts": 96, "AdapterVoltage": 20_000],
      "ChargerData": [
        "ChargingCurrent": 3_000, "ChargingVoltage": 12_500, "NotChargingReason": 16,
      ],
      "BatteryData": ["CellVoltage": [4_010, 4_015, 4_005]],
    ]
    let battery = BatteryParser.parse(properties)
    try require(try battery.maximumCapacityMAh.get() == 5700, "Normalized MaxCapacity is not mAh")
    try require(
      try battery.currentCapacityMAh.get() == 3000, "Normalized CurrentCapacity is not mAh")
    try require(try close(battery.healthPercent.get(), 95), "Health uses raw maximum / design")
    try require(try battery.cycleCount.get() == 0, "Zero cycles is valid")
    try require(try close(battery.temperatureCelsius.get(), 30.5), "Battery centi-Celsius scaling")
    let discharge = try battery.power.get()
    try require(
      close(discharge.signedWatts, -18) && discharge.label == "Battery Discharge (instantaneous)",
      "Discharge direction and mV*mA scaling")
    try require(
      try battery.powerSource.get() == .battery,
      "ExternalConnected=false did not select Battery profile")
    try require(try close(battery.voltageVolts.get(), 12), "Battery voltage conversion")
    try require(try close(battery.currentAmps.get(), -1.5), "Battery current conversion")
    try require(try battery.adapterWatts.get() == 96, "Adapter wattage parsing")
    try require(try close(battery.adapterVoltageVolts.get(), 20), "Adapter voltage conversion")
    try require(try close(battery.chargingCurrentAmps.get(), 3), "Charging current conversion")
    try require(try close(battery.chargingVoltageVolts.get(), 12.5), "Charging voltage conversion")
    let cells = try battery.cellVoltagesVolts.get()
    try require(
      cells.count == 3 && close(cells[0], 4.010) && close(cells[2], 4.005),
      "Battery cell-voltage parsing")
    try require(
      try close(battery.cellBalanceMillivolts.get(), 10), "Battery cell-balance calculation")
    try require(
      try battery.notChargingReasonRaw.get() == 16, "Not-charging reason stays raw diagnostic data")
    try require(try battery.isCharging.get() == false, "Charging state parsing")
    try require(
      try close(battery.systemChargePercent.get(), 52),
      "System CurrentCapacity must remain normalized SoC")
    try require(
      try close(battery.stateOfChargePercent.get(), 52),
      "User-facing state of charge must prefer macOS normalized SoC")
    try require(
      try close(battery.rawStateOfChargePercent.get(), Double(3000) / Double(5700) * 100),
      "Raw capacity ratio must remain separately observable")
    let description: [String: Any] = [
      kIOPSCurrentCapacityKey as String: 80, kIOPSIsChargedKey as String: false,
      "Optimized Battery Charging Engaged": 1,
    ]
    let described = BatteryParser.parse(properties, powerSourceDescription: description)
    try require(
      try close(described.stateOfChargePercent.get(), 52),
      "AppleSmartBattery normalized SoC should take precedence when present")
    var noRegistrySoC = properties
    noRegistrySoC.removeValue(forKey: "CurrentCapacity")
    let describedFallback = BatteryParser.parse(noRegistrySoC, powerSourceDescription: description)
    try require(
      try close(describedFallback.stateOfChargePercent.get(), 80),
      "IOPowerSources normalized SoC fallback")
    try require(try describedFallback.optimizedChargingEngaged.get(), "Optimized charging state")
    properties["ExternalConnected"] = true
    try require(
      try BatteryParser.parse(properties).powerSource.get() == .powerAdapter,
      "ExternalConnected=true did not select Power Adapter profile")
    properties["ExternalConnected"] = NSNumber(value: 1)
    properties["IsCharging"] = NSNumber(value: 1)
    let numericFlags = BatteryParser.parse(properties)
    try require(
      try numericFlags.powerSource.get() == .powerAdapter && numericFlags.isCharging.get(),
      "Integral 0/1 battery flags")
    properties["ExternalConnected"] = false
    properties["IsCharging"] = false
    for raw in [
      NSNumber(value: -1500), NSNumber(value: UInt32.max - 1499),
      NSNumber(value: UInt64.max - 1499),
    ] {
      try require(
        try BatteryParser.signedAmperage(raw) == -1500,
        "Signed/unsigned IORegistry current representations")
    }
    properties["InstantAmperage"] = 2000
    let charge = try BatteryParser.parse(properties).power.get()
    try require(
      close(charge.signedWatts, 24) && charge.label == "Battery Charge (instantaneous)",
      "Battery charging power")
    properties["InstantAmperage"] = 0
    try require(
      try BatteryParser.parse(properties).power.get().label == "Battery Idle (instantaneous)",
      "Zero current is valid")
    properties.removeValue(forKey: "InstantAmperage")
    properties["Amperage"] = -1000
    let averaged = try BatteryParser.parse(properties).power.get()
    try require(
      !averaged.usesInstantaneousCurrent && averaged.label.contains("averaged current"),
      "Averaged fallback must be labeled")
    properties["InstantAmperage"] = "broken"
    try expectTelemetryFailure { try BatteryParser.parse(properties).power.get() }
    properties.removeValue(forKey: "AppleRawMaxCapacity")
    properties.removeValue(forKey: "AppleRawCurrentCapacity")
    let partial = BatteryParser.parse(properties)
    try expectTelemetryFailure { try partial.maximumCapacityMAh.get() }
    try expectTelemetryFailure { try partial.currentCapacityMAh.get() }
    try require(
      try partial.designCapacityMAh.get() == 6000,
      "Missing fields must not erase independent metrics")
    let nested = BatteryParser.parse([
      "BatteryData": [
        "DesignCapacity": 6000, "FullChargeCapacity": 5700, "RemainingCapacity": 0,
        "CycleCount": 10,
      ]
    ])
    try require(
      try nested.currentCapacityMAh.get() == 0 && nested.maximumCapacityMAh.get() == 5700,
      "Raw nested fallbacks")
    for invalid: Any in [true, -1, 0.5, "6000", Double.nan, Double.infinity] {
      try expectTelemetryFailure {
        try BatteryParser.parse(["DesignCapacity": invalid]).designCapacityMAh.get()
      }
    }
    for invalid in [
      NSNumber(value: true), NSNumber(value: 1.5), NSNumber(value: 100001),
      NSNumber(value: Double.nan),
    ] {
      try expectTelemetryFailure { try BatteryParser.signedAmperage(invalid) }
    }
    try expectTelemetryFailure { try BatteryParser.parse([:]).power.get() }
    let timed = BatteryParser.parse(properties, timeRemaining: .success(.seconds(7_200)))
    try require(
      TelemetryFormatting.batteryTimeRemaining(try timed.timeRemaining.get()) == "2h 0m",
      "Battery time remaining formatting")
    let packedDate = UInt16(((2025 - 1980) << 9) | (9 << 5) | 7)
    let manufactured = BatteryParser.parse([
      "BatteryData": ["ManufactureDate": NSNumber(value: packedDate)]
    ])
    let components = Calendar(identifier: .gregorian).dateComponents(
      in: TimeZone(secondsFromGMT: 0)!, from: try manufactured.manufactureDate.get())
    try require(
      components.year == 2025 && components.month == 9 && components.day == 7,
      "Packed SBS manufacture date decoding")
  }

  private static func gpuChecks() throws {
    let properties: [String: Any] = [
      "model": "Apple M4",
      "gpu-core-count": NSNumber(value: 10),
      "PerformanceStatistics": [
        "Device Utilization %": NSNumber(value: 37),
        "Renderer Utilization %": NSNumber(value: 31),
        "Tiler Utilization %": NSNumber(value: 12),
        "Alloc system memory": NSNumber(value: UInt64(2_000_000_000)),
        "In use system memory": NSNumber(value: UInt64(600_000_000)),
      ],
    ]
    let gpu = try GPURegistryParser.parse(properties)
    try require(try close(gpu.deviceUtilizationPercent.get(), 37), "GPU utilization")
    try require(
      try close(gpu.rendererUtilizationPercent.get(), 31)
        && close(gpu.tilerUtilizationPercent.get(), 12), "GPU renderer/tiler utilization")
    try require(try gpu.coreCount.get() == 10 && gpu.model.get() == "Apple M4", "GPU identity")
    try require(
      try gpu.allocatedSystemMemoryBytes.get() == 2_000_000_000
        && gpu.inUseSystemMemoryBytes.get() == 600_000_000, "GPU memory counters")

    let partial = try GPURegistryParser.parse(["PerformanceStatistics": ["Device Utilization %": 0]]
    )
    try require(try partial.deviceUtilizationPercent.get() == 0, "GPU zero utilization is valid")
    try expectTelemetryFailure { try partial.rendererUtilizationPercent.get() }
    try expectTelemetryFailure {
      try GPURegistryParser.parse(["PerformanceStatistics": ["Device Utilization %": 101]])
        .deviceUtilizationPercent.get()
    }
    let identityOnly = try GPURegistryParser.parse(["model": "Apple M4"])
    try require(
      try identityOnly.model.get() == "Apple M4",
      "GPU identity must survive missing PerformanceStatistics")
    try expectTelemetryFailure { try identityOnly.deviceUtilizationPercent.get() }
    try expectTelemetryFailure {
      _ = try GPURegistryParser.parse(["PerformanceStatistics": "broken"])
    }

    for invalid in [NSNumber(value: true), NSNumber(value: -1), NSNumber(value: 1.5),
      NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
      NSNumber(value: -Double.infinity), NSNumber(value: Double(UInt64.max)),
      NSNumber(value: Double.greatestFiniteMagnitude)] {
      let parsed = try GPURegistryParser.parse([
        "PerformanceStatistics": ["Alloc system memory": invalid]])
      try expectTelemetryFailure { try parsed.allocatedSystemMemoryBytes.get() }
    }
    for valid in [NSNumber(value: UInt64.max), NSNumber(value: UInt64.max - 1),
      NSNumber(value: UInt64(9_007_199_254_740_993)), NSNumber(value: UInt64(0))] {
      let parsed = try GPURegistryParser.parse([
        "PerformanceStatistics": ["Alloc system memory": valid]])
      try require(try parsed.allocatedSystemMemoryBytes.get() == valid.uint64Value,
        "GPU integer counter lost exact UInt64 precision")
    }
    let floating = try GPURegistryParser.parse([
      "PerformanceStatistics": ["Alloc system memory": NSNumber(value: 512.0)]])
    try require(try floating.allocatedSystemMemoryBytes.get() == 512,
      "Exactly representable floating GPU counter rejected")
    for invalid in [NSNumber(value: UInt64.max), NSNumber(value: Double(Int.max)),
      NSNumber(value: Double.greatestFiniteMagnitude), NSNumber(value: 1.5),
      NSNumber(value: true), NSNumber(value: 0), NSNumber(value: 513)] {
      try expectTelemetryFailure {
        try GPURegistryParser.parse(["gpu-core-count": invalid]).coreCount.get()
      }
    }
    for boundary in [1, 512] {
      try require(try GPURegistryParser.parse(["gpu-core-count": boundary]).coreCount.get() == boundary,
        "GPU core count boundary rejected")
    }
    let dataMax = try GPURegistryParser.parse([
      "PerformanceStatistics": ["Alloc system memory": Data(repeating: 255, count: 8)]])
    try require(try dataMax.allocatedSystemMemoryBytes.get() == UInt64.max,
      "GPU little-endian Data counter lost exact UInt64.max")
  }

  private static func processChecks() throws {
    var timebase = mach_timebase_info_data_t()
    try require(mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.numer > 0,
                "CPU fixture requires the native Mach timebase")
    func cpuTicks(_ nanoseconds: UInt64) -> UInt64 {
      nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer)
    }
    let previous = ProcessCounterSnapshot(
      pid: 42, startAbsoluteTime: 100,
      userTime: cpuTicks(1_000_000_000), systemTime: cpuTicks(500_000_000),
      energyNanojoules: 2_000_000_000, performanceEnergyNanojoules: 400_000_000,
      diskReadBytes: 10_000, diskWriteBytes: 20_000,
      packageIdleWakeups: 10, interruptWakeups: 20,
      instructions: 1_000, cycles: 500,
      physicalFootprintBytes: 200_000_000, neuralFootprintBytes: 4_000_000
    )
    let current = ProcessCounterSnapshot(
      pid: 42, startAbsoluteTime: 100,
      userTime: cpuTicks(2_500_000_000), systemTime: cpuTicks(1_000_000_000),
      energyNanojoules: 6_000_000_000, performanceEnergyNanojoules: 1_400_000_000,
      diskReadBytes: 50_000, diskWriteBytes: 80_000,
      packageIdleWakeups: 18, interruptWakeups: 32,
      instructions: 5_000, cycles: 2_500,
      physicalFootprintBytes: 220_000_000, neuralFootprintBytes: 5_000_000
    )
    guard
      let rate = ProcessRateCalculator.calculate(
        previous: previous, current: current, elapsedSeconds: 2, logicalCPUCount: 10)
    else {
      throw CheckFailure(description: "Valid process deltas were rejected")
    }
    try require(close(rate.cpuPercent, 100), "Process CPU must convert Mach ticks through the native timebase (100% of one core)")
    try require(
      close(rate.powerWatts, 2) && close(rate.performanceCorePowerWatts, 0.5),
      "Direct process energy conversion")
    try require(
      close(rate.diskReadBytesPerSecond, 20_000) && close(rate.diskWriteBytesPerSecond, 30_000),
      "Process disk rates")
    try require(
      rate.diskReadBytesDelta == 40_000 && rate.diskWriteBytesDelta == 60_000,
      "Process exact disk deltas for session attribution")
    try require(close(rate.wakeupsPerSecond, 10), "Process wakeup rate")
    try require(
      close(rate.instructionsPerSecond, 2_000) && close(rate.cyclesPerSecond, 1_000),
      "Process instruction/cycle rates")
    try require(rate.instructionsPerCycle.map { close($0, 2) } == true, "Process IPC")
    try require(current.neuralFootprintBytes == 5_000_000, "Neural footprint preservation")

    let extreme = ProcessCounterSnapshot(
      pid: current.pid, startAbsoluteTime: current.startAbsoluteTime,
      userTime: current.userTime, systemTime: current.systemTime,
      energyNanojoules: current.energyNanojoules, performanceEnergyNanojoules: current.performanceEnergyNanojoules,
      diskReadBytes: current.diskReadBytes, diskWriteBytes: current.diskWriteBytes,
      packageIdleWakeups: UInt64.max, interruptWakeups: UInt64.max,
      instructions: current.instructions, cycles: current.cycles,
      physicalFootprintBytes: current.physicalFootprintBytes, neuralFootprintBytes: current.neuralFootprintBytes)
    let extremeRate = ProcessRateCalculator.calculate(previous: previous, current: extreme,
      elapsedSeconds: 10, logicalCPUCount: 10)
    try require(extremeRate?.wakeupsPerSecond.isFinite == true,
      "Individually monotonic wakeup counters overflowed before floating-point addition")
    try require(ProcessRateCalculator.calculate(previous: previous, current: current,
      elapsedSeconds: 10, logicalCPUCount: 10) != nil, "Hidden process cadence invalidated rates")
    let reused = ProcessCounterSnapshot(
      pid: 42, startAbsoluteTime: 101,
      userTime: current.userTime, systemTime: current.systemTime,
      energyNanojoules: current.energyNanojoules,
      performanceEnergyNanojoules: current.performanceEnergyNanojoules,
      diskReadBytes: current.diskReadBytes, diskWriteBytes: current.diskWriteBytes,
      packageIdleWakeups: current.packageIdleWakeups, interruptWakeups: current.interruptWakeups,
      instructions: current.instructions, cycles: current.cycles,
      physicalFootprintBytes: current.physicalFootprintBytes,
      neuralFootprintBytes: current.neuralFootprintBytes
    )
    try require(
      ProcessRateCalculator.calculate(
        previous: previous, current: reused, elapsedSeconds: 2, logicalCPUCount: 10) == nil,
      "PID reuse must invalidate deltas")

    let rolledBack = ProcessCounterSnapshot(
      pid: 42, startAbsoluteTime: 100,
      userTime: 1, systemTime: 1,
      energyNanojoules: 1, performanceEnergyNanojoules: 1,
      diskReadBytes: 1, diskWriteBytes: 1,
      packageIdleWakeups: 1, interruptWakeups: 1,
      instructions: 1, cycles: 1,
      physicalFootprintBytes: current.physicalFootprintBytes,
      neuralFootprintBytes: current.neuralFootprintBytes
    )
    try require(
      ProcessRateCalculator.calculate(
        previous: current, current: rolledBack, elapsedSeconds: 2, logicalCPUCount: 10) == nil,
      "Counter rollback must invalidate process deltas")
    try require(
      ProcessRateCalculator.calculate(
        previous: previous, current: current, elapsedSeconds: 0, logicalCPUCount: 10) == nil,
      "Invalid process sampling interval")
  }

  private static func appEnergyChecks() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    let safari = AppEnergyEntry(
      appKey: "app:/Applications/Safari.app", displayName: "Safari", energyWattHours: 0.2,
      cpuCoreSeconds: 3, wakeups: 10, peakMemoryBytes: 500_000_000)
    let terminal = AppEnergyEntry(
      appKey: "app:/System/Applications/Utilities/Terminal.app", displayName: "Terminal",
      energyWattHours: 0.05, cpuCoreSeconds: 1, wakeups: 2, peakMemoryBytes: 100_000_000)
    let buckets = [
      AppEnergyBucket(
        capturedAt: start, durationSeconds: 60, onBattery: true, batteryPercent: 80,
        entries: [safari, terminal]),
      AppEnergyBucket(
        capturedAt: start.addingTimeInterval(60), durationSeconds: 60, onBattery: false,
        batteryPercent: 80, entries: [safari]),
    ]
    let summary = AppEnergyHistoryEngine.summary(buckets)
    try require(
      close(summary.coverageSeconds, 120) && close(summary.onBatteryCoverageSeconds, 60),
      "App-energy coverage")
    try require(
      summary.topAll.first?.displayName == "Safari"
        && close(summary.topAll.first?.energyWattHours ?? -1, 0.4), "App-energy aggregation")
    try require(
      summary.topOnBattery.first?.displayName == "Safari"
        && close(summary.topOnBattery.first?.energyWattHours ?? -1, 0.2),
      "On-battery app-energy aggregation")
    let comparisonStart = Date(timeIntervalSince1970: 20_000)
    let priorSafari = AppEnergyEntry(
      appKey: safari.appKey, displayName: safari.displayName, energyWattHours: 0.10,
      cpuCoreSeconds: 1, wakeups: 2, peakMemoryBytes: 400_000_000)
    let recentSafari = AppEnergyEntry(
      appKey: safari.appKey, displayName: safari.displayName, energyWattHours: 0.30,
      cpuCoreSeconds: 2, wakeups: 4, peakMemoryBytes: 450_000_000)
    let comparison = AppEnergyHistoryEngine.summary([
      AppEnergyBucket(
        capturedAt: comparisonStart, durationSeconds: 60, onBattery: true, batteryPercent: 80,
        entries: [priorSafari]),
      // Keep this bucket in the previous-hour window. The comparison is anchored to
      // t=7_100, so the recent-hour boundary is t=3_500. A former t=3_550
      // fixture accidentally landed inside the recent window and made the test
      // expect a -1.5% delta while the implementation correctly measured -2.0%.
      AppEnergyBucket(
        capturedAt: comparisonStart.addingTimeInterval(3_450), durationSeconds: 60, onBattery: true,
        batteryPercent: 79, entries: [priorSafari]),
      AppEnergyBucket(
        capturedAt: comparisonStart.addingTimeInterval(3_650), durationSeconds: 60, onBattery: true,
        batteryPercent: 78.5, entries: [recentSafari]),
      AppEnergyBucket(
        capturedAt: comparisonStart.addingTimeInterval(7_100), durationSeconds: 60, onBattery: true,
        batteryPercent: 77, entries: [recentSafari]),
    ])
    guard let trend = comparison.recentHourTrends.first(where: { $0.displayName == "Safari" })
    else {
      throw CheckFailure(description: "App-energy recent-hour trend missing")
    }
    try require(
      trend.recentEnergyWattHours > trend.previousEnergyWattHours
        && trend.changePercent.map { $0 > 0 } == true, "App-energy recent vs previous comparison")
    try require(
      comparison.recentHourOnBatteryChargeDeltaPercent.map { close($0, -1.5) } == true,
      "Recent on-battery charge delta")

    // Window semantics are intentionally half-open: (anchor - 1h, anchor].
    // A sample exactly on the boundary belongs to the preceding hour and must
    // not change the recent-hour battery delta.
    let boundaryComparison = AppEnergyHistoryEngine.summary([
      AppEnergyBucket(
        capturedAt: comparisonStart.addingTimeInterval(3_500), durationSeconds: 60, onBattery: true,
        batteryPercent: 80, entries: []),
      AppEnergyBucket(
        capturedAt: comparisonStart.addingTimeInterval(3_501), durationSeconds: 60, onBattery: true,
        batteryPercent: 79, entries: []),
      AppEnergyBucket(
        capturedAt: comparisonStart.addingTimeInterval(7_100), durationSeconds: 60, onBattery: true,
        batteryPercent: 78, entries: []),
    ])
    try require(
      boundaryComparison.recentHourOnBatteryChargeDeltaPercent.map { close($0, -1) } == true,
      "Recent on-battery charge delta boundary")

    let stale = AppEnergyBucket(
      capturedAt: start.addingTimeInterval(-AppEnergyHistoryEngine.rawRetention - 1),
      durationSeconds: 60, onBattery: true, batteryPercent: 90, entries: [safari])
    let clean = AppEnergyHistoryEngine.sanitized(
      [stale] + buckets, now: start.addingTimeInterval(60))
    try require(clean.count == 2, "App-energy retention")
    let csv = AppEnergyHistoryEngine.csv(buckets)
    try require(
      csv.contains("app_key,display_name,energy_wh") && csv.contains("Safari"),
      "App-energy CSV export")
  }

  private static func maintenanceChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "helios-maintenance-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    func thinMagic(cpu: UInt32) -> Data {
      var bytes = Data([0xcf, 0xfa, 0xed, 0xfe])  // MH_MAGIC_64 as little-endian bytes
      bytes.append(UInt8(truncatingIfNeeded: cpu))
      bytes.append(UInt8(truncatingIfNeeded: cpu >> 8))
      bytes.append(UInt8(truncatingIfNeeded: cpu >> 16))
      bytes.append(UInt8(truncatingIfNeeded: cpu >> 24))
      bytes.append(Data(repeating: 0, count: 32))
      return bytes
    }
    let arm = root.appendingPathComponent("arm64")
    let intel = root.appendingPathComponent("x86_64")
    try thinMagic(cpu: 0x0100_000c).write(to: arm)
    try thinMagic(cpu: 0x0100_0007).write(to: intel)
    try require(
      ApplicationsProvider.binaryArchitecture(arm) == .appleSilicon,
      "Thin arm64 Mach-O classification")
    try require(
      ApplicationsProvider.binaryArchitecture(intel) == .intel, "Thin x86_64 Mach-O classification")

    var fat = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2])
    func fatEntry(cpu: UInt32) -> Data {
      var data = Data()
      data.append(UInt8(truncatingIfNeeded: cpu >> 24))
      data.append(UInt8(truncatingIfNeeded: cpu >> 16))
      data.append(UInt8(truncatingIfNeeded: cpu >> 8))
      data.append(UInt8(truncatingIfNeeded: cpu))
      data.append(Data(repeating: 0, count: 16))
      return data
    }
    fat.append(fatEntry(cpu: 0x0100_000c))
    fat.append(fatEntry(cpu: 0x0100_0007))
    let universal = root.appendingPathComponent("universal")
    try fat.write(to: universal)
    try require(
      ApplicationsProvider.binaryArchitecture(universal) == .universal, "Fat Mach-O classification")

    let cache = root.appendingPathComponent("Library/Caches/Test", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(repeating: 0x5a, count: 8_192).write(to: cache.appendingPathComponent("cache.bin"))
    let homebrew = root.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
    try FileManager.default.createDirectory(at: homebrew, withIntermediateDirectories: true)
    let brewFile = homebrew.appendingPathComponent("brew.bin")
    try Data(repeating: 0x39, count: 16_384).write(to: brewFile)
    let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
    func allocated(_ url: URL) throws -> UInt64 {
      let values = try url.resourceValues(forKeys: keys)
      let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
      try require(bytes > 0, "Maintenance size fixture did not allocate file storage")
      return UInt64(bytes)
    }
    let cacheBytes = try allocated(cache.appendingPathComponent("cache.bin"))
    let brewBytes = try allocated(brewFile)
    let cleanup = CleanupProvider.read(home: root, entryBudget: 100)
    try require(
      cleanup.candidates.first { $0.id == "Library/Caches" }?.estimatedBytes == cacheBytes,
      "User caches double-counted the separate Homebrew category")
    try require(
      cleanup.candidates.first { $0.id == "Library/Caches/Homebrew" }?.estimatedBytes == brewBytes
      && cleanup.estimatedBytes == cacheBytes + brewBytes,
      "Cleanup total did not preserve both distinct cache categories")
    try require(
      cleanup.candidates.contains { $0.id == "Library/Caches" && $0.scannedEntries > 0 },
      "Cleanup Scout must discover the configured user cache root")
    let lowerBrew = root.appendingPathComponent("Library/Caches/homebrew", isDirectory: true)
    let stagingBrew = root.appendingPathComponent("brew-case-stage", isDirectory: true)
    try FileManager.default.moveItem(at: homebrew, to: stagingBrew)
    try FileManager.default.moveItem(at: stagingBrew, to: lowerBrew)
    let differentCase = CleanupProvider.read(home: root, entryBudget: 100)
    if FileManager.default.fileExists(atPath: homebrew.path) {
      // This volume resolves the configured spelling to the differently cased
      // directory. File identity must prevent counting that same cache twice.
      try require(differentCase.candidates.first { $0.id == "Library/Caches" }?.estimatedBytes == cacheBytes
        && differentCase.estimatedBytes == cacheBytes + brewBytes,
        "Case-insensitive Homebrew path alias was counted twice")
    } else {
      // On a case-sensitive volume it is a distinct, ordinary user-cache folder.
      try require(differentCase.candidates.first { $0.id == "Library/Caches" }?.estimatedBytes == cacheBytes + brewBytes
        && differentCase.candidates.allSatisfy { $0.id != "Library/Caches/Homebrew" },
        "A distinct case-sensitive cache folder was incorrectly excluded")
    }
    let bounded = CleanupProvider.read(home: root, entryBudget: 1)
    try require(
      bounded.candidates.first?.truncated == true || bounded.candidates.first?.scannedEntries == 1,
      "Cleanup scan must honor its entry budget")
  }

  @MainActor private static func maintenanceCancellationChecks() async throws {
    let fixtureHome = URL(fileURLWithPath: "/fixture/maintenance-never-read", isDirectory: true)
    let canceled = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      // The explicit fake home plus the first cancellation check prevent all
      // filesystem enumeration, including ApplicationsProvider's /Applications root.
      let cleanup = CleanupProvider.read(home: fixtureHome)
      let applications = ApplicationsProvider.read(home: fixtureHome)
      return (cleanup, applications)
    }
    canceled.cancel()
    let result = await canceled.value
    try require(result.0.candidates.isEmpty && result.1.applications.isEmpty,
      "Pre-start cancellation admitted a filesystem scan")
  }

  private static func utilityProviderChecks() throws {
    // IOBluetooth rawRSSI() uses +127 as the public unavailable sentinel.
    // Unlike rssi(), a raw value of 0 is a legitimate raw dBm value and is preserved.
    try require(
      BluetoothProvider.normalizedRawRSSI(127) == nil, "Bluetooth raw RSSI unavailable sentinel")
    try require(
      BluetoothProvider.normalizedRawRSSI(-47) == -47, "Bluetooth raw RSSI dBm preservation")
    try require(BluetoothProvider.normalizedRawRSSI(0) == 0, "Bluetooth raw RSSI zero preservation")

    // IOPMCopyAssertionsByProcess documents CFNumber PID keys, not Strings.
    // Exercise the real dictionary shape and public AssertType / AssertLevel keys.
    let fixture: NSDictionary = [
      NSNumber(value: 42): [
        [
          "AssertLevel": NSNumber(value: 255),
          "AssertType": "PreventUserIdleDisplaySleep",
          "HumanReadableReason": "Video playback",
        ],
        [
          "AssertLevel": NSNumber(value: 255),
          "AssertType": "PreventUserIdleSystemSleep",
          "AssertName": "Long operation",
        ],
        [
          "AssertLevel": NSNumber(value: 0),
          "AssertType": "PreventUserIdleDisplaySleep",
          "AssertName": "Inactive assertion",
        ],
      ],
      // Malformed top-level entries must be ignored rather than poisoning the sample.
      "not-a-pid": [["AssertLevel": NSNumber(value: 255), "AssertType": "PreventSystemSleep"]],
    ]
    let parsed = PowerAssertionsProvider.parseDictionary(fixture) { pid in
      pid == 42 ? "FixtureApp" : nil
    }
    try require(parsed.assertions.count == 2, "Power assertion active record filtering")
    try require(parsed.displaySleepBlockers.count == 1, "Display sleep blocker classification")
    try require(parsed.systemSleepBlockers.count == 1, "System sleep blocker classification")
    try require(
      parsed.assertions.allSatisfy { $0.pid == 42 && $0.processName == "FixtureApp" },
      "CFNumber PID parsing")
    try require(
      parsed.displaySleepBlockers.first?.reason == "Video playback",
      "Power assertion human-readable reason")
    try require(
      parsed.systemSleepBlockers.first?.reason == "Long operation",
      "Power assertion AssertName fallback")
  }

  @MainActor private static func numericCancellationChecks() async throws {
    let fixtures = [
      SensorFixture(key: "Praw", type: "flt ", bytes: word(Float(12.5).bitPattern)),
      SensorFixture(key: "Vraw", type: "ui16", bytes: [0x04, 0xD2]),
    ]
    let beforeStart = Task { @MainActor in
      let transport = FixtureTransport(fixtures)
      let reader = SMCNumericReader(client: SMCClient(transport: transport))
      do {
        _ = try reader.read()
        throw CheckFailure(description: "Canceled numeric reader started discovery")
      } catch is CancellationError {}
      try require(transport.requests.isEmpty, "Canceled numeric reader reached its injected transport")
    }
    beforeStart.cancel()
    try await beforeStart.value

    let duringRead = Task { @MainActor in
      let transport = FixtureTransport(fixtures)
      transport.onExchange = { request in
        if request.command == .bytes && request.key == "Praw" {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
      let reader = SMCNumericReader(client: SMCClient(transport: transport))
      do {
        _ = try reader.read()
        throw CheckFailure(description: "Numeric reader ignored cancellation between keys")
      } catch is CancellationError {}
      try require(transport.requests.contains { $0.command == .bytes && $0.key == "Praw" }
        && !transport.requests.contains { $0.command == .bytes && $0.key == "Vraw" },
        "Numeric reader continued channel reads after cooperative cancellation")
    }
    try await duringRead.value
  }

  private static func networkChecks() throws {
    let first = NetworkLinkCounters(
      receivedBytes: 1_000, transmittedBytes: 2_000, receivedPackets: 10, transmittedPackets: 20,
      receiveErrors: 0, transmitErrors: 0)
    var calculator = NetworkRateCalculator()
    try expectTelemetryFailure {
      try calculator.consume(name: "en0", counters: first, elapsedSeconds: 1).get()
    }
    let second = NetworkLinkCounters(
      receivedBytes: 5_000, transmittedBytes: 8_000, receivedPackets: 14, transmittedPackets: 26,
      receiveErrors: 0, transmitErrors: 0)
    let rate = try calculator.consume(name: "en0", counters: second, elapsedSeconds: 2).get()
    try require(
      close(rate.downloadBytesPerSecond, 2_000) && close(rate.uploadBytesPerSecond, 3_000),
      "Network byte deltas")
    try require(
      close(rate.receivePacketsPerSecond, 2) && close(rate.transmitPacketsPerSecond, 3),
      "Network packet deltas")
    try expectTelemetryFailure {
      try calculator.consume(name: "en1", counters: second, elapsedSeconds: 1).get()
    }

    calculator.reset()
    let nearWrap = NetworkLinkCounters(
      receivedBytes: UInt32.max - 9, transmittedBytes: UInt32.max - 19,
      receivedPackets: UInt32.max - 4, transmittedPackets: UInt32.max - 7, receiveErrors: 0,
      transmitErrors: 0)
    try expectTelemetryFailure {
      try calculator.consume(name: "en0", counters: nearWrap, elapsedSeconds: 1).get()
    }
    let wrapped = NetworkLinkCounters(
      receivedBytes: 10, transmittedBytes: 20, receivedPackets: 5, transmittedPackets: 8,
      receiveErrors: 0, transmitErrors: 0)
    let wrappedRate = try calculator.consume(name: "en0", counters: wrapped, elapsedSeconds: 1)
      .get()
    try require(
      close(wrappedRate.downloadBytesPerSecond, 20) && close(wrappedRate.uploadBytesPerSecond, 40),
      "32-bit network byte rollover")
    try require(
      close(wrappedRate.receivePacketsPerSecond, 10)
        && close(wrappedRate.transmitPacketsPerSecond, 16), "32-bit network packet rollover")
    try expectTelemetryFailure {
      try calculator.consume(name: "en0", counters: wrapped, elapsedSeconds: 0).get()
    }

    var session = NetworkSessionAccounting()
    _ = session.consume(name: "en0", counters: first)
    let totals = session.consume(name: "en0", counters: second)
    try require(totals.0 == 4_000 && totals.1 == 6_000, "Session byte deltas")
    session.resetBaseline() // Production missing-link and sleep/wake paths.
    let resumed = session.consume(name: "en0", counters: wrapped)
    try require(resumed.0 == totals.0 && resumed.1 == totals.1,
      "Same-name recovery fabricated rollover traffic after missing link")
    let afterRecovery = session.consume(name: "en0", counters: first)
    try require(afterRecovery.0 == 4_990 && afterRecovery.1 == 7_980,
      "Session did not resume real deltas from the recovered baseline")
    let handoff = session.consume(name: "en1", counters: second)
    try require(handoff.0 == afterRecovery.0 && handoff.1 == afterRecovery.1,
      "Interface handoff added an unrelated interface counter")
    session.resetBaseline()
    _ = session.consume(name: "en1", counters: nearWrap)
    let rolled = session.consume(name: "en1", counters: wrapped)
    try require(rolled.0 == handoff.0 + 20 && rolled.1 == handoff.1 + 40,
      "Continuous same-interface session rollover changed")
    session.resetBaseline()
    session.resetBaseline()
    try require(session.downloadedBytes == rolled.0 && session.uploadedBytes == rolled.1,
      "Repeated missing-link resets erased session totals")
  }

  private static func wifiChecks() throws {
    try require(
      WiFiFormatting.band(rawValue: 1) == "2.4 GHz" && WiFiFormatting.band(rawValue: 3) == "6 GHz",
      "Wi-Fi band formatting")
    try require(WiFiFormatting.width(rawValue: 4) == "160 MHz", "Wi-Fi channel width formatting")
    try require(
      WiFiFormatting.phy(rawValue: 6).contains("Wi-Fi 6")
        && WiFiFormatting.phy(rawValue: 7).contains("Wi-Fi 7"), "Wi-Fi PHY formatting")
    try require(
      WiFiFormatting.security(rawValue: 3) == "WPA/WPA2 Personal",
      "Wi-Fi mixed-personal security mapping")
    try require(
      WiFiFormatting.security(rawValue: 8) == "WPA/WPA2 Enterprise",
      "Wi-Fi mixed-enterprise security mapping")
    try require(
      WiFiFormatting.security(rawValue: 11) == "WPA3 Personal"
        && WiFiFormatting.security(rawValue: 14) == "OWE", "Modern Wi-Fi security mapping")
    try require(
      WiFiFormatting.band(rawValue: Int.max) == "Unknown"
        && WiFiFormatting.width(rawValue: Int.max) == "Unknown"
        && WiFiFormatting.security(rawValue: Int.max) == "Unknown",
      "CoreWLAN unknown enum formatting")

    let metrics = WiFiMetrics(
      interfaceName: "en0", powerOn: true, serviceActive: true,
      ssid: .failure(.unavailable("SSID hidden by macOS privacy")),
      rssiDBm: .success(-50), noiseDBm: .success(-90),
      transmitRateMbps: .success(866), transmitPowerMilliwatts: .success(31),
      channelNumber: .success(36), channelBand: .success("5 GHz"), channelWidth: .success("80 MHz"),
      phyMode: .success("802.11ax / Wi-Fi 6/6E"), security: .success("WPA3 Personal")
    )
    try require(try metrics.signalToNoiseDB.get() == 40, "Wi-Fi SNR")
    try expectTelemetryFailure { try metrics.ssid.get() }

    let invalidSNR = WiFiMetrics(
      interfaceName: "en0", powerOn: true, serviceActive: true,
      ssid: .success("Test"), rssiDBm: .success(-100), noiseDBm: .success(-20),
      transmitRateMbps: .success(1), transmitPowerMilliwatts: .success(1),
      channelNumber: .success(1), channelBand: .success("2.4 GHz"),
      channelWidth: .success("20 MHz"),
      phyMode: .success("802.11n / Wi-Fi 4"), security: .success("WPA2 Personal")
    )
    try expectTelemetryFailure { try invalidSNR.signalToNoiseDB.get() }
    func suppliedSNR(_ rssi: Int, _ noise: Int) -> MetricResult<Int> {
      WiFiMetrics(interfaceName: "fixture", powerOn: true, serviceActive: true,
        ssid: .failure(.unavailable("Fixture")), rssiDBm: .success(rssi), noiseDBm: .success(noise),
        transmitRateMbps: .success(1), transmitPowerMilliwatts: .success(1),
        channelNumber: .success(1), channelBand: .success("Fixture"), channelWidth: .success("Fixture"),
        phyMode: .success("Fixture"), security: .success("Fixture")).signalToNoiseDB
    }
    for (rssi, noise) in [(Int.max, -1), (Int.min, 1), (Int.max, Int.min), (Int.min, Int.max)] {
      try expectTelemetryFailure { try suppliedSNR(rssi, noise).get() }
    }
    for boundary in [-20, 100] {
      try require(try suppliedSNR(boundary, 0).get() == boundary,
        "Existing inclusive SNR plausibility boundary changed")
    }
    try require(try suppliedSNR(Int.max, Int.max).get() == 0,
      "Safe difference of extreme supplied values was rejected")
  }

  private static func historyChecks() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var history = TelemetryHistory()
    history.append(historySnapshot(now: start, power: 10, cpu: 20), now: start)
    let secondTime = start.addingTimeInterval(1)
    history.append(historySnapshot(now: secondTime, power: 14, cpu: 30), now: secondTime)
    try require(history.points.count == 2, "History one-second append")
    try require(
      history.points.last?.memoryPercent.map { close($0, 50) } == true,
      "History memory trend capture")
    try require(
      history.points.last?.batteryPercent.map { close($0, 80) } == true,
      "History battery trend capture")
    try require(
      history.points.last?.batteryPowerWatts.map { close($0, -5) } == true,
      "History battery-flow trend capture")
    try require(
      history.points.last?.storageReadBytesPerSecond.map { close($0, 100) } == true
        && history.points.last?.storageWriteBytesPerSecond.map { close($0, 200) } == true,
      "History storage-throughput trend capture")
    try require(
      close(history.sessionEnergyWattHours, 12.0 / 3_600.0), "Trapezoidal PSTR energy integration")
    try require(close(history.measuredPowerCoverageSeconds, 1), "Power coverage accounting")
    history.append(
      historySnapshot(now: secondTime.addingTimeInterval(0.2), power: 99, cpu: 99),
      now: secondTime.addingTimeInterval(0.2))
    try require(history.points.count == 2, "Sub-second redraw must not duplicate history")
    let afterGap = secondTime.addingTimeInterval(10)
    history.append(historySnapshot(now: afterGap, power: 20, cpu: 40), now: afterGap)
    try require(
      close(history.sessionEnergyWattHours, 12.0 / 3_600.0), "Long gaps must not invent energy")
    try require(history.durationSeconds == 11, "History duration")

    var bounded = TelemetryHistory()
    for index in 0..<(TelemetryHistory.maximumPoints + 12) {
      let now = start.addingTimeInterval(Double(index))
      bounded.append(historySnapshot(now: now, power: 5, cpu: 10), now: now)
    }
    try require(bounded.points.count == TelemetryHistory.maximumPoints, "History rolling bound")
    try require(
      bounded.points.first?.capturedAt == start.addingTimeInterval(12),
      "History must evict oldest samples")
  }

  private static func historySnapshot(now: Date, power: Double, cpu: Double) -> TelemetrySnapshot {
    var snapshot = TelemetrySnapshot()
    snapshot.cpu = MetricSample(
      .success(
        CPUMetrics(userPercent: cpu, systemPercent: 0, nicePercent: 0, idlePercent: 100 - cpu)),
      capturedAt: now)
    snapshot.gpu = MetricSample(
      .success(
        GPUMetrics(
          model: .success("Apple M4"), coreCount: .success(10),
          deviceUtilizationPercent: .success(25), rendererUtilizationPercent: .success(20),
          tilerUtilizationPercent: .success(5), allocatedSystemMemoryBytes: .success(1),
          inUseSystemMemoryBytes: .success(1))), capturedAt: now)
    snapshot.systemPower = MetricSample(
      .success(SystemPowerMetrics(totalSystemWatts: .success(power))), capturedAt: now)
    snapshot.thermals = MetricSample(
      .success(
        ThermalMetrics(
          readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 50)],
          failures: [:])), capturedAt: now)
    snapshot.fans = MetricSample(
      .success(
        FanInventory(fans: [
          FanReading(
            id: 0, actualRPM: .success(2_500), targetRPM: .success(2_500),
            minimumRPM: .success(2_000), maximumRPM: .success(6_000), automatic: .success(true))
        ])), capturedAt: now)
    snapshot.network = MetricSample(
      .success(
        NetworkMetrics(
          primaryInterface: .success("en0"), ipv4Address: .success("192.168.1.2"),
          ipv6Address: .failure(.unavailable("IPv6 unavailable")), isRunning: .success(true),
          mtu: .success(1_500), linkSpeedBitsPerSecond: .success(1_000_000_000),
          throughput: .success(
            NetworkThroughput(
              downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500, receivePacketsPerSecond: 10,
              transmitPacketsPerSecond: 5)), receiveErrors: .success(0),
          transmitErrors: .success(0), activeInterfaceCount: 1)), capturedAt: now)
    snapshot.memory = MetricSample(
      .success(
        MemoryMetrics(
          physicalBytes: 16 << 30, activeBytes: 6 << 30, inactiveBytes: 0, wiredBytes: 1 << 30,
          compressedBytes: 1 << 30, freeBytes: 8 << 30, pressure: .success(.normal))),
      capturedAt: now)
    snapshot.battery = MetricSample(
      .success(
        BatteryMetrics(
          designCapacityMAh: .success(6_000), maximumCapacityMAh: .success(6_000),
          currentCapacityMAh: .success(4_800), systemChargePercent: .success(80),
          cycleCount: .success(4), temperatureCelsius: .success(30),
          power: .success(BatteryPower(signedWatts: -5, usesInstantaneousCurrent: true)))),
      capturedAt: now)
    let historyStorageDevice = StorageDeviceMetrics(
      registryID: 1, bsdName: "disk0", model: "APPLE SSD", capacityBytes: 1_000_000,
      isInternal: true, isRemovable: false, transport: "Apple Fabric",
      controllerClass: "IOEmbeddedNVMeBlockDevice", smartCapability: .nvmeAdvertised,
      counters: .failure(.warmingUp))
    snapshot.storage = MetricSample(
      .success(
        StorageMetrics(
          rootVolume: .success(RootVolumeMetrics(totalBytes: 1_000_000, freeBytes: 500_000)),
          devices: [historyStorageDevice], primaryDeviceBSDName: "disk0",
          throughput: .success(
            StorageThroughput(
              readBytesPerSecond: 100, writeBytesPerSecond: 200, readIOPS: 1, writeIOPS: 1)),
          smartHealth: .failure(.warmingUp), smartHealthCapturedTicks: nil)), capturedAt: now)
    return snapshot
  }

  private static func persistentHistoryChecks() async throws {
    let start = Date(timeIntervalSince1970: 10_000)
    func point(
      _ offset: TimeInterval, power: Double?, batteryPercent: Double = 80,
      batteryPower: Double? = nil, memoryPercent: Double = 50
    ) -> PersistedTelemetryPoint {
      PersistedTelemetryPoint(
        capturedAt: start.addingTimeInterval(offset),
        cpuPercent: 20, memoryPercent: memoryPercent, gpuPercent: 10, maxSoCCelsius: 50,
        systemPowerWatts: power, batteryPercent: batteryPercent, batteryHealthPercent: 98,
        batteryPowerWatts: batteryPower, batteryOnAC: batteryPower.map { $0 >= 0 },
        batteryTemperatureCelsius: 30 + offset / 60, batteryCycleCount: 4,
        storageTemperatureCelsius: 30, storageDeviceBSDName: "disk0",
        storageLifetimeReadBytes: 1_000_000_000 + offset * 1_000_000,
        storageLifetimeWrittenBytes: 2_000_000_000 + offset * 2_000_000,
        storageReadBytesPerSecond: 2_000, storageWriteBytesPerSecond: 1_000,
        processAccountedReadBytesPerSecond: 500, processAccountedWriteBytesPerSecond: 250,
        heliosCPUPercent: 0.2 + offset / 1_000, heliosPowerWatts: 0.15 + offset / 2_000,
        heliosMemoryBytes: 80_000_000, heliosWakeupsPerSecond: 2,
        fanRPM: 0, networkDownloadBytesPerSecond: 1_000, networkUploadBytesPerSecond: 500
      )
    }

    let ordered = [
      point(0, power: 10, batteryPercent: 80, batteryPower: -10),
      point(30, power: 14, batteryPercent: 79.8, batteryPower: -14),
      point(60, power: 18, batteryPercent: 79.5, batteryPower: -18),
    ]
    let summary = PersistentHistoryEngine.summary(ordered)
    try require(
      close(summary.energyWattHours, ((10 + 14) / 2 * 30 + (14 + 18) / 2 * 30) / 3_600),
      "Persistent history PSTR integration")
    try require(close(summary.measuredPowerCoverageSeconds, 60), "Persistent power coverage")
    try require(
      summary.batteryChargeDeltaPercent.map { close($0, -0.5) } == true,
      "Persistent battery charge delta")
    try require(
      summary.batteryMinimumPercent == 79.5 && summary.batteryMaximumPercent == 80,
      "Persistent battery min/max")
    try require(
      close(summary.batteryEnergyWattHours, -(((10 + 14) / 2 * 30 + (14 + 18) / 2 * 30) / 3_600)),
      "Signed persistent battery energy")
    try require(
      close(summary.measuredBatteryPowerCoverageSeconds, 60), "Persistent battery power coverage")
    try require(
      summary.batteryMinimumTemperatureCelsius == 30
        && summary.batteryMaximumTemperatureCelsius == 31, "Persistent battery temperature range")
    try require(
      summary.batteryMinimumHealthPercent == 98 && summary.batteryMaximumHealthPercent == 98
        && summary.latestBatteryCycleCount == 4, "Persistent battery health/cycle trend")
    try require(
      summary.storageLifetimeReadDeltaBytes.map { close($0, 60_000_000) } == true
        && summary.storageLifetimeWrittenDeltaBytes.map { close($0, 120_000_000) } == true,
      "Persistent NVMe lifetime I/O deltas")
    try require(
      summary.heliosAverageCPUPercent != nil && summary.heliosPeakPowerWatts != nil
        && summary.heliosPeakMemoryBytes == 80_000_000
        && summary.heliosAverageWakeupsPerSecond == 2, "Persistent Helios overhead summary")
    let csv = PersistentHistoryEngine.csv(ordered)
    try require(
      csv.contains("memory_percent") && csv.contains("battery_power_w")
        && csv.contains("process_write_Bps")
        && csv.contains("helios_memory_bytes") && csv.contains("lifetime_write_bytes")
        && csv.split(separator: "\n").count == 4, "Persistent history CSV export")

    let gap = PersistentHistoryEngine.summary([
      point(0, power: 10, batteryPower: -10), point(120, power: 20, batteryPower: -20),
    ])
    try require(
      close(gap.energyWattHours, 0) && close(gap.measuredPowerCoverageSeconds, 0),
      "Persistent history must not bridge long gaps")
    try require(
      close(gap.batteryEnergyWattHours, 0) && close(gap.measuredBatteryPowerCoverageSeconds, 0),
      "Persistent battery history must not bridge long gaps")

    let now = start.addingTimeInterval(PersistentHistoryEngine.retention + 600)
    let stale = PersistedTelemetryPoint(
      capturedAt: start, cpuPercent: nil, gpuPercent: nil, maxSoCCelsius: nil,
      systemPowerWatts: nil,
      batteryPercent: nil, storageTemperatureCelsius: nil, fanRPM: nil,
      networkDownloadBytesPerSecond: nil, networkUploadBytesPerSecond: nil
    )
    let freshA = PersistedTelemetryPoint(
      capturedAt: now.addingTimeInterval(-60), cpuPercent: 1, gpuPercent: nil, maxSoCCelsius: nil,
      systemPowerWatts: nil,
      batteryPercent: nil, storageTemperatureCelsius: nil, fanRPM: nil,
      networkDownloadBytesPerSecond: nil, networkUploadBytesPerSecond: nil
    )
    let duplicateOrRollback = PersistedTelemetryPoint(
      capturedAt: now.addingTimeInterval(-120), cpuPercent: 2, gpuPercent: nil, maxSoCCelsius: nil,
      systemPowerWatts: nil,
      batteryPercent: nil, storageTemperatureCelsius: nil, fanRPM: nil,
      networkDownloadBytesPerSecond: nil, networkUploadBytesPerSecond: nil
    )
    let clean = PersistentHistoryEngine.sanitized([stale, freshA, duplicateOrRollback], now: now)
    try require(
      clean.count == 1 && clean.first?.cpuPercent == 1,
      "Persistent history retention and strict chronology")

    // UI8 adds memoryPercent to the v1 record without changing the file name.
    // Synthesized Codable must therefore continue accepting pre-UI8 lines that
    // simply do not contain the new optional key.
    let legacyLine = """
      {"capturedAt":10000,"cpuPercent":20,"gpuPercent":10,"maxSoCCelsius":50,"systemPowerWatts":10,"batteryPercent":80,"storageTemperatureCelsius":30,"fanRPM":0,"networkDownloadBytesPerSecond":1000,"networkUploadBytesPerSecond":500}
      """
    let legacyDecoder = JSONDecoder()
    legacyDecoder.dateDecodingStrategy = .millisecondsSince1970
    let legacyDecoded = PersistentHistoryEngine.decodeLines(
      Data((legacyLine + "\n").utf8), decoder: legacyDecoder)
    try require(
      legacyDecoded.count == 1 && legacyDecoded[0].memoryPercent == nil
        && legacyDecoded[0].cpuPercent == 20,
      "UI8 persistent history must remain backward-compatible with pre-memory v1 records")

    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("Helios-PersistentHistory-\(UUID().uuidString).ndjson")
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = PersistentHistoryStore(url: temp)
    _ = await store.append(snapshot: historySnapshot(now: start, power: 10, cpu: 20), now: start)
    _ = await store.append(
      snapshot: historySnapshot(now: start.addingTimeInterval(30), power: 14, cpu: 30),
      now: start.addingTimeInterval(30))
    // A cached descriptor must follow atomic path replacement, not append to
    // an unlinked inode while reporting successful in-memory history.
    let saved = try Data(contentsOf: temp)
    try saved.write(to: temp, options: .atomic)
    _ = await store.append(
      snapshot: historySnapshot(now: start.addingTimeInterval(60), power: 18, cpu: 40),
      now: start.addingTimeInterval(60))
    let replaced = await PersistentHistoryStore(url: temp).current(now: start.addingTimeInterval(60))
    try require(replaced.points.count == 3, "Cached history handle lost append after atomic replacement")
    // Restore this fixture's original two-record state for existing assertions.
    try saved.write(to: temp, options: .atomic)
    let fromDisk = PersistentHistoryStore(url: temp)
    let reloaded = await fromDisk.current(now: start.addingTimeInterval(30))
    try require(reloaded.points.count == 2, "Persistent history must reload append-only NDJSON")
    try require(
      reloaded.points.last?.memoryPercent.map { close($0, 50) } == true,
      "Persistent history must preserve memory percentage for long-range UI charts")
    try require(close(reloaded.energyWattHours, 12 * 30 / 3_600), "Reloaded persistent energy")

    var data = (try? Data(contentsOf: temp)) ?? Data()
    data.append(Data("{malformed-tail".utf8))
    try data.write(to: temp)
    let tolerant = PersistentHistoryStore(url: temp)
    let tolerantSummary = await tolerant.current(now: start.addingTimeInterval(30))
    try require(
      tolerantSummary.points.count == 2, "Malformed history tail must not erase valid samples")
    _ = await tolerant.append(
      snapshot: historySnapshot(now: start.addingTimeInterval(60), power: 18, cpu: 40),
      now: start.addingTimeInterval(60))
    let recovered = PersistentHistoryStore(url: temp)
    let recoveredSummary = await recovered.current(now: start.addingTimeInterval(60))
    try require(
      recoveredSummary.points.count == 3,
      "Malformed tail recovery must preserve the next valid append")
  }

  /// Field regression: retained history larger than the old absolute limits was
  /// rewritten on every append (74 MB app energy per minute, 2 MB history per
  /// 30 s) and on every launch. Compaction is now relative and repair-only on load.
  private static func batteryHealthChecks() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func battery(design: Int, maximum: Int, cycles: Int) -> BatteryMetrics {
      BatteryParser.parse([
        "DesignCapacity": design, "AppleRawMaxCapacity": maximum, "NominalChargeCapacity": maximum,
        "CycleCount": cycles, "CurrentCapacity": 50, "MaxCapacity": 100, "IsCharging": false,
        "ExternalConnected": false,
      ])
    }
    func snapshot(_ metrics: BatteryMetrics, at date: Date) -> TelemetrySnapshot {
      var snapshot = TelemetrySnapshot(capturedAt: date, capturedTicks: 1)
      snapshot.battery = MetricSample(.success(metrics), capturedAt: date, capturedTicks: 1)
      return snapshot
    }
    let first = BatteryHealthEngine.record(from: battery(design: 6000, maximum: 5700, cycles: 100), now: start, calendar: calendar)
    try require(first?.cycleCount == 100 && abs((first?.healthPercent ?? 0) - 95) < 0.01,
      "A day record carries health and cycle count")
    try require(first?.day == calendar.startOfDay(for: start), "Records are keyed by local day")
    var days = BatteryHealthEngine.merged([], with: first!)
    let sameDay = BatteryDayRecord(day: first!.day, healthPercent: 94.9, maximumCapacityMAh: 5694,
      designCapacityMAh: 6000, cycleCount: 100)
    days = BatteryHealthEngine.merged(days, with: sameDay)
    try require(days.count == 1 && days[0].healthPercent == 94.9, "The same day replaces its record")
    let tomorrow = BatteryDayRecord(day: first!.day.addingTimeInterval(86_400), healthPercent: 94.5,
      maximumCapacityMAh: 5670, designCapacityMAh: 6000, cycleCount: 101)
    days = BatteryHealthEngine.merged(days, with: tomorrow)
    try require(days.count == 2, "A new day appends")
    try require(BatteryHealthEngine.merged(days, with: first!).count == 2
      && BatteryHealthEngine.merged(days, with: first!) == days, "A clock rollback is ignored")
    try require(!BatteryHealthEngine.needsPersisting(sameDay, after: BatteryDayRecord(
      day: first!.day, healthPercent: 95.0, maximumCapacityMAh: 5700, designCapacityMAh: 6000, cycleCount: 100)),
      "Sub-threshold wobble within a day is not rewritten")
    try require(BatteryHealthEngine.needsPersisting(tomorrow, after: sameDay), "A new day is written")
    try require(BatteryHealthEngine.needsPersisting(
      BatteryDayRecord(day: first!.day, healthPercent: 95, maximumCapacityMAh: 5700, designCapacityMAh: 6000, cycleCount: 101),
      after: first), "A cycle change is written")
    let summary = BatteryHealthSummary(days: days)
    try require(summary.cyclesAdded == 1 && abs((summary.healthChangePoints ?? 0) - (-0.4)) < 0.001,
      "Summary reports wear and added cycles")
    let many = (0..<1_300).map {
      BatteryDayRecord(day: start.addingTimeInterval(Double($0) * 86_400), healthPercent: 90, maximumCapacityMAh: nil,
        designCapacityMAh: nil, cycleCount: $0)
    }
    try require(BatteryHealthEngine.sanitized(many, now: start.addingTimeInterval(1_400 * 86_400)).count
      == BatteryHealthEngine.retentionDays, "Retention is bounded")

    // Store round trip: one line per day, persisted, reloaded, duplicates repaired.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Helios-BatteryHealth-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("battery.ndjson")
    let store = BatteryHealthHistoryStore(url: url)
    _ = await store.record(snapshot: snapshot(battery(design: 6000, maximum: 5700, cycles: 100), at: start), now: start, calendar: calendar)
    _ = await store.record(snapshot: snapshot(battery(design: 6000, maximum: 5699, cycles: 100), at: start.addingTimeInterval(30)),
      now: start.addingTimeInterval(30), calendar: calendar)
    let nextDay = start.addingTimeInterval(86_400)
    let result = await store.record(snapshot: snapshot(battery(design: 6000, maximum: 5690, cycles: 101), at: nextDay),
      now: nextDay, calendar: calendar)
    try require(result.days.count == 2, "Two days recorded")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    try require(lines.count == 2, "Wobble within a day is not a new line (\(lines.count) lines)")
    let reloaded = await BatteryHealthHistoryStore(url: url).current(now: nextDay)
    try require(reloaded.days.map(\.cycleCount) == [100, 101], "The daily record persists across launches")
    // Duplicated days in the file collapse to the newest line.
    var duplicated = try Data(contentsOf: url)
    for _ in 0..<40 { duplicated.append(lines[1].data(using: .utf8)!); duplicated.append(0x0A) }
    try duplicated.write(to: url)
    let repaired = BatteryHealthHistoryStore(url: url)
    let repairedDays = await repaired.current(now: nextDay).days
    try require(repairedDays.count == 2, "Duplicate days collapse on load")
    try require(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 2,
      "The file is rewritten without duplicates")
    print("PASS daily battery health record: day keys, wobble threshold, rollback, retention, persistence and repair")
  }

  private static func appEnergyTieringChecks() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func entry(_ key: String, _ wattHours: Double) -> AppEnergyEntry {
      AppEnergyEntry(appKey: key, displayName: key, energyWattHours: wattHours,
        cpuCoreSeconds: wattHours * 100, wakeups: 10, peakMemoryBytes: UInt64(wattHours * 1e6))
    }
    // Seven days of one-minute buckets, power state flipping every ten hours.
    let total = 7 * 24 * 60
    let buckets = (0..<total).map { index in
      AppEnergyBucket(
        capturedAt: now.addingTimeInterval(-Double(total - index) * 60), durationSeconds: 60,
        onBattery: (index / 600) % 2 == 0, batteryPercent: 80 - Double(index % 20),
        entries: [entry("a", 0.01), entry("b", 0.02), entry("c", 0.005)])
    }
    let tiered = AppEnergyHistoryEngine.coarsened(buckets, now: now)
    try require(tiered.count < 700, "Seven days must tier down to a few hundred buckets (\(tiered.count))")
    let before = AppEnergyHistoryEngine.summary(buckets)
    let after = AppEnergyHistoryEngine.summary(tiered)
    try require(before.coverageSeconds == after.coverageSeconds
      && before.onBatteryCoverageSeconds == after.onBatteryCoverageSeconds,
      "Tiering must preserve coverage")
    try require(zip(before.topAll, after.topAll).allSatisfy {
      $0.appKey == $1.appKey && abs($0.energyWattHours - $1.energyWattHours) < 1e-6
        && abs($0.cpuCoreSeconds - $1.cpuCoreSeconds) < 1e-6 && $0.peakMemoryBytes == $1.peakMemoryBytes
    } && before.topAll.count == after.topAll.count, "Tiering must preserve per-app totals")
    try require(zip(before.topOnBattery, after.topOnBattery).allSatisfy {
      abs($0.energyWattHours - $1.energyWattHours) < 1e-6 } , "Tiering must preserve on-battery totals")
    try require(before.recentHourTrends == after.recentHourTrends
      && before.recentHourOnBatteryChargeDeltaPercent == after.recentHourOnBatteryChargeDeltaPercent,
      "The last three hours stay at one-minute resolution, so trends do not change")
    let recent = tiered.filter { now.timeIntervalSince($0.capturedAt) < AppEnergyHistoryEngine.fineRetention }
    try require(recent.count == 179 && recent.allSatisfy { $0.durationSeconds == 60 },
      "The newest three hours are untouched")
    try require(AppEnergyHistoryEngine.coarsened(tiered, now: now) == tiered, "Tiering is idempotent")
    try require(AppEnergyHistoryEngine.sanitized(tiered, now: now).count == tiered.count,
      "Tiered buckets stay valid and ordered")
    try require(tiered.allSatisfy { $0.durationSeconds <= AppEnergyHistoryEngine.maximumBucketSeconds },
      "No bucket exceeds an hour")
    try require(zip(tiered, tiered.dropFirst()).allSatisfy { $0.capturedAt < $1.capturedAt }, "Order is preserved")
    // The decode path produces the same tiers without materialising the full week.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    var file = Data()
    for bucket in buckets { file.append(try encoder.encode(bucket)); file.append(0x0A) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    var strings = AppEnergyStringTable()
    var decodedCount = 0
    let streamed = AppEnergyHistoryEngine.decodeLines(
      file, decoder: decoder, strings: &strings, coarseningAt: now, decodedCount: &decodedCount)
    try require(decodedCount == total && streamed == tiered, "Streaming decode tiers like the pure function")
  }

  private static func historyCompactionChecks() async throws {
    try require(!HistoryCompactionPolicy.shouldCompact(fileSize: 2_100_000, compactedSize: 2_100_000, slack: 2_000_000),
      "Retained content above the slack alone must not trigger a rewrite")
    try require(HistoryCompactionPolicy.shouldCompact(fileSize: 4_100_001, compactedSize: 2_100_000, slack: 2_000_000),
      "Growth beyond the slack compacts")
    try require(HistoryCompactionPolicy.shouldCompact(fileSize: 2_000_001, compactedSize: 0, slack: 2_000_000),
      "Small histories keep the previous absolute bound")
    try require(!HistoryCompactionPolicy.shouldCompact(fileSize: .max, compactedSize: .max, slack: 1),
      "Overflowing limits never compact in a loop")
    try require(!HistoryCompactionPolicy.needsRepair(rawRecords: 10, decoded: 10, clean: 7, expiredPrefix: 3,
      endsWithNewline: true), "Expired head records are left for compaction")
    try require(HistoryCompactionPolicy.needsRepair(rawRecords: 10, decoded: 9, clean: 9, expiredPrefix: 0,
      endsWithNewline: true), "Malformed lines are repaired")
    try require(HistoryCompactionPolicy.needsRepair(rawRecords: 10, decoded: 10, clean: 8, expiredPrefix: 1,
      endsWithNewline: true), "Ordering/future drops are repaired")
    try require(HistoryCompactionPolicy.needsRepair(rawRecords: 10, decoded: 10, clean: 10, expiredPrefix: 0,
      endsWithNewline: false), "A torn final line is repaired")

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Helios-Compaction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.ndjson")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func point(_ age: TimeInterval) -> PersistedTelemetryPoint {
      PersistedTelemetryPoint(
        capturedAt: now.addingTimeInterval(-age), cpuPercent: 12.345678, memoryPercent: 64.123456,
        gpuPercent: 8.765432, maxSoCCelsius: 51.234567, systemPowerWatts: 9.876543,
        batteryPercent: 80.123456, batteryHealthPercent: 94.567891, batteryPowerWatts: -6.543219,
        batteryOnAC: false, batteryTemperatureCelsius: 31.234567, batteryCycleCount: 123,
        storageTemperatureCelsius: 38.765432, storageDeviceBSDName: "disk0",
        storageLifetimeReadBytes: 1.234567e13, storageLifetimeWrittenBytes: 9.876543e12,
        storageReadBytesPerSecond: 1_234_567.89, storageWriteBytesPerSecond: 987_654.32,
        processAccountedReadBytesPerSecond: 123_456.78, processAccountedWriteBytesPerSecond: 98_765.43,
        heliosCPUPercent: 1.234567, heliosPowerWatts: 0.056789, heliosMemoryBytes: 61_234_567,
        heliosWakeupsPerSecond: 5.678912, fanRPM: 2_345.678, networkDownloadBytesPerSecond: 234_567.89,
        networkUploadBytesPerSecond: 45_678.91)
    }
    // Three expired records at the head, then a full 24 hours at 30 s.
    var points = (0..<3).map { point(25 * 3_600 + Double($0)) }
    points += stride(from: 24.0 * 3_600 - 60, through: 60, by: -30).map(point)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let written = try HistoryCompactionPolicy.writeLines(points, encoder: encoder, to: url)
    try require(written > 2_000_000, "Fixture must exceed the old absolute limit (\(written) bytes)")
    try require(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["history.ndjson"],
      "Streaming rewrite must not leave temporary files")
    // Orphaned temporaries from an interrupted compaction are removed on load;
    // recent ones (possibly another instance) and unrelated files are kept.
    let staleTemporary = directory.appendingPathComponent(".history.ndjson.\(UUID().uuidString).tmp")
    let freshTemporary = directory.appendingPathComponent(".history.ndjson.\(UUID().uuidString).tmp")
    let unrelated = directory.appendingPathComponent(".other.ndjson.\(UUID().uuidString).tmp")
    for file in [staleTemporary, freshTemporary, unrelated] {
      try Data("x".utf8).write(to: file)
    }
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: staleTemporary.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: unrelated.path)
    HistoryCompactionPolicy.removeStaleTemporaries(for: url)
    try require(!FileManager.default.fileExists(atPath: staleTemporary.path), "Stale temporary is removed")
    try require(FileManager.default.fileExists(atPath: freshTemporary.path), "Recent temporary is kept")
    try require(FileManager.default.fileExists(atPath: unrelated.path), "Other stores' temporaries are kept")
    try FileManager.default.removeItem(at: freshTemporary)
    try FileManager.default.removeItem(at: unrelated)
    func inode() throws -> Int {
      (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue ?? -1
    }
    let originalInode = try inode()
    let store = PersistentHistoryStore(url: url)
    let loaded = await store.current(now: now)
    try require(loaded.points.count == points.count - 3, "Expired head records are excluded in memory")
    try require(try inode() == originalInode, "Load must not rewrite for expired head records")
    var snapshot = TelemetrySnapshot(capturedAt: now, capturedTicks: 1)
    snapshot.cpu = MetricSample(.success(CPUMetrics(
      userPercent: 10, systemPercent: 2, nicePercent: 0, idlePercent: 88)), capturedAt: now, capturedTicks: 1)
    _ = await store.append(snapshot: snapshot, now: now)
    try require(try inode() == originalInode, "A single append must not rewrite >2 MB of retained history")
    let lines = try Data(contentsOf: url).split(separator: 0x0A).count
    try require(lines == points.count + 1, "Append adds exactly one line")
    var torn = try Data(contentsOf: url)
    torn.append(Data("{\"capturedAt\":".utf8))
    try torn.write(to: url)
    let repaired = PersistentHistoryStore(url: url)
    _ = await repaired.current(now: now)
    let repairedData = try Data(contentsOf: url)
    try require(repairedData.last == 0x0A && repairedData.split(separator: 0x0A).count == points.count - 3 + 1,
      "A torn tail is repaired, dropping expired records at the same time")
  }

  private static func persistenceLifecycleChecks() async throws {
    // Every store uses disposable paths. Exercise the production cached-handle
    // paths, then inspect disk bytes independently of their in-memory summaries.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Helios-AppendLifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for kind in ["history", "io", "energy"] {
      let url = directory.appendingPathComponent(kind + ".ndjson")
      let history = PersistentHistoryStore(url: url)
      let audit = IOActivityAuditStore(url: url)
      let energy = AppEnergyHistoryStore(url: url)
      let start = Date(timeIntervalSince1970: 60_000)
      func append(_ index: Int) async {
        if kind == "energy" {
          // Seed once and then provide real five-second sample intervals, so
          // each call flushes one complete minute through the production store.
          let lower = index == 0 ? 0 : index * 12 + 1
          for tick in lower...((index + 1) * 12) {
            let now = start.addingTimeInterval(Double(tick) * 5)
            var snapshot = TelemetrySnapshot()
            snapshot.processes = MetricSample(.success(ProcessMetrics(
              accessibleProcessCount: 0, topByCPU: [], topByEnergy: [], topByMemory: [])),
              capturedAt: now, capturedTicks: UInt64(tick + 1))
            _ = await energy.consume(snapshot: snapshot, now: now)
          }
        } else {
          let now = start.addingTimeInterval(Double(index) * 60)
          if kind == "history" { _ = await history.append(snapshot: TelemetrySnapshot(), now: now) }
          else { _ = await audit.append(snapshot: TelemetrySnapshot(), now: now) }
        }
      }
      func diskCount() throws -> Int {
        let data = try Data(contentsOf: url)
        try require(!data.contains(0), "\(kind): append left a sparse NUL hole")
        let lines = data.split(separator: 0x0A)
        for line in lines { _ = try JSONSerialization.jsonObject(with: Data(line)) }
        return lines.count
      }
      await append(0)
      await append(1) // Hold a cached descriptor.
      let original = try Data(contentsOf: url)
      try original.write(to: url, options: .atomic)
      await append(2)
      let replacedCount = try diskCount()
      try require(replacedCount == 3, "\(kind): atomic replacement lost append")
      let truncating = try FileHandle(forWritingTo: url)
      try truncating.truncate(atOffset: 0)
      try truncating.close()
      await append(3)
      let truncatedCount = try diskCount()
      try require(truncatedCount == 1, "\(kind): truncated file did not resume at its new end")
      try FileManager.default.removeItem(at: url)
      await append(4)
      let recreatedCount = try diskCount()
      try require(recreatedCount == 1, "\(kind): missing path was not recreated")
      // A crash may leave valid JSON with only its final newline missing.
      var unterminated = try Data(contentsOf: url)
      unterminated.removeLast()
      try unterminated.write(to: url, options: .atomic)
      let now = start.addingTimeInterval(600)
      if kind == "history" { _ = await PersistentHistoryStore(url: url).current(now: now) }
      else if kind == "io" { _ = await IOActivityAuditStore(url: url).current(now: now) }
      else { _ = await AppEnergyHistoryStore(url: url).current(now: now) }
      let repaired = try Data(contentsOf: url)
      try require(repaired.last == 0x0A,
                  "\(kind): complete JSON tail needs a delimiter before another append")
    }
    let resetEnergy = AppEnergyHistoryStore(url: directory.appendingPathComponent("reset-energy.ndjson"))
    let resetStart = Date(timeIntervalSince1970: 70_000)
    for tick in 0...19 {
      if tick == 7 { await resetEnergy.resetSamplingBaseline() }
      let now = resetStart.addingTimeInterval(Double(tick) * 5)
      var snapshot = tick < 7 ? historySnapshot(now: now, power: 10, cpu: 20) : TelemetrySnapshot()
      snapshot.processes = MetricSample(.success(ProcessMetrics(
        accessibleProcessCount: 0, topByCPU: [], topByEnergy: [], topByMemory: [])),
        capturedAt: now, capturedTicks: UInt64(tick + 1))
      _ = await resetEnergy.consume(snapshot: snapshot, now: now)
    }
    let resetSummary = await resetEnergy.current(now: resetStart.addingTimeInterval(95))
    try require(resetSummary.buckets.count == 1 && resetSummary.buckets[0].durationSeconds == 60,
      "Discarded app-energy samples must not bridge the integration baseline")
    try require(resetSummary.buckets[0].batteryPercent == nil && resetSummary.buckets[0].onBattery == nil,
      "App-energy baseline reset must discard old battery metadata")
    print("PASS all three history stores: atomic replacement, truncation, recreation and unterminated JSON recovery; app-energy backpressure resets integration and battery metadata")
  }

  private static func ioAuditChecks() async throws {
    let start = Date(timeIntervalSince1970: 30_000)
    func record(
      _ offset: TimeInterval, read: UInt64, write: UInt64, readRate: Double = 100,
      writeRate: Double = 200
    ) -> IOActivityRecord {
      IOActivityRecord(
        capturedAt: start.addingTimeInterval(offset), deviceBSDName: "disk0",
        deviceReadSinceBootBytes: read, deviceWrittenSinceBootBytes: write,
        deviceReadBytesPerSecond: readRate, deviceWriteBytesPerSecond: writeRate,
        processAccountedReadBytesPerSecond: 50, processAccountedWriteBytesPerSecond: 75,
        topReaderName: "Reader", topReaderPID: 101, topReaderBytesPerSecond: 40,
        topWriterName: "Writer", topWriterPID: 202, topWriterBytesPerSecond: 60,
        heliosReadBytesPerSecond: 1, heliosWriteBytesPerSecond: 2
      )
    }

    let observed = [
      record(0, read: 1_000, write: 2_000), record(30, read: 1_600, write: 2_600),
      record(60, read: 2_500, write: 3_500),
    ]
    let summary = IOActivityAuditEngine.summary(observed)
    try require(
      summary.observedDeviceReadBytes == 1_500 && summary.observedDeviceWrittenBytes == 1_500,
      "I/O audit physical-device deltas")
    try require(close(summary.observedCoverageSeconds, 60), "I/O audit observed coverage")
    try require(
      summary.peakReadBytesPerSecond == 100 && summary.peakWriteBytesPerSecond == 200,
      "I/O audit peaks")

    let longGap = IOActivityAuditEngine.summary([
      record(0, read: 1_000, write: 1_000), record(120, read: 9_000, write: 9_000),
    ])
    try require(
      longGap.observedDeviceReadBytes == 0 && longGap.observedDeviceWrittenBytes == 0
        && close(longGap.observedCoverageSeconds, 0), "I/O audit must not bridge long gaps")
    let rollback = IOActivityAuditEngine.summary([
      record(0, read: 9_000, write: 9_000), record(30, read: 100, write: 100),
    ])
    try require(
      rollback.observedDeviceReadBytes == 0 && rollback.observedDeviceWrittenBytes == 0,
      "I/O audit must reject device counter rollback")
    let changedDevice = IOActivityRecord(
      capturedAt: start.addingTimeInterval(30), deviceBSDName: "disk9",
      deviceReadSinceBootBytes: 99_000, deviceWrittenSinceBootBytes: 99_000,
      deviceReadBytesPerSecond: nil, deviceWriteBytesPerSecond: nil,
      processAccountedReadBytesPerSecond: nil, processAccountedWriteBytesPerSecond: nil,
      topReaderName: nil, topReaderPID: nil, topReaderBytesPerSecond: nil, topWriterName: nil,
      topWriterPID: nil, topWriterBytesPerSecond: nil,
      heliosReadBytesPerSecond: nil, heliosWriteBytesPerSecond: nil
    )
    try require(
      IOActivityAuditEngine.summary([observed[0], changedDevice]).observedDeviceReadBytes == 0,
      "I/O audit must not bridge a device handoff")
    let csv = IOActivityAuditEngine.csv(observed)
    try require(
      csv.contains("process_write_Bps") && csv.contains("\"Writer\"")
        && csv.split(separator: "\n").count == 4, "I/O audit CSV export")

    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Helios-IOAudit-\(UUID().uuidString).ndjson")
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = IOActivityAuditStore(url: temp)
    _ = await store.append(
      snapshot: ioAuditSnapshot(now: start, read: 1_000, write: 2_000), now: start)
    _ = await store.append(
      snapshot: ioAuditSnapshot(now: start.addingTimeInterval(30), read: 1_600, write: 2_600),
      now: start.addingTimeInterval(30))
    let reloaded = await IOActivityAuditStore(url: temp).current(now: start.addingTimeInterval(30))
    try require(
      reloaded.records.count == 2 && reloaded.observedDeviceReadBytes == 600
        && reloaded.observedDeviceWrittenBytes == 600, "I/O audit reload and physical accounting")

    var data = (try? Data(contentsOf: temp)) ?? Data()
    data.append(Data("{malformed-tail".utf8))
    try data.write(to: temp)
    let tolerant = IOActivityAuditStore(url: temp)
    let tolerantSummary = await tolerant.current(now: start.addingTimeInterval(30))
    try require(
      tolerantSummary.records.count == 2, "Malformed I/O audit tail must not erase valid records")
    _ = await tolerant.append(
      snapshot: ioAuditSnapshot(now: start.addingTimeInterval(60), read: 2_500, write: 3_500),
      now: start.addingTimeInterval(60))
    let recovered = await IOActivityAuditStore(url: temp).current(now: start.addingTimeInterval(60))
    try require(
      recovered.records.count == 3 && recovered.observedDeviceReadBytes == 1_500,
      "I/O audit malformed-tail recovery must preserve next append")
  }

  private static func ioAuditSnapshot(now: Date, read: UInt64, write: UInt64) -> TelemetrySnapshot {
    var snapshot = TelemetrySnapshot()
    let counters = StorageIOCounters(
      bytesRead: read, bytesWritten: write, readOperations: 1, writeOperations: 1, readErrors: 0,
      writeErrors: 0)
    let device = StorageDeviceMetrics(
      registryID: 1, bsdName: "disk0", model: "APPLE SSD", capacityBytes: 1_000_000,
      isInternal: true, isRemovable: false, transport: "Apple Fabric",
      controllerClass: "IOEmbeddedNVMeBlockDevice",
      smartCapability: .nvmeAdvertised, counters: .success(counters)
    )
    snapshot.storage = MetricSample(
      .success(
        StorageMetrics(
          rootVolume: .success(RootVolumeMetrics(totalBytes: 1_000_000, freeBytes: 500_000)),
          devices: [device], primaryDeviceBSDName: "disk0",
          throughput: .success(
            StorageThroughput(
              readBytesPerSecond: 100, writeBytesPerSecond: 200, readIOPS: 1, writeIOPS: 1)),
          smartHealth: .failure(.unavailable("fixture")), smartHealthCapturedTicks: nil
        )), capturedAt: now)
    let reader = ProcessActivity(
      pid: 101, name: "Reader", executablePath: nil, physicalFootprintBytes: 1,
      neuralFootprintBytes: 0, cpuPercent: 1, powerWatts: 0.1, performanceCorePowerWatts: 0.05,
      diskReadBytesPerSecond: 40, diskWriteBytesPerSecond: 2, wakeupsPerSecond: 1,
      instructionsPerSecond: 1, cyclesPerSecond: 1, instructionsPerCycle: 1,
      sessionDiskReadBytes: 40, sessionDiskWriteBytes: 2)
    let writer = ProcessActivity(
      pid: 202, name: "Writer", executablePath: nil, physicalFootprintBytes: 1,
      neuralFootprintBytes: 0, cpuPercent: 1, powerWatts: 0.1, performanceCorePowerWatts: 0.05,
      diskReadBytesPerSecond: 3, diskWriteBytesPerSecond: 60, wakeupsPerSecond: 1,
      instructionsPerSecond: 1, cyclesPerSecond: 1, instructionsPerCycle: 1,
      sessionDiskReadBytes: 3, sessionDiskWriteBytes: 60)
    let helios = ProcessActivity(
      pid: 303, name: "Helios", executablePath: nil, physicalFootprintBytes: 1,
      neuralFootprintBytes: 0, cpuPercent: 0.1, powerWatts: 0.01, performanceCorePowerWatts: 0.01,
      diskReadBytesPerSecond: 1, diskWriteBytesPerSecond: 2, wakeupsPerSecond: 0,
      instructionsPerSecond: 1, cyclesPerSecond: 1, instructionsPerCycle: 1,
      sessionDiskReadBytes: 1, sessionDiskWriteBytes: 2)
    snapshot.processes = MetricSample(
      .success(
        ProcessMetrics(
          accessibleProcessCount: 3, topByCPU: [reader], topByEnergy: [reader],
          topByMemory: [reader],
          topByDiskRead: [reader, writer], topByDiskWrite: [writer, reader],
          topSessionReaders: [reader], topSessionWriters: [writer],
          accountedDiskReadBytesPerSecond: 44, accountedDiskWriteBytesPerSecond: 64,
          sessionAccountedReadBytes: 44, sessionAccountedWriteBytes: 64, heliosActivity: helios
        )), capturedAt: now)
    return snapshot
  }

  private static func capabilityChecks() throws {
    let now = Date(timeIntervalSince1970: 40_000)
    var snapshot = ioAuditSnapshot(now: now, read: 1_000, write: 2_000)
    snapshot.cpu = MetricSample(
      .success(
        CPUMetrics(
          userPercent: 1, systemPercent: 1, nicePercent: 0, idlePercent: 98,
          perCoreUsagePercent: [1, 2])), capturedAt: now)
    snapshot.gpu = MetricSample(
      .success(
        GPUMetrics(
          model: .success("Apple M4"), coreCount: .success(10),
          deviceUtilizationPercent: .success(5), rendererUtilizationPercent: .success(4),
          tilerUtilizationPercent: .success(3), allocatedSystemMemoryBytes: .success(1),
          inUseSystemMemoryBytes: .success(1))), capturedAt: now)
    snapshot.systemPower = MetricSample(
      .success(SystemPowerMetrics(totalSystemWatts: .success(5))), capturedAt: now)
    snapshot.wifi = MetricSample(
      .success(
        WiFiMetrics(
          interfaceName: "en0", powerOn: true, serviceActive: true,
          ssid: .failure(.unavailable("privacy")), rssiDBm: .success(-50), noiseDBm: .success(-90),
          transmitRateMbps: .success(800), transmitPowerMilliwatts: .success(20),
          channelNumber: .success(36), channelBand: .success("5 GHz"),
          channelWidth: .success("80 MHz"), phyMode: .success("802.11ax / Wi-Fi 6/6E"),
          security: .success("WPA3 Personal"))), capturedAt: now)
    snapshot.battery = MetricSample(
      .success(
        BatteryMetrics(
          designCapacityMAh: .success(6_000), maximumCapacityMAh: .success(5_900),
          currentCapacityMAh: .success(4_000), cycleCount: .success(10),
          temperatureCelsius: .success(30),
          power: .success(BatteryPower(signedWatts: -5, usesInstantaneousCurrent: true)))),
      capturedAt: now)
    snapshot.thermals = MetricSample(
      .success(
        ThermalMetrics(
          readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 45)],
          failures: [:])), capturedAt: now)
    snapshot.fans = MetricSample(
      .success(
        FanInventory(fans: [
          FanReading(
            id: 0, actualRPM: .success(0), targetRPM: .success(0), minimumRPM: .success(2_000),
            maximumRPM: .success(6_000), automatic: .success(true))
        ])), capturedAt: now)
    let ownershipEvidence = FanOwnershipPreflightEvidence(
      modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
      globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0,
      fans: [
        FanOwnershipPreflightFan(
          id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 0, minimumRPM: 2_317,
          maximumRPM: 6_550, targetType: "flt ")
      ]
    )
    snapshot.fanOwnershipPreflight = MetricSample(
      .success(FanOwnershipPreflightEvaluator.evaluate(ownershipEvidence)), capturedAt: now)
    if case .success(var storage) = snapshot.storage.result {
      let smart = NVMeSMARTHealth(
        criticalWarning: 0, temperatureCelsius: 30, availableSparePercent: 100,
        availableSpareThresholdPercent: 99, percentageUsed: 0,
        dataUnitsRead: NVMeCounter128(low: 1, high: 0),
        dataUnitsWritten: NVMeCounter128(low: 1, high: 0),
        hostReadCommands: NVMeCounter128(low: 1, high: 0),
        hostWriteCommands: NVMeCounter128(low: 1, high: 0),
        controllerBusyMinutes: NVMeCounter128(low: 0, high: 0),
        powerCycles: NVMeCounter128(low: 1, high: 0), powerOnHours: NVMeCounter128(low: 1, high: 0),
        unsafeShutdowns: NVMeCounter128(low: 0, high: 0),
        mediaErrors: NVMeCounter128(low: 0, high: 0),
        errorLogEntries: NVMeCounter128(low: 0, high: 0))
      storage = StorageMetrics(
        rootVolume: storage.rootVolume, devices: storage.devices,
        primaryDeviceBSDName: storage.primaryDeviceBSDName, throughput: storage.throughput,
        smartHealth: .success(smart), smartHealthCapturedTicks: HostClock.now)
      snapshot.storage = MetricSample(.success(storage), capturedAt: now)
    }
    let report = CapabilityEvaluator.evaluate(snapshot, now: now)
    try require(report.items.count == 16, "Capability report coverage")
    try require(
      report.items.contains(where: { $0.title == "Native NVMe SMART" && $0.state == .available }),
      "NVMe SMART capability must reflect real read success")
    guard let fans = report.items.first(where: { $0.title == "Fan telemetry" }) else {
      throw CheckFailure(description: "Fan capability missing")
    }
    try require(
      fans.state == .available && fans.detail.contains("writes remain separately gated"),
      "Capability report must not imply read discovery authorizes fan writes")
    guard let surface = report.items.first(where: { $0.title == "Fan-control surface match" })
    else { throw CheckFailure(description: "Fan surface capability missing") }
    try require(
      surface.state == .available && surface.detail.contains("read-only evidence only"),
      "Fan surface match must remain read-only evidence")
  }

  private static func healthChecks() throws {
    let now = Date(timeIntervalSince1970: 20_000)
    var healthy = historySnapshot(now: now, power: 5, cpu: 10)
    healthy.memory = MetricSample(
      .success(
        MemoryMetrics(
          physicalBytes: 16 << 30, activeBytes: 4 << 30, inactiveBytes: 4 << 30,
          wiredBytes: 2 << 30, compressedBytes: 1 << 30, freeBytes: 5 << 30,
          pressure: .success(.normal)
        )), capturedAt: now)
    healthy.system = MetricSample(
      .success(
        SystemMetrics(
          modelIdentifier: .success("Mac16,1"), chipName: .success("Apple M4"),
          osVersion: "test", uptimeSeconds: 1_000, logicalProcessorCount: 10,
          physicalMemoryBytes: 16 << 30,
          loadAverage1: .success(1), loadAverage5: .success(1), loadAverage15: .success(1),
          thermalState: .nominal, lowPowerModeEnabled: false
        )), capturedAt: now)
    healthy.battery = MetricSample(
      .success(
        BatteryMetrics(
          designCapacityMAh: .success(6_000), maximumCapacityMAh: .success(5_700),
          currentCapacityMAh: .success(4_000),
          cycleCount: .success(100), temperatureCelsius: .success(30),
          power: .success(BatteryPower(signedWatts: -5, usesInstantaneousCurrent: true))
        )), capturedAt: now)
    healthy.storage = MetricSample(
      .success(
        StorageMetrics(
          rootVolume: .failure(.unavailable("fixture")), devices: [], primaryDeviceBSDName: nil,
          throughput: .failure(.warmingUp),
          smartHealth: .success(
            NVMeSMARTHealth(
              criticalWarning: 0, temperatureCelsius: 35, availableSparePercent: 100,
              availableSpareThresholdPercent: 10, percentageUsed: 5,
              dataUnitsRead: NVMeCounter128(low: 0, high: 0),
              dataUnitsWritten: NVMeCounter128(low: 0, high: 0),
              hostReadCommands: NVMeCounter128(low: 0, high: 0),
              hostWriteCommands: NVMeCounter128(low: 0, high: 0),
              controllerBusyMinutes: NVMeCounter128(low: 0, high: 0),
              powerCycles: NVMeCounter128(low: 0, high: 0),
              powerOnHours: NVMeCounter128(low: 0, high: 0),
              unsafeShutdowns: NVMeCounter128(low: 0, high: 0),
              mediaErrors: NVMeCounter128(low: 0, high: 0),
              errorLogEntries: NVMeCounter128(low: 0, high: 0)
            )), smartHealthCapturedTicks: nil
        )), capturedAt: now)
    try require(
      HealthEvaluator.evaluate(healthy, now: now).isEmpty, "Healthy telemetry must not raise alerts"
    )

    var bad = healthy
    bad.thermals = MetricSample(
      .success(
        ThermalMetrics(
          readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 96)],
          failures: [:]
        )), capturedAt: now)
    bad.memory = MetricSample(
      .success(
        MemoryMetrics(
          physicalBytes: 16 << 30, activeBytes: 10 << 30, inactiveBytes: 1 << 30,
          wiredBytes: 3 << 30, compressedBytes: 2 << 30, freeBytes: 0,
          pressure: .success(.critical)
        )), capturedAt: now)
    bad.system = MetricSample(
      .success(
        SystemMetrics(
          modelIdentifier: .success("Mac16,1"), chipName: .success("Apple M4"),
          osVersion: "test", uptimeSeconds: 1_000, logicalProcessorCount: 10,
          physicalMemoryBytes: 16 << 30,
          loadAverage1: .success(1), loadAverage5: .success(1), loadAverage15: .success(1),
          thermalState: .serious, lowPowerModeEnabled: false
        )), capturedAt: now)
    bad.battery = MetricSample(
      .success(
        BatteryMetrics(
          designCapacityMAh: .success(6_000), maximumCapacityMAh: .success(3_900),
          currentCapacityMAh: .success(3_000),
          cycleCount: .success(900), temperatureCelsius: .success(51),
          power: .success(BatteryPower(signedWatts: -10, usesInstantaneousCurrent: true))
        )), capturedAt: now)
    bad.storage = MetricSample(
      .success(
        StorageMetrics(
          rootVolume: .failure(.unavailable("fixture")), devices: [], primaryDeviceBSDName: nil,
          throughput: .failure(.warmingUp),
          smartHealth: .success(
            NVMeSMARTHealth(
              criticalWarning: 1, temperatureCelsius: 81, availableSparePercent: 5,
              availableSpareThresholdPercent: 10, percentageUsed: 101,
              dataUnitsRead: NVMeCounter128(low: 0, high: 0),
              dataUnitsWritten: NVMeCounter128(low: 0, high: 0),
              hostReadCommands: NVMeCounter128(low: 0, high: 0),
              hostWriteCommands: NVMeCounter128(low: 0, high: 0),
              controllerBusyMinutes: NVMeCounter128(low: 0, high: 0),
              powerCycles: NVMeCounter128(low: 0, high: 0),
              powerOnHours: NVMeCounter128(low: 0, high: 0),
              unsafeShutdowns: NVMeCounter128(low: 0, high: 0),
              mediaErrors: NVMeCounter128(low: 1, high: 0),
              errorLogEntries: NVMeCounter128(low: 1, high: 0)
            )), smartHealthCapturedTicks: nil
        )), capturedAt: now)
    let issues = HealthEvaluator.evaluate(bad, now: now)
    let ids = Set(issues.map(\.id))
    for expected in [
      "soc-critical", "memory-critical", "thermal-state-serious", "battery-health-critical",
      "battery-temp-critical", "ssd-smart-critical", "ssd-media-errors", "ssd-temp-critical",
    ] {
      try require(ids.contains(expected), "Missing health issue \(expected)")
    }
    try require(issues.first?.severity == .critical, "Critical health issues must sort first")

    var configuration = HealthAlertConfiguration.defaults
    for rule in HealthAlertRule.allCases {
      try require(configuration[rule].enabled, "Existing alert unexpectedly disabled by default")
      try require(configuration[rule].threshold == rule.defaultThreshold, "Threshold migration baseline")
    }
    // CPU average: P- and E-core sensors only, GPU and hotspots excluded.
    let averageFixture = ThermalMetrics(readings: [
      ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 80),
      ThermalReading(key: "Te05", group: .efficiencyCPU, celsius: 60),
      ThermalReading(key: "Tg0G", group: .gpu, celsius: 90),
    ], failures: [:])
    try require((try? averageFixture.averageCPUCelsius.get()) == 70, "CPU average must mean the P- and E-core sensors")
    try require((try? averageFixture.maximumSoCCelsius.get()) == 90, "Hottest sensor must still include the GPU")
    let gpuOnly = ThermalMetrics(readings: [ThermalReading(key: "Tg0G", group: .gpu, celsius: 90)], failures: [:])
    try require((try? gpuOnly.averageCPUCelsius.get()) == nil, "CPU average without CPU sensors must be unavailable")
    configuration[.socCritical] = HealthAlertSetting(enabled: false, threshold: 95)
    configuration[.socHot] = HealthAlertSetting(enabled: true, threshold: 100)
    try require(!HealthEvaluator.evaluate(bad, now: now, configuration: configuration)
      .contains { $0.id.hasPrefix("soc-") }, "Disabled/custom thresholds must affect evaluator")
    configuration[.socHot] = HealthAlertSetting(enabled: true, threshold: 90)
    try require(configuration.crossed(.socHot, value: 89.9, previouslyActive: ["soc-hot"]),
      "Hover near threshold must retain numeric activation")
    try require(!configuration.crossed(.socHot, value: 86.9, previouslyActive: ["soc-hot"]),
      "Three-degree recovery must rearm alert")
    try require(!configuration.crossed(.socHot, value: 89.9, previouslyActive: []),
      "Below-threshold value must not activate")
    try require(!configuration.crossed(.socHot, value: .nan, previouslyActive: []), "NaN alert")
    configuration[.socHot] = HealthAlertSetting(enabled: true, threshold: .infinity)
    try require(configuration[.socHot].threshold == HealthAlertRule.socHot.defaultThreshold, "Nonfinite preference default")
    configuration[.socHot] = HealthAlertSetting(enabled: true, threshold: 200)
    try require(configuration[.socHot].threshold == 120, "Threshold upper bound")
    configuration[.batteryHealthLow] = HealthAlertSetting(enabled: true, threshold: 80)
    try require(configuration.crossed(.batteryHealthLow, value: 82, previouslyActive: ["battery-health-low"]),
      "Battery low-direction recovery hysteresis")
    try require(!configuration.crossed(.batteryHealthLow, value: 83, previouslyActive: ["battery-health-low"]),
      "Battery recovery boundary")
    let warning = HealthIssue(id: "soc-hot", severity: .attention, title: "Heat", detail: "fixture")
    try require(!HealthNotificationPolicy.shouldNotify(issue: warning, activeSince: now,
      lastNotifiedAt: nil, now: now.addingTimeInterval(14)), "Sustained warning boundary")
    try require(HealthNotificationPolicy.shouldNotify(issue: warning, activeSince: now,
      lastNotifiedAt: nil, now: now.addingTimeInterval(15)), "Sustained warning eligible")
    try require(!HealthNotificationPolicy.shouldNotify(issue: warning, activeSince: now,
      lastNotifiedAt: now, now: now.addingTimeInterval(1799)), "Delivery-time warning cooldown boundary")
    try require(HealthNotificationPolicy.shouldNotify(issue: warning, activeSince: now,
      lastNotifiedAt: now, now: now.addingTimeInterval(1800)), "Delivery-time warning cooldown expired; activation eligibility is separate")

    var stale = bad
    stale.thermals = MetricSample(bad.thermals.result, capturedAt: now.addingTimeInterval(-60))
    stale.memory = MetricSample(bad.memory.result, capturedAt: now.addingTimeInterval(-60))
    stale.system = MetricSample(bad.system.result, capturedAt: now.addingTimeInterval(-60))
    stale.battery = MetricSample(bad.battery.result, capturedAt: now.addingTimeInterval(-60))
    stale.storage = MetricSample(bad.storage.result, capturedAt: now.addingTimeInterval(-60))
    try require(
      HealthEvaluator.evaluate(stale, now: now).isEmpty,
      "Stale telemetry must never raise health alerts")
  }

  @MainActor
  private static func notificationDeliveryChecks() async throws {
    let start = Date()
    let tasks = NotificationFixtureTasks()
    var attempts = 0
    let center = HealthAlertCenter(runtimeServicesEnabled: false, fixtureDelivery: { _ in
      attempts += 1
      if attempts == 1 { throw TelemetryError.unavailable("fixture delivery failure") }
    }, fixtureTaskObserver: { tasks.observe($0) })
    defer { center.shutdown() }
    func snapshot(_ temperature: Double, at date: Date) -> TelemetrySnapshot {
      var value = TelemetrySnapshot()
      value.thermals = MetricSample(.success(ThermalMetrics(readings: [
        ThermalReading(key: "Tp01", group: .performanceCPU, celsius: temperature)
      ], failures: [:])), capturedAt: date)
      return value
    }
    center.accept(snapshot(60, at: start), now: start)
    center.accept(snapshot(96, at: start.addingTimeInterval(1)), now: start.addingTimeInterval(1))
    try require(tasks.tasks.count == 1, "Expected the initial delivery task")
    await tasks.drain()
    try require(attempts == 1 && center.deliveryFailed, "Failed delivery must be observable")
    try require(!center.events.contains { $0.change == .notified }, "Failure falsely recorded as delivery")
    for second in 2...61 {
      let date = start.addingTimeInterval(Double(second))
      center.accept(snapshot(96, at: date), now: date)
      await tasks.drain()
      try require(attempts == (second < 61 ? 1 : 2), "Delivery retried before its one-minute boundary")
    }
    await tasks.drain()
    try require(attempts == 2 && !center.deliveryFailed, "Bounded delivery retry failed")
    try require(center.events.filter { $0.change == .notified }.count == 1, "Successful enqueue record")
    let later = start.addingTimeInterval(62)
    center.accept(snapshot(94.9, at: later), now: later)
    await tasks.drain()
    try require(attempts == 2, "Threshold hover repeated delivery")
    let gap = start.addingTimeInterval(200)
    center.accept(snapshot(96, at: gap), now: gap)
    await tasks.drain()
    try require(attempts == 2, "Wake baseline replayed active alert")
    let configuration = NotificationFixtureConfiguration()
    let independentTasks = NotificationFixtureTasks()
    var independentDeliveries = 0
    let independent = HealthAlertCenter(runtimeServicesEnabled: false,
      configuration: { configuration.value }, fixtureDelivery: { _ in independentDeliveries += 1 },
      fixtureTaskObserver: { independentTasks.observe($0) })
    defer { independent.shutdown() }
    independent.accept(snapshot(60, at: start), now: start)
    independent.accept(snapshot(91, at: start.addingTimeInterval(1)), now: start.addingTimeInterval(1))
    configuration.value[.batteryHealthLow] = HealthAlertSetting(enabled: false, threshold: 80)
    independent.accept(snapshot(91, at: start.addingTimeInterval(8)), now: start.addingTimeInterval(8))
    independent.accept(snapshot(91, at: start.addingTimeInterval(16)), now: start.addingTimeInterval(16))
    try require(independentTasks.tasks.count == 1, "Independent warning must create a delivery task")
    await independentTasks.drain()
    try require(independentDeliveries == 1, "Changing another rule reset sustained alert time")
    var paused = snapshot(91, at: start.addingTimeInterval(17))
    paused.isSuspended = true
    independent.accept(paused, now: start.addingTimeInterval(17))
    // The redraw can precede the post-wake readers. A placeholder publication
    // must not consume the baseline and then replay the first real hot sample.
    independent.accept(TelemetrySnapshot(), now: start.addingTimeInterval(18))
    independent.accept(snapshot(96, at: start.addingTimeInterval(19)), now: start.addingTimeInterval(19))
    await independentTasks.drain()
    try require(independentDeliveries == 1, "Short sleep replayed a critical alert")

    // Direct jumps have one immediate critical delivery. A downgrade within
    // the critical cooldown cannot produce a redundant attention notification.
    let severityTasks = NotificationFixtureTasks()
    var severityDeliveries: [String] = []
    let severityCenter = HealthAlertCenter(runtimeServicesEnabled: false,
      fixtureDelivery: { severityDeliveries.append($0.id) },
      fixtureTaskObserver: { severityTasks.observe($0) })
    defer { severityCenter.shutdown() }
    severityCenter.accept(snapshot(85, at: start), now: start)
    let jump = start.addingTimeInterval(1)
    severityCenter.accept(snapshot(97, at: jump), now: jump)
    await severityTasks.drain()
    try require(severityDeliveries == ["soc-critical"], "85 -> 97 produced redundant severity notifications")
    for second in 2...25 {
      let date = start.addingTimeInterval(Double(second))
      severityCenter.accept(snapshot(90, at: date), now: date)
      await severityTasks.drain()
    }
    try require(severityDeliveries == ["soc-critical"], "Critical -> high downgrade created notification spam")

    // A warning queued but not yet enqueued must be cancelled by escalation.
    let escalationTasks = NotificationFixtureTasks()
    var escalationDeliveries: [String] = []
    let escalationCenter = HealthAlertCenter(runtimeServicesEnabled: false,
      fixtureDelivery: { escalationDeliveries.append($0.id) },
      fixtureTaskObserver: { escalationTasks.observe($0) })
    defer { escalationCenter.shutdown() }
    escalationCenter.accept(snapshot(85, at: start), now: start)
    for (second, temperature) in [(1.0, 91.0), (16.0, 91.0), (17.0, 97.0)] {
      let date = start.addingTimeInterval(second)
      escalationCenter.accept(snapshot(temperature, at: date), now: date)
    }
    await escalationTasks.drain()
    try require(escalationDeliveries == ["soc-critical"], "Escalation failed to cancel pending warning delivery")

    // All cancellations happen synchronously on MainActor before the created
    // delivery task gets its first turn. Await the captured handle even though
    // cancellation removes it from the center's own task dictionary.
    for action in ["resolve", "sleep", "shutdown", "configuration", "reactivate",
      "threshold-no-publication", "unrelated-threshold-no-publication"] {
      let canceledTasks = NotificationFixtureTasks()
      var deliveries = 0
      let settings = NotificationFixtureConfiguration()
      let canceled = HealthAlertCenter(runtimeServicesEnabled: false,
        configuration: { settings.value }, fixtureDelivery: { _ in deliveries += 1 },
        fixtureTaskObserver: { canceledTasks.observe($0) })
      canceled.accept(snapshot(60, at: start), now: start)
      canceled.accept(snapshot(96, at: start.addingTimeInterval(1)), now: start.addingTimeInterval(1))
      try require(canceledTasks.tasks.count == 1, "Cancellation fixture must schedule a task: \(action)")
      let canceledAt = start.addingTimeInterval(2)
      switch action {
      case "shutdown": canceled.shutdown()
      case "sleep":
        var sleeping = snapshot(96, at: canceledAt)
        sleeping.isSuspended = true
        canceled.accept(sleeping, now: canceledAt)
      case "configuration":
        settings.value[.socCritical] = HealthAlertSetting(enabled: false, threshold: 95)
        canceled.accept(snapshot(96, at: canceledAt), now: canceledAt)
      case "threshold-no-publication":
        settings.value[.socCritical] = HealthAlertSetting(enabled: true, threshold: 100)
      case "unrelated-threshold-no-publication":
        settings.value[.batteryHealthCritical] = HealthAlertSetting(enabled: true, threshold: 60)
      default:
        canceled.accept(snapshot(60, at: canceledAt), now: canceledAt)
      }
      if action == "reactivate" {
        let reactivatedAt = start.addingTimeInterval(3)
        canceled.accept(snapshot(96, at: reactivatedAt), now: reactivatedAt)
        try require(canceledTasks.tasks.count == 2, "Capture both activation task handles")
      }
      await canceledTasks.drain()
      let expected = action == "reactivate" || action == "unrelated-threshold-no-publication" ? 1 : 0
      try require(deliveries == expected, "Per-rule delivery invalidation failed: \(action)")
      try require(canceled.events.filter { $0.change == .notified }.count == expected,
        "Canceled activation recorded delivery: \(action)")
      canceled.shutdown()
    }

    // Cancellation after entering delivery cannot retract that call, but both
    // the success and failure paths must ignore stale activation bookkeeping.
    for (action, failDelivery) in [
      ("resolve", false), ("resolve", true),
      ("threshold-no-publication", false), ("threshold-no-publication", true),
    ] {
      let settings = NotificationFixtureConfiguration()
      let inFlightTasks = NotificationFixtureTasks()
      let (started, startDelivery) = AsyncStream<Void>.makeStream()
      let (released, releaseDelivery) = AsyncStream<Void>.makeStream()
      var entries = 0
      let inFlight = HealthAlertCenter(runtimeServicesEnabled: false,
        configuration: { settings.value }, fixtureDelivery: { _ in
        entries += 1
        startDelivery.yield(())
        startDelivery.finish()
        var releaseIterator = released.makeAsyncIterator()
        _ = await releaseIterator.next()
        if failDelivery { throw TelemetryError.unavailable("late fixture failure") }
      }, fixtureTaskObserver: { inFlightTasks.observe($0) })
      let deadline = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        fatalError("In-flight notification fixture did not complete within five seconds")
      }
      defer { deadline.cancel(); inFlight.shutdown() }
      inFlight.accept(snapshot(60, at: start), now: start)
      inFlight.accept(snapshot(96, at: start.addingTimeInterval(1)), now: start.addingTimeInterval(1))
      var startIterator = started.makeAsyncIterator()
      guard await startIterator.next() != nil else {
        throw CheckFailure(description: "In-flight fixture did not enter delivery")
      }
      if action == "threshold-no-publication" {
        settings.value[.socCritical] = HealthAlertSetting(enabled: true, threshold: 100)
      } else {
        inFlight.accept(snapshot(60, at: start.addingTimeInterval(2)), now: start.addingTimeInterval(2))
      }
      releaseDelivery.yield(())
      releaseDelivery.finish()
      await inFlightTasks.drain()
      try require(entries == 1 && !inFlight.deliveryFailed,
        "Stale post-await completion must not record success or failure")
      try require(!inFlight.events.contains { $0.change == .notified },
        "Resolved in-flight activation must not write cooldown history")
      deadline.cancel()
    }

    let attention = HealthIssue(id: "soc-hot", severity: .attention, title: "Heat", detail: "fixture")
    let critical = HealthIssue(id: "soc-critical", severity: .critical, title: "Heat", detail: "fixture")
    for issue in [attention, critical] {
      let cooldown = HealthNotificationPolicy.repeatCooldown(for: issue)
      for (offset, expected) in [(-0.001, false), (0.0, true), (0.001, true)] {
        try require(HealthNotificationPolicy.activationAllowsNotification(issue: issue,
          activeSince: start.addingTimeInterval(cooldown + offset), lastNotifiedAt: start) == expected,
          "Exact activation cooldown boundary: \(issue.id), \(offset)")
      }
      try require(!HealthNotificationPolicy.activationAllowsNotification(issue: issue,
        activeSince: start.addingTimeInterval(-1), lastNotifiedAt: start),
        "A backwards activation timestamp must not bypass cooldown")
    }

    // The warning near expiry is the inherited sustain boundary gap. Delaying
    // persisted history until after activation additionally tests readiness.
    for historyReadiness in ["ready", "delayed", "delayed-with-missing-sample"] {
      let delayedHistory = historyReadiness != "ready"
      for (temperature, issueID, cooldown, sustain) in [
        (91.0, "soc-hot", 1800.0, 15.0), (96.0, "soc-critical", 600.0, 0.0)
      ] {
        for offset in [-1.0, 0.0, 1.0] {
          let historyTasks = NotificationFixtureTasks()
          var deliveries = 0
          let record = HealthEventRecord(capturedAt: start, change: .notified,
            issueID: issueID, severity: temperature == 91 ? 1 : 2,
            title: "Previous enqueue", detail: "fixture")
          let cooled = HealthAlertCenter(runtimeServicesEnabled: false,
            fixtureDelivery: { _ in deliveries += 1 }, fixtureHistory: { [record] },
            fixtureTaskObserver: { historyTasks.observe($0) })
          if !delayedHistory { await historyTasks.drain() }
          // Warning starts ten seconds before expiry; sustain ends five seconds
          // after expiry. The exact boundary and just-after remain eligible.
          let activationOffset = cooldown + (offset < 0 && sustain > 0 ? -10 : offset)
          let activatedAt = start.addingTimeInterval(activationOffset)
          let baselineAt = activatedAt.addingTimeInterval(-1)
          cooled.accept(snapshot(60, at: baselineAt), now: baselineAt)
          cooled.accept(snapshot(temperature, at: activatedAt), now: activatedAt)
          let readinessDelay = historyReadiness == "delayed-with-missing-sample" ? 20.0 : 0.0
          if readinessDelay > 0 {
            let missingAt = activatedAt.addingTimeInterval(readinessDelay)
            cooled.accept(TelemetrySnapshot(), now: missingAt)
          }
          if delayedHistory { await historyTasks.drain() }
          if readinessDelay > 0 {
            let returnedAt = activatedAt.addingTimeInterval(readinessDelay)
            cooled.accept(snapshot(temperature, at: returnedAt), now: returnedAt)
          }
          let eligibleAt = activatedAt.addingTimeInterval(readinessDelay + sustain)
          cooled.accept(snapshot(temperature, at: eligibleAt), now: eligibleAt)
          await historyTasks.drain()
          let expected = offset < 0 ? 0 : 1
          try require(deliveries == expected,
            "Activation cooldown boundary: \(issueID), \(offset), readiness=\(historyReadiness)")
          for elapsed in [20.0, 40.0, 60.0] {
            let date = eligibleAt.addingTimeInterval(elapsed)
            cooled.accept(snapshot(temperature, at: date), now: date)
            await historyTasks.drain()
          }
          try require(deliveries == expected, "Cooldown suppression must last the whole activation")
          try require(cooled.events.filter { $0.change == .notified }.count == expected + 1,
            "Cooldown history must record only successful enqueue")
          cooled.shutdown()
        }
      }
    }

  }

  /// Real observation types, isolated to one enabled rule by the caller.
  private static func notificationObservation(_ rule: HealthAlertRule, triggering: Bool,
    at date: Date, fieldMissing: Bool = false) -> TelemetrySnapshot {
    var snapshot = TelemetrySnapshot()
    switch rule {
    case .socHot, .socCritical:
      snapshot.thermals = MetricSample(.success(ThermalMetrics(readings: fieldMissing ? [] : [
        ThermalReading(key: "Tp01", group: .performanceCPU, celsius: triggering ? 96 : 60)
      ], failures: [:])), capturedAt: date)
    case .batteryHealthLow, .batteryHealthCritical, .batteryTempHot, .batteryTempCritical:
      snapshot.battery = MetricSample(.success(BatteryMetrics(
        designCapacityMAh: .success(6_000), maximumCapacityMAh: fieldMissing
          ? .failure(.unavailable("fixture capacity")) : .success(triggering ? 3_600 : 5_700),
        currentCapacityMAh: .success(3_000), cycleCount: .success(100),
        temperatureCelsius: fieldMissing ? .failure(.unavailable("fixture temperature"))
          : .success(triggering ? 51 : 30),
        power: .success(BatteryPower(signedWatts: -5, usesInstantaneousCurrent: true))
      )), capturedAt: date)
    case .memoryWarning, .memoryCritical:
      snapshot.memory = MetricSample(.success(MemoryMetrics(
        physicalBytes: 16 << 30, activeBytes: 4 << 30, inactiveBytes: 4 << 30,
        wiredBytes: 2 << 30, compressedBytes: 1 << 30, freeBytes: 5 << 30,
        pressure: fieldMissing ? .failure(.unavailable("fixture pressure"))
          : .success(triggering ? (rule == .memoryWarning ? .warning : .critical) : .normal)
      )), capturedAt: date)
    case .thermalSerious, .thermalCritical:
      snapshot.system = MetricSample(.success(SystemMetrics(
        modelIdentifier: .success("fixture"), chipName: .success("fixture"), osVersion: "fixture",
        uptimeSeconds: 1_000, logicalProcessorCount: 10, physicalMemoryBytes: 16 << 30,
        loadAverage1: .success(1), loadAverage5: .success(1), loadAverage15: .success(1),
        thermalState: triggering ? (rule == .thermalSerious ? .serious : .critical) : .nominal,
        lowPowerModeEnabled: false
      )), capturedAt: date)
      if fieldMissing { snapshot.system = MetricSample(.failure(.unavailable("fixture system")), capturedAt: date) }
    case .ssdTempHot, .ssdTempCritical, .smartAttention, .smartCritical, .mediaErrors:
      snapshot.storage = MetricSample(.success(StorageMetrics(
        rootVolume: .failure(.unavailable("fixture")), devices: [], primaryDeviceBSDName: nil,
        throughput: .failure(.warmingUp), smartHealth: fieldMissing
          ? .failure(.unavailable("fixture SMART")) : .success(NVMeSMARTHealth(
          criticalWarning: triggering && rule == .smartCritical ? 1 : 0,
          temperatureCelsius: triggering ? 81 : 35, availableSparePercent: 100,
          availableSpareThresholdPercent: 10,
          percentageUsed: triggering && rule == .smartAttention ? 85 : 5,
          dataUnitsRead: NVMeCounter128(low: 0, high: 0),
          dataUnitsWritten: NVMeCounter128(low: 0, high: 0),
          hostReadCommands: NVMeCounter128(low: 0, high: 0),
          hostWriteCommands: NVMeCounter128(low: 0, high: 0),
          controllerBusyMinutes: NVMeCounter128(low: 0, high: 0),
          powerCycles: NVMeCounter128(low: 0, high: 0),
          powerOnHours: NVMeCounter128(low: 0, high: 0),
          unsafeShutdowns: NVMeCounter128(low: 0, high: 0),
          mediaErrors: NVMeCounter128(low: triggering && rule == .mediaErrors ? 1 : 0, high: 0),
          errorLogEntries: NVMeCounter128(low: 0, high: 0)
        )), smartHealthCapturedTicks: nil
      )), capturedAt: date)
    }
    return snapshot
  }

  @MainActor
  private static func notificationObservationChecks() async throws {
    let start = Date()
    for rule in HealthAlertRule.allCases {
      var settings = HealthAlertConfiguration.defaults
      for other in HealthAlertRule.allCases {
        settings[other] = HealthAlertSetting(enabled: other == rule, threshold: other.defaultThreshold)
      }
      let configuration = settings
      let active = HealthEvaluator.evaluate(notificationObservation(rule, triggering: true, at: start),
        now: start, configuration: configuration)
      try require(active.count == 1 && active[0].id == rule.rawValue,
        "Observation fixture must activate exactly its own rule: \(rule)")
      let sustain = HealthNotificationPolicy.minimumActiveDuration(for: active[0])
      let queuedAt = start.addingTimeInterval(1 + sustain)
      // Late history arrives after the cooldown expires. Missing evidence must
      // not replace the original pre-expiry activation time for any rule type.
      let historyTasks = NotificationFixtureTasks()
      var historyDeliveries = 0
      let prior = HealthEventRecord(capturedAt: start, change: .notified, issueID: rule.rawValue,
        severity: active[0].severity.rawValue, title: "Prior enqueue", detail: "fixture")
      let cooled = HealthAlertCenter(runtimeServicesEnabled: false,
        configuration: { configuration }, fixtureDelivery: { _ in historyDeliveries += 1 },
        fixtureHistory: { [prior] }, fixtureTaskObserver: { historyTasks.observe($0) },
        fixtureObservationClock: { start })
      defer { cooled.shutdown() }
      let preExpiry = start.addingTimeInterval(HealthNotificationPolicy.repeatCooldown(for: active[0]) - 1)
      cooled.accept(notificationObservation(rule, triggering: false, at: preExpiry.addingTimeInterval(-1)),
        now: preExpiry.addingTimeInterval(-1))
      cooled.accept(notificationObservation(rule, triggering: true, at: preExpiry), now: preExpiry)
      let missingAt = preExpiry.addingTimeInterval(2)
      cooled.accept(notificationObservation(rule, triggering: true, at: missingAt, fieldMissing: true),
        now: missingAt)
      try require(!cooled.events.contains { $0.change == .resolved },
        "Delayed history fixture must retain unresolved latch: \(rule)")
      await historyTasks.drain()
      let historyReadyAt = missingAt.addingTimeInterval(1)
      cooled.accept(notificationObservation(rule, triggering: true, at: historyReadyAt), now: historyReadyAt)
      let sustainedAt = historyReadyAt.addingTimeInterval(sustain)
      cooled.accept(notificationObservation(rule, triggering: true, at: sustainedAt), now: sustainedAt)
      await historyTasks.drain()
      try require(historyDeliveries == 0 && cooled.events.filter { $0.change == .notified }.count == 1,
        "Observation loss must preserve original activation-time cooldown: \(rule)")
      for loss in ["missing", "stale", "field-missing"] {
        let lostAt = queuedAt.addingTimeInterval(1)
        let missing = loss == "missing" ? TelemetrySnapshot()
          : notificationObservation(rule, triggering: true,
            at: loss == "stale" ? lostAt.addingTimeInterval(-60) : lostAt,
            fieldMissing: loss == "field-missing")
        try require(!rule.hasCurrentObservation(in: missing, now: lostAt),
          "Loss fixture must lack a current observation: \(rule), \(loss)")

        // No suspension occurs between scheduling and invalidation. Captured
        // task handles prove the cancelled task actually finishes without enqueue.
        let tasks = NotificationFixtureTasks()
        let clock = NotificationFixtureClock(start)
        var deliveries = 0
        let center = HealthAlertCenter(runtimeServicesEnabled: false,
          configuration: { configuration }, fixtureDelivery: { _ in deliveries += 1 },
          fixtureTaskObserver: { tasks.observe($0) }, fixtureObservationClock: { clock.now })
        defer { center.shutdown() }
        center.accept(notificationObservation(rule, triggering: false, at: start), now: start)
        let activatedAt = start.addingTimeInterval(1)
        center.accept(notificationObservation(rule, triggering: true, at: activatedAt), now: activatedAt)
        center.accept(notificationObservation(rule, triggering: true, at: queuedAt), now: queuedAt)
        try require(tasks.tasks.count == 1, "Expected before-start task: \(rule), \(loss)")
        center.accept(missing, now: lostAt)
        await tasks.drain()
        try require(deliveries == 0 && center.issues.map(\.id) == [rule.rawValue],
          "Observation loss must cancel enqueue and preserve latch: \(rule), \(loss)")
        try require(center.events.map(\.change) == [.activated],
          "Observation loss must not resolve or notify: \(rule), \(loss)")
        let returnedAt = lostAt.addingTimeInterval(1)
        center.accept(notificationObservation(rule, triggering: true, at: returnedAt), now: returnedAt)
        if sustain > 0 {
          let early = returnedAt.addingTimeInterval(sustain - 0.001)
          center.accept(notificationObservation(rule, triggering: true, at: early), now: early)
          try require(tasks.tasks.isEmpty, "Returning data must restart sustain: \(rule), \(loss)")
        }
        let eligibleAt = returnedAt.addingTimeInterval(sustain)
        center.accept(notificationObservation(rule, triggering: true, at: eligibleAt), now: eligibleAt)
        await tasks.drain()
        try require(deliveries == 1 && center.events.filter { $0.change == .activated }.count == 1,
          "Returning condition must retain activation and become eligible: \(rule), \(loss)")
        let recoveredAt = eligibleAt.addingTimeInterval(1)
        center.accept(notificationObservation(rule, triggering: false, at: recoveredAt), now: recoveredAt)
        try require(center.issues.isEmpty && center.events.filter { $0.change == .resolved }.count == 1,
          "Only fresh nontriggering evidence clears latch: \(rule), \(loss)")
        center.accept(notificationObservation(rule, triggering: true, at: recoveredAt.addingTimeInterval(1)),
          now: recoveredAt.addingTimeInterval(1))
        try require(center.events.filter { $0.change == .activated }.count == 2,
          "Fresh recovery must rearm the rule: \(rule), \(loss)")
        await tasks.drain()
        try require(deliveries == 1, "Recovery must retain repeat cooldown: \(rule), \(loss)")

        // A startup condition stays silent across an unobserved interval.
        let silentTasks = NotificationFixtureTasks()
        var silentDeliveries = 0
        let silent = HealthAlertCenter(runtimeServicesEnabled: false,
          configuration: { configuration }, fixtureDelivery: { _ in silentDeliveries += 1 },
          fixtureTaskObserver: { silentTasks.observe($0) }, fixtureObservationClock: { start })
        defer { silent.shutdown() }
        silent.accept(notificationObservation(rule, triggering: true, at: queuedAt), now: queuedAt)
        silent.accept(missing, now: lostAt)
        silent.accept(notificationObservation(rule, triggering: true, at: returnedAt), now: returnedAt)
        silent.accept(notificationObservation(rule, triggering: true, at: eligibleAt), now: eligibleAt)
        await silentTasks.drain()
        try require(silentDeliveries == 0 && silent.events.isEmpty,
          "Missing source must not replay startup or create transitions: \(rule), \(loss)")

        // Suspend inside delivery on an explicit continuation. Cancellation cannot
        // release this gate; the fixture decides when success/failure returns.
        for (failDelivery, replaceBeforeCompletion) in [(false, false), (true, false), (false, true), (true, true)] {
          let suspendedTasks = NotificationFixtureTasks()
          let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
          var release: CheckedContinuation<Void, Never>?
          var entries = 0
          let suspended = HealthAlertCenter(runtimeServicesEnabled: false,
            configuration: { configuration }, fixtureDelivery: { _ in
              entries += 1
              if entries == 1 {
                await withCheckedContinuation { continuation in
                  release = continuation
                  enteredSignal.yield(())
                  enteredSignal.finish()
                }
                if failDelivery { throw TelemetryError.unavailable("late observation-loss fixture") }
              }
            }, fixtureTaskObserver: { suspendedTasks.observe($0) }, fixtureObservationClock: { start })
          let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            fatalError("Observation-loss fixture never entered delivery")
          }
          defer { deadline.cancel(); suspended.shutdown() }
          suspended.accept(notificationObservation(rule, triggering: false, at: start), now: start)
          suspended.accept(notificationObservation(rule, triggering: true, at: activatedAt), now: activatedAt)
          suspended.accept(notificationObservation(rule, triggering: true, at: queuedAt), now: queuedAt)
          var iterator = entered.makeAsyncIterator()
          guard await iterator.next() != nil, let continuation = release else {
            throw CheckFailure(description: "Observation-loss fixture did not suspend: \(rule)")
          }
          suspended.accept(missing, now: lostAt)
          try require(suspended.events.map(\.change) == [.activated]
            && suspended.issues.map(\.id) == [rule.rawValue],
            "Suspended loss must retain latch without recovery: \(rule), \(loss)")
          if replaceBeforeCompletion {
            suspended.accept(notificationObservation(rule, triggering: true, at: returnedAt), now: returnedAt)
            suspended.accept(notificationObservation(rule, triggering: true, at: eligibleAt), now: eligibleAt)
            try require(suspendedTasks.tasks.count == 2,
              "Replacement must be captured while cancelled delivery is suspended: \(rule), \(loss)")
          }
          continuation.resume()
          release = nil
          await suspendedTasks.drain()
          deadline.cancel()
          try require(entries == (replaceBeforeCompletion ? 2 : 1) && !suspended.deliveryFailed
            && suspended.events.filter { $0.change == .notified }.count == (replaceBeforeCompletion ? 1 : 0)
            && suspended.events.filter { $0.change == .resolved }.isEmpty
            && suspended.events.filter { $0.change == .activated }.count == 1,
            "Lost-source completion must not update history/cooldown/retry: \(rule), \(loss), \(failDelivery)")
          if !replaceBeforeCompletion {
            suspended.accept(notificationObservation(rule, triggering: true, at: returnedAt), now: returnedAt)
            suspended.accept(notificationObservation(rule, triggering: true, at: eligibleAt), now: eligibleAt)
          }
          await suspendedTasks.drain()
          try require(entries == 2 && suspended.events.filter { $0.change == .notified }.count == 1,
            "Ignored completion must not consume cooldown or impose retry: \(rule), \(loss), \(failDelivery)")
        }
      }
      // Expiry between publications must be checked at actual enqueue/completion,
      // not only by accept(). Advance an injected clock without sleeping/yielding.
      for stage in ["before-start", "suspended-success", "suspended-failure"] {
        let tasks = NotificationFixtureTasks()
        let clock = NotificationFixtureClock(start)
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var entries = 0
        let center = HealthAlertCenter(runtimeServicesEnabled: false,
          configuration: { configuration }, fixtureDelivery: { _ in
            entries += 1
            if stage != "before-start" && entries == 1 {
              await withCheckedContinuation { continuation in
                release = continuation
                enteredSignal.yield(())
                enteredSignal.finish()
              }
              if stage == "suspended-failure" { throw TelemetryError.unavailable("expired fixture") }
            }
          }, fixtureTaskObserver: { tasks.observe($0) }, fixtureObservationClock: { clock.now })
        let deadline = Task { @MainActor in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          fatalError("Expiry fixture did not finish")
        }
        defer { deadline.cancel(); center.shutdown() }
        center.accept(notificationObservation(rule, triggering: false, at: start), now: start)
        let activatedAt = start.addingTimeInterval(1)
        center.accept(notificationObservation(rule, triggering: true, at: activatedAt), now: activatedAt)
        center.accept(notificationObservation(rule, triggering: true, at: queuedAt), now: queuedAt)
        try require(tasks.tasks.count == 1, "Expiry fixture must schedule: \(rule), \(stage)")
        if stage != "before-start" {
          var iterator = entered.makeAsyncIterator()
          guard await iterator.next() != nil, release != nil else {
            throw CheckFailure(description: "Expiry fixture did not enter delivery")
          }
        }
        clock.now = start.addingTimeInterval(61)
        release?.resume()
        release = nil
        await tasks.drain()
        try require(entries == (stage == "before-start" ? 0 : 1) && !center.deliveryFailed
          && center.events.map(\.change) == [.activated] && center.issues.map(\.id) == [rule.rawValue],
          "Expiry must invalidate enqueue/completion while retaining latch: \(rule), \(stage)")
        let returnedAt = queuedAt.addingTimeInterval(1)
        center.accept(notificationObservation(rule, triggering: true, at: returnedAt), now: returnedAt)
        if sustain > 0 {
          try require(tasks.tasks.isEmpty, "Expiry must restart sustain: \(rule), \(stage)")
        }
        let eligibleAt = returnedAt.addingTimeInterval(sustain)
        center.accept(notificationObservation(rule, triggering: true, at: eligibleAt), now: eligibleAt)
        await tasks.drain()
        try require(entries == (stage == "before-start" ? 1 : 2)
          && center.events.filter { $0.change == .notified }.count == 1,
          "Expired task must not block replacement or consume cooldown/retry: \(rule), \(stage)")
      }
    }
  }

  private static func healthEventChecks() async throws {
    let start = Date(timeIntervalSince1970: 50_000)
    let old = HealthIssue(id: "old", severity: .attention, title: "Old warning", detail: "old")
    let new = HealthIssue(id: "new", severity: .critical, title: "New warning", detail: "new")
    let transition = HealthEventEngine.transitionRecords(
      previous: [old.id: old], current: [new], now: start)
    try require(transition.newlyActive.map(\.id) == ["new"], "Health transition activation")
    try require(
      Set(transition.records.map(\.change)) == Set([.activated, .resolved]),
      "Health transition activation/resolution records")

    let stale = HealthEventRecord(
      capturedAt: start.addingTimeInterval(-HealthEventEngine.retention - 1), change: .activated,
      issueID: "stale", severity: 1, title: "Stale", detail: "")
    let currentA = HealthEventRecord(
      capturedAt: start.addingTimeInterval(-30), change: .activated, issueID: "a", severity: 1,
      title: "A", detail: "")
    let currentB = HealthEventRecord(
      capturedAt: start, change: .resolved, issueID: "a", severity: 1, title: "A", detail: "")
    let clean = HealthEventEngine.sanitized([stale, currentA, currentB], now: start)
    try require(clean.count == 2 && clean.first?.issueID == "a", "Health event retention")

    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Helios-HealthEvents-\(UUID().uuidString).ndjson")
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = HealthEventStore(url: temp)
    let stored = await store.append([currentA, currentB], now: start)
    try require(stored.count == 2, "Health event append")
    let reloaded = await HealthEventStore(url: temp).current(now: start)
    try require(reloaded == stored, "Health event reload")

    var data = (try? Data(contentsOf: temp)) ?? Data()
    data.append(Data("{malformed-tail".utf8))
    try data.write(to: temp)
    let tolerant = HealthEventStore(url: temp)
    let tolerantHistory = await tolerant.current(now: start)
    try require(
      tolerantHistory.count == 2, "Malformed health event tail must not erase valid events")
    let later = HealthEventRecord(
      capturedAt: start.addingTimeInterval(30), change: .activated, issueID: "b", severity: 2,
      title: "B", detail: "")
    let recovered = await tolerant.append([later], now: start.addingTimeInterval(30))
    try require(
      recovered.count == 3 && recovered.last?.issueID == "b", "Health event malformed-tail recovery"
    )
  }

  private static func systemChecks() throws {
    try require(SystemInfoReader.thermalState(.nominal) == .nominal, "Nominal thermal mapping")
    try require(SystemInfoReader.thermalState(.fair) == .fair, "Fair thermal mapping")
    try require(SystemInfoReader.thermalState(.serious) == .serious, "Serious thermal mapping")
    try require(SystemInfoReader.thermalState(.critical) == .critical, "Critical thermal mapping")
    try require(
      TelemetryFormatting.bitsPerSecond(1_000_000_000) == "1.0 Gb/s", "Network link formatting")
    try require(
      TelemetryFormatting.duration(90) == "1m" && TelemetryFormatting.duration(7_200) == "2h 0m",
      "Duration formatting")
    try require(
      TelemetryFormatting.batteryTimeRemaining(.unlimited) == "On AC"
        && TelemetryFormatting.batteryTimeRemaining(.calculating) == "Calculating",
      "Battery estimate states")
  }

  private static func storageChecks() throws {
    let counters = try StorageParser.counters([
      "Bytes (Read)": NSNumber(value: UInt64(1_000_000)),
      "Bytes (Write)": NSNumber(value: UInt64(2_000_000)),
      "Operations (Read)": 10,
      "Operations (Write)": 20,
      "Errors (Read)": 0,
      "Errors (Write)": 1,
    ])
    try require(
      counters.bytesRead == 1_000_000 && counters.bytesWritten == 2_000_000, "Storage byte counters"
    )
    try require(
      counters.readOperations == 10 && counters.writeOperations == 20 && counters.writeErrors == 1,
      "Storage operation/error counters")
    let minimal = try StorageParser.counters(["Bytes (Read)": 1, "Bytes (Write)": 2])
    try require(
      minimal.readOperations == 0 && minimal.writeErrors == 0,
      "Optional storage counters default to zero")
    for invalid: Any in [true, -1, 1.5, "12"] {
      try expectTelemetryFailure {
        try StorageParser.counters(["Bytes (Read)": invalid, "Bytes (Write)": 2])
      }
    }
    try expectTelemetryFailure { try StorageParser.counters(["Bytes (Read)": 1]) }

    let volume = try StorageParser.rootVolume([
      .systemSize: NSNumber(value: UInt64(1_000)), .systemFreeSize: NSNumber(value: UInt64(250)),
    ])
    try require(
      volume.totalBytes == 1_000 && volume.freeBytes == 250 && volume.usedBytes == 750,
      "Root volume arithmetic")
    try expectTelemetryFailure {
      try StorageParser.rootVolume([.systemSize: 100, .systemFreeSize: 101])
    }
    try expectTelemetryFailure { try StorageParser.rootVolume([:]) }

    try require(
      StorageParser.smartCapability(nvme: true, ata: false) == .nvmeAdvertised,
      "NVMe SMART capability")
    try require(
      StorageParser.smartCapability(nvme: false, ata: true) == .ataAdvertised,
      "ATA SMART capability")
    try require(
      StorageParser.smartCapability(nvme: false, ata: false) == .notAdvertised,
      "Unadvertised SMART capability")

    var rate = StorageRateCalculator()
    try expectTelemetryFailure { try rate.consume(counters, elapsedSeconds: 2).get() }
    let next = StorageIOCounters(
      bytesRead: 1_004_000, bytesWritten: 2_008_000, readOperations: 12, writeOperations: 24,
      readErrors: 0, writeErrors: 1)
    let throughput = try rate.consume(next, elapsedSeconds: 2).get()
    try require(
      close(throughput.readBytesPerSecond, 2_000) && close(throughput.writeBytesPerSecond, 4_000),
      "Storage throughput delta")
    let rolledBack = StorageIOCounters(
      bytesRead: 1, bytesWritten: 1, readOperations: 0, writeOperations: 0, readErrors: 0,
      writeErrors: 0)
    try expectTelemetryFailure { try rate.consume(rolledBack, elapsedSeconds: 2).get() }
    rate.reset()
    try expectTelemetryFailure { try rate.consume(counters, elapsedSeconds: 2).get() }
    try expectTelemetryFailure { try rate.consume(next, elapsedSeconds: 0).get() }

    let internalDevice = StorageDeviceMetrics(
      registryID: 1, bsdName: "disk0", model: "APPLE SSD", capacityBytes: 1_000,
      isInternal: true, isRemovable: false, transport: "Apple Fabric",
      controllerClass: "AppleANSController",
      smartCapability: .nvmeAdvertised, counters: .success(counters)
    )
    let externalDevice = StorageDeviceMetrics(
      registryID: 2, bsdName: "disk4", model: "External NVMe", capacityBytes: 2_000,
      isInternal: false, isRemovable: true, transport: "USB",
      controllerClass: "IOBlockStorageDevice",
      smartCapability: .notAdvertised, counters: .success(counters)
    )
    let diskImage = StorageDeviceMetrics(
      registryID: 3, bsdName: "disk5", model: "Disk Image", capacityBytes: 3_000,
      isInternal: false, isRemovable: true, transport: "Virtual Interface",
      controllerClass: "IOBlockStorageDriver",
      smartCapability: .notAdvertised, counters: .success(counters)
    )
    let inventory = StorageMetrics(
      rootVolume: .success(volume), devices: [internalDevice, externalDevice, diskImage],
      primaryDeviceBSDName: "disk0", throughput: .failure(.warmingUp),
      smartHealth: .failure(.unavailable("fixture")), smartHealthCapturedTicks: nil
    )
    try require(
      inventory.externalPhysicalDevices.map(\.bsdName) == ["disk4"],
      "Disk images must not appear as physical external storage")
  }

  private static func smcChecks() throws {
    try require(
      try close(SMCCodec.temperature(type: "sp78", bytes: [0x19, 0x80]), 25.5),
      "sp78 positive fraction")
    try require(
      try close(SMCCodec.temperature(type: "sp78", bytes: [0xff, 0x80]), -0.5),
      "sp78 signed fraction")
    try require(
      try close(SMCCodec.temperature(type: "flt ", bytes: [0x00, 0x00, 0x42, 0x42]), 48.5),
      "SMC float is little endian")
    try require(
      try close(SMCCodec.numeric(type: "sp78", bytes: [0x19, 0x80]), 25.5),
      "Generic signed fixed-point sp78")
    try require(
      try close(SMCCodec.numeric(type: "sp87", bytes: [0x0c, 0xc0]), 25.5),
      "Generic signed fixed-point sp87")
    try require(
      try close(SMCCodec.numeric(type: "fpe2", bytes: [0x00, 0x66]), 25.5),
      "Generic unsigned fixed-point fpe2")
    try require(
      try close(SMCCodec.numeric(type: "flt ", bytes: [0x00, 0x00, 0x42, 0x42]), 48.5),
      "Generic SMC float")
    try require(
      try close(SystemPowerParser.watts(type: "sp78", bytes: [0x0c, 0x80]), 12.5),
      "PSTR fixed-point power decoding")
    try expectTelemetryFailure { try SystemPowerParser.watts(type: "sp78", bytes: [0xff, 0x00]) }
    try expectTelemetryFailure { try SystemPowerParser.watts(type: "ui16", bytes: [0x02, 0x01]) }
    for bytes in [word(Float.nan.bitPattern), word(Float.infinity.bitPattern), [0, 0, 0]] {
      try expectTelemetryFailure { try SMCCodec.temperature(type: "flt ", bytes: bytes) }
    }
    try expectTelemetryFailure { try SMCCodec.temperature(type: "sp78", bytes: [0]) }
    try expectTelemetryFailure { try SMCCodec.temperature(type: "ui16", bytes: [0, 1]) }
    try expectTelemetryFailure { try SMCCodec.fourCC("too long") }
    try expectTelemetryFailure { try SMCCodec.uint32([0, 1, 2], at: 0) }
    let request = try SMCCodec.frame(
      SMCReadRequest(command: .keyInfo, key: "Tp01", dataSize: 4, index: 17))
    try require(
      request.count == 80 && Array(request[0..<4]) == [0x31, 0x30, 0x70, 0x54],
      "Native SMC key field ABI")
    try require(
      request[28] == 4 && request[42] == 9 && request[44] == 17, "Native SMC command offsets")
    let m4Classifier = ThermalClassifier(cpuBrand: "Apple M4")
    let statsPKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
    let statsEKeys = ["Te05", "Te09", "Te0H", "Te0S"]
    let statsGPUKeys = ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k"]
    try require(
      statsPKeys.allSatisfy { m4Classifier.group(for: $0) == .performanceCPU },
      "An attributed Stats M4 P-zone mapping changed")
    try require(
      statsEKeys.allSatisfy { m4Classifier.group(for: $0) == .efficiencyCPU },
      "An attributed Stats M4 E-zone mapping changed")
    try require(
      statsGPUKeys.allSatisfy { m4Classifier.group(for: $0) == .gpu },
      "An attributed Stats M4 GPU-zone mapping changed")
    try require(
      m4Classifier.group(for: "TpZZ") == .unclassified,
      "Unknown Tp prefix became a trusted fan-control sensor")
    try require(
      ["Te06", "Te0T", "Tp0H"].allSatisfy { m4Classifier.group(for: $0) == .unclassified },
      "Issue-only keys must not be trusted without the exact validated hardware/build")

    let validatedClassifier = ThermalClassifier(
      cpuBrand: "Apple M4", machineModel: "Mac16,1", osBuild: "25G83")
    try require(
      validatedClassifier.group(for: "Te06") == .validatedHotspot
        && validatedClassifier.group(for: "Te0T") == .validatedHotspot,
      "Mac16,1 / 25G83 hotspots lost their independent trusted classification")
    try require(
      validatedClassifier.group(for: "Tp0H") == .unclassified,
      "Tp0H was incorrectly treated as independently validated Mac16,1 evidence")
    let wrongModel = ThermalClassifier(
      cpuBrand: "Apple M4", machineModel: "Mac16,2", osBuild: "25G83")
    let wrongBuild = ThermalClassifier(
      cpuBrand: "Apple M4", machineModel: "Mac16,1", osBuild: "25G84")
    try require(
      wrongModel.group(for: "Te06") == .unclassified
        && wrongBuild.group(for: "Te0T") == .unclassified,
      "Validated hotspot trust escaped the exact Mac16,1 / 25G83 scope")

    let displayFixtures = [
      ThermalReading(key: "TCMz", group: .unclassified, celsius: 66.6),
      ThermalReading(key: "TVMS", group: .unclassified, celsius: 90.8),
      ThermalReading(key: "TVmS", group: .unclassified, celsius: 72.0),
      ThermalReading(key: "TD14", group: .unclassified, celsius: 31.8),
      ThermalReading(key: "TDER", group: .unclassified, celsius: 31.4),
      ThermalReading(key: "Tm0p", group: .unclassified, celsius: 47.0),
      ThermalReading(key: "Ta01", group: .unclassified, celsius: 6.25),
      ThermalReading(key: "Ta05", group: .unclassified, celsius: 6.25),
      ThermalReading(key: "Ta09", group: .unclassified, celsius: 6.25),
      ThermalReading(key: "Txyz", group: .unclassified, celsius: 44.0),
    ]
    let displayClassified = ThermalDisplayClassifier.classify(displayFixtures)
    func displayKind(_ key: String) -> ThermalDisplayKind? {
      displayClassified.first(where: { $0.reading.key == key })?.info.kind
    }
    try require(
      ["TCMz", "TVMS", "TVmS", "TD14", "TDER", "Ta01", "Ta05", "Ta09", "Txyz"]
        .allSatisfy { displayKind($0) == .unknown },
      "Unsupported exact/family mappings must resolve to unclassified display semantics")
    try require(
      displayKind("Tm0p") == .knownAuxiliary,
      "Attributed Stats auxiliary key should retain its display mapping")
    try require(
      displayClassified.filter { $0.info.kind == .unknown }.allSatisfy {
        $0.info.title == "Unclassified SMC temperature"
          && $0.info.detail.contains("No meaning or safety role is inferred")
      },
      "Raw unknown keys must retain one provenance-safe generic presentation")
    try require(
      displayFixtures.allSatisfy { m4Classifier.group(for: $0.key) == .unclassified },
      "Display classification must never promote auxiliary/raw keys into fan-safety groups")
    let conservative = ThermalMetrics(
      readings: [
        ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 60),
        ThermalReading(key: "Te06", group: .validatedHotspot, celsius: 95),
        ThermalReading(key: "Tzzz", group: .unclassified, celsius: 120),
      ], failures: ["Tbad": .invalidData("fixture")], advisoryReadingsCapturedAt: Date())
    let conservativeMaximum = try conservative.maximumSoCReading.get()
    try require(
      conservativeMaximum.key == "Te06" && conservativeMaximum.group == .validatedHotspot
        && conservativeMaximum.celsius == 95,
      "Validated hotspot did not participate in conservative trusted Max SoC")
    try require(
      conservative.readings.count == 3 && conservative.failures.count == 1
        && conservative.advisoryReadingsCapturedAt != nil,
      "Thermal values, counts, failures, or advisory metadata disappeared")
    let hotspotFixtures = [
      SensorFixture(key: "Te06", type: "flt ", bytes: word(Float(70).bitPattern)),
      SensorFixture(key: "Te0T", type: "flt ", bytes: word(Float(65).bitPattern)),
      SensorFixture(key: "Tp0H", type: "flt ", bytes: word(Float(100).bitPattern)),
      SensorFixture(key: "Tzzz", type: "flt ", bytes: word(Float(110).bitPattern)),
    ]
    let hotspotTransport = FixtureTransport(hotspotFixtures)
    let hotspotReader = SMCThermalReader(
      client: SMCClient(transport: hotspotTransport), classifier: validatedClassifier)
    let hotspotFirst = try hotspotReader.read()
    try require(
      try hotspotFirst.maximumSoCReading.get().key == "Te06",
      "Validated hotspots did not drive the reader's trusted maximum")
    try require(
      hotspotFirst.readings.first(where: { $0.key == "Te0T" })?.group == .validatedHotspot,
      "Te0T lost validated-hotspot semantics in raw reader output")
    try require(
      hotspotFirst.readings.first(where: { $0.key == "Tp0H" })?.group == .unclassified,
      "Tp0H disappeared from raw telemetry or became trusted")
    let hotspotReadsAfterFirst = hotspotTransport.requests.filter {
      $0.command == .bytes && ($0.key == "Te06" || $0.key == "Te0T")
    }.count
    let tp0HReadsAfterFirst = hotspotTransport.requests.filter {
      $0.command == .bytes && $0.key == "Tp0H"
    }.count
    _ = try hotspotReader.read()
    try require(
      hotspotTransport.requests.filter {
        $0.command == .bytes && ($0.key == "Te06" || $0.key == "Te0T")
      }.count == hotspotReadsAfterFirst + 2,
      "Validated hotspots did not remain on the fast trusted cadence")
    try require(
      hotspotTransport.requests.filter { $0.command == .bytes && $0.key == "Tp0H" }.count
        == tp0HReadsAfterFirst,
      "Unvalidated Tp0H was promoted from advisory to fast trusted cadence")
    let fixtures = [
      SensorFixture(key: "Tp01", type: "flt ", bytes: word(Float(55).bitPattern)),
      SensorFixture(key: "Te05", type: "sp78", bytes: [40, 0]),
      SensorFixture(key: "Tg0G", type: "flt ", bytes: word(Float(45).bitPattern)),
      SensorFixture(key: "TpZZ", type: "flt ", bytes: word(Float(120).bitPattern)),
      SensorFixture(key: "Tzzz", type: "flt ", bytes: word(Float(90).bitPattern)),
      SensorFixture(key: "Tp05", type: "flt ", bytes: word(Float(0).bitPattern)),
      SensorFixture(key: "Tp09", type: "flt ", bytes: word(Float(151).bitPattern)),
      SensorFixture(key: "F0Tg", type: "fpe2", bytes: [0, 0]),
      SensorFixture(key: "Tbad", type: "ui32", bytes: [1, 2, 3, 4]),
    ]
    let transport = FixtureTransport(fixtures)
    let client = SMCClient(transport: transport)
    let reader = SMCThermalReader(
      client: client, classifier: ThermalClassifier(cpuBrand: "Apple M4 Pro"))
    let metrics = try reader.read()
    try require(
      try metrics.maximumSoCCelsius.get() == 55,
      "SoC maximum excludes unknown, inactive and invalid sensors")
    try require(
      metrics.readings.count == 5 && metrics.failures.count == 3,
      "Per-key validation retains good readings")
    try require(
      metrics.trustedFailures.count == 2
        && metrics.failures["Tbad"] != nil
        && metrics.trustedFailures["Tbad"] == nil,
      "Raw advisory failure evidence leaked into trusted thermal health")
    let hottest = try metrics.maximumSoCReading.get()
    try require(
      hottest.key == "Tp01" && hottest.group == .performanceCPU,
      "Max SoC source was not the hottest trusted M4 zone")
    try require(
      metrics.advisoryReadingsCapturedAt != nil,
      "Raw/unclassified thermal inventory must expose its relaxed-cadence capture time")
    let advisoryReadsAfterFirst =
      transport.requests.filter { $0.command == .bytes && $0.key == "Tzzz" }.count
    let trustedReadsAfterFirst =
      transport.requests.filter { $0.command == .bytes && $0.key == "Tg0G" }.count
    let indices = transport.requests.filter { $0.command == .keyAtIndex }.map(\.index)
    try require(
      indices == Array(0..<UInt32(fixtures.count)), "Discovery must enumerate count exclusively")
    try require(
      !transport.requests.contains { $0.key == "F0Tg" }, "Thermal discovery must not read fan data")
    transport.failingReads.insert("Tp01")
    let partial = try reader.read()
    try require(
      try partial.maximumSoCCelsius.get() == 45,
      "A failed hottest sensor must not retain stale values")
    try require(
      transport.requests.filter { $0.command == .bytes && $0.key == "Tzzz" }.count
        == advisoryReadsAfterFirst,
      "Diagnostic raw SMC sensors must not be re-read on every fast thermal poll")
    try require(
      transport.requests.filter { $0.command == .bytes && $0.key == "Tg0G" }.count
        == trustedReadsAfterFirst + 1,
      "Curated SoC sensors must remain fresh on every fast thermal poll")
    transport.failingReads.removeAll()
    try require(
      try reader.read().maximumSoCCelsius.get() == 55, "Transient sensor failure must recover")
    try require(
      transport.requests.filter { $0.command == .keyInfo && $0.key == "Tp01" }.count == 1,
      "Metadata cached across samples")
    let unknown = SMCThermalReader(
      client: client, classifier: ThermalClassifier(cpuBrand: "Unknown CPU"))
    try expectTelemetryFailure { try unknown.read().maximumSoCCelsius.get() }
    let numericFixtures = [
      SensorFixture(key: "Praw", type: "flt ", bytes: word(Float(12.5).bitPattern)),
      SensorFixture(key: "Vraw", type: "ui16", bytes: [0x04, 0xD2]),
      SensorFixture(key: "Braw", type: "ch8*", bytes: [1, 2, 3, 4]),
    ]
    let numeric = try SMCNumericReader(
      client: SMCClient(transport: FixtureTransport(numericFixtures))
    ).read(maximumReadings: 8)
    try require(
      numeric.readings.count == 2 && !numeric.truncated,
      "Expert SMC inventory keeps only supported numeric types")
    try require(
      numeric.readings.contains { $0.key == "Praw" && close($0.value, 12.5) },
      "Expert SMC float decoding")
    try require(
      numeric.readings.contains { $0.key == "Vraw" && close($0.value, 1234) },
      "Expert SMC integer decoding")
    let hole = FixtureTransport(fixtures)
    hole.failingIndexes = [0]
    let discovery = try SMCClient(transport: hole).discoverKeys()
    try require(
      discovery.keys.count == fixtures.count - 1 && discovery.failures.count == 1,
      "One failed enumeration index must not discard other keys")

    let holeThermals = try SMCThermalReader(
      client: SMCClient(transport: hole),
      classifier: ThermalClassifier(cpuBrand: "Apple M4 Pro")
    ).read()
    let discoveryFailureKeys = Set(discovery.failures.keys)
    try require(
      discoveryFailureKeys.isSubset(of: Set(holeThermals.failures.keys))
        && discoveryFailureKeys.isSubset(of: Set(holeThermals.trustedFailures.keys)),
      "Unknown SMC discovery gaps must remain trusted thermal health failures")
    for count: UInt32 in [0, 16385, UInt32.max] {
      let invalid = FixtureTransport(fixtures)
      invalid.countOverride = count
      try expectTelemetryFailure { try SMCClient(transport: invalid).discoverKeys() }
    }
    let oversized = FixtureTransport([
      SensorFixture(key: "Tp01", type: "flt ", bytes: [UInt8](repeating: 0, count: 33))
    ])
    try expectTelemetryFailure { try SMCClient(transport: oversized).value("Tp01") }
    for reply in [[UInt8](repeating: 0, count: 79), (0..<80).map { $0 == 40 ? UInt8(0x84) : 0 }] {
      let malformed = FixtureTransport([])
      malformed.replyOverride = reply
      try expectTelemetryFailure { try SMCClient(transport: malformed).value("Tp01") }
    }
  }

  /// Read-only display maps for chips other than the M4 family (Helios 0.2.1). They show
  /// temperatures; they must never reach control, which keeps using `group`.
  private static func displayThermalChecks() throws {
    for (brand, generation) in [
      ("Apple M1", 1), ("Apple M1 Pro", 1), ("Apple M2 Max", 2), ("Apple M3 Ultra", 3),
      ("Apple M4", 4), ("Apple M5 Pro", 5), ("Apple M6", 6),
    ] {
      try require(
        ThermalClassifier.generation(ofCPUBrand: brand) == generation,
        "\(brand) chip generation")
    }
    try require(
      ThermalClassifier.generation(ofCPUBrand: "Apple M10") == 10
        && ThermalClassifier(cpuBrand: "Apple M10").displayGroup(for: "Tp01") == .unclassified,
      "Apple M10 must never be mistaken for M1")
    for brand in ["Apple Mx", "Apple M", "Intel(R) Core(TM) i7", "", "Apple A18 Pro"] {
      try require(
        ThermalClassifier.generation(ofCPUBrand: brand) == nil, "'\(brand)' is not an M-series chip")
    }

    // The same key means different things per generation: Tp09 is an E-core on M1 and a P-core on M2.
    let m1 = ThermalClassifier(cpuBrand: "Apple M1 Pro")
    let m2 = ThermalClassifier(cpuBrand: "Apple M2")
    let m3 = ThermalClassifier(cpuBrand: "Apple M3 Max")
    let m5 = ThermalClassifier(cpuBrand: "Apple M5")
    let m6 = ThermalClassifier(cpuBrand: "Apple M6")
    try require(m1.displayGroup(for: "Tp09") == .efficiencyCPU, "M1 Tp09 is an efficiency core")
    try require(m2.displayGroup(for: "Tp09") == .performanceCPU, "M2 Tp09 is a performance core")
    try require(m1.displayGroup(for: "Tp01") == .performanceCPU, "M1 performance core")
    try require(m1.displayGroup(for: "Tg05") == .gpu, "M1 GPU")
    try require(m2.displayGroup(for: "Tp1h") == .efficiencyCPU, "M2 efficiency core")
    try require(m2.displayGroup(for: "Tg0f") == .gpu, "M2 GPU")
    try require(m3.displayGroup(for: "Tf04") == .performanceCPU, "M3 performance core")
    try require(m3.displayGroup(for: "Te05") == .efficiencyCPU, "M3 efficiency core")
    try require(m3.displayGroup(for: "Tf14") == .gpu, "M3 GPU")
    try require(m5.displayGroup(for: "Tp00") == .performanceCPU, "M5 super core is shown with the performance cores")
    try require(m5.displayGroup(for: "Tp0O") == .performanceCPU, "M5 performance core")
    try require(m5.displayGroup(for: "Tg0U") == .gpu, "M5 GPU")
    try require(m6.displayGroup(for: "Te07") == .efficiencyCPU, "M6 efficiency core")
    try require(m6.displayGroup(for: "Tg1e") == .gpu, "M6 GPU")
    try require(
      [m1, m2, m3, m5, m6].allSatisfy { $0.displayGroup(for: "TpZZ") == .unclassified },
      "An unknown key must never be identified from its prefix")
    try require(
      m1.displayGroup(for: "Tp1h") == .unclassified && m2.displayGroup(for: "Tp0T") == .unclassified,
      "A key from another generation's map must stay unclassified")

    // Control-trusted identity is untouched: only the validated M4 family has one.
    let everyDisplayKey = ["Tp01", "Tp09", "Tp1h", "Tf04", "Te05", "Tg05", "Tg0f", "Tf14", "Tp00", "Tg0U", "Te07"]
    try require(
      [m1, m2, m3, m5, m6].allSatisfy { classifier in
        everyDisplayKey.allSatisfy { classifier.group(for: $0) == .unclassified }
      },
      "A catalogue display map became a fan-control trusted identity")
    let m4 = ThermalClassifier(cpuBrand: "Apple M4 Pro")
    try require(
      ["Tp01", "Te05", "Tg0G", "Tzzz"].allSatisfy { m4.displayGroup(for: $0) == m4.group(for: $0) },
      "The M4 family display identity must equal its trusted identity")

    // End to end on an M2: display keys are live, implausible ones are dropped,
    // and none of it becomes trusted thermal health.
    let fixtures = [
      SensorFixture(key: "Tp01", type: "flt ", bytes: word(Float(45).bitPattern)),
      SensorFixture(key: "Tp1h", type: "flt ", bytes: word(Float(38).bitPattern)),
      SensorFixture(key: "Tg0f", type: "flt ", bytes: word(Float(50).bitPattern)),
      SensorFixture(key: "Tp0b", type: "flt ", bytes: word(Float(6.7).bitPattern)),
      SensorFixture(key: "Tzzz", type: "flt ", bytes: word(Float(90).bitPattern)),
      SensorFixture(key: "Tp05", type: "ui32", bytes: [1, 2, 3, 4]),
      SensorFixture(key: "TG0B", type: "ioft", bytes: [1, 2, 3, 4, 5, 6, 7, 8]),
    ]
    let transport = FixtureTransport(fixtures)
    let reader = SMCThermalReader(
      client: SMCClient(transport: transport), classifier: ThermalClassifier(cpuBrand: "Apple M2 Pro"))
    let metrics = try reader.read()
    try require(
      try close(metrics.maximumSoCCelsius.get(), 50),
      "M2 hottest identified sensor is the GPU; raw Tzzz must stay excluded")
    try require(
      try close(metrics.averageCPUCelsius.get(), (45 + 38) / 2),
      "M2 CPU average uses only the identified P and E cores")
    guard let gpu = metrics.readings.first(where: { $0.key == "Tg0f" }) else {
      throw CheckFailure(description: "M2 GPU reading missing")
    }
    try require(
      gpu.group == .unclassified && gpu.displayGroup == .gpu,
      "M2 GPU must be display-identified yet not control-trusted")
    try require(
      metrics.failures["Tp0b"] != nil && metrics.readings.allSatisfy { $0.key != "Tp0b" },
      "A constant implausibly low sensor (6.7 C) must not become a reading")
    try require(
      metrics.trustedFailures.isEmpty,
      "Display-only and raw failures must not count as trusted thermal health failures")
    let readsAfterFirst = transport.requests.filter { $0.command == .bytes && $0.key == "Tg0f" }.count
    _ = try reader.read()
    try require(
      transport.requests.filter { $0.command == .bytes && $0.key == "Tg0f" }.count == readsAfterFirst + 1,
      "Display-identified sensors must stay live on every fast thermal poll")
  }

  private static func formattingChecks() throws {
    try require(TelemetryFormatting.duration(Double.greatestFiniteMagnitude) == "—"
      && TelemetryFormatting.duration(Double(Int.max)) == "—",
      "Out-of-range durations must not trap during integer conversion")
    try require(TelemetryFormatting.duration(90) == "1m"
      && TelemetryFormatting.duration(-1) == "—", "Ordinary duration formatting remains intact")
    try require(
      try MemoryPressure.decode(1) == .normal && MemoryPressure.decode(2) == .warning
        && MemoryPressure.decode(4) == .critical, "Kernel pressure mapping")
    try expectTelemetryFailure { try MemoryPressure.decode(0) }
    try expectTelemetryFailure { try MemoryPressure.decode(8) }
    let now = Date()
    var snapshot = TelemetrySnapshot()
    snapshot.cpu = MetricSample(
      .success(CPUMetrics(userPercent: 20, systemPercent: 5, nicePercent: 0, idlePercent: 75)),
      capturedAt: now)
    snapshot.thermals = MetricSample(
      .success(
        ThermalMetrics(
          readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 55)],
          failures: [:])), capturedAt: now)
    try require(
      TelemetryFormatting.menuBar(snapshot, now: now) == "CPU 25% · SoC 55°C", "Compact readout")
    try require(
      TelemetryFormatting.menuBar(snapshot, now: now.addingTimeInterval(7)) == "CPU — · SoC —",
      "Expired readings must disappear")
    try require(
      TelemetryFormatting.menuBar(snapshot, now: now.addingTimeInterval(-10)) == "CPU — · SoC —",
      "Clock discontinuity must invalidate readings")
    try require(
      TelemetryFormatting.menuBar(TelemetrySnapshot()) == "CPU — · SoC —",
      "Initial unavailable state")
  }

  @MainActor private static func liveChecks() async throws {
    try require(geteuid() != 0, "Live telemetry must be checked without root privileges")
    print(
      "Live check: uid=\(geteuid()), OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("CPU identity: \(try ThermalClassifier.native().cpuBrand)")
    let cpu = CPUProvider()
    let memory = MemoryProvider()
    let gpu = GPUProvider()
    let systemPower = SystemPowerProvider()
    let system = SystemProvider()
    let network = NetworkProvider()
    let battery = BatteryProvider()
    let thermal = ThermalProvider()
    let storage = StorageProvider()
    _ = await cpu.sample()
    for _ in 0..<3 {
      try await Task.sleep(for: .seconds(1))
      async let cpuSample = cpu.sample()
      async let memorySample = memory.sample()
      async let gpuSample = gpu.sample()
      async let powerSample = systemPower.sample()
      async let systemSample = system.sample()
      async let networkSample = network.sample()
      async let batterySample = battery.sample()
      async let thermalSample = thermal.sample()
      async let storageSample = storage.sample()
      let (c, m, g, p, sys, net, b, t, s) = await (
        cpuSample, memorySample, gpuSample, powerSample, systemSample, networkSample, batterySample,
        thermalSample, storageSample
      )
      let usage = try c.result.get()
      try require((0...100.001).contains(usage.usagePercent), "CPU percentage range")
      let ram = try m.result.get()
      let cell = try b.result.get()
      let heat = try t.result.get()
      print(
        String(
          format: "CPU %.1f%% | Pressure %@ | Max SoC %.1f°C | %d thermal readings, %d unavailable",
          usage.usagePercent, try ram.pressure.get().rawValue, try heat.maximumSoCCelsius.get(),
          heat.readings.count, heat.failures.count))
      print(
        "Battery: design=\(try cell.designCapacityMAh.get()) mAh, full=\(try cell.maximumCapacityMAh.get()) mAh, current=\(try cell.currentCapacityMAh.get()) mAh, cycles=\(try cell.cycleCount.get()), temp=\(try cell.temperatureCelsius.get())°C"
      )
      let power = try cell.power.get()
      print(String(format: "%@: %.2f W (signed)", power.label, power.signedWatts))
      switch g.result {
      case .success(let graphics):
        print(
          "GPU: "
            + TelemetryFormatting.text(
              graphics.deviceUtilizationPercent, format: { String(format: "%.1f%%", $0) })
            + " renderer="
            + TelemetryFormatting.text(
              graphics.rendererUtilizationPercent, format: { String(format: "%.1f%%", $0) }))
      case .failure(let error): print("GPU: unavailable — \(error.localizedDescription)")
      }
      switch p.result.flatMap(\.totalSystemWatts) {
      case .success(let watts): print(String(format: "Total System Power: %.2f W", watts))
      case .failure(let error):
        print("Total System Power: unavailable — \(error.localizedDescription)")
      }
      if case .success(let machine) = sys.result {
        print(
          "System: \(TelemetryFormatting.text(machine.modelIdentifier) { $0 }) thermal=\(machine.thermalState.rawValue) uptime=\(TelemetryFormatting.duration(machine.uptimeSeconds))"
        )
      }
      if case .success(let network) = net.result {
        print(
          "Network: " + TelemetryFormatting.text(network.primaryInterface) { $0 } + " down="
            + TelemetryFormatting.text(
              network.throughput.map(\.downloadBytesPerSecond),
              format: TelemetryFormatting.bytesPerSecond))
      }
      let disks = try s.result.get()
      if let primary = disks.primaryDevice {
        let throughputText: String
        switch disks.throughput {
        case .success(let rate):
          throughputText =
            "read=\(TelemetryFormatting.bytesPerSecond(rate.readBytesPerSecond)) write=\(TelemetryFormatting.bytesPerSecond(rate.writeBytesPerSecond))"
        case .failure(let error): throughputText = "throughput=\(error.localizedDescription)"
        }
        print(
          "Storage: \(primary.bsdName) \(primary.model) \(TelemetryFormatting.storageBytes(primary.capacityBytes)) \(primary.smartCapability.rawValue); \(throughputText)"
        )
      }
      for group in ThermalGroup.allCases where group != .unclassified {
        let readings = heat.readings.filter { $0.group == group }
        try require(!readings.isEmpty, "Expected M4 \(group.rawValue) keys")
        print("\(group.rawValue): \(readings.map(\.key).joined(separator: ", "))")
      }
    }
    await cpu.reset()
    let resetSample = await cpu.sample()
    try expectTelemetryFailure { try resetSample.result.get() }
    await gpu.reset()
    _ = await gpu.sample()
    await systemPower.reset()
    _ = await systemPower.sample()
    await system.reset()
    _ = await system.sample()
    await network.reset()
    _ = await network.sample()
    await thermal.reset()
    _ = try await thermal.sample().result.get().maximumSoCCelsius.get()
    await battery.reset()
    _ = try await battery.sample().result.get()
    await storage.reset()
    _ = try await storage.sample().result.get()
    print("PASS unprivileged live providers and explicit wake-style resets")
  }
}
