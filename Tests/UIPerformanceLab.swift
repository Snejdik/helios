import AppKit
import ServiceManagement
import SwiftUI

/// Offline UI performance lab. A plain command-line Mach-O built from the app
/// sources without the app entry point: no Helios.app, TelemetryMonitor,
/// helper connection, notifications, persistence or SMC. A fake registration
/// driver reports "not registered", so the Legacy window's DaemonService never
/// connects. Windows are ordered in far off-screen so SwiftUI/AppKit update
/// exactly as when visible, while nothing appears on the user's displays.
///
/// Usage: UIPerformanceLab [seconds-per-state] [state …]
/// States: idle helios-overview helios-performance helios-thermals helios-activity
///         helios-popover after-helios legacy-monitor legacy-popover after-legacy
@main
@MainActor
enum UIPerformanceLab {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let seconds = arguments.first.flatMap(Double.init) ?? 15
    let requested = arguments.dropFirst().map { $0 }
    let states = requested.isEmpty ? LabState.allCases : requested.compactMap(LabState.init(rawValue:))
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let lab = Lab()
    lab.run(states: states, seconds: seconds)
    application.run()
  }
}

enum LabState: String, CaseIterable {
  /// Long power-state runs, as in real use (not a flip every minute).
  static func batteryRun(_ index: Int) -> Bool { (index / 600) % 2 == 0 }

  case idle
  case heliosOverview = "helios-overview"
  case heliosPerformance = "helios-performance"
  case heliosThermals = "helios-thermals"
  case heliosActivity = "helios-activity"
  case heliosHistory = "helios-history"
  case heliosDiagnostics = "helios-diagnostics"
  case heliosBattery = "helios-battery"
  case heliosStorage = "helios-storage"
  case heliosNetwork = "helios-network"
  case heliosHardware = "helios-hardware"
  case settingsGeneral = "settings-general"
  case settingsModules = "settings-modules"
  case settingsGraphs = "settings-graphs"
  case settingsFans = "settings-fans"
  case settingsBattery = "settings-battery"
  case settingsPrivacy = "settings-privacy"
  case settingsNotifications = "settings-notifications"
  case settingsAdvanced = "settings-advanced"
  case settingsAbout = "settings-about"
  case heliosPopover = "helios-popover"
  case afterHelios = "after-helios"
  case legacyMonitor = "legacy-monitor"
  case legacyPopover = "legacy-popover"
  case afterLegacy = "after-legacy"
}

/// Off-screen window that AppKit never pulls back onto a display.
final class LabWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class LabRegistration: ServiceRegistrationDriver {
  var status: SMAppService.Status { .notRegistered }
  func register() throws {}
  func unregister() async throws {}
}

@MainActor
final class Lab {
  let model = OverviewViewModel(runtimeServicesEnabled: false)
  let preferences: HeliosPreferences
  let service = DaemonService(driver: LabRegistration(), connectAutomatically: false)
  let base = UIFixtureCatalog.make(.healthy).snapshot
  var tick = 0
  var window: LabWindow?
  var timer: Timer?
  let suite = "Helios.UIPerformanceLab.\(UUID().uuidString)"

  init() {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    preferences = HeliosPreferences(defaults: defaults)
    for module in HeliosTelemetryModule.allCases {
      preferences.setTelemetryModuleEnabled(module, enabled: true)
    }
    preferences.interface.setPopoverSection(.activity, enabled: true)
    seedHistory()
  }

  /// Full-size bounded histories, as after a long session.
  func seedHistory() {
    let now = Date()
    for second in stride(from: TelemetryHistory.maximumPoints, through: 1, by: -1) {
      tick += 1
      model.accept(snapshot(at: now.addingTimeInterval(-Double(second))),
        now: now.addingTimeInterval(-Double(second)))
    }
    var points: [PersistedTelemetryPoint] = []
    var age: Double = 24 * 3_600
    while age >= 120 {
      let cpu: Double = 15 + 10 * sin(age / 600)
      let soc: Double = 50 + 8 * sin(age / 900)
      let onAC: Bool = Int(age / 7_200) % 2 == 0
      let point = PersistedTelemetryPoint(
        capturedAt: now.addingTimeInterval(-age), cpuPercent: cpu,
        memoryPercent: 70, gpuPercent: 10, maxSoCCelsius: soc,
        systemPowerWatts: 9, batteryPercent: 80, batteryHealthPercent: 95, batteryPowerWatts: -6,
        batteryOnAC: onAC, batteryTemperatureCelsius: 31, batteryCycleCount: 40,
        storageTemperatureCelsius: 38, storageReadBytesPerSecond: 1e6, storageWriteBytesPerSecond: 5e5,
        heliosCPUPercent: 1, heliosPowerWatts: 0.05, heliosMemoryBytes: 60 << 20,
        heliosWakeupsPerSecond: 5, fanRPM: 0, networkDownloadBytesPerSecond: 2e5,
        networkUploadBytesPerSecond: 4e4)
      points.append(point)
      age -= 30
    }
    model.persistentHistory = PersistentHistorySummary(
      points: points, energyWattHours: 0, measuredPowerCoverageSeconds: 0)
    // Seven days of one-minute app-energy buckets, 20 apps each (store bound 10,500).
    let apps = (0..<20).map { "app:/Applications/Lab App \($0).app" }
    let buckets = (0..<10_000).map { index -> AppEnergyBucket in
      AppEnergyBucket(
        capturedAt: now.addingTimeInterval(-Double(10_000 - index) * 60), durationSeconds: 60,
        onBattery: LabState.batteryRun(index), batteryPercent: 80,
        entries: apps.enumerated().map { offset, key in
          AppEnergyEntry(appKey: key, displayName: "Lab App \(offset)", energyWattHours: 0.01,
            cpuCoreSeconds: 3, wakeups: 100, peakMemoryBytes: 100 << 20)
        })
    }
    model.appEnergy = AppEnergyHistoryEngine.summary(AppEnergyHistoryEngine.coarsened(buckets, now: now))
  }

  /// Realistic varying snapshot with 24 process leaders.
  func snapshot(at date: Date) -> TelemetrySnapshot {
    var copy = base
    func dated<V>(_ sample: MetricSample<V>) -> MetricSample<V> {
      MetricSample(sample.result, capturedAt: date, capturedTicks: UInt64(tick))
    }
    copy.memory = dated(base.memory); copy.gpu = dated(base.gpu)
    copy.systemPower = dated(base.systemPower); copy.system = dated(base.system)
    copy.network = dated(base.network); copy.wifi = dated(base.wifi)
    copy.battery = dated(base.battery); copy.storage = dated(base.storage)
    copy.fans = dated(base.fans); copy.fanOwnershipPreflight = dated(base.fanOwnershipPreflight)
    copy.displays = dated(base.displays); copy.volumes = dated(base.volumes)
    copy.usb = dated(base.usb); copy.bluetooth = dated(base.bluetooth); copy.audio = dated(base.audio)
    copy.powerAssertions = dated(base.powerAssertions); copy.clock = dated(base.clock)
    let wave = (sin(Double(tick) / 7) + 1) / 2
    copy.cpu = MetricSample(.success(CPUMetrics(
      userPercent: 8 + wave * 30, systemPercent: 4, nicePercent: 0, idlePercent: 88 - wave * 30,
      perCoreUsagePercent: (0..<10).map { _ in 10 + wave * 40 },
      physicalCoreCount: .success(10), performanceCoreCount: .success(4),
      efficiencyCoreCount: .success(6))), capturedAt: date, capturedTicks: UInt64(tick))
    copy.thermals = MetricSample(.success(ThermalMetrics(
      readings: [
        ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 48 + wave * 10),
        ThermalReading(key: "Te05", group: .efficiencyCPU, celsius: 44 + wave * 5),
        ThermalReading(key: "Tg0G", group: .gpu, celsius: 46 + wave * 6),
      ] + (0..<60).map { ThermalReading(key: String(format: "Tz%02d", $0), group: .unclassified, celsius: 40) },
      failures: [:], trustedFailures: [:], advisoryReadingsCapturedAt: date)),
      capturedAt: date, capturedTicks: UInt64(tick))
    var processes: [ProcessActivity] = []
    for index in 0..<24 {
      let path: String = "/Applications/Lab App \(index % 8).app/Contents/MacOS/Lab Process \(index)"
      let footprint: UInt64 = UInt64(100 + index) << 20
      let cpu: Double = Double(24 - index) * (1 + wave)
      processes.append(ProcessActivity(
        pid: Int32(500 + index), name: "Lab Process \(index)", executablePath: path,
        physicalFootprintBytes: footprint, neuralFootprintBytes: 0,
        cpuPercent: cpu, powerWatts: 0.1, performanceCorePowerWatts: 0.05,
        diskReadBytesPerSecond: 1_000, diskWriteBytesPerSecond: 500, wakeupsPerSecond: 20,
        instructionsPerSecond: 1e8, cyclesPerSecond: 5e7, instructionsPerCycle: 2))
    }
    copy.processes = MetricSample(.success(ProcessMetrics(
      accessibleProcessCount: 650, topByCPU: processes, topByEnergy: processes,
      energyHistoryLeaders: processes, topByMemory: processes.reversed())),
      capturedAt: date, capturedTicks: UInt64(tick))
    return copy
  }

  func run(states: [LabState], seconds: Double) {
    // 1 Hz publication, like TelemetryMonitor → StatusItemController.update.
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.tick += 1
        self.model.accept(self.snapshot(at: Date()))
      }
    }
    print("state\tseconds\tcpu_ms_per_s\tfootprint_mb\tpeak_mb")
    var remaining = states
    func next() {
      guard !remaining.isEmpty else {
        timer?.invalidate()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        exit(0)
      }
      let state = remaining.removeFirst()
      show(state)
      // Warm-up excluded from the measured interval.
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let start = Self.cpuSeconds()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
          let used = (Self.cpuSeconds() - start) * 1000 / seconds
          let memory = Self.footprint()
          print(String(format: "%@\t%.0f\t%.1f\t%.1f\t%.1f", state.rawValue, seconds, used,
            memory.current, memory.peak))
          fflush(stdout)
          next()
        }
      }
    }
    next()
  }

  func show(_ state: LabState) {
    close()
    switch state {
    case .idle, .afterHelios, .afterLegacy:
      HeliosAppIconCache.shared.purge()
      if ProcessInfo.processInfo.environment["HELIOS_LAB_RELIEF"] == "1" {
        malloc_zone_pressure_relief(nil, 0)
      }
    case .heliosOverview: showHelios(.overview)
    case .heliosPerformance: showHelios(.cpu)
    case .heliosThermals: showHelios(.thermals)
    case .heliosActivity: showHelios(.activity)
    case .heliosHistory: showHelios(.history)
    case .heliosDiagnostics: showHelios(.diagnostics)
    case .heliosBattery: showHelios(.battery)
    case .heliosStorage: showHelios(.storage)
    case .heliosNetwork: showHelios(.network)
    case .heliosHardware: showHelios(.hardware)
    case .settingsGeneral: showSettings(.general)
    case .settingsModules: showSettings(.modules)
    case .settingsGraphs: showSettings(.graphs)
    case .settingsFans: showSettings(.fans)
    case .settingsBattery: showSettings(.battery)
    case .settingsPrivacy: showSettings(.privacy)
    case .settingsNotifications: showSettings(.notifications)
    case .settingsAdvanced: showSettings(.advanced)
    case .settingsAbout: showSettings(.about)
    case .heliosPopover:
      let context = HeliosContext(model: model, preferences: preferences, service: service,
        feed: HeliosActivityFeed(model: model))
      present(NSHostingController(rootView: HeliosStatusPopoverView(context: context)),
        size: NSSize(width: 340, height: 640))
    case .legacyMonitor:
      let controller = HeliosMonitorWindowController(
        model: model, service: service, preferences: preferences, openEnergyInspector: {})
      let content = controller.window?.contentViewController
      controller.window?.contentViewController = nil
      if let content { present(content, size: NSSize(width: 1040, height: 720)) }
    case .legacyPopover:
      present(OverviewViewController(model: model, service: service, preferences: preferences),
        size: NSSize(width: 420, height: 600))
    }
  }

  func showSettings(_ route: HeliosSettingsRoute) {
    let diagnostics = DiagnosticsController(preferences: DiagnosticsPreferences())
    let state = HeliosSettingsState()
    state.selection = route
    let content = HeliosSettingsView(
      preferences: preferences, service: service, diagnostics: diagnostics,
      healthCenter: model.healthCenter, state: state)
    present(NSHostingController(rootView: content), size: NSSize(width: 720, height: 520))
  }

  func showHelios(_ page: HeliosPage) {
    let navigation = HeliosNavigation()
    navigation.selection = page
    let context = HeliosContext(model: model, preferences: preferences, service: service,
      feed: HeliosActivityFeed(model: model))
    present(NSHostingController(rootView: HeliosMainWindowView(context: context, navigation: navigation)),
      size: NSSize(width: 1040, height: 720))
  }

  func present(_ content: NSViewController, size: NSSize) {
    let window = LabWindow(
      contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = content
    window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    window.orderFrontRegardless()
    self.window = window
  }

  func close() {
    guard let window else { return }
    window.orderOut(nil)
    window.contentViewController = nil
    window.contentView = NSView()
    self.window = nil
  }

  static func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }

  static func footprint() -> (current: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
  }
}
