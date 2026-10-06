import Foundation

/// Informational alerts only. No fan-control or helper policy reads this configuration.
enum HealthAlertRule: String, CaseIterable, Codable, Sendable, Identifiable {
  case socHot = "soc-hot", socCritical = "soc-critical"
  case batteryHealthLow = "battery-health-low", batteryHealthCritical = "battery-health-critical"
  case batteryTempHot = "battery-temp-hot", batteryTempCritical = "battery-temp-critical"
  case ssdTempHot = "ssd-temp-hot", ssdTempCritical = "ssd-temp-critical"
  case thermalSerious = "thermal-state-serious", thermalCritical = "thermal-state-critical"
  case memoryWarning = "memory-warning", memoryCritical = "memory-critical"
  case smartAttention = "ssd-smart-attention", smartCritical = "ssd-smart-critical"
  case mediaErrors = "ssd-media-errors"

  var id: String { rawValue }
  var title: String {
    switch self {
    case .socHot: "High SoC temperature"
    case .socCritical: "Critical SoC temperature"
    case .batteryHealthLow: "Reduced battery health"
    case .batteryHealthCritical: "Very low battery health"
    case .batteryTempHot: "High battery temperature"
    case .batteryTempCritical: "Critical battery temperature"
    case .ssdTempHot: "High SSD temperature"
    case .ssdTempCritical: "Critical SSD temperature"
    case .thermalSerious: "Serious macOS thermal pressure"
    case .thermalCritical: "Critical macOS thermal pressure"
    case .memoryWarning: "Elevated memory pressure"
    case .memoryCritical: "Critical memory pressure"
    case .smartAttention: "SSD SMART attention"
    case .smartCritical: "SSD SMART critical"
    case .mediaErrors: "SSD media errors"
    }
  }
  var defaultThreshold: Double? {
    switch self {
    case .socHot: 90
    case .socCritical: 95
    case .batteryHealthLow: 80
    case .batteryHealthCritical: 70
    case .batteryTempHot: 45
    case .batteryTempCritical: 50
    case .ssdTempHot: 70
    case .ssdTempCritical: 80
    default: nil
    }
  }
  var range: ClosedRange<Double> {
    switch self {
    case .socHot, .socCritical: 40...120
    case .batteryHealthLow, .batteryHealthCritical: 1...100
    case .batteryTempHot, .batteryTempCritical: 30...60
    case .ssdTempHot, .ssdTempCritical: 40...100
    default: 0...0
    }
  }
  /// A stored or edited threshold limited to this rule's range; a value that is not
  /// a number falls back to the default.
  func clamped(_ value: Double) -> Double? {
    guard value.isFinite else { return defaultThreshold }
    return min(range.upperBound, max(range.lowerBound, value))
  }
  var unit: String { isLowThreshold ? "%" : "°C" }
  var isLowThreshold: Bool { self == .batteryHealthLow || self == .batteryHealthCritical }

  /// Optional collection dependencies only; trusted thermal/system reads are always on.
  var collectionDependency: HeliosTelemetryModule? {
    switch self {
    case .batteryHealthLow, .batteryHealthCritical, .batteryTempHot, .batteryTempCritical: .battery
    case .memoryWarning, .memoryCritical: .memory
    case .ssdTempHot, .ssdTempCritical, .smartAttention, .smartCritical, .mediaErrors: .storage
    default: nil
    }
  }
}

struct HealthAlertSetting: Codable, Sendable, Equatable {
  var enabled: Bool
  var threshold: Double?
}

struct HealthAlertConfiguration: Codable, Sendable, Equatable {
  private var settings: [String: HealthAlertSetting] = [:]
  static let defaults = HealthAlertConfiguration()

  func requiresCollection(_ module: HeliosTelemetryModule) -> Bool {
    HealthAlertRule.allCases.contains { $0.collectionDependency == module && self[$0].enabled }
  }

  subscript(_ rule: HealthAlertRule) -> HealthAlertSetting {
    get {
      let stored = settings[rule.rawValue]
      let value = stored?.threshold ?? rule.defaultThreshold
      let canonical = value.flatMap(rule.clamped)
      return HealthAlertSetting(enabled: stored?.enabled ?? true,
        threshold: rule.defaultThreshold == nil ? nil : canonical)
    }
    set {
      let number = newValue.threshold ?? rule.defaultThreshold
      let canonical = number.flatMap(rule.clamped)
      settings[rule.rawValue] = HealthAlertSetting(enabled: newValue.enabled,
        threshold: rule.defaultThreshold == nil ? nil : canonical)
    }
  }

  /// Three degrees/percentage points of recovery are required to rearm an
  /// active numeric condition. Invalid telemetry never activates an alert.
  func crossed(_ rule: HealthAlertRule, value: Double, previouslyActive: Set<String>) -> Bool {
    let setting = self[rule]
    guard setting.enabled, value.isFinite, let threshold = setting.threshold else { return false }
    let hysteresis = previouslyActive.contains(rule.rawValue) ? 3.0 : 0.0
    return rule.isLowThreshold ? value < threshold + hysteresis : value >= threshold - hysteresis
  }
}

/// How temperatures are shown. Telemetry, history and thresholds stay in Celsius;
/// only presentation converts. Set on the main actor when the user changes the unit.
enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit

    nonisolated(unsafe) static var current: TemperatureUnit = .celsius

    var id: String { rawValue }
    var title: String { self == .celsius ? "Celsius" : "Fahrenheit" }
    var suffix: String { self == .celsius ? "°C" : "°F" }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// "52°C" / "126°F" with the given decimals; "—" for a non-finite value.
    func format(_ celsius: Double, decimals: Int = 0) -> String {
        guard celsius.isFinite else { return "—" }
        return String(format: "%.\(min(3, max(0, decimals)))f", convert(celsius)) + suffix
    }
}
