import AppKit
import IOKit.ps
import OSLog

struct TelemetrySnapshot: Sendable {
  /// Lifecycle context for presentation/alerts; never a fan-control input.
  var isSuspended = false
  var cpu: MetricSample<CPUMetrics>
  var memory: MetricSample<MemoryMetrics>
  var gpu: MetricSample<GPUMetrics>
  var systemPower: MetricSample<SystemPowerMetrics>
  var system: MetricSample<SystemMetrics>
  var network: MetricSample<NetworkMetrics>
  var wifi: MetricSample<WiFiMetrics>
  var processes: MetricSample<ProcessMetrics>
  var battery: MetricSample<BatteryMetrics>
  var storage: MetricSample<StorageMetrics>
  var thermals: MetricSample<ThermalMetrics>
  var fans: MetricSample<FanInventory>
  var fanOwnershipPreflight: MetricSample<FanOwnershipPreflightSnapshot>
  var displays: MetricSample<DisplayMetrics>
  var volumes: MetricSample<VolumeMetrics>
  var usb: MetricSample<USBMetrics>
  var bluetooth: MetricSample<BluetoothMetrics>
  var audio: MetricSample<AudioMetrics>
  var powerAssertions: MetricSample<PowerAssertionsMetrics>
  var clock: MetricSample<ClockMetrics>

  /// Explicit clocks permit pure deterministic fixtures. Runtime callers retain
  /// the current wall/host clocks and the existing pending failure semantics.
  init(capturedAt: Date = Date(), capturedTicks: UInt64 = HostClock.now) {
    cpu = MetricSample(.failure(.warmingUp),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    memory = MetricSample(.failure(.unavailable("Memory readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    gpu = MetricSample(.failure(.unavailable("GPU readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    systemPower = MetricSample(.failure(.unavailable("System power readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    system = MetricSample(.failure(.unavailable("System readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    network = MetricSample(.failure(.unavailable("Network readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    wifi = MetricSample(.failure(.unavailable("Wi-Fi readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    processes = MetricSample(.failure(.unavailable("Process readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    battery = MetricSample(.failure(.unavailable("Battery readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    storage = MetricSample(.failure(.unavailable("Storage readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    thermals = MetricSample(.failure(.unavailable("Thermal readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    fans = MetricSample(.failure(.unavailable("Fan readings pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    fanOwnershipPreflight = MetricSample(.failure(.unavailable("Fan ownership preflight pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    displays = MetricSample(.failure(.unavailable("Display inventory pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    volumes = MetricSample(.failure(.unavailable("Mounted volume inventory pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    usb = MetricSample(.failure(.unavailable("USB inventory pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    bluetooth = MetricSample(.failure(.unavailable("Bluetooth inventory pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    audio = MetricSample(.failure(.unavailable("Audio inventory pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    powerAssertions = MetricSample(.failure(.unavailable("Power assertions pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
    clock = MetricSample(.failure(.unavailable("Clock metadata pending")),
      capturedAt: capturedAt, capturedTicks: capturedTicks)
  }
}

@MainActor
final class TelemetryMonitor: NSObject {
  private let cpu = CPUProvider()
  private let memory = MemoryProvider()
  private let gpu = GPUProvider()
  private let systemPower = SystemPowerProvider()
  private let system = SystemProvider()
  private let network = NetworkProvider()
  private let wifi = WiFiProvider()
  private let processes = ProcessProvider()
  private let battery = BatteryProvider()
  private let storage = StorageProvider()
  private let thermals = ThermalProvider()
  private let fans = FanProvider()
  private let fanOwnershipPreflight = FanOwnershipPreflightProvider()
  private let displays = DisplayProvider()
  private let volumes = VolumeProvider()
  private let usb = USBProvider()
  private let bluetooth = BluetoothProvider()
  private let audio = AudioProvider()
  private let powerAssertions = PowerAssertionsProvider()
  private let clock = ClockProvider()
  private let telemetryEnabled: @MainActor (HeliosTelemetryModule) -> Bool
  private let logger = Logger(subsystem: "com.snejda.Helios", category: "Telemetry")
  private var loggedFailures: [String: String] = [:]
  private var tasks: [Task<Void, Never>] = []
  private var batteryRefresh: Task<Void, Never>?
  private var rawRefreshRequested = false
  private(set) var detailDemand: TelemetryDetailDemand = []
  private var detailWaiters: [UUID: (demand: TelemetryDetailDemand, task: Task<Void, Never>)] = [:]

  func setDetailDemand(_ demand: TelemetryDetailDemand) {
    let newlyVisible = demand.subtracting(detailDemand)
    detailDemand = demand
    if newlyVisible.contains(.rawSensors) { rawRefreshRequested = true }
    // Wake existing collectors, rather than creating a competing refresh task.
    // If a collector is already reading, its imminent result is the refresh.
    for waiter in detailWaiters.values where !waiter.demand.intersection(newlyVisible).isEmpty {
      waiter.task.cancel()
    }
  }
  private var powerSource: CFRunLoopSource?
  private(set) var snapshot = TelemetrySnapshot()
  var onChange: ((TelemetrySnapshot) -> Void)?
  var onThermalSample: ((MetricSample<ThermalMetrics>) -> Void)?
  var thermalInterval: Duration = .seconds(2)

  init(
    telemetryEnabled: @escaping @MainActor (HeliosTelemetryModule) -> Bool = { _ in true }
  ) {
    self.telemetryEnabled = telemetryEnabled
    super.init()
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
      self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    center.addObserver(
      self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    let context = Unmanaged.passUnretained(self).toOpaque()
    powerSource = IOPSNotificationCreateRunLoopSource(
      { context in
        guard let context else { return }
        let monitor = Unmanaged<TelemetryMonitor>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor [weak monitor] in monitor?.refreshBattery() }
      }, context)?.takeRetainedValue()
    if let powerSource {
      CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
    } else {
      logger.error(
        "Power-source notifications unavailable; periodic battery sampling remains active.")
    }
  }

  func start() {
    guard tasks.isEmpty else { return }
    snapshot.isSuspended = false
    // Independent actors/tasks isolate driver calls from other providers and UI.
    tasks = [
      loop(
        interval: .seconds(1), prepare: { [cpu] in await cpu.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.cpu) },
        read: { [cpu] in await cpu.sample() },
        apply: { [weak self] sample in
          self?.snapshot.cpu = sample
          self?.log(sample.result, module: "CPU")
        }),
      loop(
        interval: .seconds(1),
        enabled: { [telemetryEnabled] in telemetryEnabled(.memory) },
        read: { [memory] in await memory.sample() },
        apply: { [weak self] sample in
          self?.snapshot.memory = sample
          self?.log(sample.result, module: "Memory")
          if case .success(let value) = sample.result {
            self?.log(value.pressure, module: "Memory pressure", field: true)
          }
        }),
      loop(
        interval: .seconds(1), prepare: { [gpu] in await gpu.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.gpu) },
        read: { [gpu] in await gpu.sample() },
        apply: { [weak self] sample in
          self?.snapshot.gpu = sample
          self?.log(sample.result, module: "GPU")
          if case .success(let value) = sample.result {
            self?.log(value.deviceUtilizationPercent, module: "GPU utilization", field: true)
          }
        }),
      loop(
        interval: .seconds(1), prepare: { [systemPower] in await systemPower.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.power) },
        read: { [systemPower] in await systemPower.sample() },
        apply: { [weak self] sample in
          self?.snapshot.systemPower = sample
          self?.log(sample.result, module: "System power")
        }),
      loop(
        interval: .seconds(10), prepare: { [system] in await system.reset() },
        read: { [system] in await system.sample() },
        apply: { [weak self] sample in
          self?.snapshot.system = sample
          self?.log(sample.result, module: "System")
        }),
      loop(
        interval: .seconds(1), prepare: { [network] in await network.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.network) },
        read: { [network] in await network.sample() },
        apply: { [weak self] sample in
          self?.snapshot.network = sample
          self?.log(sample.result, module: "Network")
          if case .success(let value) = sample.result {
            self?.log(value.throughput, module: "Network throughput", field: true)
          }
        }),
      loop(
        interval: .seconds(5), prepare: { [wifi] in await wifi.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.wifi) },
        read: { [wifi] in await wifi.sample() },
        apply: { [weak self] sample in
          self?.snapshot.wifi = sample
          self?.log(sample.result, module: "Wi-Fi")
        }),
      loop(
        interval: .seconds(5), prepare: { [processes] in await processes.reset() },
        detailGroup: .processes, backgroundInterval: TelemetryDetailPolicy.backgroundProcessInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.processes) },
        read: { [processes] in await processes.sample() },
        apply: { [weak self] sample in
          self?.snapshot.processes = sample
          self?.log(sample.result, module: "Processes")
        }),
      loop(
        interval: .seconds(5), prepare: { [battery] in await battery.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.battery) },
        read: { [battery] in await battery.sample() },
        apply: { [weak self] sample in
          self?.acceptBattery(sample)
        }),
      loop(
        interval: .seconds(2), prepare: { [storage] in await storage.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.storage) },
        read: { [storage] in await storage.sample() },
        apply: { [weak self] sample in
          self?.snapshot.storage = sample
          self?.log(sample.result, module: "Storage")
          if case .success(let value) = sample.result {
            self?.log(value.rootVolume, module: "Storage root volume", field: true)
            self?.log(value.throughput, module: "Storage throughput", field: true)
          }
        }),
      loop(
        interval: .seconds(1), prepare: { [fans] in await fans.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.fans) },
        read: { [fans] in await fans.sample() },
        apply: { [weak self] sample in
          self?.snapshot.fans = sample
          self?.log(sample.result, module: "Fans")
        }),
      loop(
        interval: .seconds(10),
        prepare: { [fanOwnershipPreflight] in await fanOwnershipPreflight.reset() },
        enabled: { [telemetryEnabled] in telemetryEnabled(.fans) },
        read: { [fanOwnershipPreflight] in await fanOwnershipPreflight.sample() },
        apply: { [weak self] sample in
          self?.snapshot.fanOwnershipPreflight = sample
          self?.log(sample.result, module: "Fan ownership preflight")
        }),
      loop(
        interval: .seconds(2), prepare: { [thermals] in await thermals.reset() },
        dynamicInterval: { [weak self] in self?.thermalInterval ?? .seconds(2) },
        read: { [weak self, thermals] in
          let visible = self?.detailDemand.contains(.rawSensors) ?? false
          let forceRefresh = self?.rawRefreshRequested ?? false
          self?.rawRefreshRequested = false
          return await thermals.sample(rawDetailsVisible: visible, forceRawRefresh: forceRefresh)
        },
        apply: { [weak self] sample in
          self?.snapshot.thermals = sample
          self?.onThermalSample?(sample)
          self?.log(sample.result, module: "Thermals")
          if case .success(let value) = sample.result {
            self?.log(value.maximumSoCCelsius, module: "SoC temperature", field: true)
            let details = value.failures.keys.sorted().map {
              "\($0): \(value.failures[$0]?.localizedDescription ?? "Unavailable")"
            }.joined(separator: "; ")
            self?.logFailure(details, module: "Individual sensors", field: true)
          }
        }),
      loop(
        interval: .seconds(30),
        detailGroup: .devices, backgroundInterval: TelemetryDetailPolicy.backgroundDeviceInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.devices) },
        read: { [displays] in await displays.sample() },
        apply: { [weak self] sample in
          self?.snapshot.displays = sample
          self?.log(sample.result, module: "Displays")
        }),
      loop(
        interval: .seconds(30),
        detailGroup: .devices, backgroundInterval: TelemetryDetailPolicy.backgroundDeviceInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.devices) },
        read: { [volumes] in await volumes.sample() },
        apply: { [weak self] sample in
          self?.snapshot.volumes = sample
          self?.log(sample.result, module: "Mounted volumes")
        }),
      loop(
        interval: .seconds(60),
        detailGroup: .devices, backgroundInterval: TelemetryDetailPolicy.backgroundDeviceInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.devices) },
        read: { [usb] in await usb.sample() },
        apply: { [weak self] sample in
          self?.snapshot.usb = sample
          self?.log(sample.result, module: "USB")
        }),
      loop(
        interval: .seconds(60),
        detailGroup: .devices, backgroundInterval: TelemetryDetailPolicy.backgroundDeviceInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.devices) },
        read: { [bluetooth] in await bluetooth.sample() },
        apply: { [weak self] sample in
          self?.snapshot.bluetooth = sample
          self?.log(sample.result, module: "Bluetooth")
        }),
      loop(
        interval: .seconds(30),
        detailGroup: .devices, backgroundInterval: TelemetryDetailPolicy.backgroundDeviceInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.devices) },
        read: { [audio] in await audio.sample() },
        apply: { [weak self] sample in
          self?.snapshot.audio = sample
          self?.log(sample.result, module: "Audio")
        }),
      loop(
        interval: .seconds(15),
        detailGroup: .devices, backgroundInterval: TelemetryDetailPolicy.backgroundDeviceInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.devices) },
        read: { [powerAssertions] in await powerAssertions.sample() },
        apply: { [weak self] sample in
          self?.snapshot.powerAssertions = sample
          self?.log(sample.result, module: "Power assertions")
        }),
      loop(
        interval: .seconds(60),
        detailGroup: .devices, backgroundInterval: TelemetryDetailPolicy.backgroundDeviceInterval,
        enabled: { [telemetryEnabled] in telemetryEnabled(.devices) },
        read: { [clock] in await clock.sample() },
        apply: { [weak self] sample in
          self?.snapshot.clock = sample
          self?.log(sample.result, module: "Clock")
        }),
    ]
    // Redraw independently of providers so a stalled reader cannot leave
    // an old successful value visible beyond its freshness limit.
    tasks.append(
      Task { [weak self] in
        while !Task.isCancelled {
          self?.publish()
          do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100)) } catch {
            return
          }
        }
      })
  }

  func shutdown() {
    stop()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    if let powerSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
      CFRunLoopSourceInvalidate(powerSource)
    }
    powerSource = nil
    onChange = nil
    onThermalSample = nil
  }

  private func loop<Value: Sendable>(
    interval: Duration,
    prepare: @escaping @Sendable () async -> Void = {},
    dynamicInterval: (@MainActor () -> Duration)? = nil,
    detailGroup: TelemetryDetailDemand = [],
    backgroundInterval: Duration? = nil,
    enabled: @escaping @MainActor () -> Bool = { true },
    read: @escaping @MainActor () async -> MetricSample<Value>,
    apply: @escaping @MainActor (MetricSample<Value>) -> Void
  ) -> Task<Void, Never> {
    Task {
      var wasEnabled = false
      while !Task.isCancelled {
        guard enabled() else {
          wasEnabled = false
          do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100)) } catch {
            return
          }
          continue
        }
        if !wasEnabled {
          await prepare()
          guard !Task.isCancelled else { return }
          wasEnabled = true
        }
        let sample = await read()
        guard !Task.isCancelled else { return }
        apply(sample)
        let delay = dynamicInterval?() ?? TelemetryDetailPolicy.interval(
          visible: detailGroup.isEmpty || detailDemand.contains(detailGroup),
          foreground: interval, background: backgroundInterval ?? interval)
        if detailGroup.isEmpty {
          do {
            try await Task.sleep(
              for: delay, tolerance: delay < .seconds(1) ? .milliseconds(25) : .milliseconds(100))
          } catch { return }
        } else {
          let id = UUID()
          let waiter = Task<Void, Never> {
            do { try await Task.sleep(for: delay, tolerance: .milliseconds(100)) } catch {}
          }
          detailWaiters[id] = (detailGroup, waiter)
          await withTaskCancellationHandler {
            await waiter.value
          } onCancel: {
            waiter.cancel()
          }
          detailWaiters.removeValue(forKey: id)
        }
      }
    }
  }

  private func stop() {
    for task in tasks {
      task.cancel()
    }
    tasks.removeAll()
    for waiter in detailWaiters.values { waiter.task.cancel() }
    detailWaiters.removeAll()
    batteryRefresh?.cancel()
    batteryRefresh = nil
  }

  @objc private func willSleep() {
    stop()
    snapshot.isSuspended = true
    let paused = TelemetryError.unavailable("Paused during sleep")
    snapshot.cpu = MetricSample(.failure(paused))
    snapshot.memory = MetricSample(.failure(paused))
    snapshot.gpu = MetricSample(.failure(paused))
    snapshot.systemPower = MetricSample(.failure(paused))
    snapshot.system = MetricSample(.failure(paused))
    snapshot.network = MetricSample(.failure(paused))
    snapshot.wifi = MetricSample(.failure(paused))
    snapshot.processes = MetricSample(.failure(paused))
    snapshot.battery = MetricSample(.failure(paused))
    snapshot.storage = MetricSample(.failure(paused))
    snapshot.thermals = MetricSample(.failure(paused))
    snapshot.fans = MetricSample(.failure(paused))
    snapshot.fanOwnershipPreflight = MetricSample(.failure(paused))
    snapshot.displays = MetricSample(.failure(paused))
    snapshot.volumes = MetricSample(.failure(paused))
    snapshot.usb = MetricSample(.failure(paused))
    snapshot.bluetooth = MetricSample(.failure(paused))
    snapshot.audio = MetricSample(.failure(paused))
    snapshot.powerAssertions = MetricSample(.failure(paused))
    snapshot.clock = MetricSample(.failure(paused))
    // Push the thermal failure through the control path immediately instead
    // of waiting for freshness to age out. The privileged daemon independently
    // restores before sleep as well; this keeps app state/UI fail-closed too.
    onThermalSample?(snapshot.thermals)
    publish()
  }

  @objc private func didWake() { start() }

  private func refreshBattery() {
    guard telemetryEnabled(.battery) else { return }
    guard !tasks.isEmpty, batteryRefresh == nil else { return }
    batteryRefresh = Task { [weak self, battery] in
      let sample = await battery.sample()
      guard !Task.isCancelled else { return }
      self?.acceptBattery(sample)
      // Power-source changes select a completely different Auto Rules
      // profile. Publish the notification-driven sample immediately instead
      // of waiting up to the next one-second redraw tick before releasing an
      // old AC/Battery target.
      self?.publish()
      self?.batteryRefresh = nil
    }
  }

  private func acceptBattery(_ sample: MetricSample<BatteryMetrics>) {
    snapshot.battery = sample
    log(sample.result, module: "Battery")
    if case .success(let value) = sample.result {
      log(value.designCapacityMAh, module: "Battery design capacity", field: true)
      log(value.maximumCapacityMAh, module: "Battery full charge capacity", field: true)
      log(value.currentCapacityMAh, module: "Battery current capacity", field: true)
      log(value.systemChargePercent, module: "Battery system state of charge", field: true)
      log(value.cycleCount, module: "Battery cycles", field: true)
      log(value.temperatureCelsius, module: "Battery temperature", field: true)
      log(value.power, module: "Battery power", field: true)
      log(value.voltageVolts, module: "Battery voltage", field: true)
      log(value.currentAmps, module: "Battery current", field: true)
      log(value.adapterVoltageVolts, module: "Battery adapter voltage", field: true)
      log(value.chargingCurrentAmps, module: "Battery charging current", field: true)
      log(value.chargingVoltageVolts, module: "Battery charging voltage", field: true)
      log(value.cellVoltagesVolts, module: "Battery cell voltages", field: true)
      log(value.notChargingReasonRaw, module: "Battery not-charging reason", field: true)
      log(value.timeRemaining, module: "Battery time remaining", field: true)
    }
  }

  private func publish() { onChange?(snapshot) }

  /// `field` marks a nested reading inside an otherwise working provider. Many
  /// Macs legitimately lack some fields (battery temperature, raw sensors), so
  /// those are notices; whole-provider failures stay errors.
  private func log<Value>(_ result: MetricResult<Value>, module: String, field: Bool = false) {
    if case .failure(let error) = result, error != .warmingUp {
      logFailure(error.localizedDescription, module: module, field: field)
    } else {
      logFailure("", module: module, field: field)
    }
  }

  private func logFailure(_ message: String, module: String, field: Bool = false) {
    guard loggedFailures[module] != message else { return }
    loggedFailures[module] = message
    guard !message.isEmpty else { return }
    if field {
      logger.notice("\(module, privacy: .public): \(message, privacy: .private)")
    } else {
      logger.error("\(module, privacy: .public): \(message, privacy: .private)")
    }
  }
}
