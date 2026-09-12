import AppKit
import Combine
import SwiftUI

@MainActor
final class HeliosWindowCoordinator: NSObject, NSWindowDelegate {
  private let service: DaemonService
  private let preferences: HeliosPreferences
  private let model: OverviewViewModel
  private let diagnostics: DiagnosticsController
  private var monitorController: HeliosMonitorWindowController?
  private var energyInspectorController: NSWindowController?
  private var settingsController: NSWindowController?
  private var onboardingController: NSWindowController?
  private var lastMonitorRoute: HeliosMonitorRoute = .overview
  private let energyInspectorState = HeliosEnergyInspectorState()

  init(
    service: DaemonService, preferences: HeliosPreferences, model: OverviewViewModel,
    diagnostics: DiagnosticsController
  ) {
    self.service = service
    self.preferences = preferences
    self.model = model
    self.diagnostics = diagnostics
    super.init()
  }

  /// The shared UI8 model is fed once by StatusItemController. Windows observe it
  /// directly, avoiding duplicate history/persistence work per open surface.
  func update(_ snapshot: TelemetrySnapshot) {}

  func showMonitor(snapshot: TelemetrySnapshot, route: HeliosMonitorRoute? = nil) {
    let isNew = monitorController == nil
    let controller =
      monitorController
      ?? HeliosMonitorWindowController(
        model: model, service: service, preferences: preferences,
        openEnergyInspector: { [weak self] in self?.showEnergyInspector() })
    monitorController = controller
    controller.window?.delegate = self
    controller.update(snapshot)
    if let route {
      controller.select(route)
    } else if isNew {
      controller.select(lastMonitorRoute)
    }
    show(controller.window)
  }

  func showEnergyInspector() {
    let controller: NSWindowController
    if let energyInspectorController {
      controller = energyInspectorController
    } else {
      let content = HeliosEnergyInspectorView(
        model: model, preferences: preferences, state: energyInspectorState)
      let hosting = NSHostingController(rootView: content)
      let window = NSWindow(contentViewController: hosting)
      window.title = "Helios Energy Inspector"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.minSize = NSSize(width: 700, height: 500)
      window.setContentSize(NSSize(width: 820, height: 620))
      window.toolbarStyle = .unified
      window.titlebarAppearsTransparent = true
      window.isReleasedWhenClosed = false
      window.center()
      controller = NSWindowController(window: window)
      window.delegate = self
      energyInspectorController = controller
    }
    show(controller.window)
  }

  func showSettings() {
    let controller: NSWindowController
    if let settingsController {
      controller = settingsController
    } else {
      let content = HeliosSettingsView(
        preferences: preferences, service: service, diagnostics: diagnostics)
      let hosting = NSHostingController(rootView: content)
      let window = NSWindow(contentViewController: hosting)
      window.title = "Helios Settings"
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.setContentSize(NSSize(width: 720, height: 520))
      window.isReleasedWhenClosed = false
      window.center()
      controller = NSWindowController(window: window)
      window.delegate = self
      settingsController = controller
    }
    show(controller.window)
  }

  func showOnboardingIfNeeded() {
    guard !preferences.onboardingCompleted else { return }
    if let onboardingController {
      show(onboardingController.window)
      return
    }

    let content = HeliosOnboardingView(preferences: preferences, diagnostics: diagnostics) {
      [weak self] in
      self?.onboardingController?.close()
      self?.onboardingController = nil
    }
    let hosting = NSHostingController(rootView: content)
    let window = NSWindow(contentViewController: hosting)
    window.title = "Welcome to Helios"
    window.styleMask = [.titled, .closable, .fullSizeContentView]
    window.titlebarAppearsTransparent = true
    window.setContentSize(NSSize(width: 720, height: 560))
    window.isReleasedWhenClosed = false
    window.center()
    let controller = NSWindowController(window: window)
    window.delegate = self
    onboardingController = controller
    show(window)
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }

    // A closed NSWindow can outlive the coordinator's strong reference inside
    // AppKit. Merely nil-ing our NSWindowController therefore does not prove
    // that a large NSHostingController/AttributeGraph tree is gone. Tear the
    // presentation hierarchy off the window explicitly before releasing our
    // controller. The shared telemetry model/preferences/service stay alive;
    // only reconstructible UI state is discarded.
    if window === monitorController?.window {
      let controller = monitorController
      lastMonitorRoute = controller?.selectedRoute ?? lastMonitorRoute
      monitorController = nil
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === energyInspectorController?.window {
      let controller = energyInspectorController
      energyInspectorController = nil
      energyInspectorState.clearDerivedCache()
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === settingsController?.window {
      let controller = settingsController
      settingsController = nil
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === onboardingController?.window {
      let controller = onboardingController
      onboardingController = nil
      detachPresentationTree(from: window)
      controller?.window = nil
    }

    // Application icons are reconstructible presentation data. Never keep a
    // workspace-icon cache alive merely because a heavy window was visited.
    HeliosAppIconCache.shared.purge()
  }

  private func detachPresentationTree(from window: NSWindow) {
    // Break responder/view/controller ownership in a deterministic order. This
    // is intentionally UI-only: no telemetry collector, helper, lease, fan or
    // persistence state is touched. A fresh hosting tree is built on reopen.
    window.makeFirstResponder(nil)
    window.delegate = nil
    window.contentViewController = nil
    window.contentView = NSView(frame: .zero)
  }

  private func show(_ window: NSWindow?) {
    guard let window else { return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}

@MainActor
final class HeliosMonitorWindowController: NSWindowController {
  private let model: OverviewViewModel
  private let navigation = HeliosMonitorNavigation()

  init(
    model: OverviewViewModel,
    service: DaemonService,
    preferences: HeliosPreferences,
    openEnergyInspector: @escaping () -> Void
  ) {
    self.model = model
    let root = HeliosMonitorWindowView(
      model: model, service: service, preferences: preferences, navigation: navigation,
      openEnergyInspector: openEnergyInspector)
    let hosting = NSHostingController(rootView: root)
    let window = NSWindow(contentViewController: hosting)
    window.title = "Helios"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.minSize = NSSize(width: 720, height: 500)
    window.setContentSize(NSSize(width: 860, height: 600))
    window.toolbarStyle = .unified
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    super.init(window: window)
  }

  required init?(coder: NSCoder) { nil }
  func update(_ snapshot: TelemetrySnapshot) {}
  func select(_ route: HeliosMonitorRoute) { navigation.selection = route }
  var selectedRoute: HeliosMonitorRoute { navigation.selection ?? .overview }
}

@MainActor
final class HeliosEnergyInspectorState: ObservableObject {
  struct Aggregation {
    let visibleBuckets: [AppEnergyBucket]
    let summary: AppEnergySummary
    let batteryBuckets: [AppEnergyBucket]
  }

  @Published var range: HeliosGraphRange = .sixHours
  @Published var selectedAppKey: String?

  private var cachedRange: HeliosGraphRange?
  private var cachedBucketCount = -1
  private var cachedFirstCapture: Date?
  private var cachedLastCapture: Date?
  private var cachedAggregation: Aggregation?

  func clearDerivedCache() {
    cachedRange = nil
    cachedBucketCount = -1
    cachedFirstCapture = nil
    cachedLastCapture = nil
    cachedAggregation = nil
  }

  func aggregation(for source: AppEnergySummary) -> Aggregation {
    let first = source.buckets.first?.capturedAt
    let last = source.buckets.last?.capturedAt
    if cachedRange == range, cachedBucketCount == source.buckets.count,
      cachedFirstCapture == first, cachedLastCapture == last, let cachedAggregation
    {
      return cachedAggregation
    }

    let visible: [AppEnergyBucket]
    if let anchor = last {
      let cutoff = anchor.addingTimeInterval(-range.seconds)
      visible = source.buckets.filter { $0.capturedAt >= cutoff && $0.capturedAt <= anchor }
    } else {
      visible = []
    }
    let summary = AppEnergyHistoryEngine.summary(visible)
    let result = Aggregation(
      visibleBuckets: visible,
      summary: summary,
      batteryBuckets: visible.filter { $0.onBattery == true })
    cachedRange = range
    cachedBucketCount = source.buckets.count
    cachedFirstCapture = first
    cachedLastCapture = last
    cachedAggregation = result
    return result
  }
}

@MainActor
struct HeliosEnergyInspectorView: View {
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var state: HeliosEnergyInspectorState = HeliosEnergyInspectorState()

  private var range: HeliosGraphRange { state.range }
  private var selectedAppKey: String? { state.selectedAppKey }

  private static let supportedRanges: [HeliosGraphRange] = [.oneHour, .sixHours, .twentyFourHours]
  private var p: OverviewPresentation { OverviewPresentation(model.snapshot) }

  private var aggregation: HeliosEnergyInspectorState.Aggregation {
    state.aggregation(for: model.appEnergy)
  }

  private var visibleBuckets: [AppEnergyBucket] { aggregation.visibleBuckets }
  private var summary: AppEnergySummary { aggregation.summary }
  private var batteryBuckets: [AppEnergyBucket] { aggregation.batteryBuckets }

  private var trackedEnergyWattHours: Double {
    summary.topOnBattery.reduce(0) { $0 + $1.energyWattHours }
  }

  private var effectiveSelectedAppKey: String? {
    if let selectedAppKey,
      summary.topOnBattery.contains(where: { $0.appKey == selectedAppKey })
    {
      return selectedAppKey
    }
    return summary.topOnBattery.first?.appKey
  }

  private var selectedEntry: AppEnergyEntry? {
    guard let key = effectiveSelectedAppKey else { return nil }
    return summary.topOnBattery.first { $0.appKey == key }
  }

  private var batteryChangePercent: Double? {
    let values = batteryBuckets.compactMap { bucket -> Double? in
      guard let percent = bucket.batteryPercent, percent.isFinite, (0...100).contains(percent)
      else { return nil }
      return percent
    }
    guard let first = values.first, let last = values.last, values.count >= 2 else { return nil }
    return last - first
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          summaryCards
          batteryHistory
          HStack(alignment: .top, spacing: 14) {
            rankingPanel
              .frame(minWidth: 270, idealWidth: 300, maxWidth: 320, alignment: .topLeading)
            selectedAppPanel
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          caveat
        }
        .padding(18)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 680, minHeight: 470)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "battery.75percent")
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(preferences.color(for: .energy))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text("Energy Inspector")
          .font(.system(size: 16, weight: .semibold))
        Text("Which apps used battery energy, and when")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Picker("History range", selection: $state.range) {
        ForEach(Self.supportedRanges) { item in
          Text(item.label).tag(item)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      .frame(width: 190)
      .accessibilityLabel("Energy history range")
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var summaryCards: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10
    ) {
      inspectorCard(
        "Battery now", currentBatteryText, detail: currentPowerSourceText,
        symbol: "battery.75percent", tint: preferences.color(for: .battery))
      inspectorCard(
        "Live flow", currentBatteryFlowText, detail: currentBatteryFlowDetail,
        symbol: "bolt.fill", tint: preferences.color(for: .power))
      inspectorCard(
        "Battery change", batteryChangeText,
        detail: "during observed on-battery samples", symbol: "chart.line.downtrend.xyaxis",
        tint: batteryChangeTint)
      inspectorCard(
        "Observed", TelemetryFormatting.duration(summary.onBatteryCoverageSeconds),
        detail: "on battery in selected range", symbol: "clock",
        tint: preferences.color(for: .energy))
    }
  }

  private var batteryHistory: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text("Battery level")
            .font(.system(size: 11, weight: .semibold))
          Spacer()
          Text(range.menuLabel)
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if batteryLevelSamples.contains(where: { $0.value != nil }) {
          HeliosTimeSeriesChart(
            samples: batteryLevelSamples,
            range: range,
            fixedRange: 0...100,
            tint: preferences.color(for: .battery),
            lineStyle: preferences.graphLineStyle,
            animateUpdates: false,
            inspectorEnabled: true,
            valueStyle: .percent,
            seriesLabel: "Battery"
          )
          .frame(height: 92)
        } else {
          inspectorEmpty(
            "No battery-level history in this range",
            detail:
              "Use the Mac on battery while Helios is running; the local history updates automatically."
          )
        }
      }
      .padding(4)
    }
  }

  private var rankingPanel: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Battery energy by app")
            .font(.system(size: 11, weight: .semibold))
          Spacer()
          Text("Share")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }

        if summary.topOnBattery.isEmpty {
          inspectorEmpty(
            "No on-battery app history",
            detail:
              "Helios will rank apps after it has observed at least one completed energy-history bucket while on battery."
          )
        } else {
          ForEach(Array(summary.topOnBattery.prefix(12).enumerated()), id: \.element.id) {
            index, entry in
            Button {
              state.selectedAppKey = entry.appKey
            } label: {
              energyLeaderRow(rank: index + 1, entry: entry)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(4)
    }
  }

  @ViewBuilder
  private var selectedAppPanel: some View {
    GroupBox {
      if let entry = selectedEntry {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 9) {
            HeliosAppIdentityIcon(appKey: entry.appKey, size: 30)
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
              Text(selectedShareText(entry))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(energyText(entry.energyWattHours))
              .font(.system(size: 11, weight: .semibold).monospacedDigit())
          }

          HeliosTimeSeriesChart(
            samples: selectedAppSamples(appKey: entry.appKey),
            range: range,
            fixedRange: nil,
            tint: preferences.color(for: .energy),
            lineStyle: preferences.graphLineStyle,
            animateUpdates: false,
            inspectorEnabled: true,
            valueStyle: .milliwattHours,
            seriesLabel: entry.displayName
          )
          .frame(height: 100)

          Divider().opacity(0.45)
          inspectorDetailRow("CPU time", TelemetryFormatting.duration(entry.cpuCoreSeconds))
          inspectorDetailRow("Wakeups", String(format: "%.0f", entry.wakeups))
          inspectorDetailRow(
            "Peak memory", TelemetryFormatting.storageBytes(entry.peakMemoryBytes))
        }
        .padding(4)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("App timeline")
            .font(.system(size: 11, weight: .semibold))
          inspectorEmpty(
            "Select an app",
            detail:
              "Once on-battery history exists, choose an app on the left to inspect its minute-by-minute tracked energy."
          )
        }
        .padding(4)
      }
    }
  }

  private var caveat: some View {
    Label(
      "Relative local attribution only. Inaccessible/system processes can be absent, and process-accounted energy does not equal whole-system battery drain 1:1.",
      systemImage: "info.circle"
    )
    .font(.system(size: 9.5))
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var batteryLevelSamples: [HeliosChartSample] {
    visibleBuckets.map { bucket in
      let value = bucket.onBattery == true ? bucket.batteryPercent : nil
      return HeliosChartSample(capturedAt: bucket.capturedAt, value: value)
    }
  }

  private func selectedAppSamples(appKey: String) -> [HeliosChartSample] {
    visibleBuckets.map { bucket in
      guard bucket.onBattery == true else {
        return HeliosChartSample(capturedAt: bucket.capturedAt, value: nil)
      }
      let energy = bucket.entries.first(where: { $0.appKey == appKey })?.energyWattHours
      let milliwattHours = energy.map { $0 * 1_000 }
      return HeliosChartSample(capturedAt: bucket.capturedAt, value: milliwattHours)
    }
  }

  private func energyLeaderRow(rank: Int, entry: AppEnergyEntry) -> some View {
    let selected = effectiveSelectedAppKey == entry.appKey
    let share = trackedEnergyWattHours > 0 ? entry.energyWattHours / trackedEnergyWattHours : 0
    return HStack(spacing: 8) {
      Text("\(rank)")
        .font(.system(size: 9, weight: .medium).monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(width: 14, alignment: .trailing)
      HeliosAppIdentityIcon(appKey: entry.appKey, size: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.displayName)
          .font(.system(size: 10.5, weight: .medium))
          .lineLimit(1)
        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.10))
            Capsule().fill(Color.orange.opacity(0.78))
              .frame(width: proxy.size.width * CGFloat(min(1, max(0, share))))
          }
        }
        .frame(height: 3)
      }
      Spacer(minLength: 5)
      VStack(alignment: .trailing, spacing: 1) {
        Text(String(format: "%.0f%%", share * 100))
          .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        Text(energyText(entry.energyWattHours))
          .font(.system(size: 8.5).monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
    .background(
      selected ? Color.accentColor.opacity(0.12) : Color.clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .contentShape(Rectangle())
  }

  private func inspectorCard(
    _ title: String, _ value: String, detail: String, symbol: String, tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        Image(systemName: symbol)
          .foregroundStyle(tint)
        Text(title)
          .foregroundStyle(.secondary)
      }
      .font(.system(size: 9.5, weight: .medium))
      Text(value)
        .font(.system(size: 18, weight: .semibold).monospacedDigit())
        .lineLimit(1)
      Text(detail)
        .font(.system(size: 8.5))
        .foregroundStyle(.tertiary)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    .padding(10)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.52),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func inspectorEmpty(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.system(size: 10.5, weight: .semibold))
      Text(detail)
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .padding(.vertical, 6)
  }

  private func inspectorDetailRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }
    .font(.system(size: 9.5))
  }

  private func selectedShareText(_ entry: AppEnergyEntry) -> String {
    guard trackedEnergyWattHours > 0 else { return "Tracked battery share unavailable" }
    let share = entry.energyWattHours / trackedEnergyWattHours
    return String(format: "%.1f%% of tracked app energy · %@", share * 100, range.menuLabel)
  }

  private func energyText(_ wattHours: Double) -> String {
    guard wattHours.isFinite, wattHours >= 0 else { return "—" }
    if wattHours < 1 {
      return String(format: "%.2f mWh", wattHours * 1_000)
    }
    return String(format: "%.2f Wh", wattHours)
  }

  private var currentBatteryText: String {
    guard case .success(let battery) = p.battery,
      case .success(let percent) = battery.stateOfChargePercent
    else { return "—" }
    return String(format: "%.0f%%", percent)
  }

  private var currentPowerSourceText: String {
    guard case .success(let battery) = p.battery,
      case .success(let source) = battery.powerSource
    else { return "Current power source unavailable" }
    return source.rawValue
  }

  private var currentBatteryFlowText: String {
    guard case .success(let battery) = p.battery,
      case .success(let power) = battery.power
    else { return "—" }
    return String(format: "%+.1f W", power.signedWatts)
  }

  private var currentBatteryFlowDetail: String {
    guard case .success(let battery) = p.battery,
      case .success(let source) = battery.powerSource
    else { return "Current battery flow unavailable" }
    switch source {
    case .battery: return "negative = discharging"
    case .powerAdapter: return "connected to power adapter"
    }
  }

  private var batteryChangeText: String {
    guard let batteryChangePercent else { return "—" }
    return String(format: "%+.1f%%", batteryChangePercent)
  }

  private var batteryChangeTint: Color {
    guard let batteryChangePercent else { return .secondary }
    if batteryChangePercent < -15 { return .orange }
    if batteryChangePercent > 0.5 { return .green }
    return .blue
  }
}

enum HeliosMonitorRoute: String, CaseIterable, Identifiable, Sendable {
  case overview, cpu, memory, gpu, thermals, battery, energy, storage, network, processes, history,
    health,
    system, devices, maintenance, expert
  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "Overview"
    case .cpu: "CPU"
    case .memory: "Memory"
    case .gpu: "GPU"
    case .thermals: "Thermals & Fans"
    case .battery: "Battery"
    case .energy: "Energy"
    case .storage: "Storage"
    case .network: "Network"
    case .processes: "Processes"
    case .history: "History"
    case .health: "Health & Alerts"
    case .system: "System"
    case .devices: "Devices"
    case .maintenance: "Maintenance"
    case .expert: "Expert"
    }
  }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .gpu: "display"
    case .thermals: "thermometer.medium"
    case .battery: "battery.75percent"
    case .energy: "chart.bar.xaxis"
    case .storage: "internaldrive"
    case .network: "network"
    case .processes: "list.bullet.rectangle"
    case .history: "clock.arrow.circlepath"
    case .health: "heart.text.square"
    case .system: "macbook"
    case .devices: "macbook.and.iphone"
    case .maintenance: "wrench.and.screwdriver"
    case .expert: "slider.horizontal.3"
    }
  }
}

private enum HeliosExpertSection: String, CaseIterable, Identifiable {
  case complete = "All Diagnostics"
  case sensors = "Sensors"
  case telemetry = "Telemetry"
  case services = "Services"
  case logs = "Logs"

  var id: String { rawValue }
}

@MainActor
private final class HeliosMonitorNavigation: ObservableObject {
  @Published var selection: HeliosMonitorRoute? = .overview
}

private struct HeliosMonitorWindowView: View {
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var service: DaemonService
  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var navigation: HeliosMonitorNavigation
  let openEnergyInspector: () -> Void

  var body: some View {
    NavigationSplitView {
      List(preferences.monitorRoutesForPresentation, selection: $navigation.selection) { route in
        Label(route.title, systemImage: route.symbol).tag(route)
      }
      .navigationTitle("Helios")
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
    } detail: {
      ScrollView {
        HeliosModuleDetail(
          route: navigation.selection ?? .overview, model: model, service: service,
          preferences: preferences, openEnergyInspector: openEnergyInspector
        )
        .padding(20)
        .frame(maxWidth: 1280, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .navigationTitle((navigation.selection ?? .overview).title)
    }
    .onReceive(preferences.$monitorRoutes) { _ in
      repairNavigationSelectionAfterPreferenceMutation()
    }
    .onReceive(preferences.$telemetryModules) { _ in
      // Collection and presentation are persisted independently. When a
      // sampler stops or resumes, the visible route list must update without
      // destroying the user's saved order or requiring an app restart.
      repairNavigationSelectionAfterPreferenceMutation()
    }
  }

  private func repairNavigationSelectionAfterPreferenceMutation() {
    // @Published emits before the property mutation is visible through the
    // observed object. Defer one main-loop turn, then validate against the
    // regenerated presentation surface.
    DispatchQueue.main.async {
      let routes = preferences.monitorRoutesForPresentation
      guard let selection = navigation.selection, routes.contains(selection) else {
        navigation.selection = .overview
        return
      }
    }
  }
}

private struct HeliosDiagnosticDisclosurePanel<Content: View>: View {
  let title: String
  let symbol: String
  let subtitle: String?
  let summary: String?
  @State private var isExpanded: Bool
  private let content: () -> Content

  init(
    title: String, symbol: String, subtitle: String? = nil, summary: String? = nil,
    defaultExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.symbol = symbol
    self.subtitle = subtitle
    self.summary = summary
    _isExpanded = State(initialValue: defaultExpanded)
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 10) {
          Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18)

          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.primary)
            if let subtitle {
              Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
            }
          }

          Spacer(minLength: 12)

          if let summary {
            Text(summary)
              .font(.system(size: 9.5, weight: .medium).monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(
                Color(nsColor: .separatorColor).opacity(0.18),
                in: Capsule(style: .continuous))
          }

          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(12)

      if isExpanded {
        Divider().opacity(0.45)
        VStack(alignment: .leading, spacing: 6) {
          content()
        }
        .padding(10)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.66),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.30), lineWidth: 0.5))
  }
}

private struct HeliosModuleDetail: View {
  let route: HeliosMonitorRoute
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var service: DaemonService
  @ObservedObject var preferences: HeliosPreferences
  let openEnergyInspector: () -> Void
  @State private var showRawThermalSensors = false
  @State private var expertSection: HeliosExpertSection = .complete
  @State private var smcNumericResult: MetricResult<SMCNumericMetrics>?
  @State private var smcNumericLoading = false
  private var p: OverviewPresentation { OverviewPresentation(model.snapshot) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      title
      if routeHasCharts { chartToolbar }
      routeContent
      if preferences.detailedMonitorContent, route != .overview, route != .expert {
        detailedDiagnosticsHeader
        detailedBackendTelemetry
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var detailedDiagnosticsHeader: some View {
    HStack(alignment: .center, spacing: 10) {
      Label("Advanced diagnostics", systemImage: "waveform.path.ecg")
        .font(.system(size: 12, weight: .semibold))
      Text("Complete backend telemetry, grouped into compact expandable sections.")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      Spacer()
      Text("Detailed")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule(style: .continuous))
    }
    .padding(.top, 4)
  }

  /// Keep the route switch behind a concrete type-erasure boundary. The Full
  /// Monitor intentionally exposes a very large diagnostic surface in Detailed
  /// mode; allowing every route's opaque SwiftUI type to participate directly
  /// in `body` creates an enormous nested `_ConditionalContent` tree and can
  /// trigger Swift's non-terminating opaque-type substitution failure.
  private var routeContent: AnyView {
    switch route {
    case .overview: AnyView(overview)
    case .cpu: AnyView(cpu)
    case .memory: AnyView(memory)
    case .gpu: AnyView(gpu)
    case .thermals: AnyView(thermals)
    case .battery: AnyView(battery)
    case .energy: AnyView(energy)
    case .storage: AnyView(storage)
    case .network: AnyView(network)
    case .processes: AnyView(processes)
    case .history: AnyView(history)
    case .health: AnyView(health)
    case .system: AnyView(system)
    case .devices: AnyView(devices)
    case .maintenance: AnyView(maintenance)
    case .expert: AnyView(expert)
    }
  }

  private var routeHasCharts: Bool {
    switch route {
    case .overview, .cpu, .memory, .gpu, .thermals, .battery, .energy, .storage, .network, .history:
      true
    default:
      false
    }
  }

  private var graphScope: HeliosGraphScope? {
    switch route {
    case .overview: .overview
    case .cpu: .cpu
    case .memory: .memory
    case .gpu: .gpu
    case .thermals: .thermals
    case .battery: .battery
    case .energy: .energy
    case .storage: .storage
    case .network: .network
    case .history: .history
    default: nil
    }
  }

  private var activeGraphRange: HeliosGraphRange {
    graphScope.map { preferences.graphRange(for: $0) } ?? preferences.graphRange
  }

  private var activeBatteryEnergy: AppEnergySummary {
    guard let anchor = model.appEnergy.buckets.last?.capturedAt else { return .empty }
    let cutoff = anchor.addingTimeInterval(-activeGraphRange.seconds)
    return AppEnergyHistoryEngine.summary(
      model.appEnergy.buckets.filter { $0.capturedAt >= cutoff && $0.capturedAt <= anchor })
  }

  private var chartToolbar: some View {
    HStack(spacing: 10) {
      if let scope = graphScope {
        Text("Range")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
        HeliosGraphRangePicker(
          range: Binding(
            get: { preferences.graphRange(for: scope) },
            set: { preferences.setGraphRange($0, for: scope) }))
      }
      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.35),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }

  private var title: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(route.title).font(.system(size: 26, weight: .semibold))
        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer()
      if preferences.coolingFeaturesEnabled, service.client.state == .connected {
        Label("Helper connected", systemImage: "checkmark.circle.fill").font(
          .system(size: 11, weight: .medium)
        ).foregroundStyle(.green)
      }
    }
  }

  private var subtitle: String {
    if case .success(let system) = p.system {
      return ((try? system.chipName.get()) ?? "Mac") + " · " + system.osVersion
    }
    return "Native macOS telemetry"
  }

  private var overview: some View {
    VStack(spacing: 14) {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 190, maximum: 360), spacing: 12)], spacing: 12
      ) {
        tile(
          "CPU", "cpu", metric(p.cpu.map(\.usagePercent)) { String(format: "%.1f%%", $0) },
          preferences.color(for: .cpu))
        tile(
          "Memory", "memorychip",
          metric(p.memory.map(\.usagePercent)) { String(format: "%.1f%%", $0) },
          preferences.color(for: .memory))
        tile(
          "GPU", "display",
          metric(p.gpu.flatMap(\.deviceUtilizationPercent)) { String(format: "%.1f%%", $0) },
          preferences.color(for: .gpu))
        tile(
          "Max SoC", "thermometer.medium",
          metric(p.thermals.flatMap(\.maximumSoCCelsius)) { String(format: "%.1f°C", $0) },
          preferences.color(for: .temperature))
        tile(
          "Battery", "battery.75percent",
          metric(p.battery.flatMap(\.stateOfChargePercent)) { String(format: "%.0f%%", $0) },
          preferences.color(for: .battery)
        )
        tile(
          "System Power", "bolt.fill",
          metric(p.systemPower.flatMap(\.totalSystemWatts)) { String(format: "%.1f W", $0) },
          preferences.color(for: .power))
      }

      section("Live Trends", "chart.xyaxis.line") {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 300, maximum: 620), spacing: 12)], spacing: 12
        ) {
          trendCardSeries(
            "CPU", samples: mergedSeries(\.cpuPercent, \.cpuPercent),
            current: model.history.points.last?.cpuPercent,
            fixedRange: 0...100, tint: preferences.color(for: .cpu), valueStyle: .percent,
            format: { String(format: "%.0f%%", $0) })
          trendCardSeries(
            "Memory", samples: mergedSeries(\.memoryPercent, \.memoryPercent),
            current: model.history.points.last?.memoryPercent, fixedRange: 0...100,
            tint: preferences.color(for: .memory),
            valueStyle: .percent,
            format: { String(format: "%.0f%%", $0) })
          trendCardSeries(
            "Temperature", samples: mergedSeries(\.maxSoCCelsius, \.maxSoCCelsius),
            current: model.history.points.last?.maxSoCCelsius, fixedRange: 20...100,
            tint: preferences.color(for: .temperature),
            valueStyle: .celsius,
            format: { String(format: "%.0f°C", $0) })
          trendCardSeries(
            "System Power", samples: mergedSeries(\.systemPowerWatts, \.systemPowerWatts),
            current: model.history.points.last?.systemPowerWatts, fixedRange: nil,
            tint: preferences.color(for: .power),
            valueStyle: .watts,
            format: { String(format: "%.1f W", $0) })
        }
      }

      if preferences.coolingFeaturesEnabled {
        section("Cooling", "fan") {
          if preferences.fanSafetyGuideCompleted {
            FanControlView(
              model: service.fanControl, client: service.client, preflight: p.fanOwnershipPreflight)
            HeliosFanSafetyNotice(compact: true)
          } else {
            fanSafetyFirstUseGate
          }
        }
      }
    }
  }

  private var fanSafetyFirstUseGate: some View {
    VStack(alignment: .leading, spacing: 9) {
      Label("Before using custom cooling", systemImage: "exclamationmark.triangle")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.orange)
      HeliosFanSafetyNotice()
      Text(
        "Helios recommends System mode for normal use. Acknowledge this once to reveal Boost, Manual and Automatic Rules. You can show the guide again from Settings → Cooling."
      )
      .font(.system(size: 9.5)).foregroundStyle(.secondary)
      HStack {
        Button("Keep System") { service.fanControl.setMode(.system) }
        Spacer()
        Button("I Understand — Show Controls") { preferences.completeFanSafetyGuide() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
    }
  }

  private var cpu: some View {
    VStack(spacing: 12) {
      section("CPU Usage", "cpu") {
        big(metric(p.cpu.map(\.usagePercent)) { String(format: "%.1f%%", $0) })
        if case .success(let cpu) = p.cpu {
          HStack(spacing: 28) {
            compactValue("User", String(format: "%.1f%%", cpu.userPercent))
            compactValue("System", String(format: "%.1f%%", cpu.systemPercent))
            compactValue("Idle", String(format: "%.1f%%", cpu.idlePercent))
          }
          .frame(maxWidth: 420, alignment: .leading)
        }
        timeChart(
          mergedSeries(\.cpuPercent, \.cpuPercent), fixedRange: 0...100,
          tint: preferences.color(for: .cpu),
          valueStyle: .percent, label: "CPU"
        )
        .frame(height: 110)
        HStack {
          Text("Selected range").foregroundStyle(.secondary)
          Spacer()
          Text(activeGraphRange.label).monospacedDigit()
        }
        .font(.system(size: 10))
      }

      if preferences.detailedMonitorContent, case .success(let cpu) = p.cpu {
        section("Per-Core Activity", "square.grid.3x3") {
          ForEach(Array(cpu.perCoreUsagePercent.enumerated()), id: \.offset) { index, usage in
            HStack {
              Text("Core \(index + 1)").frame(width: 58, alignment: .leading)
              ProgressView(value: min(100, max(0, usage)), total: 100)
              Text(String(format: "%.0f%%", usage)).monospacedDigit().frame(
                width: 46, alignment: .trailing)
            }
            .font(.system(size: 11))
          }
        }
      }
    }
  }

  private var memory: some View {
    VStack(spacing: 12) {
      section("Memory", "memorychip") {
        if case .success(let m) = p.memory {
          let composition = HeliosMemoryComposition(m)
          HStack(alignment: .center, spacing: 22) {
            HeliosSegmentedArcGauge(
              segments: composition.gaugeSegments(
                showAvailable: preferences.memoryGaugeShowsAvailable, preferences: preferences),
              progress: composition.usedFraction,
              valueText: String(format: "%.0f%%", m.usagePercent),
              subtitle: "Used"
            )
            .frame(width: 132, height: 116)

            VStack(alignment: .leading, spacing: 10) {
              HStack(spacing: 24) {
                compactValue("Used", TelemetryFormatting.storageBytes(composition.usedBytes))
                compactValue(
                  "Available", TelemetryFormatting.storageBytes(composition.availableBytes))
              }
              .frame(maxWidth: 320, alignment: .leading)

              HStack(spacing: 7) {
                Circle().fill(memoryPressureColor(m.pressure)).frame(width: 7, height: 7)
                Text("Memory pressure")
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
                Text(metric(m.pressure) { $0.rawValue })
                  .font(.system(size: 11.5, weight: .semibold))
                  .foregroundStyle(memoryPressureColor(m.pressure))
              }

              Text(
                preferences.memoryGaugeShowsAvailable
                  ? "The arc is an exclusive view of physical memory: app + wired + compressed + available."
                  : "The colored arc is memory in use; the neutral remainder is available physical memory."
              )
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: 540, alignment: .leading)
        } else {
          big(metric(p.memory.map(\.usagePercent)) { String(format: "%.1f%%", $0) })
        }
        timeChart(
          mergedSeries(\.memoryPercent, \.memoryPercent), fixedRange: 0...100,
          tint: preferences.color(for: .memory),
          valueStyle: .percent, label: "Memory"
        )
        .frame(height: 120)
        HStack {
          Text("Memory usage history").foregroundStyle(.secondary)
          Spacer()
          Text(activeGraphRange.label).monospacedDigit()
        }
        .font(.system(size: 10))
      }

      if case .success(let m) = p.memory {
        let composition = HeliosMemoryComposition(m)
        section("Memory Breakdown", "square.stack.3d.up") {
          memoryBar(
            "App memory", bytes: composition.appBytes, total: composition.physicalBytes,
            tint: preferences.color(for: .memoryApp)
          )
          memoryBar(
            "Wired", bytes: composition.wiredBytes, total: composition.physicalBytes,
            tint: preferences.color(for: .memoryWired))
          memoryBar(
            "Compressed", bytes: composition.compressedBytes, total: composition.physicalBytes,
            tint: preferences.color(for: .memoryCompressed))
          memoryBar(
            "Available", bytes: composition.availableBytes, total: composition.physicalBytes,
            tint: preferences.memoryGaugeShowsAvailable
              ? preferences.color(for: .memoryAvailable) : HeliosMemoryPalette.unfilled)
          Divider().opacity(0.5)
          row("Reclaimable cache", TelemetryFormatting.storageBytes(composition.cacheBytes))
          Text(
            "Cache is reclaimable memory and can overlap the available/reusable view, so it is intentionally not drawn as a fifth physical segment."
          )
          .font(.system(size: 9.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          Divider().opacity(0.5)
          row("Used", TelemetryFormatting.storageBytes(composition.usedBytes))
          row("Physical", TelemetryFormatting.storageBytes(composition.physicalBytes))
          row("Swap used", metric(m.swapUsedBytes, TelemetryFormatting.storageBytes))
          row("Swap-ins / outs", "\(m.swapIns) / \(m.swapOuts)")
        }
      }

      if preferences.detailedMonitorContent, case .success(let processes) = p.processes,
        !processes.topByMemory.isEmpty
      {
        section("Top Memory Processes", "list.bullet.rectangle") {
          ForEach(processes.topByMemory.prefix(8)) { process in
            HStack {
              Text(process.name).lineLimit(1)
              Spacer()
              Text(TelemetryFormatting.storageBytes(process.physicalFootprintBytes))
                .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5))
          }
        }
      }
    }
  }

  private var gpu: some View {
    VStack(spacing: 12) {
      section("Graphics", "display") {
        big(metric(p.gpu.flatMap(\.deviceUtilizationPercent)) { String(format: "%.1f%%", $0) })
        timeChart(
          mergedSeries(\.gpuPercent, \.gpuPercent), fixedRange: 0...100,
          tint: preferences.color(for: .gpu),
          valueStyle: .percent, label: "GPU"
        )
        .frame(height: 110)
        if case .success(let g) = p.gpu {
          row("Model", metric(g.model) { $0 })
          row("Cores", metric(g.coreCount) { String($0) })
          if preferences.detailedMonitorContent {
            row("Renderer", metric(g.rendererUtilizationPercent) { String(format: "%.1f%%", $0) })
            row("Tiler", metric(g.tilerUtilizationPercent) { String(format: "%.1f%%", $0) })
            row("Memory in use", metric(g.inUseSystemMemoryBytes, TelemetryFormatting.storageBytes))
          }
        }
      }
    }
  }

  private var thermals: some View {
    VStack(spacing: 12) {
      section("Thermal History", "chart.xyaxis.line") {
        trendRowSeries(
          "Max SoC", samples: mergedSeries(\.maxSoCCelsius, \.maxSoCCelsius),
          current: model.history.points.last?.maxSoCCelsius, fixedRange: 20...100,
          tint: preferences.color(for: .temperature),
          valueStyle: .celsius,
          format: { String(format: "%.1f°C", $0) })
        trendRowSeries(
          "Fan", samples: mergedSeries(\.fanRPM, \.fanRPM),
          current: model.history.points.last?.fanRPM,
          fixedRange: nil, tint: preferences.color(for: .fan), valueStyle: .rpm,
          format: { $0 < 50 ? "Off" : String(format: "%.0f RPM", $0) }
        )
      }

      // Cooling controls stay ahead of raw sensor inventory so normal users
      // never have to scroll through opaque SMC keys to reach the action they
      // opened this page for. Users who disable cooling still retain trusted
      // thermal health without carrying fan-control UI they do not need.
      if preferences.coolingFeaturesEnabled {
        section("Fan Control", "fan") {
          if preferences.fanSafetyGuideCompleted {
            FanControlView(
              model: service.fanControl, client: service.client, preflight: p.fanOwnershipPreflight)
            HeliosFanSafetyNotice(compact: true)
          } else {
            fanSafetyFirstUseGate
          }
        }
      } else {
        section("Cooling", "fan.slash") {
          Label("Cooling controls disabled", systemImage: "checkmark.circle")
            .font(.system(size: 11, weight: .semibold))
          Text(
            "Temperature and read-only fan telemetry remain available when their samplers are enabled. Re-enable cooling controls in Settings if you want Boost, Manual or Automatic Rules."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }

      if preferences.detailedMonitorContent {
        section("Sensors", "thermometer.medium") {
          big(metric(p.thermals.flatMap(\.maximumSoCCelsius)) { String(format: "%.1f°C", $0) })
          if case .success(let t) = p.thermals {
            let identified = t.readings.filter { $0.group != .unclassified }
            let raw = t.readings
              .filter { $0.group == .unclassified }
              .sorted(by: { $0.celsius > $1.celsius })
            let classifiedRaw = ThermalDisplayClassifier.classify(raw)
            let auxiliary = classifiedRaw.filter { $0.info.kind == .knownAuxiliary }
            let unknown = classifiedRaw.filter { $0.info.kind == .unknown }

            if identified.isEmpty {
              Text("No trusted thermal groups are currently available.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
              ForEach(
                ThermalGroup.allCases.filter { $0 != .unclassified }, id: \.rawValue
              ) { group in
                let readings = identified.filter { $0.group == group }
                if !readings.isEmpty {
                  let maximum = readings.map(\.celsius).max() ?? 0
                  let average = readings.map(\.celsius).reduce(0, +) / Double(readings.count)
                  row(
                    group.rawValue,
                    String(format: "%.1f°C max · %.1f°C avg", maximum, average))
                }
              }
            }

            if !raw.isEmpty {
              Divider().opacity(0.5)
              HStack(spacing: 6) {
                Label("Advisory sensor inventory", systemImage: "waveform.path.ecg")
                  .font(.system(size: 9.5, weight: .medium))
                Spacer()
                if let capturedAt = t.advisoryReadingsCapturedAt {
                  Text(
                    "updated \(max(0, Int(Date().timeIntervalSince(capturedAt))))s ago · relaxed ~15s cadence"
                  )
                  .font(.system(size: 9).monospacedDigit())
                  .foregroundStyle(.tertiary)
                }
              }
              .help(
                "Raw/unclassified SMC channels are refreshed less often than trusted keys to minimize monitoring overhead. Exact Max SoC / Cooling Rules sensors remain on the fast thermal cadence."
              )

              Text(
                "Only the exact trusted groups above participate in Max SoC and fan safety. Attributed Stats auxiliary mappings and unclassified raw keys remain advisory and are never promoted into control policy without independent validation."
              )
              .font(.system(size: 9.5))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

              if !auxiliary.isEmpty {
                DisclosureGroup {
                  LazyVStack(spacing: 5) {
                    ForEach(auxiliary) { item in
                      thermalDisplayRow(item)
                    }
                  }
                  .padding(.top, 6)
                } label: {
                  thermalDisclosureLabel("Auxiliary sensors", count: auxiliary.count)
                }
              }

              if !unknown.isEmpty {
                DisclosureGroup(
                  isExpanded: $showRawThermalSensors,
                  content: {
                    LazyVStack(spacing: 5) {
                      Text(
                        "Raw SMC keys are undocumented expert diagnostics. Helios does not infer their meaning or use them for Max SoC, Cooling Rules, or fan safety."
                      )
                      .font(.system(size: 9.5))
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                      .padding(.bottom, 3)
                      ForEach(unknown) { item in
                        thermalDisplayRow(item)
                      }
                    }
                    .padding(.top, 6)
                  },
                  label: {
                    thermalDisclosureLabel("Other raw / unclassified", count: unknown.count)
                  })
              }
            }
          }
        }
      }
    }
  }

  private var battery: some View {
    VStack(spacing: 12) {
      let estimate = HeliosBatteryEstimateEngine.estimate(
        battery: p.battery, history: model.history)
      let energy = activeBatteryEnergy

      section("Battery", "battery.75percent") {
        HStack(spacing: 12) {
          batteryHero(
            "Battery",
            metric(p.battery.flatMap(\.stateOfChargePercent)) { String(format: "%.0f%%", $0) },
            detail: "System SoC", tint: preferences.color(for: .battery))
          batteryHero(
            "Remaining", estimate.compactText, detail: estimate.source.rawValue,
            tint: estimate.approximate ? .orange : .blue)
          batteryHero(
            "Battery flow",
            metric(p.battery.flatMap(\.power)) { String(format: "%+.1f W", $0.signedWatts) },
            detail: batteryFlowDetail, tint: preferences.color(for: .power))
        }
        trendRowSeries(
          "Charge", samples: mergedSeries(\.batteryPercent, \.batteryPercent),
          current: model.history.points.last?.batteryPercent, fixedRange: 0...100,
          tint: preferences.color(for: .battery),
          valueStyle: .percent,
          format: { String(format: "%.0f%%", $0) })
        trendRowSeries(
          "Battery flow", samples: mergedSeries(\.batteryPowerWatts, \.batteryPowerWatts),
          current: model.history.points.last?.batteryPowerWatts, fixedRange: nil,
          tint: preferences.color(for: .power),
          valueStyle: .signedWatts,
          format: { String(format: "%+.1f W", $0) })

        if case .success(let b) = p.battery {
          row("System SoC", metric(b.systemChargePercent) { String(format: "%.1f%%", $0) })
          row(
            "Raw capacity SoC", metric(b.rawStateOfChargePercent) { String(format: "%.1f%%", $0) })
          row("Health", metric(b.healthPercent) { String(format: "%.1f%%", $0) })
          row("Cycles", metric(b.cycleCount) { String($0) })
          row("Power source", metric(b.powerSource) { $0.rawValue })
          row("Charging", metric(b.isCharging) { $0 ? "Yes" : "No" })
          row("Time remaining", estimate.compactText)
          row("Cell temperature", metric(b.temperatureCelsius) { String(format: "%.1f°C", $0) })
          if estimate.source == .helios {
            Text(
              "≈ is an early read-only Helios estimate derived from recent battery drain. It stabilizes as more samples arrive; macOS' own estimate takes priority when available."
            )
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      section("Energy Attribution", "bolt.horizontal.circle") {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Which apps used battery energy?")
              .font(.system(size: 11, weight: .semibold))
            Text(
              "Local, battery-only attribution for the selected \(activeGraphRange.label) window. Helios uses the ranking as a relative diagnostic signal, not billing-grade joules."
            )
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          VStack(alignment: .trailing, spacing: 2) {
            Text(activeGraphRange.label)
              .font(.system(size: 11, weight: .semibold).monospacedDigit())
            Text("Observed \(TelemetryFormatting.duration(energy.onBatteryCoverageSeconds))")
              .font(.system(size: 9))
              .foregroundStyle(.tertiary)
          }
        }

        HStack {
          Button {
            openEnergyInspector()
          } label: {
            Label("Open Energy Inspector…", systemImage: "chart.bar.xaxis")
          }
          .controlSize(.small)
          .help("Open the dedicated per-app battery and energy history window")
          Spacer()
        }

        if energy.topOnBattery.isEmpty {
          HStack(spacing: 9) {
            Image(systemName: "battery.25")
              .font(.system(size: 18))
              .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text("No on-battery app history in this range")
                .font(.system(size: 10.5, weight: .semibold))
              Text(
                "Use the Mac on battery for a few minutes and Helios will begin ranking the apps it can observe."
              )
              .font(.system(size: 9.5))
              .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 5)
        } else {
          let leaders = Array(energy.topOnBattery.prefix(8))
          let trackedTotal = max(
            0.000_001, energy.topOnBattery.reduce(0) { $0 + $1.energyWattHours })
          ForEach(Array(leaders.enumerated()), id: \.element.id) { index, entry in
            let trend = energy.recentHourTrends.first { $0.appKey == entry.appKey }
            batteryEnergyRow(
              rank: index + 1, entry: entry, total: trackedTotal, trend: trend)
          }

          let visibleEnergy = leaders.reduce(0) { $0 + $1.energyWattHours }
          let otherShare = max(0, (trackedTotal - visibleEnergy) / trackedTotal)
          if otherShare >= 0.005 {
            HStack {
              Text("Other tracked apps").foregroundStyle(.secondary)
              Spacer()
              Text(String(format: "%.0f%%", otherShare * 100))
                .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 9.5))
          }
        }
      }

      if preferences.detailedMonitorContent {
        section("Electrical", "bolt") {
          if case .success(let b) = p.battery {
            row("Battery flow", metric(b.power) { String(format: "%+.2f W", $0.signedWatts) })
            row("Battery voltage", metric(b.voltageVolts) { String(format: "%.2f V", $0) })
            row("Battery current", metric(b.currentAmps) { String(format: "%+.2f A", $0) })
            row("Adapter rating", metric(b.adapterWatts) { "\($0) W" })
            row("Adapter voltage", metric(b.adapterVoltageVolts) { String(format: "%.2f V", $0) })
            row("Charging current", metric(b.chargingCurrentAmps) { String(format: "%.2f A", $0) })
            row("Charging voltage", metric(b.chargingVoltageVolts) { String(format: "%.2f V", $0) })
          } else {
            Text("Battery electrical telemetry unavailable.").foregroundStyle(.secondary)
          }
        }
        section("Battery Diagnostics", "waveform.path.ecg") {
          if case .success(let b) = p.battery {
            row("Design capacity", metric(b.designCapacityMAh) { "\($0) mAh" })
            row("Full charge capacity", metric(b.maximumCapacityMAh) { "\($0) mAh" })
            row("Raw current capacity", metric(b.currentCapacityMAh) { "\($0) mAh" })
            row(
              "Optimized charging",
              metric(b.optimizedChargingEngaged) { $0 ? "Engaged" : "Not engaged" })
            row(
              "Manufactured",
              metric(b.manufactureDate) { $0.formatted(date: .abbreviated, time: .omitted) })
            row("Cell balance", metric(b.cellBalanceMillivolts) { String(format: "%.0f mV", $0) })
            row(
              "Cell voltages",
              metric(b.cellVoltagesVolts) { cells in
                cells.enumerated().map { String(format: "C%d %.3fV", $0.offset + 1, $0.element) }
                  .joined(separator: " · ")
              })
            row("Not-charging raw", metric(b.notChargingReasonRaw) { String(format: "0x%llX", $0) })
            Text(
              "Battery telemetry is read-only. Charging policy remains owned by macOS; diagnostics never issue battery or charger writes."
            )
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).fixedSize(
              horizontal: false, vertical: true)
          } else {
            Text("Battery diagnostics unavailable.").foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var energy: some View {
    VStack(spacing: 12) {
      let summary = activeBatteryEnergy
      section("Energy Overview", "chart.bar.xaxis") {
        batteryPeriodInsight(summary)
        HStack(spacing: 12) {
          batteryHero(
            "System power",
            metric(p.systemPower.flatMap(\.totalSystemWatts)) { String(format: "%.1f W", $0) },
            detail: "Live total", tint: preferences.color(for: .power))
          batteryHero(
            "Battery flow",
            metric(p.battery.flatMap(\.power)) { String(format: "%+.1f W", $0.signedWatts) },
            detail: batteryFlowDetail, tint: preferences.color(for: .battery))
          batteryHero(
            "Observed", TelemetryFormatting.duration(summary.onBatteryCoverageSeconds),
            detail: "On battery", tint: preferences.color(for: .energy))
        }
        trendRowSeries(
          "System power", samples: mergedSeries(\.systemPowerWatts, \.systemPowerWatts),
          current: model.history.points.last?.systemPowerWatts, fixedRange: nil,
          tint: preferences.color(for: .power), valueStyle: .watts,
          format: { String(format: "%.1f W", $0) })
        HStack {
          Button(action: openEnergyInspector) {
            Label("Open Energy Inspector…", systemImage: "chart.bar.xaxis")
          }
          .controlSize(.small)
          Spacer()
        }
      }

      section("Battery Energy by App", "bolt.horizontal.circle") {
        if summary.topOnBattery.isEmpty {
          Text(
            "Use the Mac on battery for a few minutes and Helios will begin ranking the apps it can observe in this range."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        } else {
          let leaders = Array(
            summary.topOnBattery.prefix(preferences.detailedMonitorContent ? 12 : 6))
          let trackedTotal = max(
            0.000_001, summary.topOnBattery.reduce(0) { $0 + $1.energyWattHours })
          ForEach(Array(leaders.enumerated()), id: \.element.id) { index, entry in
            let trend = summary.recentHourTrends.first { $0.appKey == entry.appKey }
            batteryEnergyRow(rank: index + 1, entry: entry, total: trackedTotal, trend: trend)
          }
        }
      }
    }
  }

  private var storage: some View {
    VStack(spacing: 12) {
      section("Storage", "internaldrive") {
        if case .success(let s) = p.storage {
          if case .success(let root) = s.rootVolume {
            big(TelemetryFormatting.storageBytes(root.usedBytes))
            row("Capacity", TelemetryFormatting.storageBytes(root.totalBytes))
            row("Free", TelemetryFormatting.storageBytes(root.freeBytes))
          }
          if let device = s.primaryDevice {
            row("Primary device", "\(device.model) · \(device.bsdName)")
            row("Transport", device.transport)
          }
          if case .success(let smart) = s.smartHealth {
            row("SMART", smart.state.rawValue)
            row("Life remaining", "\(smart.lifeRemainingPercent)%")
            if let temp = smart.temperatureCelsius {
              row("SSD temperature", String(format: "%.1f°C", temp))
            }
          }
        } else {
          Text("Storage telemetry unavailable.").foregroundStyle(.secondary)
        }
      }
      section("Disk Activity", "chart.xyaxis.line") {
        trendRowSeries(
          "Read", samples: mergedSeries(\.storageReadBytesPerSecond, \.storageReadBytesPerSecond),
          current: model.history.points.last?.storageReadBytesPerSecond, fixedRange: nil,
          tint: preferences.color(for: .storageRead), valueStyle: .bytesPerSecond,
          format: TelemetryFormatting.bytesPerSecond)
        trendRowSeries(
          "Write",
          samples: mergedSeries(\.storageWriteBytesPerSecond, \.storageWriteBytesPerSecond),
          current: model.history.points.last?.storageWriteBytesPerSecond, fixedRange: nil,
          tint: preferences.color(for: .storageWrite), valueStyle: .bytesPerSecond,
          format: TelemetryFormatting.bytesPerSecond)
      }
    }
  }

  private var network: some View {
    VStack(spacing: 12) {
      section("Live Traffic", "chart.xyaxis.line") {
        trendRowSeries(
          "Download",
          samples: mergedSeries(\.networkDownloadBytesPerSecond, \.networkDownloadBytesPerSecond),
          current: model.history.points.last?.networkDownloadBytesPerSecond, fixedRange: nil,
          tint: preferences.color(for: .networkDownload), valueStyle: .bytesPerSecond,
          format: TelemetryFormatting.bytesPerSecond)
        trendRowSeries(
          "Upload",
          samples: mergedSeries(\.networkUploadBytesPerSecond, \.networkUploadBytesPerSecond),
          current: model.history.points.last?.networkUploadBytesPerSecond, fixedRange: nil,
          tint: preferences.color(for: .networkUpload), valueStyle: .bytesPerSecond,
          format: TelemetryFormatting.bytesPerSecond)
      }
      section("Network", "network") {
        if case .success(let n) = p.network {
          row("Interface", metric(n.primaryInterface) { $0 })
          row("IPv4", metric(n.ipv4Address) { $0 })
          row("Gateway", metric(n.gatewayIPv4) { $0 })
          if case .success(let rate) = n.throughput {
            row("Download", TelemetryFormatting.bytesPerSecond(rate.downloadBytesPerSecond))
            row("Upload", TelemetryFormatting.bytesPerSecond(rate.uploadBytesPerSecond))
          }
          row(
            "Session downloaded", metric(n.sessionDownloadedBytes, TelemetryFormatting.storageBytes)
          )
          row("Session uploaded", metric(n.sessionUploadedBytes, TelemetryFormatting.storageBytes))
          row("DNS", n.dnsServers.isEmpty ? "—" : n.dnsServers.joined(separator: ", "))
        } else {
          Text("Network telemetry unavailable.").foregroundStyle(.secondary)
        }
      }
    }
  }

  private var processes: some View {
    section("Processes", "list.bullet.rectangle") {
      if case .success(let processes) = p.processes {
        row("Accessible processes", String(processes.accessibleProcessCount))
        Divider()
        ForEach(processes.topByCPU.prefix(12)) { process in
          HStack {
            VStack(alignment: .leading, spacing: 1) {
              Text(process.name)
              Text("PID \(process.pid)").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(TelemetryFormatting.processCPUShareText(process.cpuPercent)).monospacedDigit()
            Text(TelemetryFormatting.storageBytes(process.physicalFootprintBytes)).foregroundStyle(
              .secondary
            ).frame(width: 84, alignment: .trailing)
          }.font(.system(size: 11))
        }
      } else {
        Text("Process telemetry unavailable.").foregroundStyle(.secondary)
      }
    }
  }

  private var history: some View {
    VStack(spacing: 12) {
      section("Telemetry Trends", "chart.xyaxis.line") {
        trendRowSeries(
          "CPU", samples: mergedSeries(\.cpuPercent, \.cpuPercent),
          current: model.history.points.last?.cpuPercent,
          fixedRange: 0...100, tint: preferences.color(for: .cpu), valueStyle: .percent,
          format: { String(format: "%.0f%%", $0) })
        trendRowSeries(
          "Memory", samples: mergedSeries(\.memoryPercent, \.memoryPercent),
          current: model.history.points.last?.memoryPercent, fixedRange: 0...100,
          tint: preferences.color(for: .memory),
          format: { String(format: "%.0f%%", $0) })
        trendRowSeries(
          "Temperature", samples: mergedSeries(\.maxSoCCelsius, \.maxSoCCelsius),
          current: model.history.points.last?.maxSoCCelsius, fixedRange: 20...100,
          tint: preferences.color(for: .temperature),
          format: { String(format: "%.0f°C", $0) })
        trendRowSeries(
          "System Power", samples: mergedSeries(\.systemPowerWatts, \.systemPowerWatts),
          current: model.history.points.last?.systemPowerWatts, fixedRange: nil,
          tint: preferences.color(for: .power),
          format: { String(format: "%.1f W", $0) })
      }
      section("Current Session", "waveform.path.ecg") {
        row("History window", TelemetryFormatting.duration(model.history.durationSeconds))
        row("Samples", String(model.history.points.count))
        row("Measured energy", String(format: "%.3f Wh", model.history.sessionEnergyWattHours))
        row(
          "Power coverage", TelemetryFormatting.duration(model.history.measuredPowerCoverageSeconds)
        )
      }
      section("Persistent 24-Hour History", "clock.arrow.circlepath") {
        let persistent = model.persistentHistory
        row("History window", TelemetryFormatting.duration(persistent.durationSeconds))
        row("Persisted samples", String(persistent.points.count))
        row("System energy", String(format: "%.3f Wh", persistent.energyWattHours))
        row("PSTR coverage", TelemetryFormatting.duration(persistent.measuredPowerCoverageSeconds))
        if let delta = persistent.batteryChargeDeltaPercent {
          row("Battery change", String(format: "%+.1f%%", delta))
        }
        row("Battery energy", String(format: "%+.3f Wh", persistent.batteryEnergyWattHours))
        if let cpu = persistent.heliosAverageCPUPercent {
          row("Helios avg CPU", String(format: "%.2f%%", cpu))
        }
        if let power = persistent.heliosAveragePowerWatts {
          row("Helios avg power", String(format: "%.3f W", power))
        }
        if let memory = persistent.heliosPeakMemoryBytes {
          row("Helios peak memory", TelemetryFormatting.storageBytes(memory))
        }
        Text(
          "History integration remains gap-safe: sleep, clock jumps, stale power samples, and malformed tails are never guessed."
        )
        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
    }
  }

  private var health: some View {
    HealthCard(center: model.healthCenter, showEventLog: true)
  }

  private var system: some View {
    VStack(spacing: 12) {
      section("System", "macbook") {
        if case .success(let system) = p.system {
          row("Model", metric(system.modelIdentifier) { $0 })
          row("Chip", metric(system.chipName) { $0 })
          row("macOS", system.osVersion)
          row("Uptime", TelemetryFormatting.duration(system.uptimeSeconds))
          row("Thermal state", system.thermalState.rawValue)
          row("Low Power Mode", system.lowPowerModeEnabled ? "On" : "Off")
          row("Logical CPUs", String(system.logicalProcessorCount))
          row("Physical memory", TelemetryFormatting.storageBytes(system.physicalMemoryBytes))
          row("Load average 1m", metric(system.loadAverage1) { String(format: "%.2f", $0) })
          row("Load average 5m", metric(system.loadAverage5) { String(format: "%.2f", $0) })
          row("Load average 15m", metric(system.loadAverage15) { String(format: "%.2f", $0) })
        } else {
          Text("System telemetry unavailable.").foregroundStyle(.secondary)
        }
      }
      section("Sleep & Power Assertions", "moon.zzz") {
        if case .success(let blockers) = p.powerAssertions {
          row("Active assertions", String(blockers.assertions.count))
          row("Display blockers", String(blockers.displaySleepBlockers.count))
          row("System blockers", String(blockers.systemSleepBlockers.count))
          ForEach(blockers.assertions.prefix(8)) { assertion in
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                Text(assertion.processName).lineLimit(1)
                Text(assertion.assertionType).font(.system(size: 9)).foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
              Spacer()
              Text(assertion.reason ?? "Active").font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(1)
            }.font(.system(size: 11))
          }
        } else {
          Text("Sleep assertion inventory unavailable.").foregroundStyle(.secondary)
        }
      }
      section("Clock", "clock") {
        if case .success(let clock) = p.clock {
          row("Time zone", clock.localTimeZoneIdentifier)
          row("ISO week", String(clock.isoWeekOfYear))
          row("Day of year", String(clock.dayOfYear))
        } else {
          Text("Clock metadata unavailable.").foregroundStyle(.secondary)
        }
      }
    }
  }

  private var maintenance: some View {
    MaintenanceCard()
  }

  private var devices: some View {
    VStack(spacing: 12) {
      section("Displays", "display") {
        if case .success(let d) = p.displays {
          ForEach(d.displays, id: \.displayID) { display in
            row(display.label, "\(display.pixelWidth)×\(display.pixelHeight)")
          }
        } else {
          Text("Display inventory unavailable.").foregroundStyle(.secondary)
        }
      }
      section("Connected Devices", "macbook.and.iphone") {
        if case .success(let bt) = p.bluetooth {
          ForEach(bt.devices.filter(\.connected), id: \.address) { device in
            row(device.name, device.rssiDBm.map { "\($0) dBm" } ?? "Connected")
          }
        }
        if case .success(let usb) = p.usb { row("USB devices", String(usb.devices.count)) }
        if case .success(let audio) = p.audio {
          row("Audio output", audio.defaultOutput?.name ?? "—")
        }
      }
    }
  }

  private var expert: some View {
    VStack(alignment: .leading, spacing: 14) {
      section("Diagnostic Workspace", "waveform.path.ecg.rectangle") {
        Text(
          "Expert is the complete technical workspace. All Diagnostics intentionally includes the full app-published telemetry set, even when the same value also appears on a focused module page. Values marked advisory remain display-only unless Helios explicitly classifies them as trusted."
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
        Picker("Expert section", selection: $expertSection) {
          ForEach(HeliosExpertSection.allCases) { section in
            Text(section.rawValue).tag(section)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }

      switch expertSection {
      case .complete: expertComplete
      case .sensors: expertSensors
      case .telemetry: expertTelemetry
      case .services: expertServices
      case .logs: expertLogs
      }
    }
  }

  private var expertComplete: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Complete read-only diagnostics expose every telemetry value the frozen backend currently retains and publishes to the app layer, including lifetime counters, raw sensor inventory, process I/O, history summaries and sampler metadata. Provider-internal transient parser scratch state is not a retained metric; exposing that would require changing the frozen backend, which this UI pass deliberately does not do."
      )
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      completeTelemetryInventory
    }
  }

  private var expertSensors: some View {
    VStack(spacing: 12) {
      section("Trusted thermal map", "thermometer.medium") {
        if case .success(let thermals) = p.thermals {
          row("Max SoC", metric(thermals.maximumSoCCelsius) { String(format: "%.1f°C", $0) })
          ForEach(ThermalGroup.allCases.filter { $0 != .unclassified }, id: \.rawValue) { group in
            let values = thermals.readings.filter { $0.group == group }.map(\.celsius)
            if !values.isEmpty {
              let maximum = values.max() ?? 0
              let average = values.reduce(0, +) / Double(values.count)
              row(group.rawValue, String(format: "%.1f°C max · %.1f°C avg", maximum, average))
            }
          }
        } else {
          Text("Trusted thermal map unavailable.").foregroundStyle(.secondary)
        }
      }

      section("Advisory sensor browser", "waveform.path.ecg") {
        if case .success(let thermals) = p.thermals {
          let raw = thermals.readings.filter { $0.group == .unclassified }
          let classified = ThermalDisplayClassifier.classify(raw)
          Text(
            "Attributed Stats auxiliary mappings and unclassified raw SMC keys remain display-only. Unclassified channels never enter cooling policy without independent validation."
          )
          .font(.system(size: 9.5)).foregroundStyle(.secondary)
          DisclosureGroup(
            "Raw / unclassified sensors (\(classified.count))", isExpanded: $showRawThermalSensors
          ) {
            LazyVStack(spacing: 5) {
              ForEach(classified) { item in thermalDisplayRow(item) }
            }
            .padding(.top, 6)
          }
        } else {
          Text("Advisory sensor inventory unavailable.").foregroundStyle(.secondary)
        }
      }
    }
  }

  private var expertTelemetry: some View {
    VStack(spacing: 12) {
      section("Collection state", "switch.2") {
        ForEach(HeliosTelemetryModule.allCases) { module in
          HStack {
            VStack(alignment: .leading, spacing: 1) {
              Text(module.label).font(.system(size: 10.5, weight: .medium))
              Text(module.monitoringCost).font(.system(size: 8.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(preferences.isTelemetryEnabled(module) ? "Collecting" : "Stopped")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(
                preferences.isTelemetryEnabled(module) ? Color.green : Color.secondary)
          }
        }
      }
      section("History engines", "clock.arrow.circlepath") {
        row("Live history", "\(model.history.points.count) samples")
        row("Persistent history", "\(model.persistentHistory.points.count) samples")
        row("App-energy buckets", "\(model.appEnergy.buckets.count)")
        Text(
          "Collection toggles stop the corresponding sampler; hiding a UI module alone does not."
        )
        .font(.system(size: 9.5)).foregroundStyle(.secondary)
      }
    }
  }

  private var expertServices: some View {
    VStack(spacing: 12) {
      section("Runtime boundary", "lock.shield") {
        row(
          "Helper connection",
          preferences.coolingFeaturesEnabled ? service.client.state.rawValue : "Cooling disabled")
        if let detail = service.client.detail { row("Authenticated peer", detail) }
        row("Battery writes", "None · read-only")
        row("Privileged writes", "Fan control only")
        row("Trusted thermal health", "Always available")
      }
      if preferences.coolingFeaturesEnabled {
        DaemonServiceCard(service: service, client: service.client)
      } else {
        section("Cooling", "fan.slash") {
          Text(
            "Cooling controls are disabled by preference. The helper installation is left untouched rather than being silently removed."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var expertLogs: some View {
    VStack(spacing: 12) {
      HealthCard(center: model.healthCenter, showEventLog: true)
      section("Log policy", "doc.text.magnifyingglass") {
        Text(
          "Health events record activation, resolution and notification decisions. The log is bounded and local so repeated alerts can be diagnosed without turning Helios into a telemetry service."
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Complete published telemetry

  /// Detailed mode deliberately exposes every field that reaches the app's
  /// published telemetry models. This is presentation-only: providers, polling
  /// cadence, validation and the privileged boundary remain untouched.
  /// Same concrete boundary for the exhaustive diagnostics extension. Each
  /// backend-published surface remains present; only the compile-time generic
  /// shape is erased so SwiftUI does not build one recursive opaque-type tree.
  private var detailedBackendTelemetry: AnyView {
    switch route {
    case .cpu: AnyView(cpuBackendTelemetry)
    case .memory: AnyView(memoryBackendTelemetry)
    case .gpu: AnyView(gpuBackendTelemetry)
    case .thermals: AnyView(thermalFanBackendTelemetry)
    case .battery: AnyView(batteryBackendTelemetry)
    case .energy: AnyView(energyBackendTelemetry)
    case .storage: AnyView(storageBackendTelemetry)
    case .network: AnyView(networkBackendTelemetry)
    case .processes: AnyView(processBackendTelemetry)
    case .history: AnyView(historyBackendTelemetry)
    case .health: AnyView(healthBackendTelemetry)
    case .system: AnyView(systemBackendTelemetry)
    case .devices: AnyView(devicesBackendTelemetry)
    case .maintenance:
      AnyView(
        diagnosticSection("Maintenance telemetry", "wrench.and.screwdriver") {
          Text(
            "Maintenance providers are intentionally on-demand. Their complete scan results are shown directly in the Maintenance card after you run a scan; no background maintenance collector is added."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      )
    case .overview, .expert: AnyView(EmptyView())
    }
  }

  private var completeTelemetryInventory: some View {
    VStack(spacing: 12) {
      sampleMetadataTelemetry
      cpuBackendTelemetry
      memoryBackendTelemetry
      gpuBackendTelemetry
      thermalFanBackendTelemetry
      batteryBackendTelemetry
      energyBackendTelemetry
      storageBackendTelemetry
      networkBackendTelemetry
      processBackendTelemetry
      systemBackendTelemetry
      devicesBackendTelemetry
      historyBackendTelemetry
      healthBackendTelemetry
      capabilityBackendTelemetry
      rawSMCNumericTelemetry
    }
  }

  private var cpuBackendTelemetry: some View {
    diagnosticSection("CPU internals", "cpu") {
      if case .success(let cpu) = p.cpu {
        diagnosticRow("Usage", String(format: "%.3f%%", cpu.usagePercent))
        diagnosticRow("User", String(format: "%.3f%%", cpu.userPercent))
        diagnosticRow("System", String(format: "%.3f%%", cpu.systemPercent))
        diagnosticRow("Nice", String(format: "%.3f%%", cpu.nicePercent))
        diagnosticRow("Idle", String(format: "%.3f%%", cpu.idlePercent))
        diagnosticRow("Physical cores", metric(cpu.physicalCoreCount, String.init))
        diagnosticRow("Performance cores", metric(cpu.performanceCoreCount, String.init))
        diagnosticRow("Efficiency cores", metric(cpu.efficiencyCoreCount, String.init))
        diagnosticRow("Logical core samples", String(cpu.perCoreUsagePercent.count))
        if !cpu.perCoreUsagePercent.isEmpty {
          Divider().opacity(0.45)
          ForEach(Array(cpu.perCoreUsagePercent.enumerated()), id: \.offset) { index, value in
            diagnosticRow("Logical core \(index + 1)", String(format: "%.3f%%", value))
          }
        }
      } else {
        telemetryUnavailable("CPU", p.cpu)
      }
    }
  }

  private var memoryBackendTelemetry: some View {
    diagnosticSection("Memory internals", "memorychip") {
      if case .success(let m) = p.memory {
        diagnosticRow("Physical", TelemetryFormatting.storageBytes(m.physicalBytes))
        diagnosticRow("Used (derived)", TelemetryFormatting.storageBytes(m.usedBytes))
        diagnosticRow("App memory (derived)", TelemetryFormatting.storageBytes(m.appBytes))
        diagnosticRow("Available (derived)", TelemetryFormatting.storageBytes(m.availableBytes))
        diagnosticRow("Cache (derived)", TelemetryFormatting.storageBytes(m.cacheBytes))
        diagnosticRow("Usage", String(format: "%.3f%%", m.usagePercent))
        Divider().opacity(0.45)
        diagnosticRow("Active", TelemetryFormatting.storageBytes(m.activeBytes))
        diagnosticRow("Inactive", TelemetryFormatting.storageBytes(m.inactiveBytes))
        diagnosticRow("Wired", TelemetryFormatting.storageBytes(m.wiredBytes))
        diagnosticRow("Compressed", TelemetryFormatting.storageBytes(m.compressedBytes))
        diagnosticRow("Speculative", TelemetryFormatting.storageBytes(m.speculativeBytes))
        diagnosticRow("Purgeable", TelemetryFormatting.storageBytes(m.purgeableBytes))
        diagnosticRow("External", TelemetryFormatting.storageBytes(m.externalBytes))
        diagnosticRow("Free", TelemetryFormatting.storageBytes(m.freeBytes))
        Divider().opacity(0.45)
        diagnosticRow("Memory pressure", metric(m.pressure) { $0.rawValue })
        diagnosticRow("Swap used", metric(m.swapUsedBytes, TelemetryFormatting.storageBytes))
        diagnosticRow("Swap total", metric(m.swapTotalBytes, TelemetryFormatting.storageBytes))
        diagnosticRow("Swap free", metric(m.swapFreeBytes, TelemetryFormatting.storageBytes))
        diagnosticRow("Swap-ins", TelemetryFormatting.count(m.swapIns))
        diagnosticRow("Swap-outs", TelemetryFormatting.count(m.swapOuts))
      } else {
        telemetryUnavailable("Memory", p.memory)
      }
    }
  }

  private var gpuBackendTelemetry: some View {
    diagnosticSection("GPU internals", "display") {
      if case .success(let g) = p.gpu {
        diagnosticRow("Model", metric(g.model) { $0 })
        diagnosticRow("Core count", metric(g.coreCount, String.init))
        diagnosticRow(
          "Device utilization",
          metric(g.deviceUtilizationPercent) { String(format: "%.3f%%", $0) })
        diagnosticRow(
          "Renderer utilization",
          metric(g.rendererUtilizationPercent) { String(format: "%.3f%%", $0) })
        diagnosticRow(
          "Tiler utilization",
          metric(g.tilerUtilizationPercent) { String(format: "%.3f%%", $0) })
        diagnosticRow(
          "Allocated system memory",
          metric(g.allocatedSystemMemoryBytes, TelemetryFormatting.storageBytes))
        diagnosticRow(
          "In-use system memory",
          metric(g.inUseSystemMemoryBytes, TelemetryFormatting.storageBytes))
      } else {
        telemetryUnavailable("GPU", p.gpu)
      }
      Divider().opacity(0.45)
      diagnosticRow(
        "Total system power",
        metric(p.systemPower.flatMap(\.totalSystemWatts)) { String(format: "%.3f W", $0) })
    }
  }

  private var thermalFanBackendTelemetry: some View {
    VStack(spacing: 10) {
      diagnosticSection(
        "Thermal sensors", "thermometer.medium",
        subtitle: "Trusted groups and unclassified raw SMC temperatures",
        summary: thermalDiagnosticSummary
      ) {
        if case .success(let t) = p.thermals {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 6)], spacing: 6
          ) {
            diagnosticMiniMetric("Readable sensors", String(t.readings.count))
            diagnosticMiniMetric("Failures", String(t.failures.count))
            diagnosticMiniMetric(
              "Advisory capture", t.advisoryReadingsCapturedAt.map(fullDateText) ?? "Not captured")
          }

          ForEach(ThermalGroup.allCases, id: \.rawValue) { group in
            let readings = t.readings.filter { $0.group == group }.sorted { $0.key < $1.key }
            if !readings.isEmpty {
              VStack(alignment: .leading, spacing: 7) {
                HStack {
                  Text(group.rawValue)
                    .font(.system(size: 10.5, weight: .semibold))
                  Spacer()
                  Text("\(readings.count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                LazyVGrid(
                  columns: [GridItem(.adaptive(minimum: 125, maximum: 190), spacing: 6)], spacing: 6
                ) {
                  ForEach(readings, id: \.key) { reading in
                    thermalSensorChip(reading)
                  }
                }
              }
              .padding(9)
              .background(
                Color(nsColor: .textBackgroundColor).opacity(0.18),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
          }

          if !t.failures.isEmpty {
            diagnosticEntityCard(
              title: "Read failures", subtitle: "Unavailable keys remain diagnostic-only",
              value: "\(t.failures.count)"
            ) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 6)], spacing: 6
              ) {
                ForEach(t.failures.keys.sorted(), id: \.self) { key in
                  diagnosticMiniMetric(
                    key, t.failures[key]?.localizedDescription ?? "Unknown")
                }
              }
            }
          }
        } else {
          telemetryUnavailable("Thermals", p.thermals)
        }
      }

      diagnosticSection(
        "Fan telemetry", "fan", subtitle: "Discovered fan capabilities and current targets",
        summary: fanDiagnosticSummary
      ) {
        if case .success(let inventory) = p.fans {
          diagnosticMiniMetric("Discovered fans", String(inventory.fans.count))
          ForEach(inventory.fans) { fan in
            diagnosticEntityCard(
              title: "Fan \(fan.id)", value: metric(fan.automatic) { $0 ? "System" : "Override" }
            ) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 135, maximum: 220), spacing: 6)], spacing: 6
              ) {
                diagnosticMiniMetric(
                  "Actual", metric(fan.actualRPM) { String(format: "%.1f RPM", $0) })
                diagnosticMiniMetric(
                  "Target", metric(fan.targetRPM) { String(format: "%.1f RPM", $0) })
                diagnosticMiniMetric(
                  "Minimum", metric(fan.minimumRPM) { String(format: "%.1f RPM", $0) })
                diagnosticMiniMetric(
                  "Maximum", metric(fan.maximumRPM) { String(format: "%.1f RPM", $0) })
                diagnosticMiniMetric("Automatic", metric(fan.automatic, boolText))
              }
            }
          }
        } else {
          telemetryUnavailable("Fans", p.fans)
        }
      }

      diagnosticSection(
        "Fan control verification", "lock.shield",
        subtitle: "Read-only ownership preflight and validated machine profile"
      ) {
        if case .success(let preflight) = p.fanOwnershipPreflight {
          let e = preflight.evidence
          let profile = FanOwnershipMachineProfile.primaryM4
          diagnosticRow("State", preflight.summary)
          diagnosticRow("Model", e.modelIdentifier)
          diagnosticRow("OS build", e.osBuild)
          diagnosticRow("Fan count", String(e.fanCount))
          diagnosticRow("Global key type", e.globalKeyType)
          diagnosticRow("Global key size", String(e.globalKeySize))
          diagnosticRow("Global value", String(e.globalValue))
          diagnosticRow("Ready for validation", boolText(preflight.isReadyForValidation))
          diagnosticRow("Validated profile model", profile.modelIdentifier)
          diagnosticRow("Validated profile OS build", profile.osBuild)
          diagnosticRow("Validated profile fan count", String(profile.fanCount))
          diagnosticRow("Validated global key", profile.globalKey)
          diagnosticRow("Validated global type", profile.globalType)
          diagnosticRow("Validated mode suffix", profile.modeSuffix)
          if preflight.reasons.isEmpty {
            diagnosticRow("Reasons", "None")
          } else {
            ForEach(Array(preflight.reasons.enumerated()), id: \.offset) { index, reason in
              diagnosticRow("Reason \(index + 1)", reason)
            }
          }
          ForEach(e.fans, id: \.id) { fan in
            diagnosticEntityCard(title: "Preflight fan \(fan.id)", subtitle: fan.modeKey) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 6)], spacing: 6
              ) {
                diagnosticMiniMetric("Mode", String(fan.mode))
                diagnosticMiniMetric("Actual", String(format: "%.1f RPM", fan.actualRPM))
                diagnosticMiniMetric("Target", String(format: "%.1f RPM", fan.targetRPM))
                diagnosticMiniMetric("Minimum", String(format: "%.1f RPM", fan.minimumRPM))
                diagnosticMiniMetric("Maximum", String(format: "%.1f RPM", fan.maximumRPM))
                diagnosticMiniMetric("Target type", fan.targetType)
                diagnosticMiniMetric("Mode key", fan.modeKey)
              }
            }
          }
        } else {
          telemetryUnavailable("Fan ownership preflight", p.fanOwnershipPreflight)
        }
      }
    }
  }

  private var batteryBackendTelemetry: some View {
    diagnosticSection("Battery internals", "battery.75percent") {
      if case .success(let b) = p.battery {
        diagnosticRow(
          "System charge", metric(b.systemChargePercent) { String(format: "%.3f%%", $0) })
        diagnosticRow(
          "UI state of charge", metric(b.stateOfChargePercent) { String(format: "%.3f%%", $0) })
        diagnosticRow(
          "Raw capacity SoC", metric(b.rawStateOfChargePercent) { String(format: "%.3f%%", $0) })
        diagnosticRow("Health", metric(b.healthPercent) { String(format: "%.3f%%", $0) })
        diagnosticRow("Design capacity", metric(b.designCapacityMAh) { "\($0) mAh" })
        diagnosticRow("Maximum capacity", metric(b.maximumCapacityMAh) { "\($0) mAh" })
        diagnosticRow("Current raw capacity", metric(b.currentCapacityMAh) { "\($0) mAh" })
        diagnosticRow("Cycles", metric(b.cycleCount, String.init))
        diagnosticRow("Temperature", metric(b.temperatureCelsius) { String(format: "%.3f°C", $0) })
        Divider().opacity(0.45)
        diagnosticRow("Power source", metric(b.powerSource) { $0.rawValue })
        diagnosticRow(
          "Battery power", metric(b.power) { String(format: "%+.4f W", $0.signedWatts) })
        diagnosticRow(
          "Power current source",
          metric(b.power) {
            $0.usesInstantaneousCurrent ? "Instantaneous current" : "Averaged current"
          })
        diagnosticRow("Voltage", metric(b.voltageVolts) { String(format: "%.4f V", $0) })
        diagnosticRow("Current", metric(b.currentAmps) { String(format: "%+.4f A", $0) })
        diagnosticRow("Adapter rating", metric(b.adapterWatts) { "\($0) W" })
        diagnosticRow(
          "Adapter voltage", metric(b.adapterVoltageVolts) { String(format: "%.4f V", $0) })
        diagnosticRow(
          "Charging current", metric(b.chargingCurrentAmps) { String(format: "%.4f A", $0) })
        diagnosticRow(
          "Charging voltage", metric(b.chargingVoltageVolts) { String(format: "%.4f V", $0) })
        diagnosticRow("Is charging", metric(b.isCharging, boolText))
        diagnosticRow("Is charged", metric(b.isCharged, boolText))
        diagnosticRow("Optimized charging", metric(b.optimizedChargingEngaged, boolText))
        diagnosticRow(
          "Not-charging raw", metric(b.notChargingReasonRaw) { String(format: "0x%llX", $0) })
        diagnosticRow(
          "Time remaining", metric(b.timeRemaining, TelemetryFormatting.batteryTimeRemaining))
        diagnosticRow("Manufacture date", metric(b.manufactureDate, fullDateText))
        diagnosticRow(
          "Cell balance", metric(b.cellBalanceMillivolts) { String(format: "%.3f mV", $0) })
        if case .success(let cells) = b.cellVoltagesVolts {
          ForEach(Array(cells.enumerated()), id: \.offset) { index, voltage in
            diagnosticRow("Cell \(index + 1)", String(format: "%.5f V", voltage))
          }
        } else {
          diagnosticRow(
            "Cell voltages",
            metric(b.cellVoltagesVolts) { $0.map(String.init(describing:)).joined(separator: ", ") }
          )
        }
      } else {
        telemetryUnavailable("Battery", p.battery)
      }
    }
  }

  private var energyBackendTelemetry: some View {
    VStack(spacing: 10) {
      diagnosticSection(
        "Energy history internals", "chart.bar.xaxis",
        subtitle: "Coverage, persisted buckets and on-battery attribution",
        summary: "\(model.appEnergy.buckets.count) buckets"
      ) {
        let energy = model.appEnergy
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)], spacing: 6
        ) {
          diagnosticMiniMetric("Buckets", String(energy.buckets.count))
          diagnosticMiniMetric("Coverage", TelemetryFormatting.duration(energy.coverageSeconds))
          diagnosticMiniMetric(
            "On-battery coverage", TelemetryFormatting.duration(energy.onBatteryCoverageSeconds))
          diagnosticMiniMetric("Tracked apps", String(energy.topAll.count))
          diagnosticMiniMetric("On-battery apps", String(energy.topOnBattery.count))
          diagnosticMiniMetric("Recent trends", String(energy.recentHourTrends.count))
          diagnosticMiniMetric(
            "Recent battery delta",
            energy.recentHourOnBatteryChargeDeltaPercent.map { String(format: "%+.3f%%", $0) }
              ?? "—")
        }
        if let bucket = energy.buckets.last {
          diagnosticEntityCard(
            title: "Latest bucket", subtitle: fullDateText(bucket.capturedAt),
            value: "\(bucket.entries.count) entries"
          ) {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 6)], spacing: 6
            ) {
              diagnosticMiniMetric("Captured", fullDateText(bucket.capturedAt))
              diagnosticMiniMetric("Duration", String(format: "%.3f s", bucket.durationSeconds))
              diagnosticMiniMetric("On battery", optionalBoolText(bucket.onBattery))
              diagnosticMiniMetric(
                "Battery", bucket.batteryPercent.map { String(format: "%.3f%%", $0) } ?? "—")
              diagnosticMiniMetric("Entries", String(bucket.entries.count))
            }
          }
        }
      }

      energyEntryList("All tracked apps", entries: model.appEnergy.topAll)
      energyEntryList("On-battery tracked apps", entries: model.appEnergy.topOnBattery)

      diagnosticSection(
        "Recent energy trends", "arrow.left.arrow.right",
        subtitle: "Current hour compared with the previous hour",
        summary: "\(model.appEnergy.recentHourTrends.count) apps"
      ) {
        if model.appEnergy.recentHourTrends.isEmpty {
          Text("No recent energy trends yet.").foregroundStyle(.secondary)
        } else {
          ForEach(model.appEnergy.recentHourTrends) { trend in
            diagnosticEntityCard(
              title: trend.displayName, subtitle: trend.appKey,
              value: trend.changePercent.map { String(format: "%+.1f%%", $0) } ?? "—"
            ) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 6)], spacing: 6
              ) {
                diagnosticMiniMetric("Recent", wattHoursText(trend.recentEnergyWattHours))
                diagnosticMiniMetric("Previous", wattHoursText(trend.previousEnergyWattHours))
                diagnosticMiniMetric("Change", wattHoursText(trend.changeWattHours))
                diagnosticMiniMetric(
                  "Change percent",
                  trend.changePercent.map { String(format: "%+.3f%%", $0) } ?? "—")
                diagnosticMiniMetric("App key", trend.appKey)
              }
            }
          }
        }
      }
    }
  }

  private var storageBackendTelemetry: some View {
    VStack(spacing: 10) {
      diagnosticSection(
        "Storage internals", "internaldrive",
        subtitle: "Device inventory, root volume, live throughput and session counters",
        summary: storageDiagnosticSummary
      ) {
        if case .success(let s) = p.storage {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)], spacing: 6
          ) {
            diagnosticMiniMetric("Primary device", s.primaryDeviceBSDName ?? "—")
            diagnosticMiniMetric("Devices", String(s.devices.count))
            diagnosticMiniMetric("External physical", String(s.externalPhysicalDevices.count))
            diagnosticMiniMetric(
              "SMART captured ticks", s.smartHealthCapturedTicks.map(String.init) ?? "—")
            diagnosticMiniMetric(
              "Monitoring read", metric(s.monitoringReadBytes, TelemetryFormatting.storageBytes))
            diagnosticMiniMetric(
              "Monitoring written",
              metric(s.monitoringWrittenBytes, TelemetryFormatting.storageBytes))
          }

          if case .success(let root) = s.rootVolume {
            diagnosticEntityCard(
              title: "Root volume", value: TelemetryFormatting.storageBytes(root.usedBytes)
            ) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 6)], spacing: 6
              ) {
                diagnosticMiniMetric("Total", TelemetryFormatting.storageBytes(root.totalBytes))
                diagnosticMiniMetric("Used", TelemetryFormatting.storageBytes(root.usedBytes))
                diagnosticMiniMetric("Free", TelemetryFormatting.storageBytes(root.freeBytes))
              }
            }
          } else {
            diagnosticRow("Root volume", metric(s.rootVolume) { _ in "Available" })
          }

          if case .success(let throughput) = s.throughput {
            diagnosticEntityCard(title: "Live storage throughput") {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 6)], spacing: 6
              ) {
                diagnosticMiniMetric(
                  "Read", TelemetryFormatting.bytesPerSecond(throughput.readBytesPerSecond))
                diagnosticMiniMetric(
                  "Write", TelemetryFormatting.bytesPerSecond(throughput.writeBytesPerSecond))
                diagnosticMiniMetric("Read IOPS", TelemetryFormatting.iops(throughput.readIOPS))
                diagnosticMiniMetric("Write IOPS", TelemetryFormatting.iops(throughput.writeIOPS))
              }
            }
          } else {
            diagnosticRow("Throughput", metric(s.throughput) { _ in "Available" })
          }
        } else {
          telemetryUnavailable("Storage", p.storage)
        }
      }

      if case .success(let s) = p.storage {
        diagnosticSection(
          "Storage devices", "externaldrive",
          subtitle: "Physical and virtual block devices discovered by IOKit",
          summary: "\(s.devices.count) devices"
        ) {
          ForEach(s.devices, id: \.registryID) { device in
            diagnosticEntityCard(
              title: device.model, subtitle: "\(device.bsdName) · registry \(device.registryID)",
              value: TelemetryFormatting.storageBytes(device.capacityBytes)
            ) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 235), spacing: 6)], spacing: 6
              ) {
                diagnosticMiniMetric("BSD name", device.bsdName)
                diagnosticMiniMetric("Registry ID", String(device.registryID))
                diagnosticMiniMetric(
                  "Capacity", TelemetryFormatting.storageBytes(device.capacityBytes))
                diagnosticMiniMetric("Internal", boolText(device.isInternal))
                diagnosticMiniMetric("Removable", boolText(device.isRemovable))
                diagnosticMiniMetric("Transport", device.transport)
                diagnosticMiniMetric("Controller", device.controllerClass)
                diagnosticMiniMetric("SMART", device.smartCapability.rawValue)
                if case .success(let counters) = device.counters {
                  diagnosticMiniMetric(
                    "Read since boot", TelemetryFormatting.storageBytes(counters.bytesRead))
                  diagnosticMiniMetric(
                    "Written since boot", TelemetryFormatting.storageBytes(counters.bytesWritten))
                  diagnosticMiniMetric(
                    "Read operations", TelemetryFormatting.count(counters.readOperations))
                  diagnosticMiniMetric(
                    "Write operations", TelemetryFormatting.count(counters.writeOperations))
                  diagnosticMiniMetric(
                    "Read errors", TelemetryFormatting.count(counters.readErrors))
                  diagnosticMiniMetric(
                    "Write errors", TelemetryFormatting.count(counters.writeErrors))
                } else {
                  diagnosticMiniMetric("Counters", metric(device.counters) { _ in "Available" })
                }
              }
            }
          }
        }

        diagnosticSection(
          "NVMe SMART / Lifetime", "waveform.path.ecg",
          subtitle: "Health, endurance and raw 128-bit NVMe counters"
        ) {
          if case .success(let smart) = s.smartHealth {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)], spacing: 6
            ) {
              diagnosticMiniMetric("Health", smart.state.rawValue)
              diagnosticMiniMetric(
                "Critical warning", String(format: "0x%02X", smart.criticalWarning))
              diagnosticMiniMetric(
                "Temperature", smart.temperatureCelsius.map { String(format: "%.3f°C", $0) } ?? "—")
              diagnosticMiniMetric("Available spare", "\(smart.availableSparePercent)%")
              diagnosticMiniMetric("Spare threshold", "\(smart.availableSpareThresholdPercent)%")
              diagnosticMiniMetric("Percentage used", "\(smart.percentageUsed)%")
              diagnosticMiniMetric("Life remaining", "\(smart.lifeRemainingPercent)%")
              diagnosticMiniMetric(
                "Lifetime read", TelemetryFormatting.decimalBytes(smart.lifetimeReadBytes))
              diagnosticMiniMetric(
                "Lifetime written", TelemetryFormatting.decimalBytes(smart.lifetimeWrittenBytes))
            }

            diagnosticEntityCard(
              title: "Raw NVMe counters",
              subtitle: "Exact values plus low/high 64-bit words for diagnostics"
            ) {
              nvmeCounterRows("Data units read", smart.dataUnitsRead)
              nvmeCounterRows("Data units written", smart.dataUnitsWritten)
              nvmeCounterRows("Host read commands", smart.hostReadCommands)
              nvmeCounterRows("Host write commands", smart.hostWriteCommands)
              nvmeCounterRows("Controller busy minutes", smart.controllerBusyMinutes)
              nvmeCounterRows("Power cycles", smart.powerCycles)
              nvmeCounterRows("Power-on hours", smart.powerOnHours)
              nvmeCounterRows("Unsafe shutdowns", smart.unsafeShutdowns)
              nvmeCounterRows("Media errors", smart.mediaErrors)
              nvmeCounterRows("Error log entries", smart.errorLogEntries)
            }
          } else {
            diagnosticRow("NVMe SMART", metric(s.smartHealth) { _ in "Available" })
          }
        }
      }

      diagnosticSection(
        "24-hour I/O audit", "clock.arrow.circlepath",
        subtitle: "Physical-device accounting compared with process-attributed I/O",
        summary: "\(model.ioAudit.records.count) records"
      ) {
        let audit = model.ioAudit
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)], spacing: 6
        ) {
          diagnosticMiniMetric("Records", String(audit.records.count))
          diagnosticMiniMetric("Duration", TelemetryFormatting.duration(audit.durationSeconds))
          diagnosticMiniMetric(
            "Device read", TelemetryFormatting.storageBytes(audit.observedDeviceReadBytes))
          diagnosticMiniMetric(
            "Device written", TelemetryFormatting.storageBytes(audit.observedDeviceWrittenBytes))
          diagnosticMiniMetric(
            "Coverage", TelemetryFormatting.duration(audit.observedCoverageSeconds))
          diagnosticMiniMetric(
            "Peak read", audit.peakReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
          )
          diagnosticMiniMetric(
            "Peak write",
            audit.peakWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
        }
        if let latest = audit.latest {
          diagnosticEntityCard(
            title: "Latest audit record", subtitle: fullDateText(latest.capturedAt)
          ) {
            ioAuditRecordRows(latest)
          }
        }
      }
    }
  }

  private var networkBackendTelemetry: some View {
    VStack(spacing: 12) {
      diagnosticSection("Network internals", "network") {
        if case .success(let n) = p.network {
          diagnosticRow("Primary interface", metric(n.primaryInterface) { $0 })
          diagnosticRow("IPv4", metric(n.ipv4Address) { $0 })
          diagnosticRow("IPv6", metric(n.ipv6Address) { $0 })
          diagnosticRow("Running", metric(n.isRunning, boolText))
          diagnosticRow("MTU", metric(n.mtu, String.init))
          diagnosticRow(
            "Link speed", metric(n.linkSpeedBitsPerSecond, TelemetryFormatting.bitsPerSecond))
          if case .success(let rate) = n.throughput {
            diagnosticRow(
              "Download", TelemetryFormatting.bytesPerSecond(rate.downloadBytesPerSecond))
            diagnosticRow("Upload", TelemetryFormatting.bytesPerSecond(rate.uploadBytesPerSecond))
            diagnosticRow("Receive packets/s", String(format: "%.3f", rate.receivePacketsPerSecond))
            diagnosticRow(
              "Transmit packets/s", String(format: "%.3f", rate.transmitPacketsPerSecond))
          } else {
            diagnosticRow("Throughput", metric(n.throughput) { _ in "Available" })
          }
          diagnosticRow("Receive errors", metric(n.receiveErrors) { String($0) })
          diagnosticRow("Transmit errors", metric(n.transmitErrors) { String($0) })
          diagnosticRow("Active interface count", String(n.activeInterfaceCount))
          diagnosticRow(
            "Active interfaces",
            n.activeInterfaces.isEmpty ? "—" : n.activeInterfaces.joined(separator: ", "))
          diagnosticRow("Gateway IPv4", metric(n.gatewayIPv4) { $0 })
          diagnosticRow(
            "DNS servers", n.dnsServers.isEmpty ? "—" : n.dnsServers.joined(separator: ", "))
          diagnosticRow(
            "Search domains",
            n.searchDomains.isEmpty ? "—" : n.searchDomains.joined(separator: ", "))
          diagnosticRow(
            "Session downloaded", metric(n.sessionDownloadedBytes, TelemetryFormatting.storageBytes)
          )
          diagnosticRow(
            "Session uploaded", metric(n.sessionUploadedBytes, TelemetryFormatting.storageBytes))
        } else {
          telemetryUnavailable("Network", p.network)
        }
      }

      diagnosticSection("Wi-Fi radio", "wifi") {
        if case .success(let w) = p.wifi {
          diagnosticRow("Interface", w.interfaceName)
          diagnosticRow("Radio power", boolText(w.powerOn))
          diagnosticRow("Service active", boolText(w.serviceActive))
          diagnosticRow("SSID", metric(w.ssid) { $0 })
          diagnosticRow("RSSI", metric(w.rssiDBm) { "\($0) dBm" })
          diagnosticRow("Noise", metric(w.noiseDBm) { "\($0) dBm" })
          diagnosticRow("Signal-to-noise", metric(w.signalToNoiseDB) { "\($0) dB" })
          diagnosticRow(
            "Transmit rate", metric(w.transmitRateMbps) { String(format: "%.3f Mb/s", $0) })
          diagnosticRow("Transmit power", metric(w.transmitPowerMilliwatts) { "\($0) mW" })
          diagnosticRow("Channel", metric(w.channelNumber, String.init))
          diagnosticRow("Band", metric(w.channelBand) { $0 })
          diagnosticRow("Channel width", metric(w.channelWidth) { $0 })
          diagnosticRow("PHY mode", metric(w.phyMode) { $0 })
          diagnosticRow("Security", metric(w.security) { $0 })
        } else {
          telemetryUnavailable("Wi-Fi", p.wifi)
        }
      }
    }
  }

  private var processBackendTelemetry: some View {
    VStack(spacing: 10) {
      diagnosticSection(
        "Process sampler", "list.bullet.rectangle",
        subtitle: "Sampler coverage, I/O accounting and bounded rankings",
        summary: processDiagnosticSummary
      ) {
        if case .success(let processes) = p.processes {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 6)], spacing: 6
          ) {
            diagnosticMiniMetric("Accessible processes", String(processes.accessibleProcessCount))
            diagnosticMiniMetric(
              "Disk read",
              TelemetryFormatting.bytesPerSecond(processes.accountedDiskReadBytesPerSecond))
            diagnosticMiniMetric(
              "Disk write",
              TelemetryFormatting.bytesPerSecond(processes.accountedDiskWriteBytesPerSecond))
            diagnosticMiniMetric(
              "Session read", TelemetryFormatting.storageBytes(processes.sessionAccountedReadBytes))
            diagnosticMiniMetric(
              "Session write",
              TelemetryFormatting.storageBytes(processes.sessionAccountedWriteBytes))
            diagnosticMiniMetric("Top CPU", String(processes.topByCPU.count))
            diagnosticMiniMetric("Top energy", String(processes.topByEnergy.count))
            diagnosticMiniMetric("Energy leaders", String(processes.energyHistoryLeaders.count))
            diagnosticMiniMetric("Top memory", String(processes.topByMemory.count))
            diagnosticMiniMetric("Disk readers", String(processes.topByDiskRead.count))
            diagnosticMiniMetric("Disk writers", String(processes.topByDiskWrite.count))
            diagnosticMiniMetric("Session readers", String(processes.topSessionReaders.count))
            diagnosticMiniMetric("Session writers", String(processes.topSessionWriters.count))
          }

          if let helios = processes.heliosActivity {
            processActivityRows(helios)
          } else {
            diagnosticRow("Helios process", "Unavailable")
          }
        } else {
          telemetryUnavailable("Processes", p.processes)
        }
      }

      if case .success(let processes) = p.processes {
        processList("Top by CPU", items: processes.topByCPU)
        processList("Top by Energy", items: processes.topByEnergy)
        processList("Energy History Leaders", items: processes.energyHistoryLeaders)
        processList("Top by Memory", items: processes.topByMemory)
        processList("Top Disk Readers", items: processes.topByDiskRead)
        processList("Top Disk Writers", items: processes.topByDiskWrite)
        processList("Top Session Readers", items: processes.topSessionReaders)
        processList("Top Session Writers", items: processes.topSessionWriters)
      }
    }
  }

  private var systemBackendTelemetry: some View {
    VStack(spacing: 12) {
      diagnosticSection("System internals", "macbook") {
        if case .success(let s) = p.system {
          diagnosticRow("Model identifier", metric(s.modelIdentifier) { $0 })
          diagnosticRow("Chip name", metric(s.chipName) { $0 })
          diagnosticRow("OS version", s.osVersion)
          diagnosticRow("Uptime", TelemetryFormatting.duration(s.uptimeSeconds))
          diagnosticRow("Logical processors", String(s.logicalProcessorCount))
          diagnosticRow("Physical memory", TelemetryFormatting.storageBytes(s.physicalMemoryBytes))
          diagnosticRow("Load average 1m", metric(s.loadAverage1) { String(format: "%.6f", $0) })
          diagnosticRow("Load average 5m", metric(s.loadAverage5) { String(format: "%.6f", $0) })
          diagnosticRow("Load average 15m", metric(s.loadAverage15) { String(format: "%.6f", $0) })
          diagnosticRow("Thermal state", s.thermalState.rawValue)
          diagnosticRow("Low Power Mode", boolText(s.lowPowerModeEnabled))
        } else {
          telemetryUnavailable("System", p.system)
        }
      }

      diagnosticSection("Power assertions", "moon.zzz") {
        if case .success(let values) = p.powerAssertions {
          diagnosticRow("Assertions", String(values.assertions.count))
          diagnosticRow("Display blockers", String(values.displaySleepBlockers.count))
          diagnosticRow("System blockers", String(values.systemSleepBlockers.count))
          ForEach(values.assertions) { assertion in
            Divider().opacity(0.35)
            diagnosticRow("PID", String(assertion.pid))
            diagnosticRow("Process", assertion.processName)
            diagnosticRow("Type", assertion.assertionType)
            diagnosticRow("Reason", assertion.reason ?? "—")
            diagnosticRow("Prevents display sleep", boolText(assertion.preventsDisplaySleep))
            diagnosticRow("Prevents system sleep", boolText(assertion.preventsSystemSleep))
          }
        } else {
          telemetryUnavailable("Power assertions", p.powerAssertions)
        }
      }

      diagnosticSection("Clock metadata", "clock") {
        if case .success(let clock) = p.clock {
          diagnosticRow("Local time zone", clock.localTimeZoneIdentifier)
          diagnosticRow("ISO week", String(clock.isoWeekOfYear))
          diagnosticRow("Day of year", String(clock.dayOfYear))
          diagnosticRow("Tracked zones", String(clock.zones.count))
          ForEach(clock.zones) { zone in
            Divider().opacity(0.35)
            diagnosticRow("Zone identifier", zone.identifier)
            diagnosticRow("Abbreviation", zone.abbreviation)
            diagnosticRow("UTC offset", "\(zone.offsetSeconds) s")
            diagnosticRow("Local date", fullDateText(zone.localDate))
          }
        } else {
          telemetryUnavailable("Clock", p.clock)
        }
      }
    }
  }

  private var devicesBackendTelemetry: some View {
    VStack(spacing: 12) {
      diagnosticSection("Display inventory", "display") {
        if case .success(let values) = p.displays {
          diagnosticRow("Displays", String(values.displays.count))
          ForEach(values.displays) { d in
            Divider().opacity(0.35)
            diagnosticRow("Display ID", String(d.displayID))
            diagnosticRow("Built in", boolText(d.builtIn))
            diagnosticRow("Active", boolText(d.active))
            diagnosticRow("Asleep", boolText(d.asleep))
            diagnosticRow("Pixels", "\(d.pixelWidth)×\(d.pixelHeight)")
            diagnosticRow("Logical size", "\(d.logicalWidth)×\(d.logicalHeight)")
            diagnosticRow(
              "Refresh rate", d.refreshRateHz.map { String(format: "%.3f Hz", $0) } ?? "—")
            diagnosticRow("Rotation", String(format: "%.3f°", d.rotationDegrees))
            diagnosticRow("Physical width", String(format: "%.3f mm", d.physicalWidthMM))
            diagnosticRow("Physical height", String(format: "%.3f mm", d.physicalHeightMM))
          }
        } else {
          telemetryUnavailable("Displays", p.displays)
        }
      }

      diagnosticSection("Mounted volumes", "externaldrive") {
        if case .success(let values) = p.volumes {
          diagnosticRow("Volumes", String(values.volumes.count))
          ForEach(values.volumes) { volume in
            Divider().opacity(0.35)
            diagnosticRow("Name", volume.name)
            diagnosticRow("Path", volume.path)
            diagnosticRow("Total", volume.totalBytes.map(TelemetryFormatting.storageBytes) ?? "—")
            diagnosticRow(
              "Available", volume.availableBytes.map(TelemetryFormatting.storageBytes) ?? "—")
            diagnosticRow("Internal", optionalBoolText(volume.isInternal))
            diagnosticRow("Removable", optionalBoolText(volume.isRemovable))
            diagnosticRow("Local", optionalBoolText(volume.isLocal))
            diagnosticRow("Read only", optionalBoolText(volume.isReadOnly))
            diagnosticRow("Format", volume.localizedFormatDescription ?? "—")
            diagnosticRow("UUID", volume.uuid ?? "—")
          }
        } else {
          telemetryUnavailable("Mounted volumes", p.volumes)
        }
      }

      diagnosticSection("USB inventory", "cable.connector") {
        if case .success(let values) = p.usb {
          diagnosticRow("USB devices", String(values.devices.count))
          ForEach(values.devices) { device in
            Divider().opacity(0.35)
            diagnosticRow("Registry ID", String(device.registryID))
            diagnosticRow("Product", device.product)
            diagnosticRow("Vendor", device.vendor ?? "—")
            diagnosticRow("Vendor ID", device.vendorID.map(String.init) ?? "—")
            diagnosticRow("Product ID", device.productID.map(String.init) ?? "—")
            diagnosticRow(
              "Location ID", device.locationID.map { String(format: "0x%llX", $0) } ?? "—")
            diagnosticRow("Speed raw", device.speed.map(String.init) ?? "—")
          }
        } else {
          telemetryUnavailable("USB", p.usb)
        }
      }

      diagnosticSection("Bluetooth inventory", "dot.radiowaves.left.and.right") {
        if case .success(let values) = p.bluetooth {
          diagnosticRow("Devices", String(values.devices.count))
          ForEach(values.devices) { device in
            Divider().opacity(0.35)
            diagnosticRow("Address", device.address)
            diagnosticRow("Name", device.name)
            diagnosticRow("Connected", boolText(device.connected))
            diagnosticRow("Paired", boolText(device.paired))
            diagnosticRow("RSSI", device.rssiDBm.map { "\($0) dBm" } ?? "—")
            diagnosticRow("Battery main", percentOptional(device.battery.mainPercent))
            diagnosticRow("Battery left", percentOptional(device.battery.leftPercent))
            diagnosticRow("Battery right", percentOptional(device.battery.rightPercent))
            diagnosticRow("Battery case", percentOptional(device.battery.casePercent))
          }
        } else {
          telemetryUnavailable("Bluetooth", p.bluetooth)
        }
      }

      diagnosticSection("Audio inventory", "speaker.wave.2") {
        if case .success(let values) = p.audio {
          diagnosticRow("Devices", String(values.devices.count))
          diagnosticRow("Default input ID", values.defaultInputDeviceID.map(String.init) ?? "—")
          diagnosticRow("Default output ID", values.defaultOutputDeviceID.map(String.init) ?? "—")
          diagnosticRow(
            "Default system output ID", values.defaultSystemOutputDeviceID.map(String.init) ?? "—")
          diagnosticRow(
            "Input telemetry privacy-suppressed",
            boolText(values.inputTelemetrySuppressedForPrivacy))
          ForEach(values.devices) { device in
            Divider().opacity(0.35)
            diagnosticRow("Object ID", String(device.objectID))
            diagnosticRow("Name", device.name)
            diagnosticRow("UID", device.uid ?? "—")
            diagnosticRow("Has input", boolText(device.hasInput))
            diagnosticRow("Has output", boolText(device.hasOutput))
            diagnosticRow("Input channels", String(device.inputChannels))
            diagnosticRow("Output channels", String(device.outputChannels))
            diagnosticRow(
              "Sample rate", device.nominalSampleRateHz.map { String(format: "%.3f Hz", $0) } ?? "—"
            )
            diagnosticRow("Transport type raw", device.transportType.map(String.init) ?? "—")
          }
        } else {
          telemetryUnavailable("Audio", p.audio)
        }
      }
    }
  }

  private var historyBackendTelemetry: some View {
    VStack(spacing: 12) {
      diagnosticSection("Live history state", "waveform.path.ecg") {
        diagnosticRow("Points", String(model.history.points.count))
        diagnosticRow("Duration", TelemetryFormatting.duration(model.history.durationSeconds))
        diagnosticRow(
          "Session energy", String(format: "%.6f Wh", model.history.sessionEnergyWattHours))
        diagnosticRow(
          "Measured power coverage",
          TelemetryFormatting.duration(model.history.measuredPowerCoverageSeconds))
        if let point = model.history.points.last {
          Divider().opacity(0.45)
          diagnosticRow("Latest captured", fullDateText(point.capturedAt))
          historyPointRows(point)
        }
      }

      diagnosticSection("Persistent history state", "clock.arrow.circlepath") {
        let h = model.persistentHistory
        diagnosticRow("Points", String(h.points.count))
        diagnosticRow("Duration", TelemetryFormatting.duration(h.durationSeconds))
        diagnosticRow("System energy", String(format: "%.6f Wh", h.energyWattHours))
        diagnosticRow(
          "Power coverage", TelemetryFormatting.duration(h.measuredPowerCoverageSeconds))
        diagnosticRow("Battery energy", String(format: "%+.6f Wh", h.batteryEnergyWattHours))
        diagnosticRow(
          "Battery power coverage",
          TelemetryFormatting.duration(h.measuredBatteryPowerCoverageSeconds))
        diagnosticRow(
          "Battery delta", h.batteryChargeDeltaPercent.map { String(format: "%+.3f%%", $0) } ?? "—")
        diagnosticRow(
          "Battery min", h.batteryMinimumPercent.map { String(format: "%.3f%%", $0) } ?? "—")
        diagnosticRow(
          "Battery max", h.batteryMaximumPercent.map { String(format: "%.3f%%", $0) } ?? "—")
        diagnosticRow(
          "Battery min temperature",
          h.batteryMinimumTemperatureCelsius.map { String(format: "%.3f°C", $0) } ?? "—")
        diagnosticRow(
          "Battery max temperature",
          h.batteryMaximumTemperatureCelsius.map { String(format: "%.3f°C", $0) } ?? "—")
        diagnosticRow(
          "Battery min health",
          h.batteryMinimumHealthPercent.map { String(format: "%.3f%%", $0) } ?? "—")
        diagnosticRow(
          "Battery max health",
          h.batteryMaximumHealthPercent.map { String(format: "%.3f%%", $0) } ?? "—")
        diagnosticRow("Latest cycles", h.latestBatteryCycleCount.map(String.init) ?? "—")
        diagnosticRow(
          "Storage lifetime read delta",
          h.storageLifetimeReadDeltaBytes.map(TelemetryFormatting.decimalBytes) ?? "—")
        diagnosticRow(
          "Storage lifetime written delta",
          h.storageLifetimeWrittenDeltaBytes.map(TelemetryFormatting.decimalBytes) ?? "—")
        diagnosticRow(
          "Helios avg CPU", h.heliosAverageCPUPercent.map { String(format: "%.4f%%", $0) } ?? "—")
        diagnosticRow(
          "Helios peak CPU", h.heliosPeakCPUPercent.map { String(format: "%.4f%%", $0) } ?? "—")
        diagnosticRow(
          "Helios avg power", h.heliosAveragePowerWatts.map { String(format: "%.6f W", $0) } ?? "—")
        diagnosticRow(
          "Helios peak power", h.heliosPeakPowerWatts.map { String(format: "%.6f W", $0) } ?? "—")
        diagnosticRow(
          "Helios peak memory", h.heliosPeakMemoryBytes.map(TelemetryFormatting.storageBytes) ?? "—"
        )
        diagnosticRow(
          "Helios avg wakeups",
          h.heliosAverageWakeupsPerSecond.map { String(format: "%.4f/s", $0) } ?? "—")
        if let point = h.points.last {
          Divider().opacity(0.45)
          diagnosticRow("Latest persistent point", fullDateText(point.capturedAt))
          persistedPointRows(point)
        }
      }
    }
  }

  private var healthBackendTelemetry: some View {
    VStack(spacing: 12) {
      diagnosticSection("Health state", "heart.text.square") {
        diagnosticRow("Notification authorization", model.healthCenter.authorization.rawValue)
        diagnosticRow("Active issues", String(model.healthCenter.issues.count))
        diagnosticRow("Event records", String(model.healthCenter.events.count))
        ForEach(model.healthCenter.issues) { issue in
          Divider().opacity(0.35)
          diagnosticRow("Issue ID", issue.id)
          diagnosticRow("Severity", String(describing: issue.severity))
          diagnosticRow("Title", issue.title)
          diagnosticRow("Detail", issue.detail)
        }
      }
      diagnosticSection("Health event log", "list.bullet.clipboard") {
        if model.healthCenter.events.isEmpty {
          Text("No health events recorded yet.").foregroundStyle(.secondary)
        } else {
          ForEach(model.healthCenter.events.reversed()) { event in
            diagnosticRow("Captured", fullDateText(event.capturedAt))
            diagnosticRow("Change", String(describing: event.change))
            diagnosticRow("Issue ID", event.issueID)
            diagnosticRow("Severity", String(event.severity))
            diagnosticRow("Title", event.title)
            diagnosticRow("Detail", event.detail)
            Divider().opacity(0.35)
          }
        }
      }
    }
  }

  private var capabilityBackendTelemetry: some View {
    diagnosticSection("Hardware capability report", "checklist") {
      let report = CapabilityEvaluator.evaluate(model.snapshot)
      diagnosticRow("Available", "\(report.availableCount)/\(report.totalCount)")
      ForEach(report.items) { item in
        Divider().opacity(0.35)
        diagnosticRow("Capability ID", item.id)
        diagnosticRow("Title", item.title)
        diagnosticRow("State", item.state.rawValue)
        diagnosticRow("Detail", item.detail)
      }
    }
  }

  private var sampleMetadataTelemetry: some View {
    diagnosticSection("Sampler metadata", "timer") {
      sampleMetadataRow("CPU", model.snapshot.cpu.capturedAt, model.snapshot.cpu.capturedTicks)
      sampleMetadataRow(
        "Memory", model.snapshot.memory.capturedAt, model.snapshot.memory.capturedTicks)
      sampleMetadataRow("GPU", model.snapshot.gpu.capturedAt, model.snapshot.gpu.capturedTicks)
      sampleMetadataRow(
        "System power", model.snapshot.systemPower.capturedAt,
        model.snapshot.systemPower.capturedTicks)
      sampleMetadataRow(
        "System", model.snapshot.system.capturedAt, model.snapshot.system.capturedTicks)
      sampleMetadataRow(
        "Network", model.snapshot.network.capturedAt, model.snapshot.network.capturedTicks)
      sampleMetadataRow("Wi-Fi", model.snapshot.wifi.capturedAt, model.snapshot.wifi.capturedTicks)
      sampleMetadataRow(
        "Processes", model.snapshot.processes.capturedAt, model.snapshot.processes.capturedTicks)
      sampleMetadataRow(
        "Battery", model.snapshot.battery.capturedAt, model.snapshot.battery.capturedTicks)
      sampleMetadataRow(
        "Storage", model.snapshot.storage.capturedAt, model.snapshot.storage.capturedTicks)
      sampleMetadataRow(
        "Thermals", model.snapshot.thermals.capturedAt, model.snapshot.thermals.capturedTicks)
      sampleMetadataRow("Fans", model.snapshot.fans.capturedAt, model.snapshot.fans.capturedTicks)
      sampleMetadataRow(
        "Fan preflight", model.snapshot.fanOwnershipPreflight.capturedAt,
        model.snapshot.fanOwnershipPreflight.capturedTicks)
      sampleMetadataRow(
        "Displays", model.snapshot.displays.capturedAt, model.snapshot.displays.capturedTicks)
      sampleMetadataRow(
        "Volumes", model.snapshot.volumes.capturedAt, model.snapshot.volumes.capturedTicks)
      sampleMetadataRow("USB", model.snapshot.usb.capturedAt, model.snapshot.usb.capturedTicks)
      sampleMetadataRow(
        "Bluetooth", model.snapshot.bluetooth.capturedAt, model.snapshot.bluetooth.capturedTicks)
      sampleMetadataRow(
        "Audio", model.snapshot.audio.capturedAt, model.snapshot.audio.capturedTicks)
      sampleMetadataRow(
        "Power assertions", model.snapshot.powerAssertions.capturedAt,
        model.snapshot.powerAssertions.capturedTicks)
      sampleMetadataRow(
        "Clock", model.snapshot.clock.capturedAt, model.snapshot.clock.capturedTicks)
    }
  }

  private var rawSMCNumericTelemetry: some View {
    diagnosticSection("Raw SMC numeric inventory", "waveform.path.ecg") {
      Text(
        "This uses Helios' existing read-only SMCNumericProvider only when requested. Values remain unitless unless a dedicated provider has validated their meaning; unknown keys never enter cooling policy."
      )
      .font(.system(size: 9.5)).foregroundStyle(.secondary)

      HStack {
        Button(smcNumericLoading ? "Reading SMC…" : "Load / Refresh Raw SMC") {
          loadSMCNumericInventory()
        }
        .disabled(smcNumericLoading)
        .controlSize(.small)
        if smcNumericLoading { ProgressView().controlSize(.small) }
        Spacer()
      }

      if let result = smcNumericResult {
        switch result {
        case .success(let value):
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 6)], spacing: 6
          ) {
            diagnosticMiniMetric("Numeric channels", String(value.readings.count))
            diagnosticMiniMetric("Failures", String(value.failures.count))
            diagnosticMiniMetric("Truncated", boolText(value.truncated))
          }

          if !value.readings.isEmpty {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: 6)], spacing: 6
            ) {
              ForEach(value.readings) { reading in
                diagnosticMiniMetric(
                  "\(reading.key) · \(reading.type)", String(format: "%.9g", reading.value))
              }
            }
          }

          if !value.failures.isEmpty {
            diagnosticEntityCard(
              title: "Read failures", subtitle: "Raw numeric channels that could not be decoded",
              value: "\(value.failures.count)"
            ) {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 6)], spacing: 6
              ) {
                ForEach(value.failures.keys.sorted(), id: \.self) { key in
                  diagnosticMiniMetric(
                    key, value.failures[key]?.localizedDescription ?? "Unknown")
                }
              }
            }
          }
        case .failure(let error):
          Text("Raw SMC inventory unavailable — \(error.localizedDescription)")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func loadSMCNumericInventory() {
    guard !smcNumericLoading else { return }
    smcNumericLoading = true
    Task {
      let sample = await SMCNumericProvider().sample(maximumReadings: 512)
      await MainActor.run {
        smcNumericResult = sample.result
        smcNumericLoading = false
      }
    }
  }

  private func energyEntryList(_ title: String, entries: [AppEnergyEntry]) -> some View {
    diagnosticSection(
      title, "bolt.horizontal",
      subtitle: "Grouped by display name; raw app identities remain visible",
      summary: "\(entries.count) entries"
    ) {
      let grouped = Dictionary(grouping: entries, by: \.displayName)
      let orderedNames = grouped.keys.sorted { lhs, rhs in
        let left = grouped[lhs, default: []].reduce(0) { $0 + $1.energyWattHours }
        let right = grouped[rhs, default: []].reduce(0) { $0 + $1.energyWattHours }
        return left == right
          ? lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending : left > right
      }
      if entries.isEmpty {
        Text("No entries yet.").foregroundStyle(.secondary)
      } else {
        ForEach(orderedNames, id: \.self) { displayName in
          let identities = grouped[displayName] ?? []
          let totalEnergy = identities.reduce(0) { $0 + $1.energyWattHours }
          diagnosticEntityCard(
            title: displayName,
            subtitle: identities.count == 1
              ? identities.first?.appKey : "\(identities.count) retained identities",
            value: wattHoursText(totalEnergy)
          ) {
            ForEach(identities) { entry in
              VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  Text(entry.appKey)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                  Spacer(minLength: 8)
                  Text(wattHoursText(entry.energyWattHours))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                LazyVGrid(
                  columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 6)], spacing: 6
                ) {
                  diagnosticMiniMetric("Display name", entry.displayName)
                  diagnosticMiniMetric(
                    "CPU core-seconds", String(format: "%.6f", entry.cpuCoreSeconds))
                  diagnosticMiniMetric("Wakeups", String(format: "%.3f", entry.wakeups))
                  diagnosticMiniMetric(
                    "Peak memory", TelemetryFormatting.storageBytes(entry.peakMemoryBytes))
                  diagnosticMiniMetric("App key", entry.appKey)
                  diagnosticMiniMetric("Energy", wattHoursText(entry.energyWattHours))
                }
              }
              .padding(8)
              .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.42),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
          }
        }
      }
    }
  }

  private func processList(_ title: String, items: [ProcessActivity]) -> some View {
    diagnosticSection(
      title, "list.bullet.rectangle", subtitle: "Bounded ranking from the process sampler",
      summary: "\(items.count) entries"
    ) {
      if items.isEmpty {
        Text("No entries in this bounded list.").foregroundStyle(.secondary)
      } else {
        ForEach(items) { process in
          processActivityRows(process)
        }
      }
    }
  }

  @ViewBuilder
  private func processActivityRows(_ process: ProcessActivity) -> some View {
    diagnosticEntityCard(
      title: process.name,
      subtitle: process.executablePath ?? "PID \(process.pid)",
      value: "PID \(process.pid)"
    ) {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 6)], spacing: 6
      ) {
        diagnosticMiniMetric(
          "Physical memory", TelemetryFormatting.storageBytes(process.physicalFootprintBytes))
        diagnosticMiniMetric(
          "Neural memory", TelemetryFormatting.storageBytes(process.neuralFootprintBytes))
        diagnosticMiniMetric(
          "CPU (1 core = 100%)",
          process.cpuPercent.map { String(format: "%.4f%%", $0) } ?? "—")
        diagnosticMiniMetric(
          "Power", process.powerWatts.map { String(format: "%.6f W", $0) } ?? "—")
        diagnosticMiniMetric(
          "P-core power",
          process.performanceCorePowerWatts.map { String(format: "%.6f W", $0) } ?? "—")
        diagnosticMiniMetric(
          "Disk read",
          process.diskReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
        diagnosticMiniMetric(
          "Disk write",
          process.diskWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
        diagnosticMiniMetric(
          "Wakeups", process.wakeupsPerSecond.map { String(format: "%.4f/s", $0) } ?? "—")
        diagnosticMiniMetric(
          "Instructions",
          process.instructionsPerSecond.map { String(format: "%.3f/s", $0) } ?? "—")
        diagnosticMiniMetric(
          "Cycles", process.cyclesPerSecond.map { String(format: "%.3f/s", $0) } ?? "—")
        diagnosticMiniMetric(
          "Instructions / cycle",
          process.instructionsPerCycle.map { String(format: "%.6f", $0) } ?? "—")
        diagnosticMiniMetric(
          "Session read", TelemetryFormatting.storageBytes(process.sessionDiskReadBytes))
        diagnosticMiniMetric(
          "Session write", TelemetryFormatting.storageBytes(process.sessionDiskWriteBytes))
        diagnosticMiniMetric("Executable", process.executablePath ?? "—")
      }
    }
  }

  @ViewBuilder
  private func nvmeCounterRows(_ title: String, _ counter: NVMeCounter128) -> some View {
    diagnosticRow(title, nvmeCounterText(counter))
    diagnosticRow("\(title) low 64", String(counter.low))
    diagnosticRow("\(title) high 64", String(counter.high))
  }

  @ViewBuilder
  private func ioAuditRecordRows(_ record: IOActivityRecord) -> some View {
    diagnosticRow("Captured", fullDateText(record.capturedAt))
    diagnosticRow("Device BSD", record.deviceBSDName ?? "—")
    diagnosticRow(
      "Device read since boot",
      record.deviceReadSinceBootBytes.map(TelemetryFormatting.storageBytes) ?? "—")
    diagnosticRow(
      "Device written since boot",
      record.deviceWrittenSinceBootBytes.map(TelemetryFormatting.storageBytes) ?? "—")
    diagnosticRow(
      "Device read rate",
      record.deviceReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Device write rate",
      record.deviceWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Process-accounted read",
      record.processAccountedReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Process-accounted write",
      record.processAccountedWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow("Top reader", record.topReaderName ?? "—")
    diagnosticRow("Top reader PID", record.topReaderPID.map(String.init) ?? "—")
    diagnosticRow(
      "Top reader rate",
      record.topReaderBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow("Top writer", record.topWriterName ?? "—")
    diagnosticRow("Top writer PID", record.topWriterPID.map(String.init) ?? "—")
    diagnosticRow(
      "Top writer rate",
      record.topWriterBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Helios read rate",
      record.heliosReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Helios write rate",
      record.heliosWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
  }

  @ViewBuilder
  private func historyPointRows(_ point: TelemetryHistoryPoint) -> some View {
    diagnosticRow("CPU", point.cpuPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow("Memory", point.memoryPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow("GPU", point.gpuPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow("Max SoC", point.maxSoCCelsius.map { String(format: "%.3f°C", $0) } ?? "—")
    diagnosticRow(
      "System power", point.systemPowerWatts.map { String(format: "%.6f W", $0) } ?? "—")
    diagnosticRow("Battery", point.batteryPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow(
      "Battery power", point.batteryPowerWatts.map { String(format: "%+.6f W", $0) } ?? "—")
    diagnosticRow("Fan", point.fanRPM.map { String(format: "%.3f RPM", $0) } ?? "—")
    diagnosticRow(
      "Network down",
      point.networkDownloadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Network up", point.networkUploadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
    )
    diagnosticRow(
      "Storage read", point.storageReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
    )
    diagnosticRow(
      "Storage write",
      point.storageWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
  }

  @ViewBuilder
  private func persistedPointRows(_ point: PersistedTelemetryPoint) -> some View {
    diagnosticRow("CPU", point.cpuPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow("Memory", point.memoryPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow("GPU", point.gpuPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow("Max SoC", point.maxSoCCelsius.map { String(format: "%.3f°C", $0) } ?? "—")
    diagnosticRow(
      "System power", point.systemPowerWatts.map { String(format: "%.6f W", $0) } ?? "—")
    diagnosticRow(
      "Battery percent", point.batteryPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow(
      "Battery health", point.batteryHealthPercent.map { String(format: "%.3f%%", $0) } ?? "—")
    diagnosticRow(
      "Battery power", point.batteryPowerWatts.map { String(format: "%+.6f W", $0) } ?? "—")
    diagnosticRow("Battery on AC", optionalBoolText(point.batteryOnAC))
    diagnosticRow(
      "Battery temperature",
      point.batteryTemperatureCelsius.map { String(format: "%.3f°C", $0) } ?? "—")
    diagnosticRow("Battery cycles", point.batteryCycleCount.map(String.init) ?? "—")
    diagnosticRow(
      "SSD temperature", point.storageTemperatureCelsius.map { String(format: "%.3f°C", $0) } ?? "—"
    )
    diagnosticRow("Storage device", point.storageDeviceBSDName ?? "—")
    diagnosticRow(
      "Storage lifetime read",
      point.storageLifetimeReadBytes.map(TelemetryFormatting.decimalBytes) ?? "—")
    diagnosticRow(
      "Storage lifetime written",
      point.storageLifetimeWrittenBytes.map(TelemetryFormatting.decimalBytes) ?? "—")
    diagnosticRow(
      "Storage read rate",
      point.storageReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Storage write rate",
      point.storageWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Process read rate",
      point.processAccountedReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Process write rate",
      point.processAccountedWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow("Helios CPU", point.heliosCPUPercent.map { String(format: "%.4f%%", $0) } ?? "—")
    diagnosticRow(
      "Helios power", point.heliosPowerWatts.map { String(format: "%.6f W", $0) } ?? "—")
    diagnosticRow(
      "Helios memory", point.heliosMemoryBytes.map(TelemetryFormatting.storageBytes) ?? "—")
    diagnosticRow(
      "Helios wakeups", point.heliosWakeupsPerSecond.map { String(format: "%.4f/s", $0) } ?? "—")
    diagnosticRow("Fan RPM", point.fanRPM.map { String(format: "%.3f RPM", $0) } ?? "—")
    diagnosticRow(
      "Network down",
      point.networkDownloadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")
    diagnosticRow(
      "Network up", point.networkUploadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
    )
  }

  private func sampleMetadataRow(_ name: String, _ date: Date, _ ticks: UInt64) -> some View {
    VStack(spacing: 2) {
      diagnosticRow("\(name) captured", fullDateText(date))
      diagnosticRow("\(name) host ticks", String(ticks))
    }
  }

  private func telemetryUnavailable<Value>(_ title: String, _ result: MetricResult<Value>)
    -> some View
  {
    Text(TelemetryFormatting.text(result) { _ in title })
      .font(.system(size: 10)).foregroundStyle(.secondary)
  }

  private func boolText(_ value: Bool) -> String { value ? "Yes" : "No" }

  private func optionalBoolText(_ value: Bool?) -> String {
    value.map(boolText) ?? "—"
  }

  private func percentOptional(_ value: Int?) -> String {
    value.map { "\($0)%" } ?? "—"
  }

  private func fullDateText(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .standard)
  }

  private func wattHoursText(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return abs(value) < 1
      ? String(format: "%.6f mWh", value * 1_000) : String(format: "%.6f Wh", value)
  }

  private func nvmeCounterText(_ value: NVMeCounter128) -> String {
    if let exact = value.uint64Value { return TelemetryFormatting.count(exact) }
    return String(format: "%.6e", value.approximateValue)
  }

  private func thermalDisclosureLabel(_ title: String, count: Int) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(String(count))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }
    .font(.system(size: 10.5, weight: .medium))
  }

  private func thermalDisplayRow(_ item: ThermalDisplayReading) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(item.info.title)
          .lineLimit(1)
        Text(item.reading.key)
          .font(.system(size: 8.5, design: .monospaced))
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Text(String(format: "%.1f°C", item.reading.celsius))
        .monospacedDigit()
    }
    .font(.system(size: 10.5))
    .help(item.info.detail)
  }

  private var batteryFlowDetail: String {
    guard case .success(let battery) = p.battery, case .success(let source) = battery.powerSource
    else {
      return "Read-only"
    }
    return source == .powerAdapter ? "Power adapter" : "Discharging"
  }

  private func batteryHero(
    _ title: String, _ value: String, detail: String, tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 21, weight: .semibold).monospacedDigit())
        .foregroundStyle(tint)
      Text(detail).font(.system(size: 8.5)).foregroundStyle(.tertiary).lineLimit(1)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.45),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }

  private func mergedSeries(
    _ live: KeyPath<TelemetryHistoryPoint, Double?>,
    _ persisted: KeyPath<PersistedTelemetryPoint, Double?>
  ) -> [HeliosChartSample] {
    HeliosChartSeries.merged(
      range: activeGraphRange,
      live: model.history.points,
      persistent: model.persistentHistory.points,
      liveValue: { $0[keyPath: live] },
      persistentValue: { $0[keyPath: persisted] })
  }

  private func timeChart(
    _ samples: [HeliosChartSample], fixedRange: ClosedRange<Double>?, tint: Color,
    valueStyle: HeliosChartValueStyle = .plain, label: String = "Value"
  ) -> some View {
    HeliosTimeSeriesChart(
      samples: samples,
      range: activeGraphRange,
      fixedRange: fixedRange,
      tint: tint,
      lineStyle: preferences.graphLineStyle,
      animateUpdates: preferences.animateGraphUpdates,
      inspectorEnabled: true,
      valueStyle: valueStyle,
      seriesLabel: label)
  }

  private func trendCardSeries(
    _ title: String, samples: [HeliosChartSample], current: Double?,
    fixedRange: ClosedRange<Double>?, tint: Color = .secondary,
    valueStyle: HeliosChartValueStyle = .plain,
    format: @escaping (Double) -> String
  ) -> some View {
    let valid = samples.compactMap(\.value).filter(\.isFinite)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        Spacer()
        Text(current.map(format) ?? "—")
          .font(.system(size: 11, weight: .semibold).monospacedDigit())
      }
      timeChart(
        samples, fixedRange: fixedRange, tint: tint, valueStyle: valueStyle, label: title
      ).frame(height: 52)
      HStack(spacing: 8) {
        Text("Min \(valid.min().map(format) ?? "—")")
        Spacer()
        Text("Max \(valid.max().map(format) ?? "—")")
      }
      .font(.system(size: 8.5).monospacedDigit())
      .foregroundStyle(.tertiary)
    }
    .padding(9)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.45),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }

  private func trendRowSeries(
    _ title: String, samples: [HeliosChartSample], current: Double?,
    fixedRange: ClosedRange<Double>?, tint: Color = .secondary,
    valueStyle: HeliosChartValueStyle = .plain,
    format: @escaping (Double) -> String
  ) -> some View {
    let valid = samples.compactMap(\.value).filter(\.isFinite)
    return VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        Spacer()
        Text(current.map(format) ?? "—")
          .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
      }
      timeChart(
        samples, fixedRange: fixedRange, tint: tint, valueStyle: valueStyle, label: title
      ).frame(height: 76)
      HStack {
        Text("Min \(valid.min().map(format) ?? "—")")
        Spacer()
        Text("Max \(valid.max().map(format) ?? "—")")
        Spacer()
        Text(activeGraphRange.label)
      }
      .font(.system(size: 8.5).monospacedDigit())
      .foregroundStyle(.tertiary)
    }
  }

  private func compactValue(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func memoryBar(
    _ title: String, bytes: UInt64, total: UInt64, tint: Color = .accentColor
  ) -> some View {
    let fraction = total > 0 ? min(1, max(0, Double(bytes) / Double(total))) : 0
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).foregroundStyle(.secondary)
        Spacer()
        Text(TelemetryFormatting.storageBytes(bytes)).monospacedDigit()
      }
      .font(.system(size: 10.5))
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .tint(tint)
    }
  }

  private func memoryPressureColor(_ pressure: MetricResult<MemoryPressure>) -> Color {
    guard case .success(let value) = pressure else { return .secondary }
    switch value {
    case .normal: return .green
    case .warning: return .orange
    case .critical: return .red
    }
  }

  @ViewBuilder
  private func batteryPeriodInsight(_ energy: AppEnergySummary) -> some View {
    let samples = mergedSeries(\.batteryPercent, \.batteryPercent)
      .compactMap { sample -> (Date, Double)? in
        guard let value = sample.value, value.isFinite else { return nil }
        return (sample.capturedAt, value)
      }
    if let first = samples.first, let last = samples.last, last.0 > first.0 {
      let delta = last.1 - first.1
      let headline: String = {
        if delta <= -0.5 {
          return "Battery dropped \(String(format: "%.0f%%", abs(delta))) in this window"
        }
        if delta >= 0.5 {
          return "Battery gained \(String(format: "%.0f%%", delta)) in this window"
        }
        return "Battery level stayed nearly unchanged"
      }()

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: delta < -0.5 ? "battery.50percent" : "waveform.path.ecg")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(delta < -0.5 ? Color.orange : Color.secondary)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(headline)
              .font(.system(size: 10.5, weight: .semibold))
            Spacer()
            Text(activeGraphRange.label)
              .font(.system(size: 9.5, weight: .medium).monospacedDigit())
              .foregroundStyle(.tertiary)
          }
          if let leader = energy.topOnBattery.first {
            let total = max(0.000_001, energy.topOnBattery.reduce(0) { $0 + $1.energyWattHours })
            let share = min(1, max(0, leader.energyWattHours / total))
            Text(
              "Top tracked app: \(leader.displayName) · \(String(format: "%.0f%%", share * 100)) of attributed app energy · observed \(TelemetryFormatting.duration(energy.onBatteryCoverageSeconds))."
            )
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } else {
            Text(
              "Per-app attribution will appear here after Helios observes on-battery activity in the selected range."
            )
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(10)
      .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }
  }

  private func batteryEnergyRow(
    rank: Int, entry: AppEnergyEntry, total: Double, trend: AppEnergyTrend?
  ) -> some View {
    let share = total > 0 ? min(1, max(0, entry.energyWattHours / total)) : 0
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 9) {
        Text("\(rank)")
          .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
          .foregroundStyle(.tertiary)
          .frame(width: 14, alignment: .trailing)

        HeliosAppIdentityIcon(appKey: entry.appKey, size: 26)

        VStack(alignment: .leading, spacing: 2) {
          Text(entry.displayName)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
          HStack(spacing: 7) {
            Text("Tracked share")
              .foregroundStyle(.secondary)
            if entry.wakeups >= 1 {
              Text("·")
                .foregroundStyle(.tertiary)
              Text("\(Int(entry.wakeups.rounded())) wakeups")
                .foregroundStyle(.tertiary)
            }
          }
          .font(.system(size: 8.75))
          .lineLimit(1)
        }

        Spacer(minLength: 8)

        VStack(alignment: .trailing, spacing: 2) {
          Text(String(format: "%.0f%%", share * 100))
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
          if let trendText = batteryTrendText(trend) {
            Text(trendText.text)
              .font(.system(size: 8.5, weight: .medium).monospacedDigit())
              .foregroundStyle(trendText.tint)
          }
        }
      }

      ProgressView(value: share, total: 1)
        .progressViewStyle(.linear)
        .tint(.green)
        .controlSize(.mini)
        .padding(.leading, 49)
    }
    .padding(.vertical, 2)
  }

  private func batteryTrendText(_ trend: AppEnergyTrend?) -> (text: String, tint: Color)? {
    guard let change = trend?.changePercent, change.isFinite, abs(change) >= 10 else { return nil }
    if change > 0 {
      return (String(format: "↑ %.0f%% vs prev h", change), .orange)
    }
    return (String(format: "↓ %.0f%% vs prev h", abs(change)), .green)
  }

  private func tile(_ title: String, _ symbol: String, _ value: String, _ tint: Color) -> some View
  {
    HeliosMetricTile(title: title, symbol: symbol, value: value, tint: tint)
  }

  private func section<Content: View>(
    _ title: String, _ symbol: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HeliosPanel(title: title, symbol: symbol) { content() }.frame(maxWidth: .infinity)
  }

  private func diagnosticSection<Content: View>(
    _ title: String, _ symbol: String, subtitle: String? = nil, summary: String? = nil,
    defaultExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content
  ) -> AnyView {
    AnyView(
      HeliosDiagnosticDisclosurePanel(
        title: title, symbol: symbol, subtitle: subtitle ?? diagnosticSubtitle(for: title),
        summary: summary, defaultExpanded: defaultExpanded
      ) {
        content()
      }
      .id(title)
      .frame(maxWidth: 940, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    )
  }

  private func diagnosticSubtitle(for title: String) -> String? {
    switch title {
    case "CPU internals": return "Raw utilization, topology and per-core samples"
    case "Memory internals": return "VM accounting, pressure, reclaimable memory and swap"
    case "GPU internals": return "Renderer, tiler, device utilization and shared-memory counters"
    case "Battery internals": return "Read-only capacity, electrical, charging and cell telemetry"
    case "Network internals": return "Interface identity, route, counters and session totals"
    case "Wi-Fi radio": return "Radio state, signal quality, channel and PHY metadata"
    case "System internals": return "Hardware identity, memory, uptime and kernel metadata"
    case "Power assertions": return "Native sleep-prevention assertions and ownership metadata"
    case "Clock metadata": return "Local/UTC zones and system clock context"
    case "Display inventory": return "Connected displays, modes, scale and refresh metadata"
    case "Mounted volumes": return "Mounted filesystems, capacities and mount characteristics"
    case "USB inventory": return "Connected USB devices and descriptor metadata"
    case "Bluetooth inventory": return "Nearby/paired device metadata exposed by native APIs"
    case "Audio inventory": return "Audio devices, channels, rates and transport metadata"
    case "Live history state": return "In-memory rolling history and current sampled coverage"
    case "Persistent history state":
      return "On-disk retained history, deltas and Helios self-metrics"
    case "Health state": return "Current issues, severity and notification authorization"
    case "Health event log": return "Persistent activation, notification and resolution events"
    case "Hardware capability report":
      return "Read-only capability discovery and availability state"
    case "Sampler metadata": return "Capture timestamps and host ticks for every live collector"
    case "Raw SMC numeric inventory": return "On-demand display-only numeric SMC channels"
    case "Maintenance telemetry":
      return "On-demand maintenance results; no background scanner added"
    default: return nil
    }
  }

  private func diagnosticRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 190, alignment: .leading)
        .lineLimit(2)
      Text(value)
        .monospacedDigit()
        .textSelection(.enabled)
        .multilineTextAlignment(.trailing)
        .lineLimit(3)
        .truncationMode(.middle)
        .frame(maxWidth: 610, alignment: .trailing)
    }
    .font(.system(size: 10.5))
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: 820, alignment: .leading)
    .background(
      Color(nsColor: .textBackgroundColor).opacity(0.16),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private var thermalDiagnosticSummary: String? {
    guard case .success(let t) = p.thermals else { return nil }
    return "\(t.readings.count) sensors"
  }

  private var fanDiagnosticSummary: String? {
    guard case .success(let inventory) = p.fans else { return nil }
    return inventory.fans.count == 1 ? "1 fan" : "\(inventory.fans.count) fans"
  }

  private var storageDiagnosticSummary: String? {
    guard case .success(let storage) = p.storage else { return nil }
    return storage.devices.count == 1 ? "1 device" : "\(storage.devices.count) devices"
  }

  private var processDiagnosticSummary: String? {
    guard case .success(let processes) = p.processes else { return nil }
    return "\(processes.accessibleProcessCount) accessible"
  }

  private func thermalSensorChip(_ reading: ThermalReading) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(reading.key)
          .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        Text(reading.group.rawValue)
          .font(.system(size: 7.5))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      Text(String(format: "%.1f°C", reading.celsius))
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      Color(nsColor: .textBackgroundColor).opacity(0.18),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private func diagnosticMiniMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 8.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      Text(value)
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.primary)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .textBackgroundColor).opacity(0.16),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }

  private func diagnosticEntityCard<Content: View>(
    title: String, subtitle: String? = nil, value: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
          if let subtitle {
            Text(subtitle)
              .font(.system(size: 8.5, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
        }
        Spacer(minLength: 12)
        if let value {
          Text(value)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      content()
    }
    .padding(10)
    .frame(maxWidth: 820, alignment: .leading)
    .background(
      Color(nsColor: .textBackgroundColor).opacity(0.22),
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.20), lineWidth: 0.5))
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 20)
      Text(value).monospacedDigit().multilineTextAlignment(.trailing)
    }
    .font(.system(size: 11))
  }

  private func big(_ value: String) -> some View {
    Text(value).font(.system(size: 28, weight: .semibold).monospacedDigit())
  }

  private func metric<Value>(_ result: MetricResult<Value>, _ formatter: (Value) -> String)
    -> String
  { DisplayValue(result, format: formatter).text }
}

private enum HeliosSettingsRoute: String, CaseIterable, Identifiable {
  case general
  case modules
  case graphs
  case fans
  case battery
  case privacy
  case advanced
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .modules: "Modules"
    case .graphs: "Graphs & Colors"
    case .fans: "Cooling"
    case .battery: "Battery & Energy"
    case .privacy: "Privacy & Diagnostics"
    case .advanced: "Advanced"
    case .about: "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gear"
    case .modules: "square.grid.2x2"
    case .graphs: "chart.xyaxis.line"
    case .fans: "fan"
    case .battery: "battery.75percent"
    case .privacy: "hand.raised"
    case .advanced: "slider.horizontal.3"
    case .about: "info.circle"
    }
  }
}

private enum HeliosModuleSettingsTab: String, CaseIterable, Identifiable {
  case collection = "Data Collection"
  case menuBar = "Menu Bar"
  case popover = "Dashboard"
  case monitor = "Full Monitor"
  var id: String { rawValue }
}

struct HeliosSettingsView: View {
  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var service: DaemonService
  @ObservedObject var diagnostics: DiagnosticsController
  @ObservedObject private var diagnosticsPreferences: DiagnosticsPreferences
  @StateObject private var manualApproval = DiagnosticsManualApproval()
  @State private var selection: HeliosSettingsRoute? = .modules
  @State private var moduleTab: HeliosModuleSettingsTab = .collection
  @State private var showingPrepareRemoval = false
  @State private var eraseLocalDataOnRemoval = false
  @State private var removalStatus: String?
  @State private var diagnosticsPreview: FrozenDiagnosticsPayload?
  @State private var showingDiagnosticsPreview = false
  @State private var previewAllowsSend = false
  @State private var diagnosticsStatus: String?
  @State private var showingCompatibilityConsent = false
  @State private var generatingCompatibility = false
  @State private var compatibilityStatus: String?
  @State private var compatibilityTransitioningToPreview = false
  @State private var manualSendCompleted = false

  init(
    preferences: HeliosPreferences, service: DaemonService, diagnostics: DiagnosticsController
  ) {
    self.preferences = preferences
    self.service = service
    self.diagnostics = diagnostics
    diagnosticsPreferences = diagnostics.preferences
  }

  var body: some View {
    NavigationSplitView {
      List(HeliosSettingsRoute.allCases, selection: $selection) { route in
        Label(route.title, systemImage: route.symbol).tag(route)
      }
      .navigationTitle("Settings")
      .navigationSplitViewColumnWidth(min: 145, ideal: 160, max: 180)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          settingsHeader
          settingsDetail(selection ?? .modules)
        }
        .padding(22)
        .frame(maxWidth: 600, alignment: .topLeading)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 720, minHeight: 520)
    .sheet(isPresented: $showingDiagnosticsPreview, onDismiss: dismissDiagnosticsPreview) {
      diagnosticsPreviewSheet
    }
    .sheet(isPresented: $showingCompatibilityConsent, onDismiss: compatibilityConsentDismissed) {
      DiagnosticsCompatibilityConsentView(
        generating: generatingCompatibility, status: compatibilityStatus,
        onCancel: cancelCompatibilityReport,
        onGenerate: generateCompatibilityPreview)
    }
  }

  @ViewBuilder
  private var diagnosticsPreviewSheet: some View {
    if let diagnosticsPreview {
      if previewAllowsSend {
        DiagnosticsPayloadView(
          title: "Confirm diagnostic report",
          explanation:
            "Review the complete request body, then choose Send report. This one-shot action does not enable automatic diagnostics.",
          payload: diagnosticsPreview,
          sendTitle: manualSendCompleted ? "Sent" : "Send report",
          sending: diagnostics.sending,
          sendDisabled: manualSendCompleted,
          status: diagnosticsStatus,
          onSend: sendApprovedManualReport,
          onRegenerate: diagnosticsPreview.reportType == .manualCompatibility
            ? generateCompatibilityPreview : showManualHealthPreview)
      } else {
        DiagnosticsPayloadView(
          title: "Beta diagnostics preview",
          explanation:
            "This local preview shows the complete automatic diagnostics body. Viewing it sends nothing.",
          payload: diagnosticsPreview,
          status: diagnosticsStatus,
          onRegenerate: showAutomaticPreview)
      }
    }
  }

  private var settingsHeader: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text((selection ?? .modules).title).font(.system(size: 24, weight: .semibold))
      Text(settingsSubtitle(selection ?? .modules))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func settingsDetail(_ route: HeliosSettingsRoute) -> some View {
    switch route {
    case .general: general
    case .modules: modules
    case .graphs: graphs
    case .fans: fans
    case .battery: batterySettings
    case .privacy: privacy
    case .advanced: advanced
    case .about: about
    }
  }

  private func settingsSubtitle(_ route: HeliosSettingsRoute) -> String {
    switch route {
    case .general: "How Helios behaves as a macOS utility."
    case .modules:
      "Build the menu bar, module popups and Full Monitor around what you actually use."
    case .graphs:
      "Choose chart behavior, history ranges and a color for every module or data series."
    case .fans: "Understand the safe fan-control boundary and helper status."
    case .battery: "Read-only battery-life estimation and energy-history behavior."
    case .privacy: "Control optional beta diagnostics and inspect every byte before a manual send."
    case .advanced: "Diagnostics and interface reset options for experienced users."
    case .about: "Version, author and project links."
    }
  }

  private func setCoolingEnabled(_ enabled: Bool) {
    if !enabled {
      // Never hide the controls while leaving an invisible Helios override active.
      service.fanControl.setMode(.system)
    }
    preferences.setCoolingFeaturesEnabled(enabled)
  }

  private func setTelemetryCollection(_ module: HeliosTelemetryModule, enabled: Bool) {
    if module == .fans, !enabled, preferences.coolingFeaturesEnabled {
      // Fan control depends on fresh fan inventory. Returning to System before
      // stopping the read-only sampler keeps the write path impossible to
      // strand behind hidden controls.
      service.fanControl.setMode(.system)
      preferences.setCoolingFeaturesEnabled(false)
    }
    preferences.setTelemetryModuleEnabled(module, enabled: enabled)
  }

  private var general: some View {
    Form {
      Section("Helios") {
        LabeledContent("Interface", value: "Menu bar + optional Full Monitor")
        LabeledContent("Telemetry", value: "Local native monitoring")
        LabeledContent("Hardware writes", value: "Fan control only")
        LabeledContent("Battery policy", value: "macOS-managed")
      }
      Section("Interface preset") {
        Picker(
          "Preset",
          selection: Binding(
            get: { preferences.dashboardMode },
            set: { preferences.applyInterfacePreset($0) })
        ) {
          ForEach(HeliosDashboardMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        Text(preferences.dashboardMode.onboardingDetail)
          .foregroundStyle(.secondary)
        Text(
          "Presets are starting configurations, not restrictions. Detailed enables the full diagnostic presentation and every normal telemetry sampler; manual module changes remain editable at any time."
        )
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      }
      Section("Startup") {
        Toggle(
          "Launch Helios at login",
          isOn: Binding(
            get: { service.launchAtLoginEnabled },
            set: { enabled in Task { await service.setLaunchAtLogin(enabled) } })
        )
        .disabled(service.launchAtLoginBusy)
        Text(
          "Uses macOS Service Management. This starts the Helios app after you sign in; it is separate from the optional privileged fan helper."
        )
        .foregroundStyle(.secondary)
        if service.launchAtLoginRequiresApproval {
          Button("Open Login Items Settings") { service.openApprovalSettings() }
        }
        if let message = service.launchAtLoginMessage {
          Text(message).foregroundStyle(.secondary)
        }
      }
      Section("Interface behavior") {
        Toggle(
          "Compact dashboard card spacing",
          isOn: Binding(
            get: { preferences.compactCards },
            set: { preferences.setCompactCards($0) })
        )
        Text(
          "Helios follows macOS semantic colors, materials, typography and SF Symbols so future macOS appearance changes do not require a hard-coded theme rewrite."
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var modules: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker("Module surface", selection: $moduleTab) {
        ForEach(HeliosModuleSettingsTab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      switch moduleTab {
      case .collection: dataCollection
      case .menuBar: menuBar
      case .popover: dashboard
      case .monitor: monitor
      }
    }
  }

  private var dataCollection: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Collection vs. visibility") {
        VStack(alignment: .leading, spacing: 7) {
          Label("Stop work you do not need", systemImage: "bolt.slash")
            .font(.system(size: 11, weight: .semibold))
          Text(
            "Hiding a module changes only the interface. Turning collection off stops that sampler and temporarily removes live surfaces that depend on it, without deleting their saved menu-bar, Dashboard or Full Monitor placement. Re-enable collection and the same modules regenerate in the same order. Trusted thermal health sampling stays available because Helios uses it for safety and system-health state."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(4)
      }

      GroupBox("Cooling & fan control") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Enable cooling controls",
            isOn: Binding(
              get: { preferences.coolingFeaturesEnabled },
              set: { setCoolingEnabled($0) })
          )
          Text(
            preferences.coolingFeaturesEnabled
              ? "Fan-control writes are enabled. System remains the recommended mode; read-only fan telemetry is configured separately below."
              : "Fan-control writes and helper-facing controls are disabled. Read-only fan RPM monitoring can stay enabled independently."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
          HeliosFanSafetyNotice(compact: true)
            .opacity(preferences.coolingFeaturesEnabled ? 1 : 0.55)
        }
        .padding(4)
      }

      GroupBox("Telemetry samplers") {
        VStack(spacing: 0) {
          ForEach(HeliosTelemetryModule.allCases) { module in
            HStack(alignment: .top, spacing: 10) {
              Toggle(
                module.label,
                isOn: Binding(
                  get: { preferences.isTelemetryEnabled(module) },
                  set: { setTelemetryCollection(module, enabled: $0) })
              )
              .toggleStyle(.switch)
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(module.detail)
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                  Text(module.monitoringCost)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
                }
                Text(
                  preferences.isTelemetryEnabled(module)
                    ? "Collecting locally" : "Sampler stopped"
                )
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(
                  preferences.isTelemetryEnabled(module) ? Color.green : Color.secondary)
              }
              Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            if module != HeliosTelemetryModule.allCases.filter({ $0 != .fans }).last {
              Divider()
            }
          }
        }
        .padding(.horizontal, 4)
      }

      GroupBox("Always-on core") {
        VStack(alignment: .leading, spacing: 6) {
          LabeledContent("Trusted thermal health", value: "On")
          LabeledContent("System metadata", value: "On")
          Text(
            "These lightweight reads support temperature health, capability discovery and safe UI state. Raw/advisory sensor inventory remains on a slower expert cadence and is never trusted blindly for fan safety."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(4)
      }
    }
  }

  private var graphs: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Live charts") {
        VStack(alignment: .leading, spacing: 12) {
          Picker("Line shape", selection: $preferences.graphLineStyle) {
            ForEach(HeliosGraphLineStyle.allCases) { style in
              Text(style.label).tag(style)
            }
          }
          .pickerStyle(.segmented)
          Toggle("Continuous graph motion", isOn: $preferences.animateGraphUpdates)
          Text(
            "Helios still samples at the normal telemetry cadence. When a real sample arrives, the final path is rendered once and Core Animation glides it into its new position over the observed sample interval. No fake telemetry points are created and polling is not increased."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
          Label(
            "Hover any chart to inspect the nearest real sample with its timestamp and exact value.",
            systemImage: "scope"
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
          Text(
            "Smooth changes only the curve drawn between real samples. Raw shows straight sample-to-sample segments. Switching either option redraws the entire visible history immediately."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(4)
      }
      GroupBox("Memory gauge") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Color available memory in the gauge", isOn: $preferences.memoryGaugeShowsAvailable)
          Text(
            preferences.memoryGaugeShowsAvailable
              ? "Available memory uses a muted green segment. App, wired and compressed memory keep their own fixed colors; swap and reclaimable cache remain separate and never reuse those colors."
              : "Recommended: colored segments show only memory in use. The neutral remainder is available physical memory, so free headroom is visible without adding another bright status color."
          )
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        }
        .padding(4)
      }
      GroupBox("Colors") {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "Colors apply consistently to popups, the Quick Dashboard, Full Monitor and Energy Inspector. The macOS menu bar itself stays native monochrome."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
          colorRoleGroup(
            "Modules", roles: HeliosColorRole.allCases.filter { $0.group == "Modules" })
          Divider().opacity(0.45)
          colorRoleGroup(
            "Network", roles: HeliosColorRole.allCases.filter { $0.group == "Network" })
          Divider().opacity(0.45)
          colorRoleGroup(
            "Memory breakdown",
            roles: HeliosColorRole.allCases.filter { $0.group == "Memory breakdown" })
          HStack {
            Spacer()
            Button("Reset Colors") { preferences.resetColors() }
          }
        }
        .padding(4)
      }
      GroupBox("Default time range") {
        VStack(alignment: .leading, spacing: 9) {
          HeliosGraphRangePicker(
            range: Binding(
              get: { preferences.graphRange },
              set: { preferences.setAllGraphRanges($0) }))
          Text(
            "This sets every chart to the same starting range. Afterwards each module remembers its own 1m–24h selection. Longer ranges merge the live tail with Helios' persistent 24-hour history instead of starting when a window opens."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(4)
      }
    }
  }

  private var batterySettings: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Battery life") {
        VStack(alignment: .leading, spacing: 8) {
          Label("macOS estimate first", systemImage: "checkmark.circle")
            .font(.system(size: 11, weight: .semibold))
          Text(
            "When macOS still reports Calculating, Helios can show an early ≈ estimate from read-only remaining capacity, voltage and recent discharge power. The system estimate automatically takes priority when it becomes available."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(4)
      }
      GroupBox("Energy attribution") {
        Text(
          "Battery & Energy ranks the bounded per-app energy history that Helios already records locally. Rankings are intended for relative attribution and trends, not billing-grade joule measurement."
        )
        .font(.system(size: 10)).foregroundStyle(.secondary).padding(4)
      }
      GroupBox("Charging policy") {
        Label("Always macOS-managed", systemImage: "lock.shield")
          .font(.system(size: 11, weight: .semibold)).padding(4)
        Text("Helios never changes charge limits, charger state, or optimized charging policy.")
          .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(
            .bottom, 4)
      }
    }
  }

  private var dashboard: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Quick presets") {
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 8) {
            ForEach(HeliosDashboardMode.allCases.filter { $0 != .custom }) { mode in
              Button(mode.label) {
                preferences.applyDashboardPreset(mode)
              }
              .frame(maxWidth: .infinity)
              .help(mode.onboardingDetail)
            }
          }
          Text(
            "A preset replaces the visible module list once. After that, add, remove, or reorder anything below — Helios does not lock you into a mode."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(4)
      }

      if preferences.isPopoverModuleEnabled(.summary) {
        GroupBox("Summary metrics") {
          VStack(spacing: 0) {
            ForEach(preferences.dashboardMetrics) { metric in
              configurableDashboardMetricRow(metric)
              if preferences.dashboardMetrics.last != metric { Divider() }
            }
            let availableMetrics = HeliosDashboardMetric.allCases.filter {
              !preferences.isDashboardMetricEnabled($0)
            }
            if !availableMetrics.isEmpty {
              Divider().opacity(0.45)
              HStack {
                Text("Add")
                  .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                ForEach(availableMetrics) { metric in
                  Button {
                    preferences.setDashboardMetricEnabled(metric, enabled: true)
                  } label: {
                    Image(systemName: metric.symbolName)
                  }
                  .buttonStyle(.borderless)
                  .help("Add \(metric.label)")
                }
                Spacer()
              }
              .padding(.vertical, 7)
            }
          }
          .padding(.horizontal, 4)
        }
      }

      GroupBox("Visible modules") {
        VStack(spacing: 0) {
          ForEach(preferences.popoverModules) { module in
            configurablePopoverRow(module)
            if preferences.popoverModules.last != module { Divider() }
          }
          if preferences.popoverModules.isEmpty {
            Text("No dashboard modules are enabled.")
              .font(.system(size: 11)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 8)
          }
        }
        .padding(.horizontal, 4)
      }

      let available = HeliosPopoverModule.allCases.filter {
        !preferences.isPopoverModuleEnabled($0)
      }
      if !available.isEmpty {
        GroupBox("Add a module") {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(available) { module in
              Button {
                preferences.setPopoverModuleEnabled(module, enabled: true)
              } label: {
                Label(module.label, systemImage: module.symbolName)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .padding(4)
        }
      }

      HStack {
        Spacer()
        Button("Reset Dashboard to Recommended") { preferences.resetDashboard() }
      }
    }
  }

  private func configurablePopoverRow(_ module: HeliosPopoverModule) -> some View {
    HStack(spacing: 10) {
      Label(module.label, systemImage: module.symbolName)
      Spacer()
      Button {
        preferences.movePopoverModule(module, offset: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.popoverModules.first == module)
      .help("Move up")
      Button {
        preferences.movePopoverModule(module, offset: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.popoverModules.last == module)
      .help("Move down")
      Button(role: .destructive) {
        preferences.setPopoverModuleEnabled(module, enabled: false)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove from dashboard")
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  private var monitor: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Sidebar modules") {
        VStack(spacing: 0) {
          ForEach(preferences.monitorRoutes) { route in
            configurableMonitorRow(route)
            if preferences.monitorRoutes.last != route { Divider() }
          }
        }
        .padding(.horizontal, 4)
      }

      let available = HeliosMonitorRoute.allCases.filter { !preferences.isMonitorRouteEnabled($0) }
      if !available.isEmpty {
        GroupBox("Add a module") {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(available) { route in
              Button {
                preferences.setMonitorRouteEnabled(route, enabled: true)
              } label: {
                Label(route.title, systemImage: route.symbol)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .padding(4)
        }
      }

      GroupBox("Behavior") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Detailed Full Monitor content",
            isOn: Binding(
              get: { preferences.detailedMonitorContent },
              set: { preferences.setDetailedMonitorContent($0) })
          )
          Text(
            preferences.detailedMonitorContent
              ? "Detailed content exposes per-core/process/diagnostic context by default. Detailed and Custom onboarding presets enable this automatically."
              : "Essential content keeps Full Monitor focused. Hidden detail is not deleted and can be re-enabled at any time."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
          Text(
            "Overview stays pinned as the landing page. Hidden sidebar modules are not deleted; you can add them back here at any time."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
          HStack {
            Spacer()
            Button("Show All Modules") { preferences.resetMonitor() }
          }
        }
        .padding(4)
      }
    }
  }

  private func configurableMonitorRow(_ route: HeliosMonitorRoute) -> some View {
    HStack(spacing: 10) {
      Label(route.title, systemImage: route.symbol)
      if route == .overview {
        Text("Pinned").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
      }
      Spacer()
      Button {
        preferences.moveMonitorRoute(route, offset: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(route == .overview || preferences.monitorRoutes.firstIndex(of: route) == 1)
      .help("Move up")
      Button {
        preferences.moveMonitorRoute(route, offset: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(route == .overview || preferences.monitorRoutes.last == route)
      .help("Move down")
      Button(role: .destructive) {
        preferences.setMonitorRouteEnabled(route, enabled: false)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .disabled(route == .overview)
      .help(route == .overview ? "Overview is always available" : "Hide from Full Monitor")
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  private var menuBar: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Layout") {
        VStack(alignment: .leading, spacing: 9) {
          Picker(
            "Menu bar layout",
            selection: Binding(
              get: { preferences.menuBarLayout },
              set: { preferences.setMenuBarLayout($0) })
          ) {
            ForEach(HeliosMenuBarLayout.allCases) { layout in
              Text(layout.label).tag(layout)
            }
          }
          .pickerStyle(.segmented)
          Text(preferences.menuBarLayout.detail)
            .font(.system(size: 10)).foregroundStyle(.secondary)
          Label(
            preferences.menuBarLayout == .nativeModules
              ? "Separate modules can open their own metric popups. The Helios sun is an optional extra Dashboard hub."
              : "The whole compact group is one Helios item and opens the Dashboard, so there is no separate hub icon.",
            systemImage: preferences.menuBarLayout == .nativeModules
              ? "rectangle.3.group" : "rectangle.compress.vertical"
          )
          .font(.system(size: 9.5))
          .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Metric spacing")
                .font(.system(size: 10, weight: .medium))
              Spacer()
              Text(String(format: "%.1f pt", preferences.menuBarSpacing))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Text("Compact").font(.system(size: 9)).foregroundStyle(.secondary)
              Slider(
                value: Binding(
                  get: { preferences.menuBarSpacing },
                  set: { preferences.setMenuBarSpacing($0) }),
                in: 0...8, step: 0.5
              )
              .accessibilityLabel("Menu bar metric spacing")
              Text("Roomy").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(
              preferences.menuBarLayout == .nativeModules
                ? "Removes Helios-owned padding down to the fixed text width. macOS still reserves its own separation between independent status items; Single compact group is the tightest layout."
                : "Controls the internal gap and fixed padding inside the single Helios item. At Compact, Helios adds no extra gap between metric slots."
            )
            .font(.system(size: 9)).foregroundStyle(.secondary)
          }
          if preferences.menuBarLayout == .nativeModules {
            Toggle(
              "Show Helios dashboard hub",
              isOn: Binding(
                get: { preferences.showMenuBarHub },
                set: { preferences.setMenuBarHubVisible($0) })
            )
            .disabled(preferences.menuBarMetricsForPresentation.isEmpty)
            .help(
              preferences.menuBarMetricsForPresentation.isEmpty
                ? "The Helios hub stays visible when no metric modules are enabled so the app remains reachable."
                : "Adds the Helios solar mark as a separate status item that opens the complete dashboard."
            )
            Label(
              "Hold ⌘ and drag native modules directly in the menu bar to reorder them. macOS remembers each module's position.",
              systemImage: "command"
            )
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
          }
        }
        .padding(4)
      }

      GroupBox("Thermals in the menu bar") {
        Label(
          "Temperature & Fan is the combined two-line option. Use Temperature for a single temperature value, Fan for RPM only, or Temperature & Fan when you want one module instead of two.",
          systemImage: "thermometer.medium"
        )
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .padding(4)
      }

      GroupBox("Preview") {
        HStack {
          Spacer(minLength: 0)
          HeliosMenuBarPreview(preferences: preferences)
          Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
      }

      GroupBox("Visible metrics") {
        VStack(spacing: 0) {
          ForEach(preferences.menuBarMetrics) { metric in
            configurableMenuBarRow(metric)
            if preferences.menuBarMetrics.last != metric { Divider() }
          }
          if preferences.menuBarMetrics.isEmpty {
            Text(
              "No metric modules are enabled. The optional Helios hub can still open the dashboard."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
          }
        }
        .padding(.horizontal, 4)
      }

      let available = HeliosMenuBarMetric.allCases.filter { !preferences.isEnabled($0) }
      if !available.isEmpty {
        GroupBox("Add a metric") {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(available) { metric in
              Button {
                preferences.setEnabled(metric, enabled: true)
              } label: {
                Label(metric.label, systemImage: metric.symbolName)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .padding(4)
        }
      }

      HStack {
        Spacer()
        Button("Reset Menu Bar") { preferences.resetMenuBar() }
      }
    }
  }

  private func configurableMenuBarRow(_ metric: HeliosMenuBarMetric) -> some View {
    let content = preferences.menuBarContent(for: metric)
    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 9) {
        Label(metric.label, systemImage: metric.symbolName)
          .frame(width: 120, alignment: .leading)
        TextField(
          "Label",
          text: Binding(
            get: { preferences.label(for: metric) },
            set: { preferences.setLabel($0, for: metric) })
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 76)
        .disabled(!content.showLabel)
        .help("Optional short label shown when Label is enabled")
        Spacer(minLength: 4)
        if preferences.menuBarLayout == .compactGroup {
          Button {
            preferences.move(metric, offset: -1)
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.borderless)
          .disabled(preferences.menuBarMetrics.first == metric)
          .help("Move left inside the compact group")
          Button {
            preferences.move(metric, offset: 1)
          } label: {
            Image(systemName: "chevron.right")
          }
          .buttonStyle(.borderless)
          .disabled(preferences.menuBarMetrics.last == metric)
          .help("Move right inside the compact group")
        }
        Button(role: .destructive) {
          preferences.setEnabled(metric, enabled: false)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove from menu bar")
      }

      HStack(spacing: 15) {
        Text("Show")
          .font(.system(size: 9.5, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 120, alignment: .trailing)
        Toggle(
          "Icon",
          isOn: Binding(
            get: { preferences.menuBarContent(for: metric).showIcon },
            set: { preferences.setMenuBarIconVisible($0, for: metric) })
        )
        Toggle(
          "Label",
          isOn: Binding(
            get: { preferences.menuBarContent(for: metric).showLabel },
            set: { preferences.setMenuBarLabelVisible($0, for: metric) })
        )
        Toggle(
          "Value",
          isOn: Binding(
            get: { preferences.menuBarContent(for: metric).showValue },
            set: { preferences.setMenuBarValueVisible($0, for: metric) })
        )
        Spacer()
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .font(.system(size: 10))
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  private func configurableDashboardMetricRow(_ metric: HeliosDashboardMetric) -> some View {
    HStack(spacing: 10) {
      Label(metric.label, systemImage: metric.symbolName)
      Spacer()
      Button {
        preferences.moveDashboardMetric(metric, offset: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.dashboardMetrics.first == metric)
      .help("Move up")
      Button {
        preferences.moveDashboardMetric(metric, offset: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.dashboardMetrics.last == metric)
      .help("Move down")
      Button(role: .destructive) {
        preferences.setDashboardMetricEnabled(metric, enabled: false)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Hide from System summary")
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  @ViewBuilder
  private func colorRoleGroup(_ title: String, roles: [HeliosColorRole]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
        ForEach(roles) { role in
          HStack(spacing: 8) {
            ColorPicker(
              role.label,
              selection: Binding(
                get: { preferences.color(for: role) },
                set: { preferences.setColorHex($0.heliosHex, for: role) }),
              supportsOpacity: true
            )
            .labelsHidden()
            .frame(width: 28)
            Text(role.label)
              .font(.system(size: 10))
              .lineLimit(1)
            Spacer(minLength: 0)
          }
        }
      }
    }
  }

  private var fans: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Cooling availability") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Enable cooling controls",
            isOn: Binding(
              get: { preferences.coolingFeaturesEnabled },
              set: { setCoolingEnabled($0) })
          )
          Text(
            preferences.coolingFeaturesEnabled
              ? "Cooling controls are available in the dashboard and Full Monitor. Fan RPM collection remains a separate read-only sampler."
              : "Fan-control UI is disabled. Read-only fan RPM telemetry can remain visible if Fan telemetry is enabled under Modules → Data Collection."
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(4)
      }

      GroupBox("Safety model") {
        VStack(alignment: .leading, spacing: 8) {
          Label("System is the recommended default", systemImage: "checkmark.shield")
            .font(.system(size: 12, weight: .semibold))
          HeliosFanSafetyNotice()
          HStack {
            Spacer()
            Button("Show first-use safety guide again") { preferences.resetFanSafetyGuide() }
              .disabled(!preferences.fanSafetyGuideCompleted)
          }
        }
        .padding(4)
      }

      GroupBox("Privileged fan helper") {
        VStack(alignment: .leading, spacing: 8) {
          DaemonServiceCard(service: service, client: service.client)
          Text(
            "The helper is a macOS-managed LaunchDaemon. If it is registered, macOS may start it at boot even when the Helios app is not open. Disable Cooling to stop Helios fan-control use; uninstall the helper here if you do not want it registered at all."
          )
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        }
        .padding(4)
      }
      if preferences.coolingFeaturesEnabled {
        Text("Edit complete Cooling Rules in Full Monitor → Thermals & Fans.")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }

  private var privacy: some View {
    Form {
      Section("Local by design") {
        LabeledContent("Analytics", value: "None")
        LabeledContent(
          "Background network",
          value: diagnosticsPreferences.automaticEnabled
            ? "Optional beta diagnostics enabled" : "No automatic diagnostics")
        LabeledContent("Battery", value: "Read-only telemetry")
        Text(
          "Helios does not send page views, clicks, feature-use events, identities, raw monitoring samples, or fan-control data. External links open only when you click them."
        )
        .foregroundStyle(.secondary)
      }
      Section("Privacy-preserving beta diagnostics") {
        Toggle(
          "Share beta diagnostics",
          isOn: Binding(
            get: { diagnosticsPreferences.automaticEnabled },
            set: { diagnostics.setAutomaticEnabled($0) }))
        LabeledContent(
          "Last successful report", value: diagnosticsLastSuccessfulReport)
        LabeledContent("Last report status", value: diagnosticsPreferences.lastReportStatus.label)
        if diagnosticsPreferences.lastReportStatus == .failed {
          Text("Last failure category: \(diagnosticsPreferences.lastStatusCategory.rawValue)")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Button("View exactly what is shared", action: showAutomaticPreview)
        Button("Send diagnostic report now", action: showManualHealthPreview)
        Button("Create compatibility report", action: beginCompatibilityReport)
        Button("Privacy information") { open("https://snejda.cz/helios/privacy") }
        Text(
          "Automatic diagnostics are off unless you enable them. Manual actions work while they are off, require an exact preview and separate Send confirmation, and never change this switch."
        )
        .foregroundStyle(.secondary)
      }
      Section("Protected resources") {
        LabeledContent("Bluetooth", value: "Paired/connected inventory only")
        LabeledContent("Microphone", value: "Not requested")
        Text(
          "Audio input details are intentionally not probed so Helios does not need microphone permission merely to inventory audio devices."
        )
        .foregroundStyle(.secondary)
      }
      Section("Privileged boundary") {
        Text(
          "The privileged helper is fan-only. Battery charging policy remains owned by macOS and is never modified by Helios."
        )
        .foregroundStyle(.secondary)
        LabeledContent("Privacy & support", value: "helios@snejda.cz")
      }
    }
    .formStyle(.grouped)
  }

  private var diagnosticsLastSuccessfulReport: String {
    diagnosticsPreferences.lastSuccessfulReport?.formatted(date: .abbreviated, time: .shortened)
      ?? "Never"
  }

  private func showAutomaticPreview() {
    do {
      diagnosticsPreview = try diagnostics.makeHealthPayload(
        type: .automaticHealth,
        reason: diagnosticsPreferences.lastSuccessfulAutomaticSend == nil ? .initialOptIn : .daily)
      previewAllowsSend = false
      manualSendCompleted = false
      diagnosticsStatus = nil
      manualApproval.invalidate()
      showingDiagnosticsPreview = true
    } catch {
      diagnosticsStatus = "A safe diagnostics preview is not available yet. Nothing was sent."
    }
  }

  private func showManualHealthPreview() {
    do {
      let payload = try diagnostics.makeHealthPayload(
        type: .manualHealth, reason: .userInitiated)
      manualApproval.setFrozen(payload)
      diagnosticsPreview = manualApproval.payload
      previewAllowsSend = true
      manualSendCompleted = false
      diagnosticsStatus = nil
      showingDiagnosticsPreview = true
    } catch {
      diagnosticsStatus = "A safe manual report could not be created. Nothing was sent."
    }
  }

  private func beginCompatibilityReport() {
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    diagnosticsStatus = nil
    compatibilityStatus = nil
    compatibilityTransitioningToPreview = false
    showingCompatibilityConsent = true
  }

  private func cancelCompatibilityReport() {
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    compatibilityStatus = nil
    compatibilityTransitioningToPreview = false
    showingCompatibilityConsent = false
  }

  private func compatibilityConsentDismissed() {
    if compatibilityTransitioningToPreview {
      compatibilityTransitioningToPreview = false
      return
    }
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    compatibilityStatus = nil
  }

  private func dismissDiagnosticsPreview() {
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    diagnosticsStatus = nil
  }

  private func generateCompatibilityPreview() {
    let transitioningFromConsent = showingCompatibilityConsent
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    generatingCompatibility = true
    compatibilityStatus = "Reading bounded compatibility metadata…"
    Task {
      do {
        let payload = try await diagnostics.makeCompatibilityPayload()
        manualApproval.setFrozen(payload)
        diagnosticsPreview = manualApproval.payload
        previewAllowsSend = true
        diagnosticsStatus = nil
        compatibilityStatus = nil
        generatingCompatibility = false
        if transitioningFromConsent {
          compatibilityTransitioningToPreview = true
          showingCompatibilityConsent = false
        }
        showingDiagnosticsPreview = true
      } catch {
        generatingCompatibility = false
        compatibilityStatus =
          "A safe compatibility preview could not be created. Nothing was sent."
      }
    }
  }

  private func sendApprovedManualReport() {
    guard let payload = manualApproval.approve() else {
      diagnosticsStatus = "This preview expired. Regenerate it before sending."
      return
    }
    Task {
      let result = await diagnostics.sendManual(payload)
      switch result {
      case .accepted:
        diagnosticsStatus = "Report sent successfully."
        manualSendCompleted = true
      case .retryable:
        diagnosticsStatus = "Send failed. The same frozen preview can be retried explicitly."
      case .rejected:
        diagnosticsStatus = "The report was rejected and was not accepted."
      case .cancelled:
        diagnosticsStatus = "Send cancelled."
      }
    }
  }

  private var advanced: some View {
    Form {
      Section("Diagnostics") {
        LabeledContent("Complete diagnostics", value: "Full Monitor → Expert")
        Text(
          "Unknown/raw SMC channels stay expert-only and never enter fan safety or automatic cooling decisions unless separately validated."
        )
        .foregroundStyle(.secondary)
      }
      Section("Interface") {
        Button("Reset Interface Settings") { preferences.resetInterface() }
        Button("Show Welcome Setup on Next Launch") { preferences.markOnboardingIncomplete() }
        Text(
          "These actions affect only interface preferences. They do not reinstall the helper, alter fan ownership, change battery behavior, or erase monitoring history."
        )
        .foregroundStyle(.secondary)
      }
      Section("Removal") {
        Toggle("Erase local Helios settings and monitoring history", isOn: $eraseLocalDataOnRemoval)
        Text(
          eraseLocalDataOnRemoval
            ? "Complete cleanup removes Helios preferences and the local Application Support/Helios history files after fan control and launch services are released."
            : "Leave this off if you may reinstall Helios and want to keep your layout and local monitoring history."
        )
        .foregroundStyle(.secondary)
        Button("Prepare Helios for Removal…", role: .destructive) {
          removalStatus = nil
          showingPrepareRemoval = true
        }
        Text(
          "Returns fan control to System, disables Launch at Login and unregisters the privileged helper. A registered helper is a RunAtLoad LaunchDaemon; uninstalling it is the supported way to stop helper startup at boot. Helios never deletes its own app bundle."
        )
        .foregroundStyle(.secondary)
        if let removalStatus {
          Text(removalStatus)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }
    .formStyle(.grouped)
    .alert("Prepare Helios for Removal?", isPresented: $showingPrepareRemoval) {
      Button("Cancel", role: .cancel) {}
      Button("Prepare", role: .destructive) {
        Task { await prepareForRemoval() }
      }
    } message: {
      Text(
        eraseLocalDataOnRemoval
          ? "Helios will return fan control to macOS, disable Launch at Login, unregister its helper, erase its local preferences/history and then quit. Move the app to Trash afterwards."
          : "Helios will return fan control to macOS, disable Launch at Login and unregister its helper. Monitoring history and preferences will be kept."
      )
    }
  }

  private func prepareForRemoval() async {
    removalStatus = "Preparing removal…"
    service.fanControl.setMode(.system)

    if service.launchAtLoginEnabled || service.launchAtLoginRequiresApproval {
      guard await service.setLaunchAtLogin(false) else {
        removalStatus =
          "Removal stopped: Launch at Login could not be disabled. Resolve the Service Management state and try again; no local data was erased."
        return
      }
    }

    if service.state == .installed || service.state == .requiresApproval {
      guard await service.uninstall() else {
        removalStatus =
          "Removal stopped: the privileged helper is still registered. Resolve the helper state and try again; no local data was erased."
        return
      }
    }

    guard eraseLocalDataOnRemoval else {
      removalStatus =
        "Helios is prepared for removal. The helper is unregistered and Launch at Login is off; you can move Helios.app to Trash."
      return
    }

    eraseLocalHeliosData()
    // Persistent/history services must not get another opportunity to recreate
    // files after a complete cleanup. The app cannot delete its own bundle, so
    // terminate cleanly and let the user move Helios.app to Trash.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
  }

  private func eraseLocalHeliosData() {
    let fileManager = FileManager.default
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    let heliosDirectory = base.appendingPathComponent("Helios", isDirectory: true)
    try? fileManager.removeItem(at: heliosDirectory)

    let domain = Bundle.main.bundleIdentifier ?? HeliosServiceIdentity.appIdentifier
    UserDefaults.standard.removePersistentDomain(forName: domain)
    UserDefaults.standard.synchronize()
  }

  private var about: some View {
    VStack(spacing: 14) {
      Spacer()
      HeliosBrandMark(size: 64)
      Text("Helios").font(.system(size: 28, weight: .semibold))
      Text("Native macOS system monitoring and fan control").foregroundStyle(.secondary)
      Text("Created by Jakub Šnejda").font(.system(size: 13, weight: .medium))
      Text(versionText).font(.system(size: 11)).foregroundStyle(.tertiary)

      HStack {
        Button("snejda.cz") { open("https://www.snejda.cz") }
        Button("GitHub") { open("https://github.com/Snejdik/helios") }
        Button("Report Issue") { open("https://github.com/Snejdik/helios/issues") }
        Button("Contact") { open("mailto:helios@snejda.cz") }
      }

      VStack(spacing: 8) {
        Label("Support Helios", systemImage: "cup.and.saucer")
          .font(.system(size: 13, weight: .semibold))
        Text(
          "Helios is independently developed and free to use. If you find it useful and want to support continued development, you can buy me a coffee."
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        Button("Buy Me a Coffee") { open("https://buymeacoffee.com/snejda") }
          .buttonStyle(.borderedProminent)
      }
      .padding(14)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

      Text("Battery telemetry is read-only. Fan control is isolated in the privileged helper.")
        .font(.system(size: 10)).foregroundStyle(.tertiary)
      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 390)
  }

  private var versionText: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (short, build) {
    case (let version?, let build?) where version != build: return "Version \(version) (\(build))"
    case (let version?, _): return "Version \(version)"
    case (_, let build?): return "Build \(build)"
    default: return "Development build"
    }
  }

  private func open(_ value: String) {
    guard let url = URL(string: value) else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct HeliosMenuBarPreview: View {
  @ObservedObject var preferences: HeliosPreferences

  private var metrics: [HeliosMenuBarMetric] {
    preferences.menuBarMetricsForPresentation
  }

  private var previewGap: CGFloat {
    max(0, min(4, CGFloat(preferences.menuBarSpacing) * 0.45))
  }

  var body: some View {
    HStack(spacing: preferences.menuBarLayout == .compactGroup ? previewGap : 1) {
      if preferences.menuBarLayout == .nativeModules,
        preferences.showMenuBarHub || metrics.isEmpty
      {
        HeliosBrandMark(size: 16, colored: false)
          .frame(width: 24, height: 28)
          .background(Color.secondary.opacity(0.10), in: Capsule())
      }
      if metrics.isEmpty, !preferences.showMenuBarHub {
        Text("No menu-bar modules").font(.system(size: 10)).foregroundStyle(.secondary)
      } else {
        ForEach(metrics) { metric in
          previewMetric(metric)
            .fixedSize(horizontal: true, vertical: false)
            .frame(
              minWidth: max(
                24,
                CGFloat(metric.statusWidth)
                  + CGFloat(preferences.menuBarSpacing) * 0.55 - 4),
              minHeight: 28
            )
            .background(
              preferences.menuBarLayout == .nativeModules
                ? Color.secondary.opacity(0.08) : Color.clear,
              in: Capsule())
        }
      }
    }
    .padding(.horizontal, 9).padding(.vertical, 5)
    .foregroundStyle(.primary)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
    )
    .accessibilityLabel("Menu bar preview")
  }

  @ViewBuilder
  private func previewMetric(_ metric: HeliosMenuBarMetric) -> some View {
    let content = preferences.menuBarContent(for: metric)
    if metric == .cooling {
      HStack(spacing: 3) {
        previewIdentity(metric, content: content)
        if content.showValue {
          VStack(spacing: -1) {
            Text("48°C").font(.system(size: 9.5, weight: .semibold).monospacedDigit())
            Text("Fan off").font(.system(size: 7.5, weight: .medium).monospacedDigit())
          }
        }
      }
    } else if content.showValue && (content.showIcon || content.showLabel) {
      VStack(spacing: -1) {
        previewIdentity(metric, content: content)
        Text(sample(metric)).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
      }
    } else if content.showValue {
      Text(sample(metric)).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
    } else {
      previewIdentity(metric, content: content)
    }
  }

  @ViewBuilder
  private func previewIdentity(_ metric: HeliosMenuBarMetric, content: HeliosMenuBarContent)
    -> some View
  {
    HStack(spacing: 2) {
      if content.showIcon {
        Image(systemName: metric.symbolName).font(.system(size: 8.2, weight: .medium))
      }
      if content.showLabel {
        Text(preferences.label(for: metric)).font(.system(size: 7.5, weight: .medium))
      }
    }
  }

  private func sample(_ metric: HeliosMenuBarMetric) -> String {
    switch metric {
    case .cpu: "8%"
    case .memory: "58%"
    case .gpu: "22%"
    case .temperature: "48°"
    case .cooling: "48°C"
    case .fan: "Off"
    case .battery: "92%"
    case .power: "5W"
    case .network: "650K"
    }
  }
}

struct HeliosOnboardingView: View {
  private enum Page {
    case interface
    case diagnostics
  }

  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var diagnostics: DiagnosticsController
  let onFinish: () -> Void
  @State private var selection: HeliosDashboardMode = .advanced
  @State private var page: Page = .interface
  @State private var shareDiagnostics = false
  @State private var previewPayload: FrozenDiagnosticsPayload?
  @State private var showingPreview = false
  @State private var previewError: String?

  var body: some View {
    VStack(spacing: 0) {
      if page == .interface {
        interfacePage
      } else {
        diagnosticsPage
      }

      Spacer()

      Divider()
      HStack {
        if page == .interface {
          Text("You can customize the menu bar and dashboard independently at any time.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
          Button("Back") { page = .interface }
          Text("Diagnostics can be changed later in Privacy & Diagnostics.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Continue", action: continueAction)
          .keyboardShortcut(.defaultAction)
      }
      .padding(18)
    }
    .frame(width: 720, height: 560)
    .background(.regularMaterial)
    .sheet(isPresented: $showingPreview) {
      if let previewPayload {
        DiagnosticsPayloadView(
          title: "Beta diagnostics preview",
          explanation: "This local preview shows the exact automatic diagnostics body. It is not sent from this screen.",
          payload: previewPayload)
      }
    }
  }

  private var interfacePage: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        HeliosBrandMark(size: 54)
        Text("Welcome to Helios").font(.system(size: 26, weight: .semibold))
        Text(
          "Choose a starting point. Nothing is locked in — every module can be changed later in Settings."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
      }
      .padding(.top, 28)
      .padding(.bottom, 22)

      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
        spacing: 12
      ) {
        ForEach(HeliosDashboardMode.allCases) { mode in onboardingCard(mode) }
      }
      .padding(.horizontal, 24)

      Spacer()
      HStack(alignment: .center) {
        Label("Battery stays macOS-managed", systemImage: "battery.100percent")
        Text("·").foregroundStyle(.tertiary)
        Label("System fan mode is the safe default", systemImage: "checkmark.shield")
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
      .padding(.bottom, 16)
    }
  }

  private var diagnosticsPage: some View {
    VStack(spacing: 22) {
      Spacer()
      HeliosBrandMark(size: 54)
      Text("Help improve Helios Beta").font(.system(size: 26, weight: .semibold))
      Text(
        "Helios is being tested across different Apple Silicon Macs. You can optionally share privacy-preserving technical diagnostics to help improve hardware compatibility and stability. No diagnostic information is sent unless you enable this option."
      )
      .font(.system(size: 13))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 520)

      VStack(alignment: .leading, spacing: 12) {
        Toggle("Share beta diagnostics", isOn: $shareDiagnostics)
          .toggleStyle(.checkbox)
          .font(.system(size: 13, weight: .medium))
        Button("View exactly what is shared", action: showAutomaticPreview)
          .buttonStyle(.link)
        if let previewError {
          Text(previewError).font(.system(size: 10)).foregroundStyle(.secondary)
        }
      }
      .padding(18)
      .frame(width: 440, alignment: .leading)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))

      Text("The checkbox is off by default. Your choice does not affect any Helios feature.")
        .font(.system(size: 10)).foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, 24)
  }

  private func continueAction() {
    if page == .interface, diagnostics.preferences.consent == .notDecided {
      page = .diagnostics
      return
    }
    if page == .diagnostics {
      diagnostics.setAutomaticEnabled(shareDiagnostics)
    }
    preferences.completeOnboarding(with: selection)
    onFinish()
  }

  private func showAutomaticPreview() {
    do {
      previewPayload = try diagnostics.makeHealthPayload(
        type: .automaticHealth, reason: .initialOptIn)
      previewError = nil
      showingPreview = true
    } catch {
      previewError = "A safe diagnostics preview is not available yet. Nothing was sent."
    }
  }

  private func onboardingCard(_ mode: HeliosDashboardMode) -> some View {
    Button {
      selection = mode
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: onboardingSymbol(mode))
            .font(.system(size: 19, weight: .semibold))
          Spacer()
          Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selection == mode ? Color.accentColor : Color.secondary)
        }
        HStack(spacing: 6) {
          Text(mode.onboardingTitle).font(.system(size: 13, weight: .semibold))
          if mode == .advanced {
            Text("Best default")
              .font(.system(size: 8.5, weight: .semibold))
              .foregroundStyle(.green)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.green.opacity(0.10), in: Capsule())
          }
        }
        Text(mode.onboardingDetail)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Text(onboardingModules(mode))
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
      .background(
        selection == mode ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 13, style: .continuous)
          .strokeBorder(
            selection == mode ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.18),
            lineWidth: selection == mode ? 1.25 : 0.7)
      )
    }
    .buttonStyle(.plain)
  }

  private func onboardingSymbol(_ mode: HeliosDashboardMode) -> String {
    switch mode {
    case .simple: "leaf"
    case .advanced: "gauge.with.dots.needle.50percent"
    case .all: "slider.horizontal.3"
    case .custom: "square.grid.2x2"
    }
  }

  private func onboardingModules(_ mode: HeliosDashboardMode) -> String {
    switch mode {
    case .simple:
      "Menu bar: CPU + Temperature\nDashboard: Summary + Cooling\nFull Monitor: essentials"
    case .advanced:
      "Menu bar: CPU + Memory + Temperature\nDashboard: performance + network context\nFull Monitor: daily-use modules"
    case .all:
      "Menu bar: CPU + Memory + Temperature + Power\nDashboard: richer monitoring\nFull Monitor: every module + Expert"
    case .custom:
      "Start rich, then choose each menu-bar item, label/icon/value, dashboard module and Full Monitor section yourself"
    }
  }
}
