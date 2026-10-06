import Combine
import Foundation

/// Pages of the Helios main window, in sidebar order: the overview, then the
/// Mac's components (each with its live value, like Task Manager), then the
/// pages that explain what happened.
enum HeliosPage: String, CaseIterable, Identifiable, Sendable {
  case overview
  case cpu, gpu, memory, thermals, battery, energy, storage, network, hardware
  case activity, history, diagnostics

  enum Section: String, Sendable { case main, components, insights }

  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "Overview"
    case .activity: "Activity"
    case .history: "History"
    case .diagnostics: "Diagnostics"
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .memory: "Memory"
    case .thermals: "Thermals"
    case .battery: "Battery"
    case .energy: "Energy"
    case .storage: "Storage"
    case .network: "Network"
    case .hardware: "Hardware"
    }
  }
  var symbol: String {
    switch self {
    case .overview: "sun.max"
    case .activity: "list.bullet.rectangle"
    case .history: "chart.xyaxis.line"
    case .diagnostics: "stethoscope"
    case .cpu: "cpu"
    case .gpu: "square.stack.3d.up"
    case .memory: "memorychip"
    case .thermals: "thermometer.medium"
    case .battery: "battery.75percent"
    case .energy: "bolt.fill"
    case .storage: "internaldrive"
    case .network: "network"
    case .hardware: "laptopcomputer"
    }
  }
  var section: Section {
    switch self {
    case .overview: .main
    case .cpu, .gpu, .memory, .thermals, .battery, .energy, .storage, .network, .hardware: .components
    case .activity, .history, .diagnostics: .insights
    }
  }
  var area: HeliosArea? {
    switch self {
    case .cpu, .memory: .performance
    case .thermals: .thermals
    case .battery: .battery
    case .storage: .storage
    default: nil
    }
  }
  init(_ area: HeliosArea) {
    switch area {
    case .performance: self = .cpu
    case .thermals: self = .thermals
    case .battery: self = .battery
    case .storage: self = .storage
    }
  }

  /// Menu-bar metric popovers of the Legacy interface land on the matching page.
  init(legacyRoute route: HeliosMonitorRoute) {
    switch route {
    case .overview: self = .overview
    case .cpu, .processes: self = .cpu
    case .gpu: self = .gpu
    case .memory: self = .memory
    case .thermals: self = .thermals
    case .battery: self = .battery
    case .energy: self = .energy
    case .storage, .maintenance: self = .storage
    case .network: self = .network
    case .system, .devices, .expert: self = .hardware
    case .history: self = .history
    case .health: self = .diagnostics
    }
  }

  /// Closest Legacy route, used when the Legacy interface is active.
  var legacyRoute: HeliosMonitorRoute {
    switch self {
    case .overview: .overview
    case .activity, .history: .history
    case .diagnostics: .health
    case .cpu: .cpu
    case .gpu: .gpu
    case .memory: .memory
    case .thermals: .thermals
    case .battery: .battery
    case .energy: .energy
    case .storage: .storage
    case .network: .network
    case .hardware: .system
    }
  }

  /// What a visible page asks the shared collectors for (the same demand keys the Legacy interface uses).
  var detailDemand: TelemetryDetailDemand {
    switch self {
    case .overview, .cpu, .memory, .battery, .energy, .storage: .processes
    case .thermals: [.rawSensors, .processes]
    case .hardware: .devices
    case .gpu, .activity, .history, .diagnostics, .network: []
    }
  }
}

/// Modules below the fixed mini-Overview in the Helios menu-bar popover.
enum HeliosPopoverSection: String, CaseIterable, Identifiable, Sendable {
  case chart, processes, cooling, activity, network

  var id: String { rawValue }
  var title: String {
    switch self {
    case .chart: "Chart"
    case .processes: "Top processes"
    case .cooling: "Cooling"
    case .activity: "Recent activity"
    case .network: "Network"
    }
  }
  static let defaults: [HeliosPopoverSection] = [.chart, .processes, .cooling]
}

/// Interface choice and Helios-only presentation preferences. Kept separate from
/// HeliosPreferences so Helios UI edits never invalidate Legacy surfaces and the
/// Pure UI state: no collection policy.
@MainActor
final class HeliosInterfacePreferences: ObservableObject {
  enum Style: String, CaseIterable, Identifiable, Sendable {
    case helios, legacy
    var id: String { rawValue }
  }

  @Published var style: Style { didSet { defaults.set(style.rawValue, forKey: Self.styleKey) } }
  /// nil = Automatic (CPU, or the metric of the area that needs attention).
  @Published var overviewChartMetric: HeliosChartMetric? {
    didSet { defaults.set(overviewChartMetric?.rawValue, forKey: Self.chartMetricKey) }
  }
  @Published private(set) var hiddenPages: Set<HeliosPage>
  @Published private(set) var popoverSections: [HeliosPopoverSection]
  /// What the user said they care about (welcome flow / Settings › General).
  @Published private(set) var goals: Set<HeliosGoal>
  @Published private(set) var diagnosticsReminderDismissed: Bool
  /// When this install first ran the Helios interface; the diagnostics reminder
  /// waits a week from here. Stored once and never rewritten.
  let firstSeen: Date

  private let defaults: UserDefaults
  static let styleKey = "v2.ui.interfaceStyle"
  static let chartMetricKey = "v2.ui.overviewChartMetric"
  static let hiddenPagesKey = "v2.ui.hiddenPages"
  static let popoverSectionsKey = "v2.ui.popoverSections"
  static let goalsKey = "v2.ui.goals"
  static let firstSeenKey = "v2.ui.firstSeen"
  static let diagnosticsReminderKey = "v2.ui.diagnosticsReminderDismissed"
  static let diagnosticsReminderDelay: TimeInterval = 7 * 24 * 60 * 60

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    style = defaults.string(forKey: Self.styleKey).flatMap(Style.init(rawValue:)) ?? .helios
    overviewChartMetric = defaults.string(forKey: Self.chartMetricKey)
      .flatMap(HeliosChartMetric.init(rawValue:))
    // The old single "performance" page was split; hiding it hides its three successors.
    let hidden = (defaults.stringArray(forKey: Self.hiddenPagesKey) ?? [])
      .flatMap { $0 == "performance" ? [.cpu, .gpu, .memory] : [HeliosPage(rawValue: $0)].compactMap { $0 } }
    // Overview is the home page and can never be hidden.
    hiddenPages = Set(hidden).subtracting([.overview])
    goals = Set((defaults.stringArray(forKey: Self.goalsKey) ?? []).compactMap(HeliosGoal.init(rawValue:)))
    diagnosticsReminderDismissed = defaults.bool(forKey: Self.diagnosticsReminderKey)
    if let stored = defaults.object(forKey: Self.firstSeenKey) as? Date {
      firstSeen = stored
    } else {
      firstSeen = Date()
      defaults.set(firstSeen, forKey: Self.firstSeenKey)
    }
    if let stored = defaults.stringArray(forKey: Self.popoverSectionsKey) {
      var seen = Set<HeliosPopoverSection>()
      popoverSections = stored.compactMap(HeliosPopoverSection.init(rawValue:))
        .filter { seen.insert($0).inserted }
    } else {
      popoverSections = HeliosPopoverSection.defaults
    }
  }

  var visiblePages: [HeliosPage] { HeliosPage.allCases.filter { !hiddenPages.contains($0) } }

  func setPage(_ page: HeliosPage, visible: Bool) {
    guard page != .overview else { return }
    if visible { hiddenPages.remove(page) } else { hiddenPages.insert(page) }
    defaults.set(HeliosPage.allCases.filter(hiddenPages.contains).map(\.rawValue),
      forKey: Self.hiddenPagesKey)
  }

  func isPopoverSectionEnabled(_ section: HeliosPopoverSection) -> Bool {
    popoverSections.contains(section)
  }

  func setPopoverSection(_ section: HeliosPopoverSection, enabled: Bool) {
    if enabled {
      guard !popoverSections.contains(section) else { return }
      popoverSections.append(section)
    } else {
      popoverSections.removeAll { $0 == section }
    }
    persistPopoverSections()
  }

  func movePopoverSection(_ section: HeliosPopoverSection, by offset: Int) {
    guard let index = popoverSections.firstIndex(of: section) else { return }
    let target = min(popoverSections.count - 1, max(0, index + offset))
    guard target != index else { return }
    popoverSections.remove(at: index)
    popoverSections.insert(section, at: target)
    persistPopoverSections()
  }

  /// One calm reminder, a week after first use, for people who have not shared
  /// diagnostics. Dismissing it is permanent.
  func shouldShowDiagnosticsReminder(sharingDiagnostics: Bool, now: Date = Date()) -> Bool {
    !sharingDiagnostics && !diagnosticsReminderDismissed
      && now.timeIntervalSince(firstSeen) >= Self.diagnosticsReminderDelay
  }

  func dismissDiagnosticsReminder() {
    diagnosticsReminderDismissed = true
    defaults.set(true, forKey: Self.diagnosticsReminderKey)
  }

  /// Applies the sidebar pages and popover sections of a goal plan.
  func apply(_ plan: HeliosGoalPlan, goals chosen: Set<HeliosGoal>) {
    goals = chosen
    hiddenPages = Set(HeliosPage.allCases).subtracting(plan.visiblePages).subtracting([.overview])
    popoverSections = plan.popoverSections
    defaults.set(chosen.map(\.rawValue).sorted(), forKey: Self.goalsKey)
    defaults.set(HeliosPage.allCases.filter(hiddenPages.contains).map(\.rawValue), forKey: Self.hiddenPagesKey)
    persistPopoverSections()
  }

  /// Restores Helios layout preferences; the interface choice itself is kept.
  func resetLayout() {
    overviewChartMetric = nil
    hiddenPages = []
    popoverSections = HeliosPopoverSection.defaults
    defaults.removeObject(forKey: Self.hiddenPagesKey)
    persistPopoverSections()
  }

  private func persistPopoverSections() {
    defaults.set(popoverSections.map(\.rawValue), forKey: Self.popoverSectionsKey)
  }
}
