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

  init(_ sensors: [SensorFixture]) { self.sensors = sensors }

  func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
    requests.append(request)
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
    if CommandLine.arguments.contains("--ui-history-only") {
      try historyChecks()
      try await persistentHistoryChecks()
      print(
        "PASS Next23 UI chart history: live + persistent 24h bounds, memory trend capture, gap-safe energy integration, and sample semantics"
      )
      return
    }

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
    try await persistentHistoryChecks()
    print(
      "PASS 24-hour append-friendly persistent history, retention, battery trends, CSV export, clock ordering and gap-safe energy"
    )
    try await ioAuditChecks()
    print(
      "PASS 24-hour physical/process I/O audit, gap-safe device accounting, CSV export and malformed-tail recovery"
    )
    try capabilityChecks()
    print(
      "PASS capability report states keep read-only discovery separate from fan write authorization"
    )
    try healthChecks()
    try await healthEventChecks()
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
    print("PASS SMC discovery, ABI, decoding, isolation and recovery")
    try formattingChecks()
    print("PASS pressure decoding and stale/unavailable display")
    if CommandLine.arguments.contains("--live") { try await liveChecks() }
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
  }

  private static func processChecks() throws {
    let previous = ProcessCounterSnapshot(
      pid: 42, startAbsoluteTime: 100,
      userTime: 1_000_000_000, systemTime: 500_000_000,
      energyNanojoules: 2_000_000_000, performanceEnergyNanojoules: 400_000_000,
      diskReadBytes: 10_000, diskWriteBytes: 20_000,
      packageIdleWakeups: 10, interruptWakeups: 20,
      instructions: 1_000, cycles: 500,
      physicalFootprintBytes: 200_000_000, neuralFootprintBytes: 4_000_000
    )
    let current = ProcessCounterSnapshot(
      pid: 42, startAbsoluteTime: 100,
      userTime: 2_500_000_000, systemTime: 1_000_000_000,
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
    try require(close(rate.cpuPercent, 100), "Process CPU accounting")
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
    let cleanup = CleanupProvider.read(home: root, entryBudget: 100)
    try require(
      cleanup.candidates.contains { $0.id == "Library/Caches" && $0.scannedEntries > 0 },
      "Cleanup Scout must discover the configured user cache root")
    let bounded = CleanupProvider.read(home: root, entryBudget: 1)
    try require(
      bounded.candidates.first?.truncated == true || bounded.candidates.first?.scannedEntries == 1,
      "Cleanup scan must honor its entry budget")
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
    try require(
      m4Classifier.group(for: "Tp01") == .performanceCPU, "Known M4 P-zone was not trusted")
    try require(
      m4Classifier.group(for: "Te05") == .efficiencyCPU, "Known M4 E-zone was not trusted")
    try require(m4Classifier.group(for: "Tg0G") == .gpu, "Known M4 GPU zone was not trusted")
    try require(
      m4Classifier.group(for: "TpZZ") == .unclassified,
      "Unknown Tp prefix became a trusted fan-control sensor")

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
      displayKind("TCMz") == .communityAuxiliary,
      "Community CPU-die mapping must remain display-only auxiliary telemetry")
    try require(
      displayKind("TVMS") == .virtualOrDerived,
      "Unverified TVM case variants must be presented as virtual/derived, never a physical hotspot")
    let tvmsInfo = displayClassified.first(where: { $0.reading.key == "TVMS" })?.info
    try require(
      tvmsInfo?.title.contains("TVM*") == true && tvmsInfo?.title.contains("summary") == false,
      "Unknown case-sensitive TVMS must receive only a family-level identity")
    try require(
      displayKind("TVmS") == .virtualOrDerived,
      "Exact community TVmS summary key should remain virtual/derived")
    try require(
      displayKind("TD14") == .communityAuxiliary && displayKind("TDER") == .communityAuxiliary,
      "Community SoC/board-diode families should be classified for display without entering safety")
    try require(
      displayKind("Tm0p") == .knownAuxiliary,
      "Known M4 memory-proximity key should receive a friendly auxiliary label")
    try require(
      displayKind("Ta01") == .placeholderCandidate,
      "Repeated low Ta0* cluster should be presented as placeholder-like diagnostics")
    try require(
      displayKind("Txyz") == .unknown,
      "Unknown SMC temperature keys must stay explicitly unclassified")
    try require(
      displayFixtures.allSatisfy { m4Classifier.group(for: $0.key) == .unclassified },
      "Display classification must never promote auxiliary/raw keys into fan-safety groups")
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

  private static func formattingChecks() throws {
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
