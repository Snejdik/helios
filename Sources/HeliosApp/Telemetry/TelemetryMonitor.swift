import AppKit
import IOKit.ps
import OSLog

struct TelemetrySnapshot: Sendable {
    var cpu = MetricSample<CPUMetrics>(.failure(.warmingUp))
    var memory = MetricSample<MemoryMetrics>(.failure(.unavailable("Memory readings pending")))
    var gpu = MetricSample<GPUMetrics>(.failure(.unavailable("GPU readings pending")))
    var systemPower = MetricSample<SystemPowerMetrics>(.failure(.unavailable("System power readings pending")))
    var system = MetricSample<SystemMetrics>(.failure(.unavailable("System readings pending")))
    var network = MetricSample<NetworkMetrics>(.failure(.unavailable("Network readings pending")))
    var wifi = MetricSample<WiFiMetrics>(.failure(.unavailable("Wi-Fi readings pending")))
    var processes = MetricSample<ProcessMetrics>(.failure(.unavailable("Process readings pending")))
    var battery = MetricSample<BatteryMetrics>(.failure(.unavailable("Battery readings pending")))
    var storage = MetricSample<StorageMetrics>(.failure(.unavailable("Storage readings pending")))
    var thermals = MetricSample<ThermalMetrics>(.failure(.unavailable("Thermal readings pending")))
    var fans = MetricSample<FanInventory>(.failure(.unavailable("Fan readings pending")))
    var fanOwnershipPreflight = MetricSample<FanOwnershipPreflightSnapshot>(.failure(.unavailable("Fan ownership preflight pending")))
    var displays = MetricSample<DisplayMetrics>(.failure(.unavailable("Display inventory pending")))
    var volumes = MetricSample<VolumeMetrics>(.failure(.unavailable("Mounted volume inventory pending")))
    var usb = MetricSample<USBMetrics>(.failure(.unavailable("USB inventory pending")))
    var bluetooth = MetricSample<BluetoothMetrics>(.failure(.unavailable("Bluetooth inventory pending")))
    var audio = MetricSample<AudioMetrics>(.failure(.unavailable("Audio inventory pending")))
    var powerAssertions = MetricSample<PowerAssertionsMetrics>(.failure(.unavailable("Power assertions pending")))
    var clock = MetricSample<ClockMetrics>(.failure(.unavailable("Clock metadata pending")))
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
    private let logger = Logger(subsystem: "com.snejda.Helios", category: "Telemetry")
    private var loggedFailures: [String: String] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var batteryRefresh: Task<Void, Never>?
    private var powerSource: CFRunLoopSource?
    private(set) var snapshot = TelemetrySnapshot()
    var onChange: ((TelemetrySnapshot) -> Void)?
    var onThermalSample: ((MetricSample<ThermalMetrics>) -> Void)?
    var thermalInterval: Duration = .seconds(2)

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<TelemetryMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak monitor] in monitor?.refreshBattery() }
        }, context)?.takeRetainedValue()
        if let powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
        } else {
            logger.error("Power-source notifications unavailable; periodic battery sampling remains active.")
        }
    }

    func start() {
        guard tasks.isEmpty else { return }
        // Independent actors/tasks isolate driver calls from other providers and UI.
        tasks = [
            loop(interval: .seconds(1), prepare: { [cpu] in await cpu.reset() }, read: { [cpu] in await cpu.sample() }) { [weak self] sample in
                self?.snapshot.cpu = sample
                self?.log(sample.result, module: "CPU")
            },
            loop(interval: .seconds(1), read: { [memory] in await memory.sample() }) { [weak self] sample in
                self?.snapshot.memory = sample
                self?.log(sample.result, module: "Memory")
                if case .success(let value) = sample.result { self?.log(value.pressure, module: "Memory pressure") }
            },
            loop(interval: .seconds(1), prepare: { [gpu] in await gpu.reset() }, read: { [gpu] in await gpu.sample() }) { [weak self] sample in
                self?.snapshot.gpu = sample
                self?.log(sample.result, module: "GPU")
                if case .success(let value) = sample.result {
                    self?.log(value.deviceUtilizationPercent, module: "GPU utilization")
                }
            },
            loop(interval: .seconds(1), prepare: { [systemPower] in await systemPower.reset() }, read: { [systemPower] in await systemPower.sample() }) { [weak self] sample in
                self?.snapshot.systemPower = sample
                self?.log(sample.result, module: "System power")
            },
            loop(interval: .seconds(10), prepare: { [system] in await system.reset() }, read: { [system] in await system.sample() }) { [weak self] sample in
                self?.snapshot.system = sample
                self?.log(sample.result, module: "System")
            },
            loop(interval: .seconds(1), prepare: { [network] in await network.reset() }, read: { [network] in await network.sample() }) { [weak self] sample in
                self?.snapshot.network = sample
                self?.log(sample.result, module: "Network")
                if case .success(let value) = sample.result { self?.log(value.throughput, module: "Network throughput") }
            },
            loop(interval: .seconds(5), prepare: { [wifi] in await wifi.reset() }, read: { [wifi] in await wifi.sample() }) { [weak self] sample in
                self?.snapshot.wifi = sample
                self?.log(sample.result, module: "Wi-Fi")
            },
            loop(interval: .seconds(5), prepare: { [processes] in await processes.reset() }, read: { [processes] in await processes.sample() }) { [weak self] sample in
                self?.snapshot.processes = sample
                self?.log(sample.result, module: "Processes")
            },
            loop(interval: .seconds(5), prepare: { [battery] in await battery.reset() }, read: { [battery] in await battery.sample() }) { [weak self] sample in
                self?.acceptBattery(sample)
            },
            loop(interval: .seconds(2), prepare: { [storage] in await storage.reset() }, read: { [storage] in await storage.sample() }) { [weak self] sample in
                self?.snapshot.storage = sample
                self?.log(sample.result, module: "Storage")
                if case .success(let value) = sample.result {
                    self?.log(value.rootVolume, module: "Storage root volume")
                    self?.log(value.throughput, module: "Storage throughput")
                }
            },
            loop(interval: .seconds(1), prepare: { [fans] in await fans.reset() }, read: { [fans] in await fans.sample() }) { [weak self] sample in
                self?.snapshot.fans = sample
                self?.log(sample.result, module: "Fans")
            },
            loop(interval: .seconds(10), prepare: { [fanOwnershipPreflight] in await fanOwnershipPreflight.reset() },
                 read: { [fanOwnershipPreflight] in await fanOwnershipPreflight.sample() }) { [weak self] sample in
                self?.snapshot.fanOwnershipPreflight = sample
                self?.log(sample.result, module: "Fan ownership preflight")
            },
            loop(interval: .seconds(2), prepare: { [thermals] in await thermals.reset() },
                 dynamicInterval: { [weak self] in self?.thermalInterval ?? .seconds(2) },
                 read: { [thermals] in await thermals.sample() }) { [weak self] sample in
                self?.snapshot.thermals = sample
                self?.onThermalSample?(sample)
                self?.log(sample.result, module: "Thermals")
                if case .success(let value) = sample.result {
                    self?.log(value.maximumSoCCelsius, module: "SoC temperature")
                    let details = value.failures.keys.sorted().map { "\($0): \(value.failures[$0]?.localizedDescription ?? "Unavailable")" }.joined(separator: "; ")
                    self?.logFailure(details, module: "Individual sensors")
                }
            },
            loop(interval: .seconds(30), read: { [displays] in await displays.sample() }) { [weak self] sample in
                self?.snapshot.displays = sample
                self?.log(sample.result, module: "Displays")
            },
            loop(interval: .seconds(30), read: { [volumes] in await volumes.sample() }) { [weak self] sample in
                self?.snapshot.volumes = sample
                self?.log(sample.result, module: "Mounted volumes")
            },
            loop(interval: .seconds(60), read: { [usb] in await usb.sample() }) { [weak self] sample in
                self?.snapshot.usb = sample
                self?.log(sample.result, module: "USB")
            },
            loop(interval: .seconds(60), read: { [bluetooth] in await bluetooth.sample() }) { [weak self] sample in
                self?.snapshot.bluetooth = sample
                self?.log(sample.result, module: "Bluetooth")
            },
            loop(interval: .seconds(30), read: { [audio] in await audio.sample() }) { [weak self] sample in
                self?.snapshot.audio = sample
                self?.log(sample.result, module: "Audio")
            },
            loop(interval: .seconds(15), read: { [powerAssertions] in await powerAssertions.sample() }) { [weak self] sample in
                self?.snapshot.powerAssertions = sample
                self?.log(sample.result, module: "Power assertions")
            },
            loop(interval: .seconds(60), read: { [clock] in await clock.sample() }) { [weak self] sample in
                self?.snapshot.clock = sample
                self?.log(sample.result, module: "Clock")
            }
        ]
        // Redraw independently of providers so a stalled reader cannot leave
        // an old successful value visible beyond its freshness limit.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                do { try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100)) }
                catch { return }
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
        read: @escaping @Sendable () async -> MetricSample<Value>,
        apply: @escaping @MainActor (MetricSample<Value>) -> Void
    ) -> Task<Void, Never> {
        Task {
            await prepare()
            while !Task.isCancelled {
                let sample = await read()
                guard !Task.isCancelled else { return }
                apply(sample)
                let delay = dynamicInterval?() ?? interval
                do { try await Task.sleep(for: delay, tolerance: delay < .seconds(1) ? .milliseconds(25) : .milliseconds(100)) }
                catch { return }
            }
        }
    }

    private func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        batteryRefresh?.cancel()
        batteryRefresh = nil
    }

    @objc private func willSleep() {
        stop()
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
            log(value.designCapacityMAh, module: "Battery design capacity")
            log(value.maximumCapacityMAh, module: "Battery full charge capacity")
            log(value.currentCapacityMAh, module: "Battery current capacity")
            log(value.systemChargePercent, module: "Battery system state of charge")
            log(value.cycleCount, module: "Battery cycles")
            log(value.temperatureCelsius, module: "Battery temperature")
            log(value.power, module: "Battery power")
            log(value.voltageVolts, module: "Battery voltage")
            log(value.currentAmps, module: "Battery current")
            log(value.adapterVoltageVolts, module: "Battery adapter voltage")
            log(value.chargingCurrentAmps, module: "Battery charging current")
            log(value.chargingVoltageVolts, module: "Battery charging voltage")
            log(value.cellVoltagesVolts, module: "Battery cell voltages")
            log(value.notChargingReasonRaw, module: "Battery not-charging reason")
            log(value.timeRemaining, module: "Battery time remaining")
        }
    }

    private func publish() { onChange?(snapshot) }

    private func log<Value>(_ result: MetricResult<Value>, module: String) {
        if case .failure(let error) = result, error != .warmingUp {
            logFailure(error.localizedDescription, module: module)
        } else { logFailure("", module: module) }
    }

    private func logFailure(_ message: String, module: String) {
        guard loggedFailures[module] != message else { return }
        loggedFailures[module] = message
        if !message.isEmpty { logger.error("\(module, privacy: .public): \(message, privacy: .public)") }
    }
}
