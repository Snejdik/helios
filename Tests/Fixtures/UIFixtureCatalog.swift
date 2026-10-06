import Foundation

/// Pure values only: no client/service/model/provider construction, Tasks, defaults,
/// files, notification permission, network, SMC or hardware. This is test-only source.
/// A "connected" helper is display evidence, never an actual connection or authority.
@MainActor
enum UIFixtureCatalog {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)
  static let ticks: UInt64 = 1_000_000

  enum Scenario: String, CaseIterable {
    case healthy, laptop, desktop, oneFan, twoFans, helperMissing, helperConnected
    case fanControlUnavailable, fanOSUnvalidated
    case thermalAvailable, thermalPartial, thermalNoData, rawThermals
    case staleTelemetry, providerUnavailable, waitingForFirstSample, fieldUnavailable
    case memoryWarning, storageWarning, batteryWarning
    case updateAvailable, noUpdate, updateFailure, notificationsDenied
  }

  struct State {
    let scenario: Scenario
    var snapshot: TelemetrySnapshot
    var helper: DiagnosticsHelper
    var fanControlAvailable: Bool
    var fanMode: HeliosFanMode
    var update: HeliosUpdateChecker.Outcome
    var notificationAuthorization: HealthAlertCenter.Authorization

    @MainActor var presentation: OverviewPresentation { OverviewPresentation(snapshot, now: UIFixtureCatalog.now) }
  }

  static var all: [State] { Scenario.allCases.map(make) }

  static func sample<Value: Sendable>(_ result: MetricResult<Value>,
                                     age: TimeInterval = 0) -> MetricSample<Value> {
    MetricSample(result, capturedAt: now.addingTimeInterval(-age), capturedTicks: ticks)
  }

  static func make(_ scenario: Scenario) -> State {
    var state = State(
      scenario: scenario, snapshot: healthySnapshot(),
      helper: DiagnosticsHelper(installationState: .missing, connectionState: .disconnected,
        protocolCompatibility: .notChecked, failureCategory: nil),
      fanControlAvailable: false, fanMode: .system, update: .upToDate,
      notificationAuthorization: .enabled)
    switch scenario {
    case .healthy, .laptop, .oneFan, .thermalAvailable, .helperMissing, .noUpdate: break
    case .desktop:
      // Exactly what the frozen BatteryProvider reports when AppleSmartBattery is absent.
      state.snapshot.battery = sample(.failure(.unavailable("AppleSmartBattery unavailable")))
      state.snapshot.system = sample(.success(system(
        model: .failure(.unavailable("Synthetic desktop model not asserted")))))
      state.snapshot.fanOwnershipPreflight = sample(.failure(
        .unavailable("No fixture desktop write-validation identity")))
    case .twoFans:
      state.snapshot.fans = sample(.success(FanInventory(fans: [fan(0), fan(1)])))
      state.snapshot.fanOwnershipPreflight = sample(.success(preflight(fanCount: 2)))
    case .helperConnected:
      state.helper = DiagnosticsHelper(installationState: .installed, connectionState: .connected,
        protocolCompatibility: .compatible, failureCategory: nil)
      // Intentionally no DaemonService/DaemonClient exists: auto-connect is impossible.
      // A connected display state must not manufacture fan-write availability.
    case .fanControlUnavailable:
      state.helper = DiagnosticsHelper(installationState: .installed, connectionState: .disconnected,
        protocolCompatibility: .notChecked, failureCategory: .connection)
    case .fanOSUnvalidated:
      state.snapshot.fanOwnershipPreflight = sample(.success(preflight(osBuild: "26A434")))
      state.snapshot.system = sample(.success(system(osBuild: "26A434")))
    case .thermalPartial:
      state.snapshot.thermals = sample(.success(ThermalMetrics(
        readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 56)],
        failures: ["Tg0G": .smc("Tg0G", 1)], trustedFailures: ["Tg0G": .smc("Tg0G", 1)],
        advisoryReadingsCapturedAt: now)))
    case .thermalNoData:
      state.snapshot.thermals = sample(.success(ThermalMetrics(
        readings: [], failures: [:], trustedFailures: [:], advisoryReadingsCapturedAt: now)))
    case .rawThermals:
      state.snapshot.thermals = sample(.success(ThermalMetrics(
        readings: [ThermalReading(key: "Tzzz", group: .unclassified, celsius: 110)],
        failures: [:], trustedFailures: [:], advisoryReadingsCapturedAt: now)))
    case .staleTelemetry:
      state.snapshot.cpu = sample(state.snapshot.cpu.result, age: 6)
      state.snapshot.thermals = sample(state.snapshot.thermals.result, age: 7)
    case .providerUnavailable:
      state.snapshot.cpu = sample(.failure(.kernel("Fixture CPU read", 5)))
    case .waitingForFirstSample:
      state.snapshot = TelemetrySnapshot(capturedAt: now, capturedTicks: ticks)
    case .fieldUnavailable:
      state.snapshot.gpu = sample(.success(GPUMetrics(
        model: .success("Apple M4"), coreCount: .success(10),
        deviceUtilizationPercent: .failure(.unavailable("Fixture field not exposed")),
        rendererUtilizationPercent: .success(12), tilerUtilizationPercent: .success(8),
        allocatedSystemMemoryBytes: .success(1 << 30),
        inUseSystemMemoryBytes: .success(256 << 20))))
    case .memoryWarning:
      state.snapshot.memory = sample(.success(memory(pressure: .warning)))
    case .storageWarning:
      state.snapshot.storage = sample(.success(storage(warning: true)))
    case .batteryWarning:
      state.snapshot.battery = sample(.success(battery(warning: true)))
    case .updateAvailable:
      state.update = .available(HeliosReleaseVersion(tag: "v0.1.0")!)
    case .updateFailure: state.update = .failed
    case .notificationsDenied: state.notificationAuthorization = .denied
    }
    return state
  }

  private static func healthySnapshot() -> TelemetrySnapshot {
    // Every initial field has a fixed timestamp/tick, including unavailable
    // inventories; no default Date()/HostClock read enters the fixture.
    var snapshot = TelemetrySnapshot(capturedAt: now, capturedTicks: ticks)
    snapshot.cpu = sample(.success(CPUMetrics(
      userPercent: 9, systemPercent: 3, nicePercent: 0, idlePercent: 88,
      perCoreUsagePercent: [18, 16, 14, 12, 10, 10, 8, 8, 6, 6],
      physicalCoreCount: .success(10), performanceCoreCount: .success(4),
      efficiencyCoreCount: .success(6))))
    snapshot.memory = sample(.success(memory()))
    snapshot.gpu = sample(.success(GPUMetrics(
      model: .success("Apple M4"), coreCount: .success(10),
      deviceUtilizationPercent: .success(18), rendererUtilizationPercent: .success(12),
      tilerUtilizationPercent: .success(8), allocatedSystemMemoryBytes: .success(1 << 30),
      inUseSystemMemoryBytes: .success(256 << 20))))
    snapshot.systemPower = sample(.success(SystemPowerMetrics(totalSystemWatts: .success(11.8))))
    snapshot.system = sample(.success(system()))
    snapshot.battery = sample(.success(battery()))
    snapshot.storage = sample(.success(storage()))
    snapshot.thermals = sample(.success(ThermalMetrics(readings: [
      ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 56),
      ThermalReading(key: "Tp05", group: .performanceCPU, celsius: 48),
      ThermalReading(key: "Te05", group: .efficiencyCPU, celsius: 44),
      ThermalReading(key: "Tg0G", group: .gpu, celsius: 46),
      ThermalReading(key: "Tzzz", group: .unclassified, celsius: 110),
    ], failures: [:], trustedFailures: [:], advisoryReadingsCapturedAt: now)))
    snapshot.fans = sample(.success(FanInventory(fans: [fan(0)])))
    snapshot.fanOwnershipPreflight = sample(.success(preflight()))
    let process = ProcessActivity(
      pid: 501, name: "Fixture Editor", executablePath: nil,
      physicalFootprintBytes: 512 << 20, neuralFootprintBytes: 0,
      cpuPercent: 120, powerWatts: 1.2, performanceCorePowerWatts: 0.8,
      diskReadBytesPerSecond: 120_000, diskWriteBytesPerSecond: 60_000,
      wakeupsPerSecond: 10, instructionsPerSecond: 200_000_000,
      cyclesPerSecond: 100_000_000, instructionsPerCycle: 2)
    snapshot.processes = sample(.success(ProcessMetrics(
      accessibleProcessCount: 184, topByCPU: [process], topByEnergy: [process],
      energyHistoryLeaders: [process], topByMemory: [process])))
    snapshot.network = sample(.success(NetworkMetrics(
      primaryInterface: .success("en0"), ipv4Address: .success("192.0.2.42"),
      ipv6Address: .success("2001:db8::42"), isRunning: .success(true),
      mtu: .success(1500), linkSpeedBitsPerSecond: .success(1_000_000_000),
      throughput: .success(NetworkThroughput(downloadBytesPerSecond: 12_300_000,
        uploadBytesPerSecond: 2_400_000, receivePacketsPerSecond: 1300, transmitPacketsPerSecond: 820)),
      receiveErrors: .success(0), transmitErrors: .success(0),
      activeInterfaceCount: 1, activeInterfaces: ["en0"])))
    snapshot.wifi = sample(.success(WiFiMetrics(
      interfaceName: "en0", powerOn: true, serviceActive: true,
      ssid: .failure(.unavailable("Fixture location permission not granted")),
      rssiDBm: .success(-48), noiseDBm: .success(-91),
      transmitRateMbps: .success(1_200), transmitPowerMilliwatts: .success(31),
      channelNumber: .success(37), channelBand: .success("6 GHz"),
      channelWidth: .success("160 MHz"), phyMode: .success("802.11ax / Wi-Fi 6/6E"),
      security: .success("WPA3 Personal"))))
    snapshot.displays = sample(.success(DisplayMetrics(displays: [])))
    snapshot.volumes = sample(.success(VolumeMetrics(volumes: [])))
    snapshot.usb = sample(.success(USBMetrics(devices: [])))
    snapshot.bluetooth = sample(.success(BluetoothMetrics(devices: [])))
    snapshot.audio = sample(.success(AudioMetrics(devices: [], defaultInputDeviceID: nil,
      defaultOutputDeviceID: nil, defaultSystemOutputDeviceID: nil,
      inputTelemetrySuppressedForPrivacy: true)))
    snapshot.powerAssertions = sample(.success(PowerAssertionsMetrics(assertions: [])))
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    snapshot.clock = sample(.success(ClockMetrics(localTimeZoneIdentifier: "UTC",
      isoWeekOfYear: calendar.component(.weekOfYear, from: now),
      dayOfYear: calendar.ordinality(of: .day, in: .year, for: now)!, zones: [
        ClockZoneMetrics(identifier: "UTC", abbreviation: "UTC", offsetSeconds: 0, localDate: now)
      ])))
    return snapshot
  }

  private static func memory(pressure: MemoryPressure = .normal) -> MemoryMetrics {
    MemoryMetrics(physicalBytes: 16 << 30, activeBytes: 8 << 30, inactiveBytes: 1 << 30,
      wiredBytes: 2 << 30, compressedBytes: 2 << 30, freeBytes: 3 << 30,
      pressure: .success(pressure), swapUsedBytes: .success(512 << 20),
      swapTotalBytes: .success(2 << 30))
  }

  private static func system(model: MetricResult<String> = .success("Mac16,1"),
                             osBuild: String = "25G83") -> SystemMetrics {
    SystemMetrics(modelIdentifier: model, chipName: .success("Apple M4"),
      osVersion: "Fixture macOS", osBuild: .success(osBuild),
      uptimeSeconds: 98_765, logicalProcessorCount: 10, physicalMemoryBytes: 16 << 30,
      loadAverage1: .success(1.25), loadAverage5: .success(1.1), loadAverage15: .success(0.95),
      thermalState: .nominal, lowPowerModeEnabled: false)
  }

  private static func battery(warning: Bool = false) -> BatteryMetrics {
    BatteryMetrics(designCapacityMAh: .success(6_000),
      maximumCapacityMAh: .success(warning ? 3_900 : 5_700),
      currentCapacityMAh: .success(warning ? 2_700 : 4_000), systemChargePercent: .success(70),
      cycleCount: .success(warning ? 1_000 : 40),
      temperatureCelsius: .success(warning ? 51 : 30.5),
      power: .success(BatteryPower(signedWatts: -12.4, usesInstantaneousCurrent: true)),
      powerSource: .success(.battery), voltageVolts: .success(12.3),
      currentAmps: .success(-1.01), isCharging: .success(false),
      timeRemaining: .success(.seconds(14_400)))
  }

  private static func fan(_ id: Int) -> FanReading {
    FanReading(id: id, actualRPM: .success(2_400), targetRPM: .success(2_400),
      minimumRPM: .success(2_317), maximumRPM: .success(6_550), automatic: .success(true))
  }

  private static func preflight(fanCount: Int = 1, osBuild: String = "25G83")
    -> FanOwnershipPreflightSnapshot {
    FanOwnershipPreflightEvaluator.evaluate(FanOwnershipPreflightEvidence(
      modelIdentifier: "Mac16,1", osBuild: osBuild, fanCount: fanCount,
      globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0,
      fans: (0..<fanCount).map { id in
        FanOwnershipPreflightFan(id: id, modeKey: "F\(id)Md", mode: 3,
          actualRPM: 2_400, targetRPM: 2_400, minimumRPM: 2_317,
          maximumRPM: 6_550, targetType: "flt ")
      }))
  }

  private static func storage(warning: Bool = false) -> StorageMetrics {
    let zero = NVMeCounter128(low: 0, high: 0)
    let health = NVMeSMARTHealth(criticalWarning: warning ? 1 : 0,
      temperatureCelsius: warning ? 81 : 40, availableSparePercent: 100,
      availableSpareThresholdPercent: 10, percentageUsed: warning ? 85 : 3,
      dataUnitsRead: NVMeCounter128(low: 8_000_000, high: 0),
      dataUnitsWritten: NVMeCounter128(low: 4_000_000, high: 0),
      hostReadCommands: zero, hostWriteCommands: zero, controllerBusyMinutes: zero,
      powerCycles: NVMeCounter128(low: 40, high: 0),
      powerOnHours: NVMeCounter128(low: 300, high: 0),
      unsafeShutdowns: zero, mediaErrors: NVMeCounter128(low: warning ? 1 : 0, high: 0),
      errorLogEntries: zero)
    return StorageMetrics(
      rootVolume: .success(RootVolumeMetrics(totalBytes: 1_000_000_000_000, freeBytes: 600_000_000_000)),
      devices: [StorageDeviceMetrics(registryID: 42, bsdName: "disk0", model: "Fixture SSD",
        capacityBytes: 1_000_000_000_000, isInternal: true, isRemovable: false,
        transport: "NVMe", controllerClass: "FixtureNVMe", smartCapability: .nvmeAdvertised,
        counters: .success(StorageIOCounters(bytesRead: 12_000_000, bytesWritten: 6_000_000,
          readOperations: 120, writeOperations: 60, readErrors: 0, writeErrors: 0)))],
      primaryDeviceBSDName: "disk0",
      throughput: .success(StorageThroughput(readBytesPerSecond: 12_000_000,
        writeBytesPerSecond: 6_000_000, readIOPS: 120, writeIOPS: 60)),
      smartHealth: .success(health), smartHealthCapturedTicks: ticks,
      monitoringReadBytes: .success(12_000_000), monitoringWrittenBytes: .success(6_000_000))
  }
}
