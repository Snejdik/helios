import Combine
import Foundation

/// UI-only preferences for Next23. These settings never alter privileged fan
/// capabilities, battery policy, or the telemetry write surface.
enum HeliosDashboardMode: String, CaseIterable, Identifiable, Sendable {
  case simple
  case advanced
  case all
  case custom

  var id: String { rawValue }

  var label: String {
    switch self {
    case .simple: "Simple"
    case .advanced: "Recommended"
    case .all: "Detailed"
    case .custom: "Custom"
    }
  }

  var onboardingTitle: String {
    switch self {
    case .simple: "Simple"
    case .advanced: "Recommended"
    case .all: "Detailed"
    case .custom: "Custom"
    }
  }

  var onboardingDetail: String {
    switch self {
    case .simple:
      "Core health, temperature, battery and safe cooling controls. Best if you want Helios to stay out of the way."
    case .advanced:
      "Adds performance, network and top-process context without turning the popover into a diagnostic console."
    case .all:
      "Shows richer monitoring, more context and the complete Full Monitor while keeping the menu bar readable."
    case .custom:
      "Start from a complete, safe canvas and decide exactly which menu-bar metrics, popups and Full Monitor modules you want."
    }
  }
}

enum HeliosDashboardMetric: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case gpu
  case temperature
  case battery
  case energy
  case power

  var id: String { rawValue }

  var label: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .gpu: "GPU"
    case .temperature: "Temperature"
    case .battery: "Battery"
    case .energy: "Energy"
    case .power: "System Power"
    }
  }

  var symbolName: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .gpu: "display"
    case .temperature: "thermometer.medium"
    case .battery: "battery.75percent"
    case .energy: "chart.bar.xaxis"
    case .power: "bolt.fill"
    }
  }
}

enum HeliosColorRole: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case gpu
  case temperature
  case fan
  case battery
  case power
  case energy
  case storageRead
  case storageWrite
  case networkDownload
  case networkUpload
  case memoryApp
  case memoryWired
  case memoryCompressed
  case memoryCache
  case swap
  case memoryAvailable

  var id: String { rawValue }

  var label: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .gpu: "GPU"
    case .temperature: "Temperature"
    case .fan: "Fan"
    case .battery: "Battery"
    case .power: "System power"
    case .energy: "Energy attribution"
    case .storageRead: "Storage read"
    case .storageWrite: "Storage write"
    case .networkDownload: "Network download"
    case .networkUpload: "Network upload"
    case .memoryApp: "App memory"
    case .memoryWired: "Wired memory"
    case .memoryCompressed: "Compressed memory"
    case .memoryCache: "Reclaimable cache"
    case .swap: "Swap"
    case .memoryAvailable: "Available memory"
    }
  }

  var defaultHex: String {
    switch self {
    case .cpu: "#0A84FFFF"
    case .memory: "#BF5AF2FF"
    case .gpu: "#64D2FFFF"
    case .temperature: "#FF9F0AFF"
    case .fan: "#5AC8FAFF"
    case .battery: "#30D158FF"
    case .power: "#FFD60AFF"
    case .energy: "#30D158FF"
    case .storageRead: "#AF52DEFF"
    case .storageWrite: "#FF375FFF"
    case .networkDownload: "#0A84FFFF"
    case .networkUpload: "#30D158FF"
    case .memoryApp: "#0A84FFFF"
    case .memoryWired: "#BF5AF2FF"
    case .memoryCompressed: "#FF375FFF"
    case .memoryCache: "#64D2FFFF"
    case .swap: "#FF9F0AFF"
    case .memoryAvailable: "#30D158B8"
    }
  }

  var group: String {
    switch self {
    case .memoryApp, .memoryWired, .memoryCompressed, .memoryCache, .swap, .memoryAvailable:
      "Memory breakdown"
    case .networkDownload, .networkUpload:
      "Network"
    default:
      "Modules"
    }
  }
}

enum HeliosPopoverModule: String, CaseIterable, Identifiable, Sendable {
  case summary
  case cooling
  case performance
  case network
  case topCPU
  case system
  case energy
  case alerts

  var id: String { rawValue }

  var label: String {
    switch self {
    case .summary: "System summary"
    case .cooling: "Temperature & Fan"
    case .performance: "Performance"
    case .network: "Network"
    case .topCPU: "Top processes"
    case .system: "System status"
    case .energy: "Energy"
    case .alerts: "Health & Alerts"
    }
  }

  var symbolName: String {
    switch self {
    case .summary: "square.grid.2x2"
    case .cooling: "fan"
    case .performance: "gauge.with.dots.needle.50percent"
    case .network: "network"
    case .topCPU: "list.bullet.rectangle"
    case .system: "desktopcomputer"
    case .energy: "chart.bar.xaxis"
    case .alerts: "exclamationmark.shield"
    }
  }
}

enum HeliosMenuBarIdentityStyle: String, CaseIterable, Identifiable, Sendable {
  case label
  case symbol
  case valueOnly

  var id: String { rawValue }

  var label: String {
    switch self {
    case .label: "Labels"
    case .symbol: "Symbols"
    case .valueOnly: "Values only"
    }
  }

  var detail: String {
    switch self {
    case .label: "Show CPU, RAM, GPU and other short text labels above each value."
    case .symbol: "Use compact SF Symbols above each value."
    case .valueOnly: "Show only the live value for the cleanest possible menu bar."
    }
  }
}

struct HeliosMenuBarContent: Equatable, Sendable {
  var showIcon: Bool
  var showLabel: Bool
  var showValue: Bool

  static let labelAndValue = Self(showIcon: false, showLabel: true, showValue: true)
  static let iconAndValue = Self(showIcon: true, showLabel: false, showValue: true)
  static let valueOnly = Self(showIcon: false, showLabel: false, showValue: true)

  init(showIcon: Bool, showLabel: Bool, showValue: Bool) {
    self.showIcon = showIcon
    self.showLabel = showLabel
    self.showValue = showValue
    normalize()
  }

  init(legacy style: HeliosMenuBarIdentityStyle) {
    switch style {
    case .label: self = .labelAndValue
    case .symbol: self = .iconAndValue
    case .valueOnly: self = .valueOnly
    }
  }

  init(bitMask: Int, fallback: HeliosMenuBarContent) {
    guard (1...7).contains(bitMask) else {
      self = fallback
      return
    }
    self.init(
      showIcon: bitMask & 1 != 0,
      showLabel: bitMask & 2 != 0,
      showValue: bitMask & 4 != 0)
  }

  var bitMask: Int {
    (showIcon ? 1 : 0) | (showLabel ? 2 : 0) | (showValue ? 4 : 0)
  }

  mutating func normalize() {
    // A metric that renders literally nothing is a confusing invisible click
    // target. Keep the live value as the safe recovery surface.
    if !showIcon && !showLabel && !showValue { showValue = true }
  }
}

enum HeliosMenuBarLayout: String, CaseIterable, Identifiable, Sendable {
  case nativeModules
  case compactGroup

  var id: String { rawValue }
  var label: String {
    switch self {
    case .nativeModules: "Separate macOS modules"
    case .compactGroup: "Single compact group"
    }
  }
  var detail: String {
    switch self {
    case .nativeModules:
      "Each metric is its own macOS status item with an independent click target and metric popup. The Helios hub icon is optional."
    case .compactGroup:
      "All selected metrics share one compact Helios status item. Clicking anywhere in the group opens the Dashboard, so a separate hub icon is not needed."
    }
  }
}

enum HeliosGraphLineStyle: String, CaseIterable, Identifiable, Sendable {
  case smooth
  case raw

  var id: String { rawValue }
  var label: String { self == .smooth ? "Smooth" : "Raw" }
}

enum HeliosGraphRange: String, CaseIterable, Identifiable, Sendable {
  case oneMinute
  case fiveMinutes
  case fifteenMinutes
  case oneHour
  case sixHours
  case twentyFourHours

  var id: String { rawValue }
  var seconds: TimeInterval {
    switch self {
    case .oneMinute: 60
    case .fiveMinutes: 5 * 60
    case .fifteenMinutes: 15 * 60
    case .oneHour: 60 * 60
    case .sixHours: 6 * 60 * 60
    case .twentyFourHours: 24 * 60 * 60
    }
  }
  var label: String {
    switch self {
    case .oneMinute: "1m"
    case .fiveMinutes: "5m"
    case .fifteenMinutes: "15m"
    case .oneHour: "1h"
    case .sixHours: "6h"
    case .twentyFourHours: "24h"
    }
  }

  var menuLabel: String {
    switch self {
    case .oneMinute: "1 min"
    case .fiveMinutes: "5 min"
    case .fifteenMinutes: "15 min"
    case .oneHour: "1 hour"
    case .sixHours: "6 hours"
    case .twentyFourHours: "24 hours"
    }
  }
}

enum HeliosGraphScope: String, CaseIterable, Identifiable, Sendable {
  case overview
  case cpu
  case memory
  case gpu
  case thermals
  case battery
  case energy
  case power
  case storage
  case network
  case history

  var id: String { rawValue }
}

enum HeliosMenuBarMetric: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case gpu
  case temperature
  case cooling
  case fan
  case battery
  case power
  case network

  var id: String { rawValue }

  var label: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .gpu: "GPU"
    case .temperature: "Temperature"
    case .cooling: "Temperature & Fan"
    case .fan: "Fan"
    case .battery: "Battery"
    case .power: "System Power"
    case .network: "Network"
    }
  }

  var shortLabel: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "RAM"
    case .gpu: "GPU"
    case .temperature: "TEMP"
    case .cooling: "T/F"
    case .fan: "FAN"
    case .battery: "BAT"
    case .power: "PWR"
    case .network: "NET"
    }
  }

  var symbolName: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .gpu: "display"
    case .temperature: "thermometer.medium"
    case .cooling: "thermometer.medium"
    case .fan: "fan"
    case .battery: "battery.75percent"
    case .power: "bolt.fill"
    case .network: "arrow.down.arrow.up"
    }
  }

  /// Fixed per-module geometry. The status item may change width when the user
  /// changes modules, but never jitters in response to live text values.
  var statusWidth: Double {
    switch self {
    // Keep the common two-line modules on one optical grid. Unequal slot
    // widths made CPU / RAM / TEMP look randomly spaced even though each item
    // was individually centered. Wider content keeps a wider fixed slot, but
    // live telemetry still never changes geometry.
    case .cpu, .memory, .gpu, .temperature: 28
    case .battery, .power: 31
    case .cooling: 56
    case .fan: 34
    case .network: 38
    }
  }
}

@MainActor
final class HeliosPreferences: ObservableObject {
  static let defaultMenuBarMetrics: [HeliosMenuBarMetric] = [.cpu, .temperature]
  static let simplePopoverModules: [HeliosPopoverModule] = [.summary, .cooling]
  static let simpleDashboardMetrics: [HeliosDashboardMetric] = [.cpu, .temperature, .battery]
  static let advancedDashboardMetrics: [HeliosDashboardMetric] = [
    .cpu, .memory, .temperature, .battery,
  ]
  static let allDashboardMetrics: [HeliosDashboardMetric] = HeliosDashboardMetric.allCases
  static let advancedPopoverModules: [HeliosPopoverModule] = [
    .summary, .cooling, .performance, .network, .topCPU, .energy, .alerts,
  ]
  static let allPopoverModules: [HeliosPopoverModule] = [
    .summary, .cooling, .performance, .network, .topCPU, .energy, .alerts, .system,
  ]
  static let simpleTelemetryModules: [HeliosTelemetryModule] = [
    .cpu, .memory, .power, .battery, .fans,
  ]
  static let recommendedTelemetryModules: [HeliosTelemetryModule] = [
    .cpu, .memory, .gpu, .power, .network, .processes, .battery, .storage, .fans,
  ]
  static let detailedTelemetryModules: [HeliosTelemetryModule] = HeliosTelemetryModule.allCases

  @Published private(set) var menuBarMetrics: [HeliosMenuBarMetric]
  @Published private(set) var popoverModules: [HeliosPopoverModule]
  @Published private(set) var dashboardMetrics: [HeliosDashboardMetric]
  @Published private(set) var monitorRoutes: [HeliosMonitorRoute]
  @Published var dashboardMode: HeliosDashboardMode { didSet { persist() } }
  @Published var compactCards: Bool { didSet { persist() } }
  /// Legacy/global identity is kept as the fallback for migrated UI7 installs.
  @Published var menuBarIdentityStyle: HeliosMenuBarIdentityStyle { didSet { persist() } }
  @Published var menuBarLayout: HeliosMenuBarLayout { didSet { persist() } }
  @Published var showMenuBarHub: Bool { didSet { persist() } }
  @Published var graphLineStyle: HeliosGraphLineStyle { didSet { persist() } }
  @Published var animateGraphUpdates: Bool { didSet { persist() } }
  /// By default the memory gauge leaves reclaimable/available physical memory as
  /// the neutral track. Users who prefer a fully segmented ring can opt into a
  /// muted Available segment without changing the underlying accounting.
  @Published var memoryGaugeShowsAvailable: Bool { didSet { persist() } }
  @Published var detailedMonitorContent: Bool { didSet { persist() } }
  /// Visual density for native menu-bar metric items. This changes configured
  /// geometry only when the user moves the slider; live telemetry never resizes
  /// an item and therefore cannot make the menu bar jitter.
  @Published var menuBarSpacing: Double { didSet { persist() } }
  /// Cooling control is an optional write surface. Disabling it hides helper-facing
  /// controls but does not implicitly disable the independent read-only fan RPM
  /// collector. Trusted thermal safety sampling remains available and the
  /// privileged helper contract itself stays fan-only.
  @Published var coolingFeaturesEnabled: Bool { didSet { persist() } }
  @Published private(set) var telemetryModules: [HeliosTelemetryModule]
  @Published var graphRange: HeliosGraphRange { didSet { persist() } }
  @Published private(set) var onboardingCompleted: Bool
  @Published private(set) var fanSafetyGuideCompleted: Bool

  private var metricIdentityStyles: [HeliosMenuBarMetric: HeliosMenuBarIdentityStyle]
  private var metricContent: [HeliosMenuBarMetric: HeliosMenuBarContent]
  private var metricLabels: [HeliosMenuBarMetric: String]
  private var graphRanges: [HeliosGraphScope: HeliosGraphRange]
  private var colorHexValues: [HeliosColorRole: String]

  private let defaults: UserDefaults
  /// Structural manual edits move the global interface preset to Custom. Preset
  /// application suppresses this so one preset can update several surfaces
  /// atomically without immediately relabelling itself as Custom.
  private var applyingInterfacePreset = false
  private static let menuBarKey = "next23.ui.menuBarMetrics"
  private static let popoverModulesKey = "next23.ui.popoverModules"
  private static let dashboardMetricsKey = "next23.ui10.dashboardMetrics"
  private static let monitorRoutesKey = "next23.ui.monitorRoutes"
  private static let dashboardKey = "next23.ui.dashboardMode"
  private static let compactKey = "next23.ui.compactCards"
  private static let symbolsKey = "next23.ui.menuBarSymbols"  // legacy UI6 migration key
  private static let identityStyleKey = "next23.ui.menuBarIdentityStyle"
  private static let menuBarLayoutKey = "next23.ui8.menuBarLayout"
  private static let menuBarHubKey = "next23.ui8.showMenuBarHub"
  private static let metricIdentityKey = "next23.ui8.metricIdentityStyles"
  private static let metricContentKey = "next23.ui9.metricContent"
  private static let metricLabelsKey = "next23.ui8.metricLabels"
  private static let graphLineStyleKey = "next23.ui8.graphLineStyle"
  private static let graphAnimateKey = "next23.ui8.animateGraphUpdates"
  private static let memoryGaugeAvailableKey = "next23.ui9.memoryGaugeShowsAvailable"
  private static let detailedMonitorKey = "next23.ui10.detailedMonitorContent"
  private static let menuBarSpacingKey = "next23.ui10.menuBarSpacing"
  private static let coolingFeaturesKey = "next23.ui10.coolingFeaturesEnabled"
  private static let telemetryModulesKey = "next23.ui10.telemetryModules"
  private static let fanSafetyGuideKey = "next23.ui10.fanSafetyGuideCompleted"
  private static let colorHexValuesKey = "next23.ui10.colorHexValues"
  private static let graphRangeKey = "next23.ui8.graphRange"
  private static let graphRangesKey = "next23.ui8.graphRanges"
  private static let onboardingKey = "next23.ui.onboardingCompleted"
  private static let schemaVersionKey = "next23.ui.schemaVersion"
  private static let currentSchemaVersion = 12

  init(defaults: UserDefaults = .standard) {
    // Resolve every persisted value into locals before assigning any stored
    // property. Swift does not allow reading `self` until all stored
    // properties have been initialized, and @Published properties still
    // participate in that rule.
    let hasStoredMenuBar = defaults.object(forKey: Self.menuBarKey) != nil
    let storedMenuBar = defaults.stringArray(forKey: Self.menuBarKey) ?? []
    let decodedMenuBar = storedMenuBar.compactMap(HeliosMenuBarMetric.init(rawValue:))
    let uniqueMenuBar = Self.unique(decodedMenuBar)
    let resolvedMenuBarMetrics: [HeliosMenuBarMetric]
    if !hasStoredMenuBar || (!storedMenuBar.isEmpty && uniqueMenuBar.isEmpty) {
      resolvedMenuBarMetrics = Self.defaultMenuBarMetrics
    } else {
      resolvedMenuBarMetrics = uniqueMenuBar
    }

    let resolvedDashboardMode =
      defaults.string(forKey: Self.dashboardKey).flatMap(HeliosDashboardMode.init(rawValue:))
      ?? .simple

    let hasStoredPopover = defaults.object(forKey: Self.popoverModulesKey) != nil
    let storedPopover = defaults.stringArray(forKey: Self.popoverModulesKey) ?? []
    let decodedPopover = storedPopover.compactMap(HeliosPopoverModule.init(rawValue:))
    let uniquePopover = Self.unique(decodedPopover)
    let resolvedPopoverModules: [HeliosPopoverModule]
    if !hasStoredPopover || (!storedPopover.isEmpty && uniquePopover.isEmpty) {
      resolvedPopoverModules = Self.modules(for: resolvedDashboardMode)
    } else {
      resolvedPopoverModules = uniquePopover
    }

    let hasStoredDashboardMetrics = defaults.object(forKey: Self.dashboardMetricsKey) != nil
    let storedDashboardMetrics = defaults.stringArray(forKey: Self.dashboardMetricsKey) ?? []
    let decodedDashboardMetrics = storedDashboardMetrics.compactMap(
      HeliosDashboardMetric.init(rawValue:))
    let uniqueDashboardMetrics = Self.unique(decodedDashboardMetrics)
    let resolvedDashboardMetrics: [HeliosDashboardMetric]
    if !hasStoredDashboardMetrics
      || (!storedDashboardMetrics.isEmpty && uniqueDashboardMetrics.isEmpty)
    {
      resolvedDashboardMetrics = Self.dashboardMetrics(for: resolvedDashboardMode)
    } else {
      resolvedDashboardMetrics = uniqueDashboardMetrics
    }

    let hasStoredMonitorRoutes = defaults.object(forKey: Self.monitorRoutesKey) != nil
    let storedMonitorRoutes = defaults.stringArray(forKey: Self.monitorRoutesKey) ?? []
    let decodedMonitorRoutes = storedMonitorRoutes.compactMap(HeliosMonitorRoute.init(rawValue:))
    let uniqueMonitorRoutes = Self.unique(decodedMonitorRoutes)
    var resolvedMonitorRoutes: [HeliosMonitorRoute]
    var monitorRoutesChangedByMigration = false
    if !hasStoredMonitorRoutes || (!storedMonitorRoutes.isEmpty && uniqueMonitorRoutes.isEmpty) {
      // Existing installs keep the full monitor intact until the user explicitly
      // chooses a preset or customizes the sidebar.
      resolvedMonitorRoutes = HeliosMonitorRoute.allCases
    } else {
      resolvedMonitorRoutes = Self.normalizedMonitorRoutes(uniqueMonitorRoutes)
    }
    // UI10 promoted Energy to a first-class route. Older persisted arrays could
    // not contain it, so migrate it once instead of silently hiding a new feature
    // forever. Later explicit user customization is respected.
    let storedSchemaVersion = defaults.integer(forKey: Self.schemaVersionKey)
    if storedSchemaVersion < 11,
      hasStoredMonitorRoutes,
      !resolvedMonitorRoutes.contains(.energy)
    {
      if let batteryIndex = resolvedMonitorRoutes.firstIndex(of: .battery) {
        resolvedMonitorRoutes.insert(
          .energy, at: min(resolvedMonitorRoutes.endIndex, batteryIndex + 1))
      } else {
        resolvedMonitorRoutes.append(.energy)
      }
      resolvedMonitorRoutes = Self.normalizedMonitorRoutes(resolvedMonitorRoutes)
      monitorRoutesChangedByMigration = true
    }

    // RC1–RC3 briefly coupled collection with presentation and could delete a
    // Full Monitor route when its sampler was toggled off. RC4 separates those
    // concepts. Prefer surviving presentation evidence, then use the still-enabled
    // sampler as a one-time development fallback for routes that RC3 could delete
    // from every presentation surface at once. This repairs the damaged RC state
    // without changing future collection-toggle behavior.
    if storedSchemaVersion == 11, hasStoredMonitorRoutes {
      let storedTelemetryForRepair = Set(
        defaults.stringArray(forKey: Self.telemetryModulesKey) ?? [])
      let recoverableRoutes: [(HeliosMonitorRoute, Bool)] = [
        (
          .cpu,
          resolvedMenuBarMetrics.contains(.cpu) || resolvedDashboardMetrics.contains(.cpu)
            || storedTelemetryForRepair.contains(HeliosTelemetryModule.cpu.rawValue)
        ),
        (
          .memory,
          resolvedMenuBarMetrics.contains(.memory) || resolvedDashboardMetrics.contains(.memory)
            || storedTelemetryForRepair.contains(HeliosTelemetryModule.memory.rawValue)
        ),
        (
          .gpu,
          resolvedMenuBarMetrics.contains(.gpu) || resolvedDashboardMetrics.contains(.gpu)
            || storedTelemetryForRepair.contains(HeliosTelemetryModule.gpu.rawValue)
        ),
        (
          .battery,
          resolvedMenuBarMetrics.contains(.battery) || resolvedDashboardMetrics.contains(.battery)
            || storedTelemetryForRepair.contains(HeliosTelemetryModule.battery.rawValue)
        ),
        (
          .network,
          resolvedMenuBarMetrics.contains(.network) || resolvedPopoverModules.contains(.network)
            || storedTelemetryForRepair.contains(HeliosTelemetryModule.network.rawValue)
        ),
        (
          .processes,
          resolvedPopoverModules.contains(.topCPU)
            || storedTelemetryForRepair.contains(HeliosTelemetryModule.processes.rawValue)
        ),
        (.storage, storedTelemetryForRepair.contains(HeliosTelemetryModule.storage.rawValue)),
        (.devices, storedTelemetryForRepair.contains(HeliosTelemetryModule.devices.rawValue)),
      ]
      for (route, shouldRecover) in recoverableRoutes
      where shouldRecover && !resolvedMonitorRoutes.contains(route) {
        resolvedMonitorRoutes = Self.insertingMonitorRoute(route, into: resolvedMonitorRoutes)
        monitorRoutesChangedByMigration = true
      }
    }

    let resolvedCompactCards = defaults.object(forKey: Self.compactKey) as? Bool ?? false
    let resolvedMenuBarIdentityStyle =
      defaults.string(forKey: Self.identityStyleKey).flatMap(
        HeliosMenuBarIdentityStyle.init(rawValue:))
      // UI7 intentionally adopts text labels as the fresh-install/upgrade
      // default when the richer identity preference has never been stored. The
      // legacy UI6 boolean is still written for rollback compatibility only.
      ?? .label
    let resolvedMenuBarLayout =
      defaults.string(forKey: Self.menuBarLayoutKey).flatMap(HeliosMenuBarLayout.init(rawValue:))
      ?? .nativeModules
    let resolvedCoolingFeaturesEnabled =
      defaults.object(forKey: Self.coolingFeaturesKey) as? Bool ?? true
    let storedShowMenuBarHub = defaults.object(forKey: Self.menuBarHubKey) as? Bool ?? true
    let visibleMenuBarMetrics = resolvedMenuBarMetrics.filter {
      resolvedCoolingFeaturesEnabled || ($0 != .fan && $0 != .cooling)
    }
    let resolvedShowMenuBarHub =
      resolvedMenuBarLayout == .nativeModules && visibleMenuBarMetrics.isEmpty
      ? true : storedShowMenuBarHub
    let resolvedGraphLineStyle =
      defaults.string(forKey: Self.graphLineStyleKey).flatMap(HeliosGraphLineStyle.init(rawValue:))
      ?? .smooth
    let resolvedAnimateGraphUpdates =
      defaults.object(forKey: Self.graphAnimateKey) as? Bool ?? true
    let resolvedMemoryGaugeShowsAvailable =
      defaults.object(forKey: Self.memoryGaugeAvailableKey) as? Bool ?? false
    let resolvedDetailedMonitorContent =
      defaults.object(forKey: Self.detailedMonitorKey) as? Bool
      ?? (resolvedDashboardMode == .all || resolvedDashboardMode == .custom)
    let resolvedMenuBarSpacing = min(
      8, max(0, defaults.object(forKey: Self.menuBarSpacingKey) as? Double ?? 2))

    let hasStoredTelemetryModules = defaults.object(forKey: Self.telemetryModulesKey) != nil
    let storedTelemetryModules = defaults.stringArray(forKey: Self.telemetryModulesKey) ?? []
    let decodedTelemetryModules = Self.unique(
      storedTelemetryModules.compactMap(HeliosTelemetryModule.init(rawValue:)))
    let resolvedTelemetryModules: [HeliosTelemetryModule]
    if !hasStoredTelemetryModules
      || (!storedTelemetryModules.isEmpty && decodedTelemetryModules.isEmpty)
    {
      resolvedTelemetryModules = Self.telemetryModules(for: resolvedDashboardMode)
    } else {
      resolvedTelemetryModules = decodedTelemetryModules
    }

    let resolvedGraphRange =
      defaults.string(forKey: Self.graphRangeKey).flatMap(HeliosGraphRange.init(rawValue:))
      ?? .fiveMinutes
    let storedGraphRanges =
      defaults.dictionary(forKey: Self.graphRangesKey) as? [String: String] ?? [:]
    var resolvedGraphRanges: [HeliosGraphScope: HeliosGraphRange] = [:]
    for scope in HeliosGraphScope.allCases {
      resolvedGraphRanges[scope] =
        storedGraphRanges[scope.rawValue].flatMap(HeliosGraphRange.init(rawValue:))
        ?? resolvedGraphRange
    }

    let storedIdentity =
      defaults.dictionary(forKey: Self.metricIdentityKey) as? [String: String] ?? [:]
    var resolvedMetricIdentity: [HeliosMenuBarMetric: HeliosMenuBarIdentityStyle] = [:]
    for metric in HeliosMenuBarMetric.allCases {
      resolvedMetricIdentity[metric] =
        storedIdentity[metric.rawValue].flatMap(HeliosMenuBarIdentityStyle.init(rawValue:))
        ?? resolvedMenuBarIdentityStyle
    }
    let storedContent = defaults.dictionary(forKey: Self.metricContentKey) ?? [:]
    var resolvedMetricContent: [HeliosMenuBarMetric: HeliosMenuBarContent] = [:]
    for metric in HeliosMenuBarMetric.allCases {
      let fallback = HeliosMenuBarContent(legacy: resolvedMetricIdentity[metric] ?? .label)
      let mask = (storedContent[metric.rawValue] as? NSNumber)?.intValue
      resolvedMetricContent[metric] =
        mask.map { HeliosMenuBarContent(bitMask: $0, fallback: fallback) } ?? fallback
    }

    let storedLabels = defaults.dictionary(forKey: Self.metricLabelsKey) as? [String: String] ?? [:]
    var resolvedMetricLabels: [HeliosMenuBarMetric: String] = [:]
    for metric in HeliosMenuBarMetric.allCases {
      let candidate =
        storedLabels[metric.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      resolvedMetricLabels[metric] =
        candidate.isEmpty ? metric.shortLabel : String(candidate.prefix(8))
    }

    let storedColors =
      defaults.dictionary(forKey: Self.colorHexValuesKey) as? [String: String] ?? [:]
    var resolvedColors: [HeliosColorRole: String] = [:]
    for role in HeliosColorRole.allCases {
      let value = storedColors[role.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      resolvedColors[role] = value.hasPrefix("#") ? value : role.defaultHex
    }

    let resolvedOnboardingCompleted = defaults.bool(forKey: Self.onboardingKey)
    let resolvedFanSafetyGuideCompleted = defaults.bool(forKey: Self.fanSafetyGuideKey)

    self.defaults = defaults
    menuBarMetrics = resolvedMenuBarMetrics
    popoverModules = resolvedPopoverModules
    dashboardMetrics = resolvedDashboardMetrics
    monitorRoutes = resolvedMonitorRoutes
    dashboardMode = resolvedDashboardMode
    compactCards = resolvedCompactCards
    menuBarIdentityStyle = resolvedMenuBarIdentityStyle
    menuBarLayout = resolvedMenuBarLayout
    showMenuBarHub = resolvedShowMenuBarHub
    graphLineStyle = resolvedGraphLineStyle
    animateGraphUpdates = resolvedAnimateGraphUpdates
    memoryGaugeShowsAvailable = resolvedMemoryGaugeShowsAvailable
    detailedMonitorContent = resolvedDetailedMonitorContent
    menuBarSpacing = resolvedMenuBarSpacing
    coolingFeaturesEnabled = resolvedCoolingFeaturesEnabled
    telemetryModules = resolvedTelemetryModules
    graphRange = resolvedGraphRange
    onboardingCompleted = resolvedOnboardingCompleted
    fanSafetyGuideCompleted = resolvedFanSafetyGuideCompleted
    metricIdentityStyles = resolvedMetricIdentity
    metricContent = resolvedMetricContent
    metricLabels = resolvedMetricLabels
    graphRanges = resolvedGraphRanges
    colorHexValues = resolvedColors
    if monitorRoutesChangedByMigration {
      defaults.set(resolvedMonitorRoutes.map(\.rawValue), forKey: Self.monitorRoutesKey)
    }
    defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
  }

  /// Compatibility surface for the Next23 presentation fixtures and older
  /// settings code. UI7 exposes the richer three-state identity style.
  var showMenuBarSymbols: Bool {
    get { menuBarIdentityStyle == .symbol }
    set { menuBarIdentityStyle = newValue ? .symbol : .label }
  }

  func identityStyle(for metric: HeliosMenuBarMetric) -> HeliosMenuBarIdentityStyle {
    metricIdentityStyles[metric] ?? menuBarIdentityStyle
  }

  func setIdentityStyle(_ style: HeliosMenuBarIdentityStyle, for metric: HeliosMenuBarMetric) {
    metricIdentityStyles[metric] = style
    metricContent[metric] = HeliosMenuBarContent(legacy: style)
    markInterfaceCustomIfNeeded()
    objectWillChange.send()
    persist()
  }

  func menuBarContent(for metric: HeliosMenuBarMetric) -> HeliosMenuBarContent {
    metricContent[metric] ?? HeliosMenuBarContent(legacy: identityStyle(for: metric))
  }

  func setMenuBarIconVisible(_ visible: Bool, for metric: HeliosMenuBarMetric) {
    updateMenuBarContent(for: metric) { $0.showIcon = visible }
  }

  func setMenuBarLabelVisible(_ visible: Bool, for metric: HeliosMenuBarMetric) {
    updateMenuBarContent(for: metric) { $0.showLabel = visible }
  }

  func setMenuBarValueVisible(_ visible: Bool, for metric: HeliosMenuBarMetric) {
    updateMenuBarContent(for: metric) { $0.showValue = visible }
  }

  private func updateMenuBarContent(
    for metric: HeliosMenuBarMetric, _ update: (inout HeliosMenuBarContent) -> Void
  ) {
    var content = menuBarContent(for: metric)
    update(&content)
    content.normalize()
    metricContent[metric] = content
    metricIdentityStyles[metric] =
      content.showLabel ? .label : (content.showIcon ? .symbol : .valueOnly)
    markInterfaceCustomIfNeeded()
    objectWillChange.send()
    persist()
  }

  func label(for metric: HeliosMenuBarMetric) -> String {
    metricLabels[metric] ?? metric.shortLabel
  }

  func setLabel(_ label: String, for metric: HeliosMenuBarMetric) {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    metricLabels[metric] = trimmed.isEmpty ? metric.shortLabel : String(trimmed.prefix(8))
    markInterfaceCustomIfNeeded()
    objectWillChange.send()
    persist()
  }

  func graphRange(for scope: HeliosGraphScope) -> HeliosGraphRange {
    graphRanges[scope] ?? graphRange
  }

  func setGraphRange(_ range: HeliosGraphRange, for scope: HeliosGraphScope) {
    guard graphRanges[scope] != range else { return }
    graphRanges[scope] = range
    objectWillChange.send()
    persist()
  }

  /// Updates the default and every existing chart scope. Individual chart
  /// pickers can diverge again afterwards and remember their own range.
  func setAllGraphRanges(_ range: HeliosGraphRange) {
    graphRanges = Dictionary(
      uniqueKeysWithValues: HeliosGraphScope.allCases.map { ($0, range) })
    if graphRange != range {
      graphRange = range
    } else {
      objectWillChange.send()
      persist()
    }
  }

  private func markInterfaceCustomIfNeeded() {
    guard !applyingInterfacePreset, dashboardMode != .custom else { return }
    dashboardMode = .custom
  }

  func setCompactCards(_ enabled: Bool) {
    guard compactCards != enabled else { return }
    compactCards = enabled
    markInterfaceCustomIfNeeded()
  }

  func setDetailedMonitorContent(_ enabled: Bool) {
    guard detailedMonitorContent != enabled else { return }
    detailedMonitorContent = enabled
    markInterfaceCustomIfNeeded()
  }

  func setMenuBarLayout(_ layout: HeliosMenuBarLayout) {
    guard menuBarLayout != layout else { return }
    menuBarLayout = layout
    if layout == .compactGroup {
      // The compact group is itself the dashboard click target. Keep the hub
      // preference remembered, but it is not needed to reach the interface.
    }
    markInterfaceCustomIfNeeded()
  }

  func setMenuBarSpacing(_ spacing: Double) {
    let clamped = min(8, max(0, spacing))
    guard menuBarSpacing != clamped else { return }
    menuBarSpacing = clamped
    markInterfaceCustomIfNeeded()
  }

  func isEnabled(_ metric: HeliosMenuBarMetric) -> Bool { menuBarMetrics.contains(metric) }

  func setEnabled(_ metric: HeliosMenuBarMetric, enabled: Bool) {
    if enabled {
      guard !menuBarMetrics.contains(metric) else { return }
      menuBarMetrics.append(metric)
    } else {
      menuBarMetrics.removeAll { $0 == metric }
      if menuBarMetrics.isEmpty, menuBarLayout == .nativeModules, !showMenuBarHub {
        // A menu-bar-only utility must never let the user remove its final way
        // back into the interface. Keep the Helios hub as the recovery item.
        showMenuBarHub = true
      }
    }
    markInterfaceCustomIfNeeded()
    persist()
  }

  func setMenuBarHubVisible(_ visible: Bool) {
    if !visible, menuBarLayout == .nativeModules, menuBarMetricsForPresentation.isEmpty {
      showMenuBarHub = true
      return
    }
    showMenuBarHub = visible
    markInterfaceCustomIfNeeded()
  }

  func move(_ metric: HeliosMenuBarMetric, offset: Int) {
    guard let index = menuBarMetrics.firstIndex(of: metric) else { return }
    let destination = index + offset
    guard menuBarMetrics.indices.contains(destination) else { return }
    menuBarMetrics.swapAt(index, destination)
    markInterfaceCustomIfNeeded()
    persist()
  }

  func resetMenuBar() {
    menuBarMetrics = Self.defaultMenuBarMetrics
    menuBarIdentityStyle = .label
    menuBarLayout = .nativeModules
    menuBarSpacing = 2
    showMenuBarHub = true
    metricIdentityStyles = Dictionary(
      uniqueKeysWithValues: HeliosMenuBarMetric.allCases.map { ($0, .label) })
    metricContent = Dictionary(
      uniqueKeysWithValues: HeliosMenuBarMetric.allCases.map { ($0, .labelAndValue) })
    metricLabels = Dictionary(
      uniqueKeysWithValues: HeliosMenuBarMetric.allCases.map { ($0, $0.shortLabel) })
    markInterfaceCustomIfNeeded()
    persist()
  }

  func isPopoverModuleEnabled(_ module: HeliosPopoverModule) -> Bool {
    popoverModules.contains(module)
  }

  func setPopoverModuleEnabled(_ module: HeliosPopoverModule, enabled: Bool) {
    if enabled {
      guard !popoverModules.contains(module) else { return }
      popoverModules.append(module)
    } else {
      popoverModules.removeAll { $0 == module }
    }
    markInterfaceCustomIfNeeded()
    persist()
  }

  func movePopoverModule(_ module: HeliosPopoverModule, offset: Int) {
    guard let index = popoverModules.firstIndex(of: module) else { return }
    let destination = index + offset
    guard popoverModules.indices.contains(destination) else { return }
    popoverModules.swapAt(index, destination)
    markInterfaceCustomIfNeeded()
    persist()
  }

  func isDashboardMetricEnabled(_ metric: HeliosDashboardMetric) -> Bool {
    dashboardMetrics.contains(metric)
  }

  func setDashboardMetricEnabled(_ metric: HeliosDashboardMetric, enabled: Bool) {
    if enabled {
      guard !dashboardMetrics.contains(metric) else { return }
      dashboardMetrics.append(metric)
    } else {
      dashboardMetrics.removeAll { $0 == metric }
    }
    markInterfaceCustomIfNeeded()
    persist()
  }

  func moveDashboardMetric(_ metric: HeliosDashboardMetric, offset: Int) {
    guard let index = dashboardMetrics.firstIndex(of: metric) else { return }
    let destination = index + offset
    guard dashboardMetrics.indices.contains(destination) else { return }
    dashboardMetrics.swapAt(index, destination)
    markInterfaceCustomIfNeeded()
    persist()
  }

  func isTelemetryEnabled(_ module: HeliosTelemetryModule) -> Bool {
    telemetryModules.contains(module)
  }

  func setTelemetryModuleEnabled(_ module: HeliosTelemetryModule, enabled: Bool) {
    if enabled {
      guard !telemetryModules.contains(module) else { return }
      telemetryModules.append(module)
      telemetryModules = HeliosTelemetryModule.allCases.filter(telemetryModules.contains)
    } else {
      telemetryModules.removeAll { $0 == module }
    }
    markInterfaceCustomIfNeeded()
    persist()
  }

  /// Collection and presentation are intentionally independent at the persisted
  /// layout level. Turning a collector off temporarily hides surfaces that
  /// would otherwise look live, but the stored order/visibility is never
  /// mutated. Re-enabling the collector therefore regenerates the same surface
  /// immediately and in the same position.
  var menuBarMetricsForPresentation: [HeliosMenuBarMetric] {
    menuBarMetrics.filter(isMenuBarMetricCollecting)
  }

  var dashboardMetricsForPresentation: [HeliosDashboardMetric] {
    dashboardMetrics.filter(isDashboardMetricCollecting)
  }

  var popoverModulesForPresentation: [HeliosPopoverModule] {
    popoverModules.filter(isPopoverModuleCollecting)
  }

  var monitorRoutesForPresentation: [HeliosMonitorRoute] {
    let visible = monitorRoutes.filter(isMonitorRouteCollecting)
    return visible.contains(.overview) ? visible : [.overview] + visible
  }

  private func isMenuBarMetricCollecting(_ metric: HeliosMenuBarMetric) -> Bool {
    switch metric {
    case .cpu: isTelemetryEnabled(.cpu)
    case .memory: isTelemetryEnabled(.memory)
    case .gpu: isTelemetryEnabled(.gpu)
    case .temperature: true
    case .cooling, .fan: isTelemetryEnabled(.fans)
    case .battery: isTelemetryEnabled(.battery)
    case .power: isTelemetryEnabled(.power)
    case .network: isTelemetryEnabled(.network)
    }
  }

  private func isDashboardMetricCollecting(_ metric: HeliosDashboardMetric) -> Bool {
    switch metric {
    case .cpu: isTelemetryEnabled(.cpu)
    case .memory: isTelemetryEnabled(.memory)
    case .gpu: isTelemetryEnabled(.gpu)
    case .temperature: true
    case .battery: isTelemetryEnabled(.battery)
    case .energy:
      isTelemetryEnabled(.processes) || isTelemetryEnabled(.battery) || isTelemetryEnabled(.power)
    case .power: isTelemetryEnabled(.power)
    }
  }

  private func isPopoverModuleCollecting(_ module: HeliosPopoverModule) -> Bool {
    switch module {
    case .summary:
      !dashboardMetricsForPresentation.isEmpty
    case .cooling:
      isTelemetryEnabled(.fans)
    case .performance:
      isTelemetryEnabled(.gpu) || isTelemetryEnabled(.power) || isTelemetryEnabled(.memory)
    case .network:
      isTelemetryEnabled(.network)
    case .topCPU:
      isTelemetryEnabled(.processes)
    case .system, .alerts:
      true
    case .energy:
      isTelemetryEnabled(.processes) || isTelemetryEnabled(.battery) || isTelemetryEnabled(.power)
    }
  }

  private func isMonitorRouteCollecting(_ route: HeliosMonitorRoute) -> Bool {
    switch route {
    case .overview, .thermals, .history, .health, .system, .maintenance, .expert:
      true
    case .cpu: isTelemetryEnabled(.cpu)
    case .memory: isTelemetryEnabled(.memory)
    case .gpu: isTelemetryEnabled(.gpu)
    case .battery: isTelemetryEnabled(.battery)
    case .energy:
      isTelemetryEnabled(.processes) || isTelemetryEnabled(.battery) || isTelemetryEnabled(.power)
    case .storage: isTelemetryEnabled(.storage)
    case .network: isTelemetryEnabled(.network)
    case .processes: isTelemetryEnabled(.processes)
    case .devices: isTelemetryEnabled(.devices)
    }
  }

  func setCoolingFeaturesEnabled(_ enabled: Bool) {
    guard coolingFeaturesEnabled != enabled else { return }
    // Fan telemetry is read-only and intentionally survives control opt-out.
    // Enabling writes does require the fan sampler so controls always have a
    // fresh inventory; disabling writes never silently removes RPM monitoring.
    coolingFeaturesEnabled = enabled
    if enabled, !telemetryModules.contains(.fans) {
      telemetryModules.append(.fans)
      telemetryModules = HeliosTelemetryModule.allCases.filter(telemetryModules.contains)
    }
    markInterfaceCustomIfNeeded()
    persist()
  }

  func resetDashboard() {
    // A predictable recovery action is more useful than trying to infer which
    // historical custom state the user wants. Recommended is the balanced
    // product default and remains fully editable afterwards.
    popoverModules = Self.advancedPopoverModules
    dashboardMetrics = Self.advancedDashboardMetrics
    dashboardMode = .custom
    persist()
  }

  func completeFanSafetyGuide() {
    guard !fanSafetyGuideCompleted else { return }
    fanSafetyGuideCompleted = true
    persist()
  }

  func resetFanSafetyGuide() {
    fanSafetyGuideCompleted = false
    persist()
  }

  func colorHex(for role: HeliosColorRole) -> String {
    colorHexValues[role] ?? role.defaultHex
  }

  func setColorHex(_ value: String, for role: HeliosColorRole) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    colorHexValues[role] = trimmed
    objectWillChange.send()
    persist()
  }

  func resetColors() {
    colorHexValues = Dictionary(
      uniqueKeysWithValues: HeliosColorRole.allCases.map { ($0, $0.defaultHex) })
    objectWillChange.send()
    persist()
  }

  /// Applies a preset only to the quick dashboard/popover surface. Because the
  /// rest of the app remains untouched, the global interface state becomes
  /// Custom afterwards.
  func applyDashboardPreset(_ mode: HeliosDashboardMode) {
    guard mode != .custom else {
      dashboardMode = .custom
      persist()
      return
    }
    popoverModules = Self.modules(for: mode)
    dashboardMetrics = Self.dashboardMetrics(for: mode)
    dashboardMode = .custom
    persist()
  }

  /// Applies one complete starting configuration across menu bar, Dashboard,
  /// collection and Full Monitor. Presets are never locks: the first structural
  /// manual edit moves the selector to Custom while preserving the edit.
  func applyInterfacePreset(_ mode: HeliosDashboardMode) {
    applyingInterfacePreset = true
    defer { applyingInterfacePreset = false }

    dashboardMode = mode
    guard mode != .custom else {
      detailedMonitorContent = true
      persist()
      return
    }

    popoverModules = Self.modules(for: mode)
    dashboardMetrics = Self.dashboardMetrics(for: mode)
    telemetryModules = Self.telemetryModules(for: mode)
    detailedMonitorContent = mode == .all

    switch mode {
    case .simple:
      menuBarMetrics = [.cpu, .temperature]
      monitorRoutes = [.overview, .cpu, .memory, .thermals, .battery]
    case .advanced:
      menuBarMetrics = [.cpu, .memory, .temperature]
      monitorRoutes = [
        .overview, .cpu, .memory, .gpu, .thermals, .battery, .energy, .storage, .network,
        .processes, .history, .health, .system,
      ]
    case .all:
      menuBarMetrics = [.cpu, .memory, .temperature, .power]
      monitorRoutes = HeliosMonitorRoute.allCases
    case .custom:
      break
    }
    monitorRoutes = Self.normalizedMonitorRoutes(monitorRoutes)
    persist()
  }

  func isMonitorRouteEnabled(_ route: HeliosMonitorRoute) -> Bool {
    monitorRoutes.contains(route)
  }

  func setMonitorRouteEnabled(_ route: HeliosMonitorRoute, enabled: Bool) {
    // Overview is the stable landing page and cannot be removed.
    if route == .overview { return }
    if enabled {
      guard !monitorRoutes.contains(route) else { return }
      monitorRoutes.append(route)
    } else {
      monitorRoutes.removeAll { $0 == route }
    }
    monitorRoutes = Self.normalizedMonitorRoutes(monitorRoutes)
    markInterfaceCustomIfNeeded()
    persist()
  }

  func moveMonitorRoute(_ route: HeliosMonitorRoute, offset: Int) {
    guard route != .overview, let index = monitorRoutes.firstIndex(of: route) else { return }
    let destination = index + offset
    guard monitorRoutes.indices.contains(destination), destination > 0 else { return }
    monitorRoutes.swapAt(index, destination)
    markInterfaceCustomIfNeeded()
    persist()
  }

  func resetMonitor() {
    monitorRoutes = HeliosMonitorRoute.allCases
    markInterfaceCustomIfNeeded()
    persist()
  }

  func completeOnboarding(with mode: HeliosDashboardMode) {
    applyInterfacePreset(mode)
    // Text labels are the clearest first-run identity. Users can switch the
    // menu bar to SF Symbols or values-only without changing module geometry.
    menuBarIdentityStyle = .label
    menuBarLayout = .nativeModules
    showMenuBarHub = true
    metricIdentityStyles = Dictionary(
      uniqueKeysWithValues: HeliosMenuBarMetric.allCases.map { ($0, .label) })
    metricContent = Dictionary(
      uniqueKeysWithValues: HeliosMenuBarMetric.allCases.map { ($0, .labelAndValue) })
    metricLabels = Dictionary(
      uniqueKeysWithValues: HeliosMenuBarMetric.allCases.map { ($0, $0.shortLabel) })
    dashboardMetrics = Self.dashboardMetrics(for: mode)
    telemetryModules = Self.telemetryModules(for: mode)
    detailedMonitorContent = mode == .all || mode == .custom
    switch mode {
    case .simple:
      menuBarMetrics = [.cpu, .temperature]
      monitorRoutes = [.overview, .cpu, .memory, .thermals, .battery]
    case .advanced:
      menuBarMetrics = [.cpu, .memory, .temperature]
      monitorRoutes = [
        .overview, .cpu, .memory, .gpu, .thermals, .battery, .energy, .storage, .network,
        .processes,
        .history,
        .health, .system,
      ]
    case .all:
      // Detailed keeps the menu bar readable while exposing the complete monitor.
      menuBarMetrics = [.cpu, .memory, .temperature, .power]
      monitorRoutes = HeliosMonitorRoute.allCases
    case .custom:
      // Custom starts from a useful complete canvas rather than an empty app.
      // Nothing is locked: every surface remains independently editable.
      popoverModules = Self.advancedPopoverModules
      menuBarMetrics = [.cpu, .memory, .temperature, .power]
      monitorRoutes = HeliosMonitorRoute.allCases
    }
    monitorRoutes = Self.normalizedMonitorRoutes(monitorRoutes)
    onboardingCompleted = true
    persist()
  }

  func markOnboardingIncomplete() {
    onboardingCompleted = false
    persist()
  }

  func resetInterface() {
    dashboardMode = .simple
    compactCards = false
    popoverModules = Self.simplePopoverModules
    dashboardMetrics = Self.simpleDashboardMetrics
    monitorRoutes = HeliosMonitorRoute.allCases
    graphLineStyle = .smooth
    animateGraphUpdates = true
    memoryGaugeShowsAvailable = false
    detailedMonitorContent = false
    menuBarSpacing = 2
    coolingFeaturesEnabled = true
    telemetryModules = Self.simpleTelemetryModules
    fanSafetyGuideCompleted = false
    graphRanges = Dictionary(
      uniqueKeysWithValues: HeliosGraphScope.allCases.map { ($0, .fiveMinutes) })
    graphRange = .fiveMinutes
    resetColors()
    resetMenuBar()
    persist()
  }

  private func persist() {
    defaults.set(menuBarMetrics.map(\.rawValue), forKey: Self.menuBarKey)
    defaults.set(popoverModules.map(\.rawValue), forKey: Self.popoverModulesKey)
    defaults.set(dashboardMetrics.map(\.rawValue), forKey: Self.dashboardMetricsKey)
    defaults.set(monitorRoutes.map(\.rawValue), forKey: Self.monitorRoutesKey)
    defaults.set(dashboardMode.rawValue, forKey: Self.dashboardKey)
    defaults.set(compactCards, forKey: Self.compactKey)
    defaults.set(menuBarIdentityStyle.rawValue, forKey: Self.identityStyleKey)
    defaults.set(menuBarLayout.rawValue, forKey: Self.menuBarLayoutKey)
    defaults.set(showMenuBarHub, forKey: Self.menuBarHubKey)
    defaults.set(
      Dictionary(
        uniqueKeysWithValues: metricIdentityStyles.map { ($0.key.rawValue, $0.value.rawValue) }),
      forKey: Self.metricIdentityKey)
    defaults.set(
      Dictionary(uniqueKeysWithValues: metricContent.map { ($0.key.rawValue, $0.value.bitMask) }),
      forKey: Self.metricContentKey)
    defaults.set(
      Dictionary(uniqueKeysWithValues: metricLabels.map { ($0.key.rawValue, $0.value) }),
      forKey: Self.metricLabelsKey)
    defaults.set(graphLineStyle.rawValue, forKey: Self.graphLineStyleKey)
    defaults.set(animateGraphUpdates, forKey: Self.graphAnimateKey)
    defaults.set(memoryGaugeShowsAvailable, forKey: Self.memoryGaugeAvailableKey)
    defaults.set(detailedMonitorContent, forKey: Self.detailedMonitorKey)
    defaults.set(menuBarSpacing, forKey: Self.menuBarSpacingKey)
    defaults.set(coolingFeaturesEnabled, forKey: Self.coolingFeaturesKey)
    defaults.set(telemetryModules.map(\.rawValue), forKey: Self.telemetryModulesKey)
    defaults.set(fanSafetyGuideCompleted, forKey: Self.fanSafetyGuideKey)
    defaults.set(
      Dictionary(uniqueKeysWithValues: colorHexValues.map { ($0.key.rawValue, $0.value) }),
      forKey: Self.colorHexValuesKey)
    defaults.set(graphRange.rawValue, forKey: Self.graphRangeKey)
    defaults.set(
      Dictionary(uniqueKeysWithValues: graphRanges.map { ($0.key.rawValue, $0.value.rawValue) }),
      forKey: Self.graphRangesKey)
    // Keep writing the UI6 key for reversible development-build migration.
    defaults.set(menuBarIdentityStyle == .symbol, forKey: Self.symbolsKey)
    defaults.set(onboardingCompleted, forKey: Self.onboardingKey)
    defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
  }

  private static func modules(for mode: HeliosDashboardMode) -> [HeliosPopoverModule] {
    switch mode {
    case .simple: simplePopoverModules
    case .advanced: advancedPopoverModules
    case .all: allPopoverModules
    case .custom: advancedPopoverModules
    }
  }

  private static func dashboardMetrics(for mode: HeliosDashboardMode) -> [HeliosDashboardMetric] {
    switch mode {
    case .simple: simpleDashboardMetrics
    case .advanced: advancedDashboardMetrics
    case .all, .custom: allDashboardMetrics
    }
  }

  private static func telemetryModules(for mode: HeliosDashboardMode) -> [HeliosTelemetryModule] {
    switch mode {
    case .simple: simpleTelemetryModules
    case .advanced: recommendedTelemetryModules
    case .all, .custom: detailedTelemetryModules
    }
  }

  private static func normalizedMonitorRoutes(_ routes: [HeliosMonitorRoute])
    -> [HeliosMonitorRoute]
  {
    var result = unique(routes)
    result.removeAll { $0 == .overview }
    result.insert(.overview, at: 0)
    return result
  }

  private static func insertingMonitorRoute(
    _ route: HeliosMonitorRoute, into routes: [HeliosMonitorRoute]
  ) -> [HeliosMonitorRoute] {
    guard route != .overview, !routes.contains(route) else {
      return normalizedMonitorRoutes(routes)
    }
    var result = normalizedMonitorRoutes(routes)
    guard let canonicalIndex = HeliosMonitorRoute.allCases.firstIndex(of: route) else {
      result.append(route)
      return normalizedMonitorRoutes(result)
    }
    let predecessors = HeliosMonitorRoute.allCases[..<canonicalIndex].reversed()
    if let predecessor = predecessors.first(where: { result.contains($0) }),
      let index = result.firstIndex(of: predecessor)
    {
      result.insert(route, at: min(result.endIndex, index + 1))
    } else {
      result.insert(route, at: min(1, result.endIndex))
    }
    return normalizedMonitorRoutes(result)
  }

  private static func unique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
  }
}
