import Foundation

enum DiagnosticsReportType: String, Codable, Sendable, CaseIterable {
  case automaticHealth = "automatic_health"
  case manualHealth = "manual_health"
  case manualCompatibility = "manual_compatibility"
}

enum DiagnosticsReportReason: String, Codable, Sendable, CaseIterable {
  case initialOptIn = "initial_opt_in"
  case daily
  case heliosVersionChanged = "helios_version_changed"
  case macOSBuildChanged = "macos_build_changed"
  case userInitiated = "user_initiated"
  case userInitiatedCompatibility = "user_initiated_compatibility"
}

enum DiagnosticsCapabilityState: String, Codable, Sendable, CaseIterable {
  case available, partial, unavailable, failed, unknown
}

enum DiagnosticsProviderState: String, Codable, Sendable, CaseIterable {
  case available, partial, unavailable, failed
  case notObserved = "not_observed"
}

enum DiagnosticsFailureCategory: String, Codable, Sendable, CaseIterable {
  case permissionDenied = "permission_denied"
  case unsupported
  case noData = "no_data"
  case invalidData = "invalid_data"
  case ioError = "io_error"
  case timedOut = "timed_out"
  case other
}

enum DiagnosticsFailureCount: String, Codable, Sendable, CaseIterable {
  case zero = "0"
  case one = "1"
  case twoToFive = "2-5"
  case sixToTwenty = "6-20"
  case twentyOnePlus = "21+"

  init(count: Int) {
    switch max(0, count) {
    case 0: self = .zero
    case 1: self = .one
    case 2...5: self = .twoToFive
    case 6...20: self = .sixToTwenty
    default: self = .twentyOnePlus
    }
  }
}

enum DiagnosticsMemoryBucket: String, Codable, Sendable, CaseIterable {
  case upToEight = "<=8"
  case nineToSixteen = "9-16"
  case seventeenToThirtyTwo = "17-32"
  case thirtyThreeToSixtyFour = "33-64"
  case sixtyFiveToOneTwentyEight = "65-128"
  case overOneTwentyEight = ">128"
  case unknown
}

enum DiagnosticsRuntimeMemoryBucket: String, Codable, Sendable, CaseIterable {
  case upToSixteen = "<=16"
  case seventeenToThirtyTwo = "17-32"
  case thirtyThreeToSixtyFour = "33-64"
  case sixtyFiveToOneTwentyEight = "65-128"
  case oneTwentyNineToTwoFiftySix = "129-256"
  case overTwoFiftySix = ">256"
  case unknown
}

enum DiagnosticsCPUPercentBucket: String, Codable, Sendable, CaseIterable {
  case underPointTwo = "<0.2"
  case pointTwoToOne = "0.2-1"
  case oneToFive = "1-5"
  case fiveToTwenty = "5-20"
  case overTwenty = ">20"
  case unknown
}

enum DiagnosticsDurationBucket: String, Codable, Sendable, CaseIterable {
  case underFiveMinutes = "<5m"
  case fiveToFifteenMinutes = "5-15m"
  case fifteenMinutesToOneHour = "15m-1h"
  case oneToSixHours = "1-6h"
  case sixToTwentyFourHours = "6-24h"
  case overTwentyFourHours = ">24h"
  case unknown
}

enum DiagnosticsErrorCategory: String, Codable, Sendable, CaseIterable {
  case none, build, encode, schedule, transport
  case serverRejected = "server_rejected"
  case other
}

enum DiagnosticsLifecycleCategory: String, Codable, Sendable, CaseIterable {
  case firstLaunch = "first_launch"
  case normalLaunch = "normal_launch"
  case afterUpdate = "after_update"
  case afterMacOSUpdate = "after_macos_update"
  case afterUncleanExit = "after_unclean_exit"
  case unknown
}

enum DiagnosticsHelperInstallationState: String, Codable, Sendable, CaseIterable {
  case missing
  case requiresApproval = "requires_approval"
  case installed, unavailable
}

enum DiagnosticsHelperConnectionState: String, Codable, Sendable, CaseIterable {
  case disconnected, connecting, connected
  case signingRequired = "signing_required"
  case versionMismatch = "version_mismatch"
  case failed
}

enum DiagnosticsProtocolCompatibility: String, Codable, Sendable, CaseIterable {
  case compatible, mismatch
  case notChecked = "not_checked"
}

enum DiagnosticsHelperFailureCategory: String, Codable, Sendable, CaseIterable {
  case signing, approval, `protocol`, timeout, connection, registration, other
}

enum DiagnosticsReadState: String, Codable, Sendable, CaseIterable {
  case readable, unreadable
  case decodeFailed = "decode_failed"
}

enum DiagnosticsFanRangeState: String, Codable, Sendable, CaseIterable {
  case available, partial, unavailable
  case readFailed = "read_failed"
}

enum DiagnosticsThermalSemanticGroup: String, Codable, Sendable, CaseIterable {
  case performanceCore = "performance_core"
  case efficiencyCore = "efficiency_core"
  case gpu
  case validatedHotspot = "validated_hotspot"
  case unclassified
}

enum DiagnosticsFanTopologyClass: String, Codable, Sendable, CaseIterable {
  case fanless
  case singleFan = "single_fan"
  case dualFan = "dual_fan"
  case multiFan = "multi_fan"
  case unknown
}

enum DiagnosticsCompatibilityState: String, Codable, Sendable, CaseIterable {
  case supportedReadOnly = "supported_read_only"
  case partial, unsupported
  case needsReview = "needs_review"
}

enum DiagnosticsProviderName: String, Codable, Sendable, CaseIterable {
  case cpu, memory, gpu, thermal
  case fanTelemetry = "fan_telemetry"
  case battery, storage
  case nvmeSmart = "nvme_smart"
  case network, wifi, bluetooth
  case energyProcess = "energy_process"
}

enum DiagnosticsProviderStage: String, Codable, Sendable, CaseIterable {
  case discover, open, read, decode, validate, sample
}

enum DiagnosticsCodeDomain: String, Codable, Sendable, CaseIterable {
  case mach, iokit, smc, posix, osstatus
}

struct DiagnosticsHelios: Codable, Sendable, Equatable {
  let version: String
  let build: String
  enum CodingKeys: String, CodingKey { case version, build }
}

struct DiagnosticsSystem: Codable, Sendable, Equatable {
  let macOSVersion: String
  let macOSBuild: String
  let machineModel: String?
  let architecture: String
  let appleSiliconFamily: String?
  let memoryBucketGiB: DiagnosticsMemoryBucket
  let fanCount: Int?
  let batteryPresent: Bool?

  enum CodingKeys: String, CodingKey {
    case macOSVersion = "macos_version"
    case macOSBuild = "macos_build"
    case machineModel = "machine_model"
    case architecture
    case appleSiliconFamily = "apple_silicon_family"
    case memoryBucketGiB = "memory_bucket_gib"
    case fanCount = "fan_count"
    case batteryPresent = "battery_present"
  }
}

struct DiagnosticsCapabilities: Codable, Sendable, Equatable {
  let cpu: DiagnosticsCapabilityState
  let memory: DiagnosticsCapabilityState
  let gpu: DiagnosticsCapabilityState
  let thermal: DiagnosticsCapabilityState
  let fanTelemetry: DiagnosticsCapabilityState
  let battery: DiagnosticsCapabilityState
  let storage: DiagnosticsCapabilityState
  let nvmeSmart: DiagnosticsCapabilityState
  let network: DiagnosticsCapabilityState
  let wifi: DiagnosticsCapabilityState
  let bluetooth: DiagnosticsCapabilityState
  let energyProcess: DiagnosticsCapabilityState

  enum CodingKeys: String, CodingKey {
    case cpu, memory, gpu, thermal, battery, storage, network, wifi, bluetooth
    case fanTelemetry = "fan_telemetry"
    case nvmeSmart = "nvme_smart"
    case energyProcess = "energy_process"
  }
}

struct DiagnosticsProviderSummary: Codable, Sendable, Equatable {
  let state: DiagnosticsProviderState
  let failureCategory: DiagnosticsFailureCategory?
  let failureCount: DiagnosticsFailureCount

  enum CodingKeys: String, CodingKey {
    case state
    case failureCategory = "failure_category"
    case failureCount = "failure_count"
  }
}

struct DiagnosticsProviders: Codable, Sendable, Equatable {
  let cpu: DiagnosticsProviderSummary
  let memory: DiagnosticsProviderSummary
  let gpu: DiagnosticsProviderSummary
  let thermal: DiagnosticsProviderSummary
  let fanTelemetry: DiagnosticsProviderSummary
  let battery: DiagnosticsProviderSummary
  let storage: DiagnosticsProviderSummary
  let nvmeSmart: DiagnosticsProviderSummary
  let network: DiagnosticsProviderSummary
  let wifi: DiagnosticsProviderSummary
  let bluetooth: DiagnosticsProviderSummary
  let energyProcess: DiagnosticsProviderSummary

  enum CodingKeys: String, CodingKey {
    case cpu, memory, gpu, thermal, battery, storage, network, wifi, bluetooth
    case fanTelemetry = "fan_telemetry"
    case nvmeSmart = "nvme_smart"
    case energyProcess = "energy_process"
  }

  var all: [DiagnosticsProviderName: DiagnosticsProviderSummary] {
    [
      .cpu: cpu, .memory: memory, .gpu: gpu, .thermal: thermal,
      .fanTelemetry: fanTelemetry, .battery: battery, .storage: storage,
      .nvmeSmart: nvmeSmart, .network: network, .wifi: wifi,
      .bluetooth: bluetooth, .energyProcess: energyProcess,
    ]
  }
}

struct DiagnosticsHelper: Codable, Sendable, Equatable {
  let installationState: DiagnosticsHelperInstallationState
  let connectionState: DiagnosticsHelperConnectionState
  let protocolCompatibility: DiagnosticsProtocolCompatibility
  let failureCategory: DiagnosticsHelperFailureCategory?

  enum CodingKeys: String, CodingKey {
    case installationState = "installation_state"
    case connectionState = "connection_state"
    case protocolCompatibility = "protocol_compatibility"
    case failureCategory = "failure_category"
  }
}

struct DiagnosticsRuntime: Codable, Sendable, Equatable {
  let memoryFootprintMiB: DiagnosticsRuntimeMemoryBucket
  let cpuPercent: DiagnosticsCPUPercentBucket
  let sessionDuration: DiagnosticsDurationBucket
  let providerFailureTotal: DiagnosticsFailureCount
  let diagnosticsErrorCategory: DiagnosticsErrorCategory

  enum CodingKeys: String, CodingKey {
    case memoryFootprintMiB = "memory_footprint_mib"
    case cpuPercent = "cpu_percent"
    case sessionDuration = "session_duration"
    case providerFailureTotal = "provider_failure_total"
    case diagnosticsErrorCategory = "diagnostics_error_category"
  }
}

struct DiagnosticsStability: Codable, Sendable, Equatable {
  let previousSessionEndedUncleanly: Bool
  let previousSessionDuration: DiagnosticsDurationBucket?
  let lifecycleCategory: DiagnosticsLifecycleCategory

  enum CodingKeys: String, CodingKey {
    case previousSessionEndedUncleanly = "previous_session_ended_uncleanly"
    case previousSessionDuration = "previous_session_duration"
    case lifecycleCategory = "lifecycle_category"
  }
}

struct DiagnosticsHealthReport: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let reportType: DiagnosticsReportType
  let generatedAt: String
  let reportReason: DiagnosticsReportReason
  let helios: DiagnosticsHelios
  let system: DiagnosticsSystem
  let capabilities: DiagnosticsCapabilities
  let providers: DiagnosticsProviders
  let helper: DiagnosticsHelper
  let runtime: DiagnosticsRuntime
  let stability: DiagnosticsStability

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case reportType = "report_type"
    case generatedAt = "generated_at"
    case reportReason = "report_reason"
    case helios, system, capabilities, providers, helper, runtime, stability
  }
}

struct DiagnosticsSMCThermalDiscovery: Codable, Sendable, Equatable {
  let key: String
  let dataType: String?
  let dataSize: Int?
  let readState: DiagnosticsReadState
  let decodedCelsius: Double?
  let failureCategory: DiagnosticsFailureCategory?

  enum CodingKeys: String, CodingKey {
    case key
    case dataType = "data_type"
    case dataSize = "data_size"
    case readState = "read_state"
    case decodedCelsius = "decoded_celsius"
    case failureCategory = "failure_category"
  }
}

struct DiagnosticsFanTopologyEntry: Codable, Sendable, Equatable {
  let index: Int
  let rangeState: DiagnosticsFanRangeState
  let minimumRPM: Int?
  let maximumRPM: Int?
  let actualRPM: Int?

  enum CodingKeys: String, CodingKey {
    case index
    case rangeState = "range_state"
    case minimumRPM = "minimum_rpm"
    case maximumRPM = "maximum_rpm"
    case actualRPM = "actual_rpm"
  }
}

struct DiagnosticsProviderDiagnostic: Codable, Sendable, Equatable {
  let provider: DiagnosticsProviderName
  let stage: DiagnosticsProviderStage
  let category: DiagnosticsFailureCategory
  let codeDomain: DiagnosticsCodeDomain?
  let numericCode: Int32?
  let occurrences: DiagnosticsFailureCount

  enum CodingKeys: String, CodingKey {
    case provider, stage, category
    case codeDomain = "code_domain"
    case numericCode = "numeric_code"
    case occurrences
  }
}

struct DiagnosticsRawHardware: Codable, Sendable, Equatable {
  let smcThermalDiscovery: [DiagnosticsSMCThermalDiscovery]
  let fanTopology: [DiagnosticsFanTopologyEntry]
  let providerDiagnostics: [DiagnosticsProviderDiagnostic]

  enum CodingKeys: String, CodingKey {
    case smcThermalDiscovery = "smc_thermal_discovery"
    case fanTopology = "fan_topology"
    case providerDiagnostics = "provider_diagnostics"
  }
}

struct DiagnosticsThermalClassification: Codable, Sendable, Equatable {
  let key: String
  let semanticGroup: DiagnosticsThermalSemanticGroup
  let classificationSource: String

  enum CodingKeys: String, CodingKey {
    case key
    case semanticGroup = "semantic_group"
    case classificationSource = "classification_source"
  }
}

struct DiagnosticsHeliosClassification: Codable, Sendable, Equatable {
  let thermalChannels: [DiagnosticsThermalClassification]
  let fanTopologyClass: DiagnosticsFanTopologyClass
  let compatibilityState: DiagnosticsCompatibilityState

  enum CodingKeys: String, CodingKey {
    case thermalChannels = "thermal_channels"
    case fanTopologyClass = "fan_topology_class"
    case compatibilityState = "compatibility_state"
  }
}

struct DiagnosticsCompatibilityReport: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let reportType: DiagnosticsReportType
  let generatedAt: String
  let reportReason: DiagnosticsReportReason
  let helios: DiagnosticsHelios
  let system: DiagnosticsSystem
  let capabilities: DiagnosticsCapabilities
  let providers: DiagnosticsProviders
  let helper: DiagnosticsHelper
  let runtime: DiagnosticsRuntime
  let stability: DiagnosticsStability
  let rawHardware: DiagnosticsRawHardware
  let heliosClassification: DiagnosticsHeliosClassification

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case reportType = "report_type"
    case generatedAt = "generated_at"
    case reportReason = "report_reason"
    case helios, system, capabilities, providers, helper, runtime, stability
    case rawHardware = "raw_hardware"
    case heliosClassification = "helios_classification"
  }
}

enum DiagnosticsPayloadError: Error, Equatable, LocalizedError {
  case encoding
  case tooLarge
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .encoding: "The diagnostic report could not be encoded."
    case .tooLarge: "The diagnostic report exceeds the 128 KiB limit."
    case .invalid(let field): "The diagnostic report is invalid at \(field)."
    }
  }
}

struct FrozenDiagnosticsPayload: Sendable, Equatable {
  static let maximumBytes = 128 * 1_024
  static let manualLifetime: TimeInterval = 15 * 60

  let data: Data
  let reportType: DiagnosticsReportType
  let createdAt: Date
  let generation: UInt64

  var preview: String { String(decoding: data, as: UTF8.self) }
  func isExpired(at date: Date = Date()) -> Bool {
    date.timeIntervalSince(createdAt) < 0 || date.timeIntervalSince(createdAt) > Self.manualLifetime
  }
}

enum DiagnosticsPayloadEncoder {
  static func freeze<T: Encodable>(
    _ report: T,
    reportType: DiagnosticsReportType,
    now: Date = Date(),
    generation: UInt64 = 0
  ) throws -> FrozenDiagnosticsPayload {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(report) else { throw DiagnosticsPayloadError.encoding }
    guard data.count <= FrozenDiagnosticsPayload.maximumBytes else {
      throw DiagnosticsPayloadError.tooLarge
    }
    try DiagnosticsPayloadValidator.validate(data, expectedType: reportType)
    return FrozenDiagnosticsPayload(
      data: data, reportType: reportType, createdAt: now, generation: generation)
  }
}

enum DiagnosticsTimestamp {
  static func minuteUTC(_ date: Date) -> String {
    let seconds = floor(date.timeIntervalSince1970 / 60) * 60
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
  }
}

/// Strict client-side validation protects preview/send integrity. The future API
/// still performs its own independent schema validation before any write.
enum DiagnosticsPayloadValidator {
  static func validate(_ data: Data, expectedType: DiagnosticsReportType? = nil) throws {
    guard data.count <= FrozenDiagnosticsPayload.maximumBytes,
      let value = try? JSONSerialization.jsonObject(with: data),
      let root = value as? [String: Any]
    else { throw DiagnosticsPayloadError.invalid("$") }
    guard maximumDepth(value) <= 6, !containsNull(value) else {
      throw DiagnosticsPayloadError.invalid("$")
    }
    let type = try string(root, "report_type", at: "$", allowed: DiagnosticsReportType.allCases)
    if let expectedType, type != expectedType { throw DiagnosticsPayloadError.invalid("$.report_type") }
    let common = [
      "schema_version", "report_type", "generated_at", "report_reason", "helios", "system",
      "capabilities", "providers", "helper", "runtime", "stability",
    ]
    let compatibility = type == .manualCompatibility
    try closed(root, required: common + (compatibility ? ["raw_hardware", "helios_classification"] : []), at: "$")
    guard integer(root["schema_version"]) == 1 else {
      throw DiagnosticsPayloadError.invalid("$.schema_version")
    }
    let reason = try string(
      root, "report_reason", at: "$", allowed: DiagnosticsReportReason.allCases)
    let validReason: Bool
    switch type {
    case .automaticHealth:
      validReason = [.initialOptIn, .daily, .heliosVersionChanged, .macOSBuildChanged].contains(reason)
    case .manualHealth: validReason = reason == .userInitiated
    case .manualCompatibility: validReason = reason == .userInitiatedCompatibility
    }
    guard validReason, let timestamp = root["generated_at"] as? String,
      timestamp.range(
        of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$"#,
        options: .regularExpression) != nil
    else { throw DiagnosticsPayloadError.invalid("$.generated_at") }

    try validateHelios(try object(root, "helios", at: "$"))
    try validateSystem(try object(root, "system", at: "$"))
    try validateCapabilities(try object(root, "capabilities", at: "$"))
    try validateProviders(try object(root, "providers", at: "$"))
    try validateHelper(try object(root, "helper", at: "$"))
    try validateRuntime(try object(root, "runtime", at: "$"))
    try validateStability(try object(root, "stability", at: "$"))
    if compatibility {
      let raw = try object(root, "raw_hardware", at: "$")
      let classification = try object(root, "helios_classification", at: "$")
      try validateCompatibility(raw: raw, classification: classification, system: try object(root, "system", at: "$"))
    }
  }

  private static let providerKeys = DiagnosticsProviderName.allCases.map(\.rawValue)

  private static func validateHelios(_ value: [String: Any]) throws {
    try closed(value, required: ["version", "build"], at: "$.helios")
    guard boundedString(value["version"], 1...32, pattern: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?$"#),
      boundedString(value["build"], 1...32, pattern: #"^[A-Za-z0-9.-]+$"#)
    else { throw DiagnosticsPayloadError.invalid("$.helios") }
  }

  private static func validateSystem(_ value: [String: Any]) throws {
    try closed(
      value,
      required: ["macos_version", "macos_build", "architecture", "memory_bucket_gib"],
      optional: ["machine_model", "apple_silicon_family", "fan_count", "battery_present"],
      at: "$.system")
    guard boundedString(value["macos_version"], 1...32, pattern: #"^[0-9.]+$"#),
      boundedString(value["macos_build"], 1...32, pattern: #"^[A-Za-z0-9]+$"#),
      value["architecture"] as? String == "arm64",
      enumString(value["memory_bucket_gib"], DiagnosticsMemoryBucket.allCases)
    else { throw DiagnosticsPayloadError.invalid("$.system") }
    if let model = value["machine_model"] {
      guard boundedString(
        model, 4...32, pattern: #"^[A-Za-z][A-Za-z0-9]*[0-9],[0-9]{1,3}$"#)
      else { throw DiagnosticsPayloadError.invalid("$.system.machine_model") }
    }
    if let family = value["apple_silicon_family"] as? String {
      guard ["M1", "M2", "M3", "M4", "M5", "future", "unknown"].contains(family) else {
        throw DiagnosticsPayloadError.invalid("$.system.apple_silicon_family")
      }
    }
    if let count = value["fan_count"] {
      guard let count = integer(count), (0...8).contains(count) else {
        throw DiagnosticsPayloadError.invalid("$.system.fan_count")
      }
    }
    if let present = value["battery_present"] { try requireBoolean(present, "$.system.battery_present") }
  }

  private static func validateCapabilities(_ value: [String: Any]) throws {
    try closed(value, required: providerKeys, at: "$.capabilities")
    for key in providerKeys where !enumString(value[key], DiagnosticsCapabilityState.allCases) {
      throw DiagnosticsPayloadError.invalid("$.capabilities.\(key)")
    }
  }

  private static func validateProviders(_ value: [String: Any]) throws {
    try closed(value, required: providerKeys, at: "$.providers")
    for key in providerKeys {
      guard let provider = value[key] as? [String: Any] else {
        throw DiagnosticsPayloadError.invalid("$.providers.\(key)")
      }
      try closed(
        provider, required: ["state", "failure_count"], optional: ["failure_category"],
        at: "$.providers.\(key)")
      guard let stateRaw = provider["state"] as? String,
        let state = DiagnosticsProviderState(rawValue: stateRaw),
        enumString(provider["failure_count"], DiagnosticsFailureCount.allCases)
      else { throw DiagnosticsPayloadError.invalid("$.providers.\(key)") }
      let category = provider["failure_category"]
      if state == .partial || state == .failed {
        guard enumString(category, DiagnosticsFailureCategory.allCases) else {
          throw DiagnosticsPayloadError.invalid("$.providers.\(key).failure_category")
        }
      } else if state == .available || state == .notObserved {
        guard category == nil else {
          throw DiagnosticsPayloadError.invalid("$.providers.\(key).failure_category")
        }
      } else if category != nil, !enumString(category, DiagnosticsFailureCategory.allCases) {
        throw DiagnosticsPayloadError.invalid("$.providers.\(key).failure_category")
      }
      if state == .notObserved, provider["failure_count"] as? String != "0" {
        throw DiagnosticsPayloadError.invalid("$.providers.\(key).failure_count")
      }
    }
  }

  private static func validateHelper(_ value: [String: Any]) throws {
    try closed(
      value, required: ["installation_state", "connection_state", "protocol_compatibility"],
      optional: ["failure_category"], at: "$.helper")
    guard enumString(value["installation_state"], DiagnosticsHelperInstallationState.allCases),
      enumString(value["connection_state"], DiagnosticsHelperConnectionState.allCases),
      enumString(value["protocol_compatibility"], DiagnosticsProtocolCompatibility.allCases)
    else { throw DiagnosticsPayloadError.invalid("$.helper") }
    if let failure = value["failure_category"],
      !enumString(failure, DiagnosticsHelperFailureCategory.allCases)
    { throw DiagnosticsPayloadError.invalid("$.helper.failure_category") }
  }

  private static func validateRuntime(_ value: [String: Any]) throws {
    let keys = [
      "memory_footprint_mib", "cpu_percent", "session_duration", "provider_failure_total",
      "diagnostics_error_category",
    ]
    try closed(value, required: keys, at: "$.runtime")
    guard enumString(value["memory_footprint_mib"], DiagnosticsRuntimeMemoryBucket.allCases),
      enumString(value["cpu_percent"], DiagnosticsCPUPercentBucket.allCases),
      enumString(value["session_duration"], DiagnosticsDurationBucket.allCases),
      enumString(value["provider_failure_total"], DiagnosticsFailureCount.allCases),
      enumString(value["diagnostics_error_category"], DiagnosticsErrorCategory.allCases)
    else { throw DiagnosticsPayloadError.invalid("$.runtime") }
  }

  private static func validateStability(_ value: [String: Any]) throws {
    try closed(
      value, required: ["previous_session_ended_uncleanly", "lifecycle_category"],
      optional: ["previous_session_duration"], at: "$.stability")
    try requireBoolean(
      value["previous_session_ended_uncleanly"], "$.stability.previous_session_ended_uncleanly")
    guard enumString(value["lifecycle_category"], DiagnosticsLifecycleCategory.allCases) else {
      throw DiagnosticsPayloadError.invalid("$.stability.lifecycle_category")
    }
    if let duration = value["previous_session_duration"],
      !enumString(duration, DiagnosticsDurationBucket.allCases)
    { throw DiagnosticsPayloadError.invalid("$.stability.previous_session_duration") }
  }

  private static func validateCompatibility(
    raw: [String: Any], classification: [String: Any], system: [String: Any]
  ) throws {
    try closed(
      raw, required: ["smc_thermal_discovery", "fan_topology", "provider_diagnostics"],
      at: "$.raw_hardware")
    guard let thermal = raw["smc_thermal_discovery"] as? [[String: Any]], thermal.count <= 512,
      let fans = raw["fan_topology"] as? [[String: Any]], fans.count <= 8,
      let diagnostics = raw["provider_diagnostics"] as? [[String: Any]], diagnostics.count <= 64
    else { throw DiagnosticsPayloadError.invalid("$.raw_hardware") }
    var thermalKeys = Set<String>()
    for (index, item) in thermal.enumerated() {
      let path = "$.raw_hardware.smc_thermal_discovery[\(index)]"
      try closed(
        item, required: ["key", "read_state"],
        optional: ["data_type", "data_size", "decoded_celsius", "failure_category"], at: path)
      guard let key = item["key"] as? String, printableFour(key), thermalKeys.insert(key).inserted,
        enumString(item["read_state"], DiagnosticsReadState.allCases)
      else { throw DiagnosticsPayloadError.invalid(path) }
      if let rawType = item["data_type"] {
        guard let type = rawType as? String, printableFour(type) else {
          throw DiagnosticsPayloadError.invalid("\(path).data_type")
        }
      }
      if let size = item["data_size"] {
        guard let size = integer(size), (1...32).contains(size) else {
          throw DiagnosticsPayloadError.invalid("\(path).data_size")
        }
      }
      let readable = item["read_state"] as? String == DiagnosticsReadState.readable.rawValue
      if let temperature = item["decoded_celsius"] {
        guard readable, let value = number(temperature), value.isFinite,
          (-100...250).contains(value), decimalPlaces(value) <= 3
        else { throw DiagnosticsPayloadError.invalid("\(path).decoded_celsius") }
      }
      if readable {
        guard item["failure_category"] == nil else {
          throw DiagnosticsPayloadError.invalid("\(path).failure_category")
        }
      } else if !enumString(item["failure_category"], DiagnosticsFailureCategory.allCases) {
        throw DiagnosticsPayloadError.invalid("\(path).failure_category")
      }
    }

    var fanIndexes = Set<Int>()
    for (offset, item) in fans.enumerated() {
      let path = "$.raw_hardware.fan_topology[\(offset)]"
      try closed(
        item, required: ["index", "range_state"],
        optional: ["minimum_rpm", "maximum_rpm", "actual_rpm"], at: path)
      guard let index = integer(item["index"]), (0...7).contains(index),
        fanIndexes.insert(index).inserted,
        let rangeRaw = item["range_state"] as? String,
        let range = DiagnosticsFanRangeState(rawValue: rangeRaw)
      else { throw DiagnosticsPayloadError.invalid(path) }
      let minimum = optionalBoundedInteger(item["minimum_rpm"], range: 0...100_000)
      let maximum = optionalBoundedInteger(item["maximum_rpm"], range: 0...100_000)
      guard item["minimum_rpm"] == nil || minimum != nil,
        item["maximum_rpm"] == nil || maximum != nil,
        item["actual_rpm"] == nil || optionalBoundedInteger(item["actual_rpm"], range: 0...100_000) != nil,
        minimum == nil || maximum == nil || minimum! <= maximum!
      else { throw DiagnosticsPayloadError.invalid(path) }
      switch range {
      case .available where minimum == nil || maximum == nil,
        .partial where (minimum == nil) == (maximum == nil),
        .unavailable where minimum != nil || maximum != nil,
        .readFailed where minimum != nil || maximum != nil:
        throw DiagnosticsPayloadError.invalid(path)
      default: break
      }
    }
    for (index, item) in diagnostics.enumerated() {
      let path = "$.raw_hardware.provider_diagnostics[\(index)]"
      try closed(
        item, required: ["provider", "stage", "category", "occurrences"],
        optional: ["code_domain", "numeric_code"], at: path)
      guard enumString(item["provider"], DiagnosticsProviderName.allCases),
        enumString(item["stage"], DiagnosticsProviderStage.allCases),
        enumString(item["category"], DiagnosticsFailureCategory.allCases),
        let occurrence = item["occurrences"] as? String,
        ["1", "2-5", "6-20", "21+"].contains(occurrence)
      else { throw DiagnosticsPayloadError.invalid(path) }
      if item["numeric_code"] != nil {
        guard enumString(item["code_domain"], DiagnosticsCodeDomain.allCases),
          let code = integer(item["numeric_code"]),
          code >= Int(Int32.min), code <= Int(Int32.max)
        else { throw DiagnosticsPayloadError.invalid(path) }
      } else if let domain = item["code_domain"], !enumString(domain, DiagnosticsCodeDomain.allCases) {
        throw DiagnosticsPayloadError.invalid(path)
      }
    }

    try closed(
      classification,
      required: ["thermal_channels", "fan_topology_class", "compatibility_state"],
      at: "$.helios_classification")
    guard let channels = classification["thermal_channels"] as? [[String: Any]],
      enumString(classification["fan_topology_class"], DiagnosticsFanTopologyClass.allCases),
      enumString(classification["compatibility_state"], DiagnosticsCompatibilityState.allCases)
    else { throw DiagnosticsPayloadError.invalid("$.helios_classification") }
    var classifiedKeys = Set<String>()
    for (index, item) in channels.enumerated() {
      let path = "$.helios_classification.thermal_channels[\(index)]"
      try closed(item, required: ["key", "semantic_group", "classification_source"], at: path)
      guard let key = item["key"] as? String, thermalKeys.contains(key),
        classifiedKeys.insert(key).inserted,
        enumString(item["semantic_group"], DiagnosticsThermalSemanticGroup.allCases),
        item["classification_source"] as? String == "helios_rule_v1"
      else { throw DiagnosticsPayloadError.invalid(path) }
    }
    guard let topologyRaw = classification["fan_topology_class"] as? String,
      let topology = DiagnosticsFanTopologyClass(rawValue: topologyRaw)
    else { throw DiagnosticsPayloadError.invalid("$.helios_classification.fan_topology_class") }
    let fanCount = integer(system["fan_count"])
    switch topology {
    case .fanless where fanCount != 0 || !fans.isEmpty,
      .singleFan where fanCount != 1 || fanIndexes != [0],
      .dualFan where fanCount != 2 || fanIndexes != [0, 1],
      .multiFan where fanCount == nil || !(3...8).contains(fanCount!)
        || fans.count != fanCount || fanIndexes != Set(0..<fanCount!):
      throw DiagnosticsPayloadError.invalid("$.helios_classification.fan_topology_class")
    case .unknown:
      if let fanCount, fans.count == fanCount, fanIndexes == Set(0..<fanCount) {
        throw DiagnosticsPayloadError.invalid("$.helios_classification.fan_topology_class")
      }
    default: break
    }
  }

  private static func closed(
    _ value: [String: Any], required: [String], optional: [String] = [], at path: String
  ) throws {
    let keys = Set(value.keys)
    guard Set(required).isSubset(of: keys), keys.isSubset(of: Set(required + optional)) else {
      throw DiagnosticsPayloadError.invalid(path)
    }
  }

  private static func object(_ root: [String: Any], _ key: String, at path: String) throws
    -> [String: Any]
  {
    guard let object = root[key] as? [String: Any] else {
      throw DiagnosticsPayloadError.invalid("\(path).\(key)")
    }
    return object
  }

  private static func string<T: RawRepresentable>(
    _ root: [String: Any], _ key: String, at path: String, allowed: [T]
  ) throws -> T where T.RawValue == String {
    guard let raw = root[key] as? String, let result = allowed.first(where: { $0.rawValue == raw }) else {
      throw DiagnosticsPayloadError.invalid("\(path).\(key)")
    }
    return result
  }

  private static func enumString<T: RawRepresentable>(_ value: Any?, _ allowed: [T]) -> Bool
  where T.RawValue == String {
    guard let value = value as? String else { return false }
    return allowed.contains { $0.rawValue == value }
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double,
      double >= Double(Int.min), double <= Double(Int.max)
    else { return nil }
    return Int(double)
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return number.doubleValue
  }

  private static func requireBoolean(_ value: Any?, _ path: String) throws {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw DiagnosticsPayloadError.invalid(path)
    }
  }

  private static func boundedString(_ value: Any?, _ bounds: ClosedRange<Int>, pattern: String) -> Bool {
    guard let value = value as? String, bounds.contains(value.utf8.count),
      value.range(of: pattern, options: .regularExpression) != nil
    else { return false }
    return true
  }

  private static func printableFour(_ value: String) -> Bool {
    value.utf8.count == 4 && value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
  }

  private static func optionalBoundedInteger(_ value: Any?, range: ClosedRange<Int>) -> Int? {
    guard let value else { return nil }
    guard let result = integer(value), range.contains(result) else { return nil }
    return result
  }

  private static func decimalPlaces(_ value: Double) -> Int {
    let rounded = (value * 1_000).rounded() / 1_000
    return abs(rounded - value) < 0.000_000_1 ? 3 : 4
  }

  private static func containsNull(_ value: Any) -> Bool {
    if value is NSNull { return true }
    if let array = value as? [Any] { return array.contains(where: containsNull) }
    if let object = value as? [String: Any] { return object.values.contains(where: containsNull) }
    return false
  }

  private static func maximumDepth(_ value: Any, depth: Int = 1) -> Int {
    if let array = value as? [Any] {
      return array.map { maximumDepth($0, depth: depth + 1) }.max() ?? depth
    }
    if let object = value as? [String: Any] {
      return object.values.map { maximumDepth($0, depth: depth + 1) }.max() ?? depth
    }
    return depth
  }
}
