import Combine
import Foundation

/// Pages of the Helios main window, in sidebar order: the overview, then the
/// Mac's components (each with its live value, like Task Manager), then the
/// pages that explain what happened.
enum HeliosPage: String, CaseIterable, Identifiable, Sendable {
  case overview
  case cpu, gpu, memory, thermals, battery, energy, storage, network, hardware
  case longevity, activity, history, diagnostics

  enum Section: String, Sendable { case main, components, insights }

  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "Overview"
    case .longevity: "Longevity"
    case .activity: "Activity"
    case .history: "History"
    case .diagnostics: "Checkup"
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
    case .longevity: "heart.text.square"
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
    case .longevity, .activity, .history, .diagnostics: .insights
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

  /// What a visible page asks the shared collectors for.
  var detailDemand: TelemetryDetailDemand {
    switch self {
    case .overview, .cpu, .memory, .battery, .energy, .storage: .processes
    case .longevity: []
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

/// Helios presentation preferences, kept separate from HeliosPreferences so UI
/// edits do not invalidate everything observing it. Pure UI state: no collection policy.
@MainActor
final class HeliosInterfacePreferences: ObservableObject {
  /// The Legacy (0.1) interface was retired in 0.3.0 (PLAN_0_3_0 decision 3); a stored
  /// "legacy" choice loads as Helios and is rewritten.
  enum Style: String, CaseIterable, Identifiable, Sendable {
    case helios
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
  /// Set once Beta 1's hidden-Longevity mistake has been undone for this install.
  static let longevityRevealedKey = "v3.ui.longevityRevealed"
  static let diagnosticsReminderDelay: TimeInterval = 7 * 24 * 60 * 60

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    style = defaults.string(forKey: Self.styleKey).flatMap(Style.init(rawValue:)) ?? .helios
    if defaults.string(forKey: Self.styleKey) != nil, defaults.string(forKey: Self.styleKey) != Style.helios.rawValue {
      defaults.set(Style.helios.rawValue, forKey: Self.styleKey)
    }
    overviewChartMetric = defaults.string(forKey: Self.chartMetricKey)
      .flatMap(HeliosChartMetric.init(rawValue:))
    // The old single "performance" page was split; hiding it hides its three successors.
    let hidden = (defaults.stringArray(forKey: Self.hiddenPagesKey) ?? [])
      .flatMap { $0 == "performance" ? [.cpu, .gpu, .memory] : [HeliosPage(rawValue: $0)].compactMap { $0 } }
    // Overview is the home page and can never be hidden.
    var hiddenSet = Set(hidden).subtracting([.overview])
    // 0.3.0 Beta 1 hid Longevity for everyone who finished the welcome or applied goals.
    // Show it once more; hiding it again afterwards is the person's own choice.
    if !defaults.bool(forKey: Self.longevityRevealedKey) {
      if hiddenSet.remove(.longevity) != nil {
        defaults.set(HeliosPage.allCases.filter(hiddenSet.contains).map(\.rawValue), forKey: Self.hiddenPagesKey)
      }
      defaults.set(true, forKey: Self.longevityRevealedKey)
    }
    hiddenPages = hiddenSet
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
