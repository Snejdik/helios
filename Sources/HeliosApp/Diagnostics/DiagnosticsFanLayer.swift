import Foundation

/// Optional `fan_layer` section of a health report. It exists only when the user
/// turned on "Include fan-control statistics", and like every other field it is a
/// closed enum, a bucket or a flag: no free text, no exact counts, no timestamps.
/// The counts cover the time since Helios was launched; nothing is stored on disk.
enum DiagnosticsFanTier: String, Codable, Sendable, CaseIterable {
  case unsupported, experimental, validated
}

enum DiagnosticsSpeedLimit: String, Codable, Sendable, CaseIterable {
  case standard = "default"
  case unlocked
}

enum DiagnosticsFanMode: String, Codable, Sendable, CaseIterable {
  case auto, boost, manual
}

enum DiagnosticsTakeoverDuration: String, Codable, Sendable, CaseIterable {
  case none
  case underThree = "<3s"
  case threeToSix = "3-6s"
  case sixToTen = "6-10s"
  case tenToFifteen = "10-15s"
  case overFifteen = ">15s"

  init(seconds: Double?) {
    guard let seconds, seconds.isFinite, seconds >= 0 else { self = .none; return }
    switch seconds {
    case ..<3: self = .underThree
    case ..<6: self = .threeToSix
    case ..<10: self = .sixToTen
    case ..<15: self = .tenToFifteen
    default: self = .overFifteen
    }
  }
}

enum DiagnosticsPeakTemperature: String, Codable, Sendable, CaseIterable {
  case under70 = "<70"
  case from70 = "70-84"
  case from85 = "85-94"
  case from95 = "95-104"
  case from105 = ">=105"
  case unknown

  init(celsius: Double?) {
    guard let celsius, celsius.isFinite else { self = .unknown; return }
    switch celsius {
    case ..<70: self = .under70
    case ..<85: self = .from70
    case ..<95: self = .from85
    case ..<105: self = .from95
    default: self = .from105
    }
  }
}

/// The fan's share of its factory maximum, in percent.
enum DiagnosticsFanShare: String, Codable, Sendable, CaseIterable {
  case under25 = "<25"
  case from25 = "25-49"
  case from50 = "50-74"
  case from75 = "75-89"
  case from90 = ">=90"
  case unknown

  init(percent: Double?) {
    guard let percent, percent.isFinite else { self = .unknown; return }
    switch percent {
    case ..<25: self = .under25
    case ..<50: self = .from25
    case ..<75: self = .from50
    case ..<90: self = .from75
    default: self = .from90
    }
  }
}

struct DiagnosticsTakeoverCounts: Codable, Sendable, Equatable {
  let held: DiagnosticsFailureCount
  let refused: DiagnosticsFailureCount
  let timedOut: DiagnosticsFailureCount
  let failed: DiagnosticsFailureCount

  enum CodingKeys: String, CodingKey {
    case held, refused, failed
    case timedOut = "timed_out"
  }
}

struct DiagnosticsHandbackCounts: Codable, Sendable, Equatable {
  let overLimit: DiagnosticsFailureCount
  let macOSCooling: DiagnosticsFailureCount
  let cooldownWaits: DiagnosticsFailureCount

  enum CodingKeys: String, CodingKey {
    case overLimit = "over_limit"
    case macOSCooling = "macos_cooling"
    case cooldownWaits = "cooldown_waits"
  }
}

struct DiagnosticsFanLayer: Codable, Sendable, Equatable {
  let tier: DiagnosticsFanTier
  let controlEnabled: Bool
  let speedLimit: DiagnosticsSpeedLimit
  let autoUsesCurve: Bool
  let restoreAuto: Bool
  let modesUsed: [DiagnosticsFanMode]
  let takeovers: DiagnosticsTakeoverCounts
  let takeoverDuration: DiagnosticsTakeoverDuration
  let handbacks: DiagnosticsHandbackCounts
  let refusalsOnBattery: DiagnosticsFailureCount
  let refusalsInLowPowerMode: DiagnosticsFailureCount
  let peakTemperatureC: DiagnosticsPeakTemperature
  let peakFanShare: DiagnosticsFanShare

  enum CodingKeys: String, CodingKey {
    case tier, takeovers, handbacks
    case controlEnabled = "control_enabled"
    case speedLimit = "speed_limit"
    case autoUsesCurve = "auto_uses_curve"
    case restoreAuto = "restore_auto"
    case modesUsed = "modes_used"
    case takeoverDuration = "takeover_duration"
    case refusalsOnBattery = "refusals_on_battery"
    case refusalsInLowPowerMode = "refusals_in_low_power_mode"
    case peakTemperatureC = "peak_temperature_c"
    case peakFanShare = "peak_fan_share"
  }
}

/// Same rules as the server: closed objects, known enums, and the cross-field
/// consistency checks that keep a report from contradicting itself.
enum DiagnosticsFanLayerValidator {
  private static let keys = [
    "tier", "control_enabled", "speed_limit", "auto_uses_curve", "restore_auto", "modes_used",
    "takeovers", "takeover_duration", "handbacks", "refusals_on_battery",
    "refusals_in_low_power_mode", "peak_temperature_c", "peak_fan_share",
  ]

  static func validate(_ value: [String: Any]) throws {
    let path = "$.fan_layer"
    guard Set(value.keys) == Set(keys) else { throw DiagnosticsPayloadError.invalid(path) }
    guard let tier = enumValue(value["tier"], DiagnosticsFanTier.self),
      let controlEnabled = value["control_enabled"] as? Bool,
      enumValue(value["speed_limit"], DiagnosticsSpeedLimit.self) != nil,
      value["auto_uses_curve"] is Bool, value["restore_auto"] is Bool,
      let modes = value["modes_used"] as? [String],
      let duration = enumValue(value["takeover_duration"], DiagnosticsTakeoverDuration.self),
      let onBattery = enumValue(value["refusals_on_battery"], DiagnosticsFailureCount.self),
      let lowPower = enumValue(value["refusals_in_low_power_mode"], DiagnosticsFailureCount.self),
      enumValue(value["peak_temperature_c"], DiagnosticsPeakTemperature.self) != nil,
      enumValue(value["peak_fan_share"], DiagnosticsFanShare.self) != nil
    else { throw DiagnosticsPayloadError.invalid(path) }

    guard modes.count <= 3, Set(modes).count == modes.count,
      modes.allSatisfy({ DiagnosticsFanMode(rawValue: $0) != nil }), modes == modes.sorted()
    else { throw DiagnosticsPayloadError.invalid("\(path).modes_used") }

    guard let takeovers = value["takeovers"] as? [String: Any],
      Set(takeovers.keys) == ["held", "refused", "timed_out", "failed"],
      let held = enumValue(takeovers["held"], DiagnosticsFailureCount.self),
      let refused = enumValue(takeovers["refused"], DiagnosticsFailureCount.self),
      enumValue(takeovers["timed_out"], DiagnosticsFailureCount.self) != nil,
      enumValue(takeovers["failed"], DiagnosticsFailureCount.self) != nil
    else { throw DiagnosticsPayloadError.invalid("\(path).takeovers") }
    guard let handbacks = value["handbacks"] as? [String: Any],
      Set(handbacks.keys) == ["over_limit", "macos_cooling", "cooldown_waits"],
      enumValue(handbacks["over_limit"], DiagnosticsFailureCount.self) != nil,
      enumValue(handbacks["macos_cooling"], DiagnosticsFailureCount.self) != nil,
      enumValue(handbacks["cooldown_waits"], DiagnosticsFailureCount.self) != nil
    else { throw DiagnosticsPayloadError.invalid("\(path).handbacks") }

    // A duration exists exactly when at least one takeover was held.
    guard (held == .zero) == (duration == .none) else {
      throw DiagnosticsPayloadError.invalid("\(path).takeover_duration")
    }
    // Refusals on battery or in Low Power Mode are a subset of all refusals.
    guard ordinal(onBattery) <= ordinal(refused), ordinal(lowPower) <= ordinal(refused) else {
      throw DiagnosticsPayloadError.invalid("\(path).refusals_on_battery")
    }
    // An unsupported Mac never controls fans.
    if tier == .unsupported {
      let silent = [takeovers, handbacks].allSatisfy { $0.values.allSatisfy { ($0 as? String) == "0" } }
      guard !controlEnabled, modes.isEmpty, silent else {
        throw DiagnosticsPayloadError.invalid("\(path).tier")
      }
    }
  }

  private static func ordinal(_ count: DiagnosticsFailureCount) -> Int {
    DiagnosticsFailureCount.allCases.firstIndex(of: count) ?? 0
  }

  private static func enumValue<T: RawRepresentable & CaseIterable>(_ value: Any?, _: T.Type) -> T?
  where T.RawValue == String {
    (value as? String).flatMap(T.init(rawValue:))
  }
}

enum FanDiagnosticEvent: Sendable, Equatable, Hashable {
  case takeoverHeld, takeoverRefused, takeoverTimedOut, takeoverFailed
  case handbackOverLimit, handbackMacOSCooling, cooldownWait
  case mode(DiagnosticsFanMode)
}

struct FanDiagnosticRecord: Sendable, Equatable {
  let event: FanDiagnosticEvent
  var seconds: Double? = nil
  var onBattery: Bool? = nil
  var lowPowerMode: Bool = false
}

/// What the fan layer did since Helios started. A plain value so that the summary
/// can be tested without a helper, a fan or a clock.
struct FanDiagnosticsData: Sendable, Equatable {
  /// Counts saturate in their top bucket ("21+"), so more records of one kind add
  /// nothing; keeping the newest of each kind bounds memory without forgetting a
  /// kind that happened early (a mode used, a refusal).
  static let maximumRecordsPerEvent = 25

  var records: [FanDiagnosticRecord] = []
  var peakTemperatureCelsius: Double?
  var peakFanSharePercent: Double?

  mutating func append(_ record: FanDiagnosticRecord) {
    records.append(record)
    let event = record.event
    if records.lazy.filter({ $0.event == event }).count > Self.maximumRecordsPerEvent,
      let oldest = records.firstIndex(where: { $0.event == event })
    {
      records.remove(at: oldest)
    }
  }

  mutating func observe(temperatureCelsius: Double?, fanSharePercent: Double?) {
    if let temperatureCelsius, temperatureCelsius.isFinite {
      peakTemperatureCelsius = max(peakTemperatureCelsius ?? temperatureCelsius, temperatureCelsius)
    }
    if let fanSharePercent, fanSharePercent.isFinite {
      peakFanSharePercent = max(peakFanSharePercent ?? fanSharePercent, fanSharePercent)
    }
  }
}

struct FanDiagnosticsSettings: Sendable, Equatable {
  var tier: DiagnosticsFanTier
  var controlEnabled: Bool
  var speedLimitUnlocked: Bool
  var autoUsesCurve: Bool
  var restoreAuto: Bool
}

enum FanDiagnosticsSummary {
  /// Takeover failures by the helper's message: the text decides the category and
  /// nothing from it is kept.
  static func failureEvent(forDetail detail: String) -> FanDiagnosticEvent {
    if detail.contains("did not reply") { return .takeoverTimedOut }
    if detail.contains("manual mode") || detail.contains("did not hand over") { return .takeoverRefused }
    return .takeoverFailed
  }

  static func report(data: FanDiagnosticsData, settings: FanDiagnosticsSettings) -> DiagnosticsFanLayer {
    func count(_ event: FanDiagnosticEvent) -> DiagnosticsFailureCount {
      DiagnosticsFailureCount(count: data.records.filter { $0.event == event }.count)
    }
    let refusals = data.records.filter { $0.event == .takeoverRefused }
    let held = data.records.filter { $0.event == .takeoverHeld }
    let heldSeconds = held.compactMap(\.seconds).sorted()
    let heldCount = held.count
    let median = heldSeconds.isEmpty ? nil : heldSeconds[heldSeconds.count / 2]
    let modes = DiagnosticsFanMode.allCases.filter { mode in
      data.records.contains { $0.event == .mode(mode) }
    }
    return DiagnosticsFanLayer(
      tier: settings.tier, controlEnabled: settings.controlEnabled,
      speedLimit: settings.speedLimitUnlocked ? .unlocked : .standard,
      autoUsesCurve: settings.autoUsesCurve, restoreAuto: settings.restoreAuto,
      modesUsed: modes.sorted { $0.rawValue < $1.rawValue },
      takeovers: DiagnosticsTakeoverCounts(
        held: count(.takeoverHeld), refused: count(.takeoverRefused),
        timedOut: count(.takeoverTimedOut), failed: count(.takeoverFailed)),
      // A held takeover without a measured duration still counts as one.
      takeoverDuration: heldCount == 0
        ? .none : (median.map { DiagnosticsTakeoverDuration(seconds: $0) } ?? .underThree),
      handbacks: DiagnosticsHandbackCounts(
        overLimit: count(.handbackOverLimit), macOSCooling: count(.handbackMacOSCooling),
        cooldownWaits: count(.cooldownWait)),
      refusalsOnBattery: DiagnosticsFailureCount(count: refusals.filter { $0.onBattery == true }.count),
      refusalsInLowPowerMode: DiagnosticsFailureCount(count: refusals.filter(\.lowPowerMode).count),
      peakTemperatureC: DiagnosticsPeakTemperature(celsius: data.peakTemperatureCelsius),
      peakFanShare: DiagnosticsFanShare(percent: data.peakFanSharePercent))
  }
}
