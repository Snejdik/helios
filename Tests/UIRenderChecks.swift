import AppKit
import ServiceManagement
import SwiftUI

/// Offline renderer for the Helios (0.2) interface. A plain command-line Mach-O:
/// no Helios.app, no TelemetryMonitor, DaemonService, helper, notification
/// center, persistence or SMC. Fixture snapshots are re-dated to "now" so the
/// views' freshness rules see them as current, then rendered to PNG files.
@main
@MainActor
enum UIRenderChecks {
  /// Two days of app energy in ten-minute buckets: a charging evening, a night
  /// asleep (no samples) and a heavy Xcode morning, so the Energy page has a
  /// ranking, a comparison and an unobserved stretch to show.
  static func energyBuckets() -> [AppEnergyBucket] {
    // Relative to now: the page's windows end at the current time.
    let now = Date()
    let apps: [(String, String, Double)] = [
      ("app:/Applications/Safari.app", "Safari", 0.9), ("app:/Applications/Xcode.app", "Xcode", 0.6),
      ("app:/Applications/Slack.app", "Slack", 0.5), ("app:/System/Applications/Music.app", "Music", 0.3),
      ("app:/System/Applications/Mail.app", "Mail", 0.2),
    ]
    var buckets: [AppEnergyBucket] = []
    for step in stride(from: -288, through: 0, by: 1) {
      let date = now.addingTimeInterval(Double(step) * 600)
      let hour = Calendar.current.component(.hour, from: date)
      if hour < 6 { continue }
      let onBattery = hour >= 9 && hour < 22
      let level = max(20, 100 - Double(abs(step) % 90))
      let entries = apps.enumerated().map { index, app -> AppEnergyEntry in
        // The last hours lean heavily on Xcode, the earlier ones on Safari.
        let recent = step > -18
        let weight = app.2 * (app.1 == "Xcode" && recent ? 3.2 : 1) * (0.7 + 0.3 * sin(Double(step + index * 7) / 5))
        return AppEnergyEntry(
          appKey: app.0, displayName: app.1, energyWattHours: weight * 0.012, cpuCoreSeconds: weight * 40,
          wakeups: weight * 900, peakMemoryBytes: UInt64(weight * 600_000_000))
      }
      buckets.append(AppEnergyBucket(
        capturedAt: date, durationSeconds: 600, onBattery: onBattery, batteryPercent: level, entries: entries))
    }
    return buckets
  }

  static func main() {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
      print("usage: UIRenderChecks <output-directory> [scenario …]")
      exit(2)
    }
    let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)

    let requested = Set(arguments.dropFirst(2))
    let scenarios = UIFixtureCatalog.Scenario.allCases.filter {
      requested.isEmpty || requested.contains($0.rawValue)
    }
    var rendered = 0
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      application.appearance = NSAppearance(named: appearanceName)
      let suffix = appearanceName == .aqua ? "light" : "dark"
      for scenario in scenarios {
        let fixture = UIRenderFixture(UIFixtureCatalog.make(scenario))
        if scenario == .healthy {
          fixture.context.model.appEnergy = AppEnergyHistoryEngine.summary(Self.energyBuckets())
        }
        let pages: [HeliosPage] = scenario == .healthy ? HeliosPage.allCases : [.overview]
        for page in pages {
          rendered += render(
            HeliosMainWindowView(context: fixture.context, navigation: fixture.navigation(page)),
            size: CGSize(width: 1040, height: 720),
            to: output.appendingPathComponent("window-\(scenario.rawValue)-\(page.rawValue)-\(suffix).png"))
          if scenario == .healthy {
            rendered += render(
              fullPage(page, fixture: fixture).frame(width: 800),
              size: nil,
              to: output.appendingPathComponent("page-\(page.rawValue)-\(suffix).png"))
          }
        }
        rendered += render(
          HeliosStatusPopoverView(context: fixture.context)
            .background(Color(nsColor: .windowBackgroundColor)), size: nil,
          to: output.appendingPathComponent("popover-\(scenario.rawValue)-\(suffix).png"))
        if scenario == .healthy {
          // The menu-bar item row: every item is label over value; cooling carries the fan state.
          let bar = MenuBarView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 24),
            metrics: [.cpu, .memory, .cooling, .power, .temperature, .battery], identityStyle: .label)
          bar.frame.size.width = bar.configuredWidth
          let barSnapshot = fixture.context.model.snapshot
          bar.update(barSnapshot, now: barSnapshot.cpu.capturedAt)
          // Menu-bar text is drawn in the label color, so it needs a bar-like backdrop to be seen.
          let backdrop = NSBox(frame: bar.bounds.insetBy(dx: -8, dy: 0))
          backdrop.boxType = .custom
          backdrop.borderWidth = 0
          backdrop.contentViewMargins = .zero
          backdrop.fillColor = suffix == "dark" ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.88, alpha: 1)
          bar.frame.origin = NSPoint(x: 8, y: 0)
          backdrop.addSubview(bar)
          if let bitmap = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) {
            backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]),
              (try? png.write(to: output.appendingPathComponent("menubar-\(suffix).png"))) != nil
            { rendered += 1 }
          }
          for metric in HeliosMenuBarMetric.allCases {
            rendered += render(
              HeliosMetricStatusPopover(metric: metric, context: fixture.context)
                .background(Color(nsColor: .windowBackgroundColor)), size: nil,
              to: output.appendingPathComponent("metric-\(metric.rawValue)-\(suffix).png"))
          }
        }
      }
      if requested.isEmpty || requested.contains("onboarding") {
        let suite = "Helios.UIRender.Onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HeliosPreferences(defaults: defaults)
        let diagnostics = DiagnosticsController(preferences: DiagnosticsPreferences(defaults: defaults))
        let service = DaemonService(driver: RenderRegistration(), connectAutomatically: false)
        // Reminder banner (first seen two weeks ago) and the sidebar support row.
        let reminderSuite = "Helios.UIRender.Reminder.\(UUID().uuidString)"
        let reminderDefaults = UserDefaults(suiteName: reminderSuite)!
        defer { reminderDefaults.removePersistentDomain(forName: reminderSuite) }
        reminderDefaults.set(Date().addingTimeInterval(-14 * 86_400), forKey: HeliosInterfacePreferences.firstSeenKey)
        let reminderPreferences = HeliosPreferences(defaults: reminderDefaults)
        rendered += render(
          VStack(spacing: 24) {
            HeliosDiagnosticsReminder(
              diagnosticsPreferences: diagnostics.preferences, interface: reminderPreferences.interface,
              review: {})
            HeliosSupportRow().frame(width: 220)
          }
          .padding(20).frame(width: 640).background(Color(nsColor: .windowBackgroundColor)),
          size: nil, to: output.appendingPathComponent("reminder-support-\(suffix).png"))
        for page in HeliosOnboardingFlow.Page.allCases {
          rendered += render(
            HeliosOnboardingView(
              preferences: preferences, diagnostics: diagnostics, service: service,
              initialGoals: [.cooling, .battery], initialPage: page, onFinish: {}),
            size: CGSize(width: 720, height: 560),
            to: output.appendingPathComponent("onboarding-\(page.rawValue)-\(suffix).png"))
        }
      }
      if requested.isEmpty || requested.contains("settings") {
        let fixture = UIRenderFixture(UIFixtureCatalog.make(.healthy))
        let service = DaemonService(driver: RenderRegistration(), connectAutomatically: false)
        let diagnostics = DiagnosticsController(preferences: DiagnosticsPreferences())
        for route in HeliosSettingsRoute.allCases {
          let state = HeliosSettingsState()
          state.selection = route
          rendered += render(
            HeliosSettingsView(
              preferences: fixture.context.preferences, service: service, diagnostics: diagnostics,
              healthCenter: fixture.context.model.healthCenter, state: state),
            size: CGSize(width: 720, height: 1500),
            to: output.appendingPathComponent("settings-\(route.rawValue)-\(suffix).png"))
        }
      }
      if requested.isEmpty {
        rendered += render(
          UISettingsPreview().frame(width: 520).background(Color(nsColor: .windowBackgroundColor)),
          size: nil, to: output.appendingPathComponent("settings-components-\(suffix).png"))
      }
    }
    print("PASS rendered \(rendered) Helios 0.2 fixture images to \(output.path)")
  }

  @ViewBuilder
  static func fullPage(_ page: HeliosPage, fixture: UIRenderFixture) -> some View {
    let context = fixture.context
    Group {
      switch page {
      case .overview:
        HeliosOverviewPage(context: context, model: context.model, interface: context.interface,
          feed: context.feed, navigation: fixture.navigation(.overview))
      case .activity: HeliosActivityPage(feed: context.feed)
      case .history: HeliosHistoryPage(context: context, model: context.model, feed: context.feed)
      case .diagnostics: HeliosDiagnosticsPage(context: context, model: context.model)
      case .cpu: HeliosCPUPage(context: context, model: context.model)
      case .gpu: HeliosGPUPage(context: context, model: context.model)
      case .memory: HeliosMemoryPage(context: context, model: context.model)
      case .thermals: HeliosThermalsPage(context: context, model: context.model)
      case .battery: HeliosBatteryPage(context: context, model: context.model)
      case .energy: HeliosEnergyPage(context: context, model: context.model)
      case .storage: HeliosStoragePage(context: context, model: context.model)
      case .network: HeliosNetworkPage(context: context, model: context.model)
      case .hardware: HeliosHardwarePage(context: context, model: context.model)
      }
    }
    .padding(HeliosDesign.pagePadding)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  /// Renders inside an off-screen window that is never ordered in.
  static func render<V: View>(_ view: V, size: CGSize?, to url: URL) -> Int {
    let hosting = NSHostingView(rootView: view)
    let fitting = size ?? hosting.fittingSize
    let frame = NSRect(origin: .zero, size: CGSize(width: max(1, fitting.width), height: max(1, fitting.height)))
    let window = NSWindow(contentRect: frame, styleMask: size == nil ? [.borderless] : [.titled, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // Off-screen windows do not follow NSApp.appearance until shown; set it explicitly.
    window.appearance = NSApp.appearance
    window.contentView = hosting
    hosting.frame = frame
    for _ in 0..<4 {
      hosting.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    hosting.displayIfNeeded()
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return 0 }
    do { try png.write(to: url) } catch { return 0 }
    window.contentView = nil
    return 1
  }
}

/// One rendered scenario: a side-effect-free model plus synthetic history.
@MainActor
struct UIRenderFixture {
  let context: HeliosContext

  init(_ state: UIFixtureCatalog.State) {
    let suite = "Helios.UIRender.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let preferences = HeliosPreferences(defaults: defaults)
    preferences.interface.setPopoverSection(.activity, enabled: true)
    // Render complete pages; the default collection profile is exercised separately.
    if state.scenario != .waitingForFirstSample {
      for module in HeliosTelemetryModule.allCases { preferences.setTelemetryModuleEnabled(module, enabled: true) }
    }
    let model = OverviewViewModel(runtimeServicesEnabled: false)
    let now = Date()
    let shift = now.timeIntervalSince(UIFixtureCatalog.now)
    // Two minutes of 1 Hz history with gentle, deterministic variation.
    for second in stride(from: 120, through: 1, by: -1) {
      let at = now.addingTimeInterval(-Double(second))
      model.accept(Self.varied(state.snapshot, shift: shift - Double(second), phase: Double(second)), now: at)
    }
    model.accept(Self.redated(state.snapshot, shift: shift), now: now)
    let history = Self.persistentHistory(now: now)
    model.persistentHistory = PersistentHistorySummary(
      points: history, energyWattHours: 0, measuredPowerCoverageSeconds: 0)
    // Four months of daily battery health, slowly wearing.
    model.batteryHealth = BatteryHealthSummary(days: (0..<120).map { index in
      BatteryDayRecord(
        day: Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(119 - index) * 86_400)),
        healthPercent: 97 - Double(index) * 0.03 + (index % 7 == 0 ? 0.2 : 0),
        maximumCapacityMAh: 5_800 - index, designCapacityMAh: 6_000, cycleCount: 200 + index / 2)
    })
    let events = HeliosActivityTimeline.events(
      health: Self.healthRecords(now: now), history: history, activeIssueIDs: [])
    context = HeliosContext(
      model: model, preferences: preferences, service: nil,
      feed: HeliosActivityFeed(fixedEvents: events))
    defaults.removePersistentDomain(forName: suite)
  }

  func navigation(_ page: HeliosPage) -> HeliosNavigation {
    let navigation = HeliosNavigation()
    navigation.selection = page
    return navigation
  }

  static func redated<V>(_ sample: MetricSample<V>, shift: TimeInterval) -> MetricSample<V> {
    MetricSample(sample.result, capturedAt: sample.capturedAt.addingTimeInterval(shift),
      capturedTicks: sample.capturedTicks)
  }

  static func redated(_ snapshot: TelemetrySnapshot, shift: TimeInterval) -> TelemetrySnapshot {
    var copy = snapshot
    copy.cpu = redated(snapshot.cpu, shift: shift)
    copy.memory = redated(snapshot.memory, shift: shift)
    copy.gpu = redated(snapshot.gpu, shift: shift)
    copy.systemPower = redated(snapshot.systemPower, shift: shift)
    copy.system = redated(snapshot.system, shift: shift)
    copy.network = redated(snapshot.network, shift: shift)
    copy.wifi = redated(snapshot.wifi, shift: shift)
    copy.processes = redated(snapshot.processes, shift: shift)
    copy.battery = redated(snapshot.battery, shift: shift)
    copy.storage = redated(snapshot.storage, shift: shift)
    copy.thermals = redated(snapshot.thermals, shift: shift)
    copy.fans = redated(snapshot.fans, shift: shift)
    copy.fanOwnershipPreflight = redated(snapshot.fanOwnershipPreflight, shift: shift)
    copy.displays = redated(snapshot.displays, shift: shift)
    copy.volumes = redated(snapshot.volumes, shift: shift)
    copy.usb = redated(snapshot.usb, shift: shift)
    copy.bluetooth = redated(snapshot.bluetooth, shift: shift)
    copy.audio = redated(snapshot.audio, shift: shift)
    copy.powerAssertions = redated(snapshot.powerAssertions, shift: shift)
    copy.clock = redated(snapshot.clock, shift: shift)
    return copy
  }

  /// Varies CPU/temperature/power so charts have shape; other fields unchanged.
  static func varied(_ snapshot: TelemetrySnapshot, shift: TimeInterval, phase: Double) -> TelemetrySnapshot {
    var copy = redated(snapshot, shift: shift)
    let wave = (sin(phase / 9) + 1) / 2
    if case .success(let cpu) = snapshot.cpu.result {
      copy.cpu = MetricSample(.success(CPUMetrics(
        userPercent: cpu.userPercent + wave * 30, systemPercent: cpu.systemPercent,
        nicePercent: 0, idlePercent: max(0, cpu.idlePercent - wave * 30),
        perCoreUsagePercent: cpu.perCoreUsagePercent, physicalCoreCount: cpu.physicalCoreCount,
        performanceCoreCount: cpu.performanceCoreCount, efficiencyCoreCount: cpu.efficiencyCoreCount)),
        capturedAt: copy.cpu.capturedAt, capturedTicks: copy.cpu.capturedTicks)
    }
    if case .success(let thermals) = snapshot.thermals.result {
      copy.thermals = MetricSample(.success(ThermalMetrics(
        readings: thermals.readings.map {
          ThermalReading(key: $0.key, group: $0.group, celsius: $0.celsius - 6 + wave * 8)
        },
        failures: thermals.failures, trustedFailures: thermals.trustedFailures,
        advisoryReadingsCapturedAt: thermals.advisoryReadingsCapturedAt.map { $0.addingTimeInterval(shift) })),
        capturedAt: copy.thermals.capturedAt, capturedTicks: copy.thermals.capturedTicks)
    }
    return copy
  }

  static func persistentHistory(now: Date) -> [PersistedTelemetryPoint] {
    stride(from: 24.0 * 60 * 60, through: 150, by: -60).map { age in
      let hour = age / 3_600
      let busy = hour > 2 && hour < 2.4
      return PersistedTelemetryPoint(
        capturedAt: now.addingTimeInterval(-age), cpuPercent: busy ? 88 : 12 + 6 * sin(age / 900),
        memoryPercent: 62, gpuPercent: 10, maxSoCCelsius: busy ? 91 : 48 + 4 * sin(age / 700),
        systemPowerWatts: busy ? 32 : 8, batteryPercent: max(20, 100 - (24 - hour) * 2),
        batteryOnAC: hour > 6, storageTemperatureCelsius: 38, fanRPM: busy ? 4_200 : 0,
        networkDownloadBytesPerSecond: 200_000, networkUploadBytesPerSecond: 40_000)
    }
  }

  static func healthRecords(now: Date) -> [HealthEventRecord] {
    [
      HealthEventRecord(capturedAt: now.addingTimeInterval(-2.38 * 3_600), change: .activated,
        issueID: "soc-hot", severity: 1, title: "High SoC temperature", detail: "Max SoC 91.0°C"),
      HealthEventRecord(capturedAt: now.addingTimeInterval(-2.05 * 3_600), change: .resolved,
        issueID: "soc-hot", severity: 1, title: "High SoC temperature", detail: "Max SoC 91.0°C"),
      HealthEventRecord(capturedAt: now.addingTimeInterval(-20 * 3_600), change: .activated,
        issueID: "memory-warning", severity: 1, title: "Elevated memory pressure",
        detail: "macOS reports warning-level memory pressure."),
      HealthEventRecord(capturedAt: now.addingTimeInterval(-19.9 * 3_600), change: .resolved,
        issueID: "memory-warning", severity: 1, title: "Elevated memory pressure",
        detail: "macOS reports warning-level memory pressure."),
    ]
  }
}

/// The Settings pieces whose layout was fixed after the first runtime screenshots:
/// the segmented preset and the telemetry sampler rows (Settings itself needs a
/// DaemonService, which the offline renderer never creates).
struct UISettingsPreview: View {
  @State private var mode = HeliosDashboardMode.all

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Form {
        Section("Interface preset") {
          HeliosPresetPicker(selection: $mode)
          Text(mode.onboardingDetail).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .frame(height: 150)
      GroupBox("Telemetry samplers") {
        VStack(spacing: 0) {
          let modules = Array(HeliosTelemetryModule.allCases.prefix(6))
          ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
            HeliosSamplerRow(
              title: module.label, detail: module.detail, cost: module.monitoringCost,
              status: index == 4 ? "Sampler stopped" : "Collecting locally",
              isCollecting: index != 4, isOn: .constant(index != 4))
            if index < modules.count - 1 { Divider() }
          }
        }
        .padding(.horizontal, 4)
      }
    }
    .padding(16)
  }
}

/// Registration driver that never touches ServiceManagement: the offline renderer
/// builds a DaemonService only so Settings can draw; it never connects or registers.
private final class RenderRegistration: ServiceRegistrationDriver {
  var status: SMAppService.Status { .notRegistered }
  func register() throws {}
  func unregister() async throws {}
}
