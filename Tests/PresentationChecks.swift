import AppKit
import ServiceManagement
import SwiftUI

@MainActor
private final class PresentationRegistration: ServiceRegistrationDriver {
  let status: SMAppService.Status
  init(_ status: SMAppService.Status) { self.status = status }
  func register() throws {}
  func unregister() async throws {}
}

private struct PresentationCheckFailure: Error {
  let message: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw PresentationCheckFailure(message: message) }
}

@main
@MainActor
private struct PresentationChecks {
  static func main() {
    do { try run() } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }

  private static func run() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let now = Date()
    let normal = fixture(cpu: 12, temperature: 56, now: now)
    let summary = try OverviewPresentation(normal, now: now).temperatures(.performanceCPU).get()
    try require(
      summary.average == 52 && summary.maximum == 56,
      "Average must include only the selected group's sensors")
    let hottest = try normal.thermals.result.get().maximumSoCCelsius.get()
    try require(hottest == 56, "Unclassified sensors must not affect the SoC maximum")
    let expired = OverviewPresentation(normal, now: now.addingTimeInterval(16))
    try require(
      DisplayValue(expired.cpu.map(\.usagePercent)) { String($0) }.failure != nil,
      "CPU staleness must survive presentation")
    try require(
      DisplayValue(expired.battery.flatMap(\.power)) { String($0.signedWatts) }.failure != nil,
      "Battery staleness must survive presentation")
    try require(
      DisplayValue(expired.gpu.flatMap(\.deviceUtilizationPercent)) { String($0) }.failure != nil,
      "GPU staleness must survive presentation")
    try require(
      DisplayValue(expired.systemPower.flatMap(\.totalSystemWatts)) { String($0) }.failure != nil,
      "System power staleness must survive presentation")
    try require(
      DisplayValue(expired.wifi.map(\.interfaceName)) { $0 }.failure != nil,
      "Wi-Fi staleness must survive presentation")
    try require(
      DisplayValue(expired.processes.map(\.accessibleProcessCount)) { String($0) }.failure != nil,
      "Process staleness must survive presentation")

    // UI8 battery ETA must prefer macOS when available, but produce a fast
    // explicitly approximate read-only fallback instead of waiting indefinitely
    // on IOPowerSources "calculating".
    let calculatingBattery = BatteryMetrics(
      designCapacityMAh: .success(6_249), maximumCapacityMAh: .success(6_348),
      currentCapacityMAh: .success(4_962), cycleCount: .success(4),
      temperatureCelsius: .success(30.5),
      power: .success(BatteryPower(signedWatts: -12.45, usesInstantaneousCurrent: true)),
      powerSource: .success(.battery), voltageVolts: .success(12.31),
      currentAmps: .success(-1.01), isCharging: .success(false),
      timeRemaining: .success(.calculating))
    let fastEstimate = HeliosBatteryEstimateEngine.estimate(
      battery: .success(calculatingBattery), history: TelemetryHistory(), now: now)
    try require(
      fastEstimate.source == .helios && fastEstimate.approximate && fastEstimate.seconds != nil,
      "UI8 battery ETA must provide a fast approximate fallback while macOS is calculating")
    let electricalFallbackBattery = BatteryMetrics(
      designCapacityMAh: .success(6_249), maximumCapacityMAh: .success(6_348),
      currentCapacityMAh: .success(4_962), cycleCount: .success(4),
      temperatureCelsius: .success(30.5), power: .failure(.unavailable("Power pending")),
      powerSource: .success(.battery), voltageVolts: .success(12.31),
      currentAmps: .success(-0.72), isCharging: .success(false),
      timeRemaining: .success(.calculating))
    let electricalEstimate = HeliosBatteryEstimateEngine.estimate(
      battery: .success(electricalFallbackBattery), history: TelemetryHistory(), now: now)
    try require(
      electricalEstimate.source == .helios && electricalEstimate.seconds != nil,
      "UI8 battery ETA must fall back to read-only current × voltage when BatteryPower is pending")
    let systemBattery = BatteryMetrics(
      designCapacityMAh: .success(6_249), maximumCapacityMAh: .success(6_348),
      currentCapacityMAh: .success(4_962), cycleCount: .success(4),
      temperatureCelsius: .success(30.5),
      power: .success(BatteryPower(signedWatts: -12.45, usesInstantaneousCurrent: true)),
      powerSource: .success(.battery), voltageVolts: .success(12.31),
      timeRemaining: .success(.seconds(14_400)))
    let systemEstimate = HeliosBatteryEstimateEngine.estimate(
      battery: .success(systemBattery), history: TelemetryHistory(), now: now)
    try require(
      systemEstimate.source == .macOS && !systemEstimate.approximate
        && systemEstimate.seconds == 14_400,
      "UI8 battery ETA must prefer a valid macOS estimate over the Helios fallback")

    let persistentGraphPoints = [
      graphPersistentPoint(at: now.addingTimeInterval(-240), cpu: 12),
      graphPersistentPoint(at: now.addingTimeInterval(-210), cpu: 18),
    ]
    let liveGraphPoints = [
      graphLivePoint(at: now.addingTimeInterval(-4), cpu: 30),
      graphLivePoint(at: now.addingTimeInterval(-3), cpu: 35),
    ]
    let gapSafeGraph = HeliosChartSeries.merged(
      now: now, range: .fiveMinutes, live: liveGraphPoints, persistent: persistentGraphPoints,
      liveValue: \.cpuPercent, persistentValue: \.cpuPercent)
    try require(
      gapSafeGraph.contains { $0.value == nil },
      "UI8 chart merge must leave a visible gap across long app/sleep outages")
    try require(
      gapSafeGraph.last?.value == 35,
      "UI8 chart merge must retain the newest high-resolution live sample")

    let directory = URL(fileURLWithPath: ".build/Presentation", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let widget = MenuBarView(frame: NSRect(x: 0, y: 0, width: MenuBarView.fixedWidth, height: 24))
    let frame = widget.frame
    let cases: [(String, TelemetrySnapshot, String, String)] = [
      ("one-digit", fixture(cpu: 1, temperature: 9, now: now), "1%", "9°C"),
      ("two-digit", fixture(cpu: 99, temperature: 99, now: now), "99%", "99°C"),
      ("three-digit", fixture(cpu: 100, temperature: 100, now: now), "100%", "100°C"),
      ("upper-bound", fixture(cpu: 100, temperature: 150, now: now), "100%", "150°C"),
      ("unavailable", TelemetrySnapshot(), "—", "—"),
    ]
    for (name, snapshot, cpuText, temperatureText) in cases {
      widget.update(snapshot, now: now)
      widget.layoutSubtreeIfNeeded()
      try require(
        widget.frame == frame && widget.intrinsicContentSize.width == MenuBarView.fixedWidth,
        "Widget width changed in \(name) state")
      try require(
        widget.cpuText == cpuText && widget.temperatureText == temperatureText,
        "Unexpected status text in \(name) state")
      for text in [widget.cpuText, widget.temperatureText] {
        let size = (text as NSString).size(withAttributes: [.font: MenuBarView.valueFont])
        try require(
          ceil(size.width) <= 36 && ceil(size.height) <= 14, "Readout clips: \(text), \(size)")
      }
      try require(
        widget.hitTest(NSPoint(x: 20, y: 12)) == nil,
        "Subview must not intercept native status-button clicks")
      for scale in [1, 2] {
        try renderWidget(
          widget, scale: scale, dark: false,
          to: directory.appendingPathComponent("status-\(name)-\(scale)x.png"))
      }
    }
    widget.update(normal, now: now)
    try renderWidget(
      widget, scale: 2, dark: true, to: directory.appendingPathComponent("status-dark-2x.png"))
    widget.isHighlighted = true
    try renderWidget(
      widget, scale: 2, dark: true,
      to: directory.appendingPathComponent("status-highlighted-2x.png"))
    widget.update(normal, now: now.addingTimeInterval(7))
    try require(
      widget.cpuText == "—" && widget.temperatureText == "—", "Stale status values must clear")

    // A native metric item must not redraw for unrelated telemetry changes.
    // The static hub has no live values at all. This guards the AppKit replicant
    // work seen in the near-final CPU profile without changing visible content.
    let temperatureItem = MenuBarView(
      frame: NSRect(x: 0, y: 0, width: 50, height: 24), metrics: [.temperature])
    temperatureItem.update(normal, now: now)
    let unrelatedInvalidation = temperatureItem.update(
      fixture(cpu: 80, temperature: 56, now: now), now: now)
    try require(!unrelatedInvalidation, "CPU changes requested a temperature-only redraw")
    let staleInvalidation = temperatureItem.update(normal, now: now.addingTimeInterval(16))
    try require(staleInvalidation && temperatureItem.temperatureText == "—",
                "Stale visible temperature must request redraw and clear its text")
    let hub = MenuBarView(frame: NSRect(x: 0, y: 0, width: 24, height: 24), metrics: [])
    try require(!hub.update(normal, now: now), "Static dashboard hub requested a live redraw")
    print("PASS native metric redraw isolation, static hub stability, and stale-value redraw")

    let preferencesSuite = "Helios.PresentationChecks.\(UUID().uuidString)"
    guard let preferencesDefaults = UserDefaults(suiteName: preferencesSuite) else {
      throw PresentationCheckFailure(message: "Unable to create isolated preferences suite")
    }
    preferencesDefaults.removePersistentDomain(forName: preferencesSuite)
    let preferences = HeliosPreferences(defaults: preferencesDefaults)
    try require(
      preferences.menuBarMetrics == [.cpu, .temperature], "Next23 default menu-bar modules changed")
    try require(
      preferences.popoverModules == [.summary, .cooling]
        && preferences.dashboardMetrics == HeliosPreferences.simpleDashboardMetrics
        && !preferences.detailedMonitorContent,
      "Next23 default dashboard modules/density changed")
    try require(
      preferences.monitorRoutes == HeliosMonitorRoute.allCases,
      "Existing/fresh Full Monitor must retain every module until onboarding or explicit customization"
    )
    try require(!preferences.onboardingCompleted, "Fresh preferences must require first-run setup")
    try require(
      preferences.menuBarLayout == .nativeModules && preferences.showMenuBarHub,
      "Fresh UI8 preferences must use native metric status items with the optional Helios hub")
    try require(
      preferences.graphLineStyle == .smooth && preferences.animateGraphUpdates
        && preferences.graphRange == .fiveMinutes
        && HeliosGraphScope.allCases.allSatisfy { preferences.graphRange(for: $0) == .fiveMinutes },
      "Fresh UI8 graph preferences must use smooth, animated five-minute charts")
    try require(
      preferences.identityStyle(for: .cpu) == .label && preferences.label(for: .memory) == "RAM",
      "Fresh UI8 per-module menu-bar identities must use readable defaults")

    // A stored dashboard preset with no explicit dashboard-module customization
    // must seed modules from that preset. This also covers the initializer path
    // that previously regressed into an illegal pre-initialization self access.
    let migrationSuite = "Helios.PresentationMigration.\(UUID().uuidString)"
    guard let migrationDefaults = UserDefaults(suiteName: migrationSuite) else {
      throw PresentationCheckFailure(message: "Unable to create migration preferences suite")
    }
    migrationDefaults.removePersistentDomain(forName: migrationSuite)
    defer { migrationDefaults.removePersistentDomain(forName: migrationSuite) }
    migrationDefaults.set(HeliosDashboardMode.advanced.rawValue, forKey: "next23.ui.dashboardMode")
    let migratedPreferences = HeliosPreferences(defaults: migrationDefaults)
    try require(
      migratedPreferences.dashboardMode == .advanced
        && migratedPreferences.popoverModules == HeliosPreferences.advancedPopoverModules
        && migratedPreferences.dashboardMetrics == HeliosPreferences.advancedDashboardMetrics
        && !migratedPreferences.detailedMonitorContent,
      "Stored dashboard preset must seed dashboard modules without explicit module customization")

    let reachabilitySuite = "Helios.PresentationReachability.\(UUID().uuidString)"
    guard let reachabilityDefaults = UserDefaults(suiteName: reachabilitySuite) else {
      throw PresentationCheckFailure(message: "Unable to create reachability preferences suite")
    }
    reachabilityDefaults.removePersistentDomain(forName: reachabilitySuite)
    defer { reachabilityDefaults.removePersistentDomain(forName: reachabilitySuite) }
    reachabilityDefaults.set([], forKey: "next23.ui.menuBarMetrics")
    reachabilityDefaults.set(
      HeliosMenuBarLayout.nativeModules.rawValue, forKey: "next23.ui8.menuBarLayout")
    reachabilityDefaults.set(false, forKey: "next23.ui8.menuBarHub")
    let reachablePreferences = HeliosPreferences(defaults: reachabilityDefaults)
    try require(
      reachablePreferences.menuBarMetrics.isEmpty && reachablePreferences.showMenuBarHub,
      "Persisted empty native layout must normalize the Helios recovery hub back on")

    preferences.setPopoverModuleEnabled(.performance, enabled: true)
    try require(
      preferences.popoverModules == [.summary, .cooling, .performance],
      "Dashboard modules must append deterministically")
    preferences.movePopoverModule(.performance, offset: -1)
    try require(
      preferences.popoverModules == [.summary, .performance, .cooling],
      "Dashboard module one-step ordering failed")
    preferences.setPopoverModuleEnabled(.performance, enabled: false)
    try require(
      preferences.popoverModules == [.summary, .cooling],
      "Dashboard module removal must preserve remaining order")
    preferences.completeOnboarding(with: .advanced)
    try require(
      preferences.onboardingCompleted
        && preferences.dashboardMode == .advanced
        && preferences.popoverModules == HeliosPreferences.advancedPopoverModules
        && preferences.menuBarMetrics == [.cpu, .memory, .temperature]
        && preferences.menuBarIdentityStyle == .label
        && preferences.dashboardMetrics == HeliosPreferences.advancedDashboardMetrics
        && !preferences.detailedMonitorContent
        && preferences.monitorRoutes == [
          .overview, .cpu, .memory, .gpu, .thermals, .battery, .energy, .storage, .network,
          .processes,
          .history,
          .health, .system,
        ],
      "Balanced onboarding preset must configure a safe deterministic starting layout")
    preferences.setMonitorRouteEnabled(.expert, enabled: false)
    try require(
      !preferences.monitorRoutes.contains(.expert) && preferences.monitorRoutes.first == .overview,
      "Full Monitor customization must hide modules without removing the pinned Overview")
    let monitorReload = HeliosPreferences(defaults: preferencesDefaults)
    try require(
      !monitorReload.monitorRoutes.contains(.expert)
        && monitorReload.monitorRoutes.first == .overview,
      "Full Monitor module visibility/order must persist")
    preferences.setMonitorRouteEnabled(.overview, enabled: false)
    try require(
      preferences.monitorRoutes.first == .overview,
      "Full Monitor Overview must remain pinned and non-removable")
    preferences.resetInterface()
    try require(
      preferences.popoverModules == HeliosPreferences.simplePopoverModules
        && preferences.menuBarMetrics == HeliosPreferences.defaultMenuBarMetrics
        && preferences.menuBarIdentityStyle == .label
        && preferences.menuBarLayout == .nativeModules && preferences.showMenuBarHub
        && preferences.graphLineStyle == .smooth && preferences.animateGraphUpdates
        && preferences.graphRange == .fiveMinutes
        && HeliosGraphScope.allCases.allSatisfy { preferences.graphRange(for: $0) == .fiveMinutes }
        && preferences.dashboardMetrics == HeliosPreferences.simpleDashboardMetrics
        && !preferences.detailedMonitorContent
        && preferences.colorHex(for: .cpu) == HeliosColorRole.cpu.defaultHex
        && preferences.monitorRoutes == HeliosMonitorRoute.allCases,
      "Interface reset must restore safe dashboard/menu-bar defaults and the complete monitor")
    try require(
      widget.coolingFanText == "—",
      "Stale cooling RPM must clear with the rest of the menu-bar telemetry")
    widget.update(normal, now: now)
    try require(widget.coolingFanText == "Fan off", "Zero-RPM cooling readout must say Fan off")
    var runningFan = normal
    runningFan.fans = MetricSample(
      .success(
        FanInventory(fans: [
          FanReading(
            id: 0, actualRPM: .success(1_556), targetRPM: .success(1_600),
            minimumRPM: .success(1_200), maximumRPM: .success(6_550), automatic: .success(true))
        ])), capturedAt: now)
    widget.update(runningFan, now: now)
    try require(
      widget.coolingFanText == "1556 RPM", "Running cooling readout must expose actual fan RPM")
    try renderWidget(
      widget, scale: 2, dark: false,
      to: directory.appendingPathComponent("status-cooling-running-2x.png"))
    var fanless = normal
    fanless.fans = MetricSample(.success(FanInventory(fans: [])), capturedAt: now)
    widget.update(fanless, now: now)
    try require(
      widget.coolingFanText == "Fanless", "Fanless Macs must never be mislabeled as a stopped fan")
    try renderWidget(
      widget, scale: 2, dark: false,
      to: directory.appendingPathComponent("status-cooling-fanless-2x.png"))
    widget.update(normal, now: now)
    preferences.setIdentityStyle(.symbol, for: .memory)
    preferences.setLabel("MEM", for: .memory)
    preferences.menuBarLayout = .compactGroup
    preferences.showMenuBarHub = false
    preferences.graphLineStyle = .raw
    preferences.animateGraphUpdates = false
    preferences.setGraphRange(.oneMinute, for: .cpu)
    preferences.setGraphRange(.sixHours, for: .battery)
    let ui8Reload = HeliosPreferences(defaults: preferencesDefaults)
    try require(
      ui8Reload.identityStyle(for: .memory) == .symbol && ui8Reload.label(for: .memory) == "MEM",
      "UI8 per-module identity and custom label must persist independently")
    try require(
      ui8Reload.menuBarLayout == .compactGroup && !ui8Reload.showMenuBarHub,
      "UI8 menu-bar layout and hub visibility must persist")
    try require(
      ui8Reload.graphLineStyle == .raw && !ui8Reload.animateGraphUpdates
        && ui8Reload.graphRange(for: .cpu) == .oneMinute
        && ui8Reload.graphRange(for: .battery) == .sixHours
        && ui8Reload.graphRange(for: .memory) == .fiveMinutes,
      "UI8 graph line, animation and per-module time-range preferences must persist")
    preferences.setDashboardMetricEnabled(.gpu, enabled: true)
    preferences.setColorHex("#123456FF", for: .cpu)
    preferences.detailedMonitorContent = true
    let ui10Reload = HeliosPreferences(defaults: preferencesDefaults)
    try require(
      ui10Reload.isDashboardMetricEnabled(.gpu)
        && ui10Reload.colorHex(for: .cpu) == "#123456FF"
        && ui10Reload.detailedMonitorContent,
      "UI10 dashboard composition, module colors and Full Monitor density must persist")
    preferences.resetColors()
    preferences.detailedMonitorContent = false

    preferences.setAllGraphRanges(.oneHour)
    let ui8AllRangesReload = HeliosPreferences(defaults: preferencesDefaults)
    try require(
      ui8AllRangesReload.graphRange == .oneHour
        && HeliosGraphScope.allCases.allSatisfy {
          ui8AllRangesReload.graphRange(for: $0) == .oneHour
        },
      "UI8 default time-range control must be able to apply one range to every chart")
    preferences.setIdentityStyle(.label, for: .memory)
    preferences.setLabel("RAM", for: .memory)
    preferences.menuBarLayout = .nativeModules
    preferences.showMenuBarHub = true
    preferences.graphLineStyle = .smooth
    preferences.animateGraphUpdates = true
    preferences.setAllGraphRanges(.fiveMinutes)

    preferences.setEnabled(.memory, enabled: true)
    try require(
      preferences.menuBarMetrics == [.cpu, .temperature, .memory],
      "New menu-bar modules must append deterministically")
    preferences.move(.memory, offset: -1)
    try require(
      preferences.menuBarMetrics == [.cpu, .memory, .temperature],
      "Menu-bar one-step upward ordering failed")
    preferences.move(.memory, offset: -1)
    try require(
      preferences.menuBarMetrics == [.memory, .cpu, .temperature],
      "Menu-bar repeated ordering failed")
    preferences.move(.memory, offset: -1)
    try require(
      preferences.menuBarMetrics == [.memory, .cpu, .temperature],
      "Menu-bar boundary move must be a no-op")
    widget.configure(metrics: preferences.menuBarMetrics, showsSymbols: true)
    let symbolContent = HeliosMenuBarContent(legacy: .symbol)
    let expectedConfiguredWidth =
      [HeliosMenuBarMetric.memory, .cpu, .temperature].reduce(CGFloat.zero) { partial, metric in
        partial
          + MenuBarView.configuredWidth(
            for: metric, content: symbolContent, label: metric.shortLabel, spacing: 2)
      } + MenuBarView.compactGroupGap(for: 2) * 2
    try require(
      widget.configuredWidth == expectedConfiguredWidth,
      "Configured status width must depend only on selected modules")
    widget.setModuleSpacing(0)
    let compactConfiguredWidth = widget.configuredWidth
    widget.setModuleSpacing(8)
    let comfortableConfiguredWidth = widget.configuredWidth
    try require(
      compactConfiguredWidth < expectedConfiguredWidth
        && comfortableConfiguredWidth > expectedConfiguredWidth,
      "Menu-bar spacing must adjust geometry monotonically without live-value jitter")
    widget.setModuleSpacing(2)
    try require(
      widget.configuredWidth == expectedConfiguredWidth,
      "Restoring balanced spacing must restore deterministic module geometry")
    for style in HeliosMenuBarIdentityStyle.allCases {
      widget.configure(metrics: preferences.menuBarMetrics, identityStyle: style)
      try require(
        widget.configuredWidth == expectedConfiguredWidth,
        "Menu-bar identity style must never alter configured geometry")
      try renderWidget(
        widget, scale: 2, dark: false,
        to: directory.appendingPathComponent("status-identity-\(style.rawValue)-2x.png"))
    }
    preferences.menuBarIdentityStyle = .valueOnly
    widget.configure(
      metrics: preferences.menuBarMetrics, identityStyle: preferences.menuBarIdentityStyle)
    try require(
      widget.configuredWidth == expectedConfiguredWidth,
      "Changing menu-bar identity style must not jitter menu-bar geometry")

    let reloadedPreferences = HeliosPreferences(defaults: preferencesDefaults)
    try require(
      reloadedPreferences.menuBarMetrics == [.memory, .cpu, .temperature],
      "Menu-bar ordering must persist exactly")
    try require(
      reloadedPreferences.menuBarIdentityStyle == .valueOnly,
      "Menu-bar identity style must persist")

    preferences.setEnabled(.memory, enabled: false)
    widget.configure(metrics: preferences.menuBarMetrics, showsSymbols: true)
    try require(
      preferences.menuBarMetrics == [.cpu, .temperature],
      "Removing a menu-bar module must preserve remaining order")
    try require(
      widget.configuredWidth == MenuBarView.fixedWidth,
      "Default compact-group width must remain stable for CPU + Temperature")

    preferences.setMenuBarHubVisible(false)
    preferences.setEnabled(.cpu, enabled: false)
    preferences.setEnabled(.temperature, enabled: false)
    widget.configure(metrics: preferences.menuBarMetrics, showsSymbols: true)
    try require(
      preferences.menuBarMetrics.isEmpty && widget.configuredWidth == 24,
      "Empty menu-bar configuration must fall back to the compact Helios glyph")
    try require(
      preferences.showMenuBarHub,
      "Native menu-bar customization must keep one Helios recovery item when every metric is removed"
    )
    preferences.resetMenuBar()
    try require(
      preferences.menuBarMetrics == [.cpu, .temperature]
        && preferences.menuBarIdentityStyle == .label
        && preferences.menuBarSpacing == 2,
      "Reset must restore the safe label-first Next23 menu-bar default and balanced spacing")
    preferencesDefaults.removePersistentDomain(forName: preferencesSuite)
    print(
      "PASS Next23 configurable menu-bar modules, fixed module geometry, hit testing, and stale values at 1x/2x"
    )

    // Render the actual Next23 live popover shell at every information level.
    // The outer frame must remain exactly 420x600 regardless of dashboard
    // detail, which prevents the old Battery Diagnostics disclosure trap.
    let uiSuite = "Helios.Next23Presentation.\(UUID().uuidString)"
    guard let uiDefaults = UserDefaults(suiteName: uiSuite) else {
      throw PresentationCheckFailure(message: "Unable to create Next23 UI preferences suite")
    }
    uiDefaults.removePersistentDomain(forName: uiSuite)
    let uiPreferences = HeliosPreferences(defaults: uiDefaults)
    let uiDiagnosticsPreferences = DiagnosticsPreferences(defaults: uiDefaults)
    let uiDiagnostics = DiagnosticsController(preferences: uiDiagnosticsPreferences)
    let uiService = DaemonService(
      driver: PresentationRegistration(.enabled), connectAutomatically: false)
    defer {
      uiService.shutdown()
      uiDefaults.removePersistentDomain(forName: uiSuite)
    }
    uiService.fanControl.refresh(normal)
    let uiModel = OverviewViewModel(runtimeServicesEnabled: false)
    try require(
      uiModel.healthCenter.authorization == .unknown,
      "Presentation model must not initialize app-only notification services")
    for offset in 0..<5 {
      uiModel.accept(normal, now: now.addingTimeInterval(Double(offset)))
    }
    try require(
      uiModel.history.points.count == 5, "Next23 chart fixture did not collect live history")
    print(
      "PASS Next23 presentation fixtures isolate notifications and persistent stores from command-line rendering"
    )
    for mode in HeliosDashboardMode.allCases {
      uiPreferences.applyDashboardPreset(mode)
      for dark in [false, true] {
        let content = HeliosPopoverView(
          model: uiModel, service: uiService, preferences: uiPreferences,
          openMonitor: {}, openCooling: {}, openSettings: {}
        )
        .environment(\.colorScheme, dark ? .dark : .light)
        guard let image = nativeImage(content, width: 420),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
          throw PresentationCheckFailure(message: "Next23 \(mode.label) popover render failed")
        }
        try require(
          image.width == 840 && image.height == 1200,
          "Next23 popover outer geometry changed in \(mode.label)")
        try png.write(
          to: directory.appendingPathComponent(
            "next23-\(mode.rawValue)-\(dark ? "dark" : "light").png"))
      }
    }
    print(
      "PASS Next23 preset-driven modular popover remains fixed at 420x600 in light/dark appearances"
    )

    for dark in [false, true] {
      let content = HeliosSettingsView(
        preferences: uiPreferences, service: uiService, diagnostics: uiDiagnostics)
        .environment(\.colorScheme, dark ? .dark : .light)
      guard let image = nativeImage(content, width: 720),
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
      else {
        throw PresentationCheckFailure(message: "Next23 Settings render failed")
      }
      try require(
        image.width == 1440 && image.height == 1040, "Next23 Settings outer geometry changed")
      try png.write(
        to: directory.appendingPathComponent("next23-settings-\(dark ? "dark" : "light").png"))
    }
    print("PASS Next23 native sidebar Settings shell renders at 720x520 in light/dark appearances")

    let onboardingPreferencesSuite = "Helios.Next23Onboarding.\(UUID().uuidString)"
    guard let onboardingDefaults = UserDefaults(suiteName: onboardingPreferencesSuite) else {
      throw PresentationCheckFailure(message: "Unable to create onboarding preferences suite")
    }
    onboardingDefaults.removePersistentDomain(forName: onboardingPreferencesSuite)
    let onboardingPreferences = HeliosPreferences(defaults: onboardingDefaults)
    let onboardingDiagnosticsPreferences = DiagnosticsPreferences(defaults: onboardingDefaults)
    let onboardingDiagnostics = DiagnosticsController(preferences: onboardingDiagnosticsPreferences)
    defer { onboardingDefaults.removePersistentDomain(forName: onboardingPreferencesSuite) }
    let onboarding = HeliosOnboardingView(
      preferences: onboardingPreferences, diagnostics: onboardingDiagnostics, onFinish: {})
      .environment(\.colorScheme, .dark)
    guard let onboardingImage = nativeImage(onboarding, width: 720),
      let onboardingPNG = NSBitmapImageRep(cgImage: onboardingImage).representation(
        using: .png, properties: [:])
    else {
      throw PresentationCheckFailure(message: "Next23 onboarding render failed")
    }
    try require(
      onboardingImage.width == 1440 && onboardingImage.height == 1120,
      "Next23 onboarding outer geometry changed")
    try onboardingPNG.write(to: directory.appendingPathComponent("next23-onboarding-dark.png"))
    print("PASS Next23 first-run onboarding renders as a fixed 720x560 native setup window")

    for metric in [HeliosMenuBarMetric.cpu, .memory, .temperature, .battery] {
      let popup = HeliosMetricPopoverView(
        metric: metric, model: uiModel, service: uiService, preferences: uiPreferences,
        openRoute: { _ in }
      )
      .environment(\.colorScheme, .dark)
      let expectedHeight = Int(HeliosMetricPopoverView.preferredHeight(for: metric) * 2)
      guard let popupImage = nativeImage(popup, width: 344),
        let popupPNG = NSBitmapImageRep(cgImage: popupImage).representation(
          using: .png, properties: [:])
      else {
        throw PresentationCheckFailure(message: "UI8 \(metric.label) metric popup render failed")
      }
      try require(
        popupImage.width == 688 && popupImage.height == expectedHeight,
        "UI8 \(metric.label) metric popup bounded geometry changed")
      try popupPNG.write(
        to: directory.appendingPathComponent("ui8-metric-\(metric.rawValue)-dark.png"))
    }
    print("PASS Next23 UI8 CPU/Memory/Battery native metric popups render with bounded geometry")

    uiModel.appEnergy = AppEnergyHistoryEngine.summary([
      AppEnergyBucket(
        capturedAt: now.addingTimeInterval(-180), durationSeconds: 60, onBattery: true,
        batteryPercent: 80,
        entries: [
          AppEnergyEntry(
            appKey: "app:/Applications/Safari.app", displayName: "Safari",
            energyWattHours: 0.020, cpuCoreSeconds: 5.2, wakeups: 80,
            peakMemoryBytes: 1_200_000_000),
          AppEnergyEntry(
            appKey: "proc:chatgpt", displayName: "ChatGPT",
            energyWattHours: 0.010, cpuCoreSeconds: 2.1, wakeups: 34,
            peakMemoryBytes: 650_000_000),
        ]),
      AppEnergyBucket(
        capturedAt: now.addingTimeInterval(-120), durationSeconds: 60, onBattery: true,
        batteryPercent: 79,
        entries: [
          AppEnergyEntry(
            appKey: "app:/Applications/Safari.app", displayName: "Safari",
            energyWattHours: 0.018, cpuCoreSeconds: 4.7, wakeups: 72,
            peakMemoryBytes: 1_250_000_000),
          AppEnergyEntry(
            appKey: "proc:chatgpt", displayName: "ChatGPT",
            energyWattHours: 0.015, cpuCoreSeconds: 3.0, wakeups: 45,
            peakMemoryBytes: 680_000_000),
        ]),
      AppEnergyBucket(
        capturedAt: now.addingTimeInterval(-60), durationSeconds: 60, onBattery: true,
        batteryPercent: 78,
        entries: [
          AppEnergyEntry(
            appKey: "app:/Applications/Safari.app", displayName: "Safari",
            energyWattHours: 0.022, cpuCoreSeconds: 5.9, wakeups: 88,
            peakMemoryBytes: 1_260_000_000),
          AppEnergyEntry(
            appKey: "proc:chatgpt", displayName: "ChatGPT",
            energyWattHours: 0.012, cpuCoreSeconds: 2.5, wakeups: 39,
            peakMemoryBytes: 700_000_000),
        ]),
    ])
    let energyInspector = HeliosEnergyInspectorView(model: uiModel, preferences: preferences)
      .frame(width: 820, height: 620)
      .environment(\.colorScheme, .dark)
    guard let energyImage = nativeImage(energyInspector, width: 820),
      let energyPNG = NSBitmapImageRep(cgImage: energyImage).representation(
        using: .png, properties: [:])
    else {
      throw PresentationCheckFailure(message: "UI9 Energy Inspector render failed")
    }
    try require(
      energyImage.width == 1640 && energyImage.height == 1240,
      "UI9 Energy Inspector fixed test geometry changed")
    try energyPNG.write(to: directory.appendingPathComponent("ui9-energy-inspector-dark.png"))
    print("PASS Next23 UI9 dedicated Energy Inspector renders with populated per-app history")

    var partial = normal
    partial.thermals = MetricSample(
      .success(
        ThermalMetrics(
          readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 56)],
          failures: ["Tg0G": .unavailable("Sensor missing")])), capturedAt: now)
    partial.memory = MetricSample(
      .success(
        MemoryMetrics(
          physicalBytes: 16 << 30, activeBytes: 8 << 30, inactiveBytes: 1 << 30,
          wiredBytes: 2 << 30, compressedBytes: 2 << 30, freeBytes: 3 << 30,
          pressure: .success(.warning))), capturedAt: now)
    let partialSummary = OverviewPresentation(partial, now: now)
    try require(
      DisplayValue(partialSummary.temperatures(.gpu).map(\.average)) { String($0) }.failure != nil,
      "Missing GPU group must not become a zero average")
    for (name, snapshot) in [
      ("normal", normal), ("unavailable", TelemetrySnapshot()), ("partial", partial),
    ] {
      for dark in [false, true] {
        try renderCards(
          snapshot, now: now, dark: dark,
          to: directory.appendingPathComponent("popover-\(name)-\(dark ? "dark" : "light").png"))
      }
    }
    let persisted = persistentFixture(now: now)
    let ioAudit = ioAuditFixture(now: now)
    let capabilities = CapabilityEvaluator.evaluate(normal, now: now)
    for dark in [false, true] {
      try renderCards(
        normal, now: now, dark: dark, persistentHistory: persisted, ioAudit: ioAudit,
        capabilityReport: capabilities,
        to: directory.appendingPathComponent("popover-next21-detail-\(dark ? "dark" : "light").png")
      )
    }
    print(
      "PASS group statistics, independent unavailable states, and Next21 persistent/audit disclosures; native light/dark renders written to .build/Presentation"
    )
    for (name, status) in [
      ("missing", SMAppService.Status.notRegistered), ("approval", .requiresApproval),
      ("installed", .enabled),
    ] {
      let service = DaemonService(driver: PresentationRegistration(status))
      service.fanControl.refresh(normal)
      defer { service.shutdown() }
      for dark in [false, true] {
        try renderCards(
          normal, now: now, dark: dark, service: service,
          to: directory.appendingPathComponent("helper-\(name)-\(dark ? "dark" : "light").png"))
      }
    }
    for mode in FanControlSelection.allCases {
      for dark in [false, true] {
        let controls = FanModeControls(
          selection: .constant(mode), targetRPM: .constant(4500), bounds: 2317...6550,
          boostEnabled: true, overrideEnabled: true, autoEnabled: true
        )
        .padding(12).frame(width: 352)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
        guard let image = nativeImage(controls, width: 352),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
          throw PresentationCheckFailure(message: "Fan control render failed")
        }
        try require(image.width == 704, "Fan controls changed width")
        try png.write(
          to: directory.appendingPathComponent("fan-\(mode.label)-\(dark ? "dark" : "light").png"))
      }
    }
  }

  private static func fixture(cpu: Double, temperature: Double, now: Date) -> TelemetrySnapshot {
    var snapshot = TelemetrySnapshot()
    snapshot.fans = MetricSample(
      .success(
        FanInventory(fans: [
          FanReading(
            id: 0, actualRPM: .success(0), targetRPM: .success(0), minimumRPM: .success(2317),
            maximumRPM: .success(6550), automatic: .success(true))
        ])))
    let ownershipEvidence = FanOwnershipPreflightEvidence(
      modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
      globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0,
      fans: [
        FanOwnershipPreflightFan(
          id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 0, minimumRPM: 2317,
          maximumRPM: 6550, targetType: "flt ")
      ]
    )
    snapshot.fanOwnershipPreflight = MetricSample(
      .success(FanOwnershipPreflightEvaluator.evaluate(ownershipEvidence)), capturedAt: now)
    snapshot.cpu = MetricSample(
      .success(
        CPUMetrics(
          userPercent: cpu * 0.7, systemPercent: cpu * 0.3, nicePercent: 0, idlePercent: 100 - cpu,
          perCoreUsagePercent: [
            cpu * 0.5, cpu * 0.7, cpu * 0.9, cpu, cpu * 1.1, cpu * 0.8, cpu * 0.6, cpu * 0.4,
            cpu * 0.3, cpu * 0.2,
          ].map { min(100, $0) }
        )), capturedAt: now)
    snapshot.memory = MetricSample(
      .success(
        MemoryMetrics(
          physicalBytes: 16 << 30, activeBytes: 8 << 30, inactiveBytes: 1 << 30,
          wiredBytes: 2 << 30, compressedBytes: 2 << 30, freeBytes: 3 << 30,
          pressure: .success(.normal), swapUsedBytes: .success(512 << 20),
          swapTotalBytes: .success(2 << 30))), capturedAt: now)
    snapshot.gpu = MetricSample(
      .success(
        GPUMetrics(
          model: .success("Apple M4"), coreCount: .success(10),
          deviceUtilizationPercent: .success(28), rendererUtilizationPercent: .success(24),
          tilerUtilizationPercent: .success(9), allocatedSystemMemoryBytes: .success(2_000_000_000),
          inUseSystemMemoryBytes: .success(650_000_000))), capturedAt: now)
    snapshot.systemPower = MetricSample(
      .success(SystemPowerMetrics(totalSystemWatts: .success(11.8))), capturedAt: now)
    snapshot.system = MetricSample(
      .success(
        SystemMetrics(
          modelIdentifier: .success("Mac16,1"), chipName: .success("Apple M4"),
          osVersion: "macOS Version 26.6.2 (Build 25G83)", uptimeSeconds: 98_765,
          logicalProcessorCount: 10, physicalMemoryBytes: 16 << 30, loadAverage1: .success(1.25),
          loadAverage5: .success(1.10), loadAverage15: .success(0.95), thermalState: .nominal,
          lowPowerModeEnabled: false)), capturedAt: now)
    snapshot.network = MetricSample(
      .success(
        NetworkMetrics(
          primaryInterface: .success("en0"), ipv4Address: .success("192.168.0.42"),
          ipv6Address: .success("2001:db8:1234:5678::42"), isRunning: .success(true),
          mtu: .success(1500), linkSpeedBitsPerSecond: .success(1_200_000_000),
          throughput: .success(
            NetworkThroughput(
              downloadBytesPerSecond: 12_300_000, uploadBytesPerSecond: 2_400_000,
              receivePacketsPerSecond: 1300, transmitPacketsPerSecond: 820)),
          receiveErrors: .success(0), transmitErrors: .success(0), activeInterfaceCount: 2,
          sessionDownloadedBytes: .success(4_200_000_000),
          sessionUploadedBytes: .success(900_000_000))), capturedAt: now)
    snapshot.wifi = MetricSample(
      .success(
        WiFiMetrics(
          interfaceName: "en0", powerOn: true, serviceActive: true,
          ssid: .success("Helios Lab"), rssiDBm: .success(-48), noiseDBm: .success(-91),
          transmitRateMbps: .success(1200), transmitPowerMilliwatts: .success(31),
          channelNumber: .success(37), channelBand: .success("6 GHz"),
          channelWidth: .success("160 MHz"),
          phyMode: .success("802.11ax / Wi-Fi 6/6E"), security: .success("WPA3 Personal")
        )), capturedAt: now)
    snapshot.processes = MetricSample(
      .success(
        ProcessMetrics(
          accessibleProcessCount: 184,
          topByCPU: [
            ProcessActivity(
              pid: 501, name: "Safari",
              executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
              physicalFootprintBytes: 1_250_000_000, neuralFootprintBytes: 0, cpuPercent: 18.4,
              powerWatts: 1.20, performanceCorePowerWatts: 0.72, diskReadBytesPerSecond: 120_000,
              diskWriteBytesPerSecond: 45_000, wakeupsPerSecond: 31,
              instructionsPerSecond: 1_200_000_000, cyclesPerSecond: 800_000_000,
              instructionsPerCycle: 1.5),
            ProcessActivity(
              pid: 502, name: "WindowServer",
              executablePath:
                "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
              physicalFootprintBytes: 540_000_000, neuralFootprintBytes: 0, cpuPercent: 8.2,
              powerWatts: 0.58, performanceCorePowerWatts: 0.22, diskReadBytesPerSecond: 10_000,
              diskWriteBytesPerSecond: 5_000, wakeupsPerSecond: 18,
              instructionsPerSecond: 500_000_000, cyclesPerSecond: 420_000_000,
              instructionsPerCycle: 1.19),
          ],
          topByEnergy: [
            ProcessActivity(
              pid: 501, name: "Safari",
              executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
              physicalFootprintBytes: 1_250_000_000, neuralFootprintBytes: 0, cpuPercent: 18.4,
              powerWatts: 1.20, performanceCorePowerWatts: 0.72, diskReadBytesPerSecond: 120_000,
              diskWriteBytesPerSecond: 45_000, wakeupsPerSecond: 31,
              instructionsPerSecond: 1_200_000_000, cyclesPerSecond: 800_000_000,
              instructionsPerCycle: 1.5)
          ],
          topByMemory: [
            ProcessActivity(
              pid: 501, name: "Safari",
              executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
              physicalFootprintBytes: 1_250_000_000, neuralFootprintBytes: 0, cpuPercent: 18.4,
              powerWatts: 1.20, performanceCorePowerWatts: 0.72, diskReadBytesPerSecond: 120_000,
              diskWriteBytesPerSecond: 45_000, wakeupsPerSecond: 31,
              instructionsPerSecond: 1_200_000_000, cyclesPerSecond: 800_000_000,
              instructionsPerCycle: 1.5, sessionDiskReadBytes: 820_000_000,
              sessionDiskWriteBytes: 330_000_000)
          ],
          topByDiskRead: [
            ProcessActivity(
              pid: 501, name: "Safari",
              executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
              physicalFootprintBytes: 1_250_000_000, neuralFootprintBytes: 0, cpuPercent: 18.4,
              powerWatts: 1.20, performanceCorePowerWatts: 0.72, diskReadBytesPerSecond: 120_000,
              diskWriteBytesPerSecond: 45_000, wakeupsPerSecond: 31,
              instructionsPerSecond: 1_200_000_000, cyclesPerSecond: 800_000_000,
              instructionsPerCycle: 1.5, sessionDiskReadBytes: 820_000_000,
              sessionDiskWriteBytes: 330_000_000)
          ],
          topByDiskWrite: [
            ProcessActivity(
              pid: 502, name: "WindowServer",
              executablePath:
                "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
              physicalFootprintBytes: 540_000_000, neuralFootprintBytes: 0, cpuPercent: 8.2,
              powerWatts: 0.58, performanceCorePowerWatts: 0.22, diskReadBytesPerSecond: 10_000,
              diskWriteBytesPerSecond: 155_000, wakeupsPerSecond: 18,
              instructionsPerSecond: 500_000_000, cyclesPerSecond: 420_000_000,
              instructionsPerCycle: 1.19, sessionDiskReadBytes: 120_000_000,
              sessionDiskWriteBytes: 1_240_000_000)
          ],
          topSessionReaders: [
            ProcessActivity(
              pid: 501, name: "Safari",
              executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
              physicalFootprintBytes: 1_250_000_000, neuralFootprintBytes: 0, cpuPercent: 18.4,
              powerWatts: 1.20, performanceCorePowerWatts: 0.72, diskReadBytesPerSecond: 120_000,
              diskWriteBytesPerSecond: 45_000, wakeupsPerSecond: 31,
              instructionsPerSecond: 1_200_000_000, cyclesPerSecond: 800_000_000,
              instructionsPerCycle: 1.5, sessionDiskReadBytes: 820_000_000,
              sessionDiskWriteBytes: 330_000_000)
          ],
          topSessionWriters: [
            ProcessActivity(
              pid: 502, name: "WindowServer",
              executablePath:
                "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
              physicalFootprintBytes: 540_000_000, neuralFootprintBytes: 0, cpuPercent: 8.2,
              powerWatts: 0.58, performanceCorePowerWatts: 0.22, diskReadBytesPerSecond: 10_000,
              diskWriteBytesPerSecond: 155_000, wakeupsPerSecond: 18,
              instructionsPerSecond: 500_000_000, cyclesPerSecond: 420_000_000,
              instructionsPerCycle: 1.19, sessionDiskReadBytes: 120_000_000,
              sessionDiskWriteBytes: 1_240_000_000)
          ],
          accountedDiskReadBytesPerSecond: 230_000,
          accountedDiskWriteBytesPerSecond: 250_000,
          sessionAccountedReadBytes: 1_800_000_000,
          sessionAccountedWriteBytes: 2_100_000_000,
          heliosActivity: ProcessActivity(
            pid: 999, name: "Helios",
            executablePath: "/Applications/Helios.app/Contents/MacOS/Helios",
            physicalFootprintBytes: 78_000_000, neuralFootprintBytes: 0, cpuPercent: 0.25,
            powerWatts: 0.12, performanceCorePowerWatts: 0.08, diskReadBytesPerSecond: 2_000,
            diskWriteBytesPerSecond: 1_200, wakeupsPerSecond: 2.2,
            instructionsPerSecond: 20_000_000, cyclesPerSecond: 12_000_000,
            instructionsPerCycle: 1.67, sessionDiskReadBytes: 12_000_000,
            sessionDiskWriteBytes: 4_000_000)
        )), capturedAt: now)
    snapshot.battery = MetricSample(
      .success(
        BatteryMetrics(
          designCapacityMAh: .success(6249), maximumCapacityMAh: .success(6348),
          currentCapacityMAh: .success(4962), cycleCount: .success(4),
          temperatureCelsius: .success(30.5),
          power: .success(BatteryPower(signedWatts: -12.45, usesInstantaneousCurrent: true)),
          powerSource: .success(.battery), voltageVolts: .success(12.31),
          currentAmps: .success(-1.01),
          adapterWatts: .failure(.unavailable("No adapter connected")), isCharging: .success(false),
          timeRemaining: .success(.seconds(14_400)))), capturedAt: now)
    snapshot.storage = MetricSample(
      .success(
        StorageMetrics(
          rootVolume: .success(
            RootVolumeMetrics(totalBytes: 994_662_584_320, freeBytes: 710_000_000_000)),
          devices: [
            StorageDeviceMetrics(
              registryID: 1, bsdName: "disk0", model: "APPLE SSD", capacityBytes: 1_000_555_581_440,
              isInternal: true, isRemovable: false, transport: "Apple Fabric",
              controllerClass: "AppleANSController", smartCapability: .nvmeAdvertised,
              counters: .success(
                StorageIOCounters(
                  bytesRead: 12_300_000_000, bytesWritten: 8_400_000_000, readOperations: 10,
                  writeOperations: 20, readErrors: 0, writeErrors: 0))),
            StorageDeviceMetrics(
              registryID: 2, bsdName: "disk4", model: "External NVMe",
              capacityBytes: 2_000_000_000_000, isInternal: false, isRemovable: true,
              transport: "USB", controllerClass: "IOBlockStorageDevice",
              smartCapability: .notAdvertised,
              counters: .success(
                StorageIOCounters(
                  bytesRead: 2_000_000, bytesWritten: 1_000_000, readOperations: 20,
                  writeOperations: 10, readErrors: 0, writeErrors: 0))),
            StorageDeviceMetrics(
              registryID: 3, bsdName: "disk5", model: "Disk Image", capacityBytes: 10_000_000,
              isInternal: false, isRemovable: true, transport: "Virtual Interface",
              controllerClass: "IOBlockStorageDriver", smartCapability: .notAdvertised,
              counters: .success(
                StorageIOCounters(
                  bytesRead: 0, bytesWritten: 0, readOperations: 0, writeOperations: 0,
                  readErrors: 0, writeErrors: 0))),
          ],
          primaryDeviceBSDName: "disk0",
          throughput: .success(
            StorageThroughput(
              readBytesPerSecond: 42_000_000, writeBytesPerSecond: 18_000_000, readIOPS: 1200,
              writeIOPS: 840)),
          smartHealth: .success(
            NVMeSMARTHealth(
              criticalWarning: 0, temperatureCelsius: 31.2, availableSparePercent: 100,
              availableSpareThresholdPercent: 99, percentageUsed: 1,
              dataUnitsRead: NVMeCounter128(low: 20_000_000, high: 0),
              dataUnitsWritten: NVMeCounter128(low: 12_000_000, high: 0),
              hostReadCommands: NVMeCounter128(low: 1_000_000, high: 0),
              hostWriteCommands: NVMeCounter128(low: 800_000, high: 0),
              controllerBusyMinutes: NVMeCounter128(low: 10, high: 0),
              powerCycles: NVMeCounter128(low: 20, high: 0),
              powerOnHours: NVMeCounter128(low: 100, high: 0),
              unsafeShutdowns: NVMeCounter128(low: 1, high: 0),
              mediaErrors: NVMeCounter128(low: 0, high: 0),
              errorLogEntries: NVMeCounter128(low: 0, high: 0)
            )),
          smartHealthCapturedTicks: HostClock.now,
          monitoringReadBytes: .success(2_400_000_000),
          monitoringWrittenBytes: .success(1_100_000_000)
        )), capturedAt: now)
    snapshot.thermals = MetricSample(
      .success(
        ThermalMetrics(
          readings: [
            ThermalReading(key: "Tp01", group: .performanceCPU, celsius: temperature),
            ThermalReading(key: "Tp05", group: .performanceCPU, celsius: temperature - 8),
            ThermalReading(key: "Te05", group: .efficiencyCPU, celsius: temperature - 10),
            ThermalReading(key: "Tg0G", group: .gpu, celsius: temperature - 6),
            ThermalReading(key: "Tzzz", group: .unclassified, celsius: 120),
          ], failures: [:])), capturedAt: now)
    return snapshot
  }

  private static func graphLivePoint(at date: Date, cpu: Double) -> TelemetryHistoryPoint {
    TelemetryHistoryPoint(
      capturedAt: date, cpuPercent: cpu, memoryPercent: nil, gpuPercent: nil,
      maxSoCCelsius: nil, systemPowerWatts: nil, batteryPercent: nil, batteryPowerWatts: nil,
      fanRPM: nil, networkDownloadBytesPerSecond: nil, networkUploadBytesPerSecond: nil,
      storageReadBytesPerSecond: nil, storageWriteBytesPerSecond: nil)
  }

  private static func graphPersistentPoint(at date: Date, cpu: Double) -> PersistedTelemetryPoint {
    PersistedTelemetryPoint(
      capturedAt: date, cpuPercent: cpu, gpuPercent: nil, maxSoCCelsius: nil,
      systemPowerWatts: nil, batteryPercent: nil, storageTemperatureCelsius: nil,
      fanRPM: nil, networkDownloadBytesPerSecond: nil, networkUploadBytesPerSecond: nil)
  }

  private static func persistentFixture(now: Date) -> PersistentHistorySummary {
    // Keep presentation fixtures deliberately boring for the Swift type checker.
    // These checks exercise rendering, not collection-expression inference.
    let offsets: [TimeInterval] = [0, 30, 60]
    var points: [PersistedTelemetryPoint] = []
    points.reserveCapacity(offsets.count)

    for offset in offsets {
      let capturedAt = now.addingTimeInterval(-60 + offset)
      let cpuPercent = 10 + offset / 10
      let systemPowerWatts = 8 + offset / 30
      let batteryPercent = 80 - offset / 120
      let batteryTemperature = 30 + offset / 60
      let lifetimeReadBytes = 1_500_000_000_000 + offset * 2_000_000
      let lifetimeWrittenBytes = 1_000_000_000_000 + offset * 1_000_000

      let point = PersistedTelemetryPoint(
        capturedAt: capturedAt, cpuPercent: cpuPercent, gpuPercent: 20, maxSoCCelsius: 52,
        systemPowerWatts: systemPowerWatts, batteryPercent: batteryPercent,
        batteryHealthPercent: 101,
        batteryPowerWatts: -8, batteryOnAC: false, batteryTemperatureCelsius: batteryTemperature,
        batteryCycleCount: 4,
        storageTemperatureCelsius: 31, storageDeviceBSDName: "disk0",
        storageLifetimeReadBytes: lifetimeReadBytes,
        storageLifetimeWrittenBytes: lifetimeWrittenBytes,
        storageReadBytesPerSecond: 1_000_000, storageWriteBytesPerSecond: 500_000,
        processAccountedReadBytesPerSecond: 400_000, processAccountedWriteBytesPerSecond: 200_000,
        heliosCPUPercent: 0.25, heliosPowerWatts: 0.12, heliosMemoryBytes: 78_000_000,
        heliosWakeupsPerSecond: 2.2,
        fanRPM: 0, networkDownloadBytesPerSecond: 2_000_000, networkUploadBytesPerSecond: 500_000
      )
      points.append(point)
    }
    return PersistentHistoryEngine.summary(points)
  }

  private static func ioAuditFixture(now: Date) -> IOActivitySummary {
    // Avoid a large map + memberwise initializer expression here. With
    // warnings-as-errors and Swift 6.2 the macOS compiler can hit its
    // expression-complexity limit even though every individual type is valid.
    let offsets: [UInt64] = [0, 30, 60]
    var records: [IOActivityRecord] = []
    records.reserveCapacity(offsets.count)

    for offset in offsets {
      let elapsed = TimeInterval(offset)
      let capturedAt = now.addingTimeInterval(-60 + elapsed)
      let readSinceBoot = UInt64(20_000_000_000) + offset * 2_000_000
      let writtenSinceBoot = UInt64(10_000_000_000) + offset * 1_000_000

      let record = IOActivityRecord(
        capturedAt: capturedAt,
        deviceBSDName: "disk0",
        deviceReadSinceBootBytes: readSinceBoot,
        deviceWrittenSinceBootBytes: writtenSinceBoot,
        deviceReadBytesPerSecond: 1_000_000,
        deviceWriteBytesPerSecond: 500_000,
        processAccountedReadBytesPerSecond: 400_000,
        processAccountedWriteBytesPerSecond: 200_000,
        topReaderName: "Safari",
        topReaderPID: 501,
        topReaderBytesPerSecond: 120_000,
        topWriterName: "WindowServer",
        topWriterPID: 502,
        topWriterBytesPerSecond: 155_000,
        heliosReadBytesPerSecond: 2_000,
        heliosWriteBytesPerSecond: 1_200
      )
      records.append(record)
    }
    return IOActivityAuditEngine.summary(records)
  }

  private static func renderCards(
    _ snapshot: TelemetrySnapshot, now: Date, dark: Bool, service: DaemonService? = nil,
    persistentHistory: PersistentHistorySummary = .empty,
    ioAudit: IOActivitySummary = .empty,
    capabilityReport: CapabilityReport = CapabilityReport(items: []),
    to url: URL
  ) throws {
    guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else {
      throw PresentationCheckFailure(message: "Missing native appearance")
    }
    var rendered: CGImage?
    appearance.performAsCurrentDrawingAppearance {
      let content = OverviewCards(
        presentation: OverviewPresentation(snapshot, now: now), service: service,
        persistentHistory: persistentHistory, ioAudit: ioAudit, capabilityReport: capabilityReport
      )
      .frame(width: 380)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, dark ? .dark : .light)
      rendered = nativeImage(content, width: 380)
    }
    guard let rendered,
      let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    else {
      throw PresentationCheckFailure(message: "Native card render unavailable")
    }
    try require(rendered.width == 760, "Cards changed fixed popover width")
    try png.write(to: url)
    print("Rendered \(url.lastPathComponent): \(rendered.width)x\(rendered.height)")
  }

  /// ImageRenderer omits AppKit-backed Picker/Slider/Toggle controls. Size with
  /// SwiftUI, then capture the actual hosting view in an offscreen window.
  private static func nativeImage<Content: View>(_ content: Content, width: CGFloat) -> CGImage? {
    let sizing = ImageRenderer(content: content)
    guard let layout = sizing.cgImage else { return nil }
    let size = NSSize(width: width, height: CGFloat(layout.height))
    let hosting = NSHostingView(rootView: content)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.appearance = NSAppearance.currentDrawing()
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderFront(nil)
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    hosting.displayIfNeeded()
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    bitmap.size = size
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    return bitmap.cgImage
  }

  private static func renderWidget(_ widget: MenuBarView, scale: Int, dark: Bool, to url: URL)
    throws
  {
    let pixelWidth = Int(ceil(widget.frame.width)) * scale
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: 24 * scale, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap),
      let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    else {
      throw PresentationCheckFailure(message: "Native widget render unavailable")
    }
    widget.appearance = appearance
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: CGFloat(24 * scale))
    context.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    appearance.performAsCurrentDrawingAppearance {
      (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
      widget.bounds.fill()
      widget.draw(widget.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      throw PresentationCheckFailure(message: "PNG encoding unavailable")
    }
    try data.write(to: url)
  }
}
