import Foundation

/// What a user cares about most. Chosen in the welcome flow and again in
/// Settings › General; a goal decides which samplers run (so Helios stays light),
/// what the menu bar shows and which popover sections and pages appear.
enum HeliosGoal: String, CaseIterable, Identifiable, Sendable {
  case cooling, battery, liveStats, apps, storage, network, simple

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cooling: "Keep my Mac cool"
    case .battery: "Look after my battery"
    case .liveStats: "Live stats in the menu bar"
    case .apps: "See what slows my Mac down"
    case .storage: "Watch my storage"
    case .network: "Keep an eye on my network"
    case .simple: "Just tell me if my Mac is OK"
    }
  }

  var detail: String {
    switch self {
    case .cooling: "Temperatures and fan control"
    case .battery: "Health, cycles and what drains it"
    case .liveStats: "CPU, memory, temperature and power at a glance"
    case .apps: "Which apps use CPU, memory and energy"
    case .storage: "Free space and SSD health"
    case .network: "Speed and Wi-Fi"
    case .simple: "A calm summary and nothing else"
    }
  }

  var symbol: String {
    switch self {
    case .cooling: "fan"
    case .battery: "battery.75percent"
    case .liveStats: "gauge.with.dots.needle.50percent"
    case .apps: "square.stack.3d.up"
    case .storage: "internaldrive"
    case .network: "network"
    case .simple: "checkmark.seal"
    }
  }

  /// Samplers this goal needs on top of the always-collected base.
  fileprivate var samplers: Set<HeliosTelemetryModule> {
    switch self {
    case .cooling: [.fans, .power]
    case .battery: [.power, .processes]
    case .liveStats: [.power]
    case .apps: [.processes, .power]
    case .storage: []
    case .network: [.network, .wifi]
    case .simple: []
    }
  }

  fileprivate var menuBarMetrics: Set<HeliosMenuBarMetric> {
    switch self {
    case .cooling: [.temperature]
    case .battery: [.battery]
    // The default bar: CPU, RAM, TEMP, PWR.
    case .liveStats: [.cpu, .memory, .temperature, .power]
    case .apps: [.cpu, .memory]
    case .storage: []
    case .network: [.network]
    case .simple: []
    }
  }

  fileprivate var popoverSections: Set<HeliosPopoverSection> {
    switch self {
    case .cooling: [.cooling]
    case .battery, .apps: [.processes]
    case .network: [.network]
    case .liveStats, .storage, .simple: []
    }
  }

  fileprivate var pages: Set<HeliosPage> {
    switch self {
    case .cooling: [.hardware]
    case .liveStats, .network: [.network]
    case .battery, .apps, .storage, .simple: []
    }
  }
}

/// What this Mac has, as far as Helios knows. `nil` means "not known yet": the
/// goal stays on offer rather than being hidden by a guess.
struct HeliosMacTraits: Equatable, Sendable {
  var hasFans: Bool?
  var hasBattery: Bool?

  static let unknown = HeliosMacTraits(hasFans: nil, hasBattery: nil)

  var offersCooling: Bool { hasFans != false }
  var offersBattery: Bool { hasBattery != false }

  /// "No fan · no battery" style note for the welcome page; empty while unknown.
  var note: String {
    var parts: [String] = []
    if hasFans == false { parts.append("no fan") }
    if hasBattery == false { parts.append("no battery") }
    return parts.joined(separator: " · ")
  }
}

extension HeliosGoal {
  func isAvailable(on traits: HeliosMacTraits) -> Bool {
    switch self {
    case .cooling: traits.offersCooling
    case .battery: traits.offersBattery
    default: true
    }
  }

  /// Goals offered on this Mac, in display order.
  static func available(on traits: HeliosMacTraits) -> [HeliosGoal] {
    allCases.filter { $0.isAvailable(on: traits) }
  }
}

/// The concrete configuration for a set of goals. Pure and deterministic.
struct HeliosGoalPlan: Equatable, Sendable {
  let menuBarMetrics: [HeliosMenuBarMetric]
  let samplers: [HeliosTelemetryModule]
  let popoverSections: [HeliosPopoverSection]
  let visiblePages: [HeliosPage]
  let wantsFanHelper: Bool

  /// The four health areas answer "Is my Mac OK?", so their samplers always run.
  static let baseSamplers: Set<HeliosTelemetryModule> = [.cpu, .memory, .battery, .storage]
  static let maximumMenuBarMetrics = 5

  /// What Helios suggests on this Mac: live stats, plus cooling where there is a fan.
  static func recommendedGoals(for traits: HeliosMacTraits) -> Set<HeliosGoal> {
    traits.hasFans == true ? [.liveStats, .cooling] : [.liveStats]
  }

  /// No goal selected behaves like "Just tell me if my Mac is OK". Goals that this
  /// Mac cannot serve (cooling without a fan, battery without one) are dropped.
  static func make(for goals: Set<HeliosGoal>, traits: HeliosMacTraits = .unknown) -> HeliosGoalPlan {
    let usable = goals.filter { $0.isAvailable(on: traits) }
    let effective: Set<HeliosGoal> = usable.isEmpty ? [.simple] : usable
    let samplers = effective.reduce(into: baseSamplers) { $0.formUnion($1.samplers) }
    var metrics = effective.reduce(into: Set<HeliosMenuBarMetric>()) { $0.formUnion($1.menuBarMetrics) }
    // On a Mac with a fan the temperature item carries the fan state above it.
    if traits.hasFans == true, metrics.remove(.temperature) != nil { metrics.insert(.cooling) }
    let sections = effective.reduce(into: Set<HeliosPopoverSection>()) { $0.formUnion($1.popoverSections) }
    var pages = effective.reduce(into: Set<HeliosPage>()) { $0.formUnion($1.pages) }
    pages.formUnion([.overview, .activity, .diagnostics, .cpu, .gpu, .memory, .thermals, .battery, .storage])
    if effective != [.simple] { pages.insert(.history) }
    return HeliosGoalPlan(
      menuBarMetrics: Array(HeliosMenuBarMetric.allCases.filter(metrics.contains).prefix(maximumMenuBarMetrics)),
      samplers: HeliosTelemetryModule.allCases.filter(samplers.contains),
      popoverSections: [HeliosPopoverSection.chart]
        + HeliosPopoverSection.allCases.filter { $0 != .chart && sections.contains($0) },
      visiblePages: HeliosPage.allCases.filter(pages.contains),
      wantsFanHelper: effective.contains(.cooling))
  }
}
