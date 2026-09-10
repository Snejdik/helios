import Darwin
import Foundation
import OSLog

struct ThermalClassifier {
  let cpuBrand: String
  let machineModel: String
  let osBuild: String

  init(cpuBrand: String, machineModel: String = "", osBuild: String = "") {
    self.cpuBrand = cpuBrand
    self.machineModel = machineModel
    self.osBuild = osBuild
  }

  // Exact M4-family thermal-zone mappings derived from the MIT-licensed Stats
  // sensor catalogue. See THIRD_PARTY_NOTICES.md. Prefixes are never trusted:
  // a key must be in one of these exact allowlists.
  private static let m4PerformanceCPUKeys: Set<String> = [
    "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
  ]
  private static let m4EfficiencyCPUKeys: Set<String> = [
    "Te05", "Te09", "Te0H", "Te0S",
  ]
  private static let m4GPUKeys: Set<String> = [
    "Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k",
  ]
  // Direct read-only measurements on Mac16,1 / 25G83 established that Te06 and
  // Te0T are changing thermal channels which can affect conservative Max SoC.
  // Their physical component and CPU-cluster identities remain unknown.
  private static let mac161ValidatedHotspotKeys: Set<String> = ["Te06", "Te0T"]

  func group(for key: String) -> ThermalGroup {
    let isM4Family = cpuBrand == "Apple M4" || cpuBrand.hasPrefix("Apple M4 ")
    if isM4Family, machineModel == "Mac16,1", osBuild == "25G83",
      Self.mac161ValidatedHotspotKeys.contains(key)
    {
      return .validatedHotspot
    }
    guard isM4Family else { return .unclassified }
    if Self.m4PerformanceCPUKeys.contains(key) { return .performanceCPU }
    if Self.m4EfficiencyCPUKeys.contains(key) { return .efficiencyCPU }
    if Self.m4GPUKeys.contains(key) { return .gpu }
    return .unclassified
  }

  static func native() throws -> Self {
    Self(
      cpuBrand: try sysctlString("machdep.cpu.brand_string"),
      machineModel: (try? sysctlString("hw.model")) ?? "",
      osBuild: (try? sysctlString("kern.osversion")) ?? "")
  }

  private static func sysctlString(_ name: String) throws -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
      throw TelemetryError.kernel("Read \(name)", errno)
    }
    guard size > 0, size <= 256 else {
      throw TelemetryError.invalidData("Invalid \(name) size")
    }
    var bytes = [UInt8](repeating: 0, count: size)
    let status = bytes.withUnsafeMutableBytes {
      sysctlbyname(name, $0.baseAddress, &size, nil, 0)
    }
    guard status == 0 else { throw TelemetryError.kernel("Read \(name)", errno) }
    guard size <= bytes.count else { throw TelemetryError.invalidData("Truncated \(name)") }
    return String(decoding: bytes.prefix(size).prefix(while: { $0 != 0 }), as: UTF8.self)
  }
}

/// UI-only interpretation of raw thermal channels. Exact Stats-derived
/// auxiliary mappings retain attributed display names; every other raw key stays
/// explicitly unclassified and never acquires a meaning from its spelling.
enum ThermalDisplayKind: String, Sendable {
  case knownAuxiliary
  case unknown
}

struct ThermalDisplayInfo: Sendable {
  let title: String
  let kind: ThermalDisplayKind
  let detail: String
}

struct ThermalDisplayReading: Identifiable, Sendable {
  let reading: ThermalReading
  let info: ThermalDisplayInfo

  var id: String { reading.key }
}

enum ThermalDisplayClassifier {
  /// Exact display-only mappings derived from the MIT-licensed Stats Apple-
  /// Silicon sensor catalogue. See THIRD_PARTY_NOTICES.md.
  private static let knownAuxiliary: [String: String] = [
    "Tm0p": "Memory proximity 1",
    "Tm1p": "Memory proximity 2",
    "Tm2p": "Memory proximity 3",
    "TaLP": "Airflow left",
    "TaRF": "Airflow right",
    "TH0x": "NAND / storage",
    "TB1T": "Battery sensor 1",
    "TB2T": "Battery sensor 2",
    "TW0P": "Wi-Fi / AirPort proximity",
  ]

  static func classify(_ readings: [ThermalReading]) -> [ThermalDisplayReading] {
    readings.map { reading in
      ThermalDisplayReading(reading: reading, info: info(for: reading, allReadings: readings))
    }
  }

  static func info(for reading: ThermalReading, allReadings _: [ThermalReading]) -> ThermalDisplayInfo
  {
    if let title = knownAuxiliary[reading.key] {
      return ThermalDisplayInfo(
        title: title,
        kind: .knownAuxiliary,
        detail:
          "Attributed Stats Apple-Silicon mapping. Informational only; not a fan-safety input."
      )
    }

    return ThermalDisplayInfo(
      title: "Unclassified SMC temperature",
      kind: .unknown,
      detail: "Undocumented raw SMC temperature key. No meaning or safety role is inferred."
    )
  }
}

final class SMCThermalReader {
  /// Curated SoC keys used by Max SoC / Cooling Rules stay on the fast thermal
  /// cadence. The much larger undocumented raw inventory is diagnostic-only and
  /// deliberately sampled more slowly to keep Helios from warming the Mac just
  /// by monitoring it.
  private static let advisoryRefreshInterval: Duration = .seconds(15)

  private let client: SMCClient
  private let classifier: ThermalClassifier

  private var trustedTemperatureKeys: [String]?
  private var advisoryTemperatureKeys: [String]?
  private var discoveryFailures: [String: TelemetryError] = [:]

  private var cachedAdvisoryReadings: [ThermalReading] = []
  private var cachedAdvisoryFailures: [String: TelemetryError] = [:]
  private var advisoryReadingsCapturedAt: Date?
  private var nextAdvisoryRefresh: ContinuousClock.Instant?

  init(client: SMCClient, classifier: ThermalClassifier) {
    self.client = client
    self.classifier = classifier
  }

  func read() throws -> ThermalMetrics {
    try discoverTemperatureKeysIfNeeded()

    let trustedKeys = trustedTemperatureKeys ?? []
    let advisoryKeys = advisoryTemperatureKeys ?? []
    guard !trustedKeys.isEmpty || !advisoryKeys.isEmpty else {
      throw TelemetryError.unavailable("No supported SMC temperature keys discovered")
    }

    // Safety-relevant curated keys are always fresh on every thermal poll.
    let trustedBatch = read(keys: trustedKeys)

    // Raw/unclassified keys are expert diagnostics, not control inputs. Reading
    // 100+ undocumented SMC channels every 1–2 seconds is needless monitoring
    // overhead, so refresh them at a relaxed cadence and expose their age.
    let now = ContinuousClock.now
    let shouldRefreshAdvisory =
      !advisoryKeys.isEmpty
      && (advisoryReadingsCapturedAt == nil
        || nextAdvisoryRefresh.map { now >= $0 } ?? true)

    if shouldRefreshAdvisory {
      let advisoryBatch = read(keys: advisoryKeys)
      cachedAdvisoryReadings = advisoryBatch.readings
      cachedAdvisoryFailures = advisoryBatch.failures
      advisoryReadingsCapturedAt = Date()
      nextAdvisoryRefresh = now.advanced(by: Self.advisoryRefreshInterval)
    }

    let readings = trustedBatch.readings + cachedAdvisoryReadings
    var failures = discoveryFailures
    failures.merge(trustedBatch.failures, uniquingKeysWith: { _, newest in newest })
    failures.merge(cachedAdvisoryFailures, uniquingKeysWith: { _, newest in newest })

    guard !readings.isEmpty else {
      let firstFailure = failures.keys.sorted().first.flatMap { failures[$0] }
      throw firstFailure ?? TelemetryError.unavailable("No valid SMC temperature readings")
    }

    return ThermalMetrics(
      readings: readings,
      failures: failures,
      advisoryReadingsCapturedAt: advisoryReadingsCapturedAt)
  }

  private func discoverTemperatureKeysIfNeeded() throws {
    guard trustedTemperatureKeys == nil || advisoryTemperatureKeys == nil else { return }

    let discovered = try client.discoverKeys()
    discoveryFailures = discovered.failures
    var trusted: [String] = []
    var advisory: [String] = []

    for key in discovered.keys where key.hasPrefix("T") {
      switch captureMetric({ try client.keyInfo(key) }) {
      case .success(let info):
        guard (info.type == "sp78" && info.size == 2) || (info.type == "flt " && info.size == 4)
        else {
          discoveryFailures[key] = .invalidData("Unsupported temperature type/size for \(key)")
          continue
        }
        if classifier.group(for: key) == .unclassified {
          advisory.append(key)
        } else {
          trusted.append(key)
        }
      case .failure(let error):
        discoveryFailures[key] = error
      }
    }

    trustedTemperatureKeys = trusted.sorted()
    advisoryTemperatureKeys = advisory.sorted()
  }

  private func read(keys: [String]) -> (
    readings: [ThermalReading], failures: [String: TelemetryError]
  ) {
    var readings: [ThermalReading] = []
    readings.reserveCapacity(keys.count)
    var failures: [String: TelemetryError] = [:]

    for key in keys {
      switch captureMetric({
        let value = try client.value(key)
        let celsius = try SMCCodec.temperature(type: value.info.type, bytes: value.bytes)
        // Zero commonly means an inactive sensor. This is data validation,
        // not a thermal safety limit or a fan-control threshold.
        guard celsius > 0, celsius <= 150 else {
          throw TelemetryError.invalidData("\(key) inactive or outside plausible temperature range")
        }
        return ThermalReading(key: key, group: classifier.group(for: key), celsius: celsius)
      }) {
      case .success(let reading):
        readings.append(reading)
      case .failure(let error):
        failures[key] = error
      }
    }
    return (readings, failures)
  }
}

actor ThermalProvider {
  private let logger = Logger(subsystem: "com.snejda.Helios", category: "Thermals")
  private var reader: SMCThermalReader?
  private var retryAfter: ContinuousClock.Instant?
  private var lastFailure: TelemetryError?

  func reset() {
    reader = nil
    retryAfter = nil
    lastFailure = nil
  }

  func sample() -> MetricSample<ThermalMetrics> {
    if let retryAfter, ContinuousClock.now < retryAfter, let lastFailure {
      return MetricSample(.failure(lastFailure))
    }
    // Conservatively age the complete batch from its first read. A slow
    // driver call must not make earlier readings appear newly captured.
    let capturedAt = Date()
    let capturedTicks = HostClock.now
    let result = captureMetric {
      if reader == nil {
        let transport = try SMCIOKitTransport()
        // Identity failure only disables grouping, not sensor discovery.
        let identity = captureMetric { try ThermalClassifier.native() }
        let classifier: ThermalClassifier
        switch identity {
        case .success(let value): classifier = value
        case .failure(let error):
          logger.error("SoC grouping unavailable: \(error.localizedDescription, privacy: .public)")
          classifier = ThermalClassifier(cpuBrand: "")
        }
        reader = SMCThermalReader(client: SMCClient(transport: transport), classifier: classifier)
      }
      guard let reader else { throw TelemetryError.unavailable("Thermal reader unavailable") }
      return try reader.read()
    }
    if case .failure(let error) = result {
      reader = nil
      lastFailure = error
      retryAfter = ContinuousClock.now.advanced(by: .seconds(30))
    } else {
      lastFailure = nil
      retryAfter = nil
    }
    return MetricSample(result, capturedAt: capturedAt, capturedTicks: capturedTicks)
  }
}

// MARK: - Expert raw SMC numeric inventory

/// Read-only expert inventory of numeric SMC channels. Values are intentionally
/// unitless unless another dedicated provider has independently established a
/// unit/meaning (for example trusted thermal sensors or PSTR system power).
/// Unknown SMC names are never promoted into fan safety or policy inputs.
struct SMCNumericReading: Sendable, Equatable, Identifiable {
  let key: String
  let type: String
  let value: Double

  var id: String { key }
}

struct SMCNumericMetrics: Sendable, Equatable {
  let readings: [SMCNumericReading]
  let failures: [String: TelemetryError]
  let truncated: Bool
}

final class SMCNumericReader {
  private let client: SMCClient

  init(client: SMCClient) { self.client = client }

  func read(maximumReadings: Int = 512) throws -> SMCNumericMetrics {
    guard (1...2_048).contains(maximumReadings) else {
      throw TelemetryError.invalidData("Invalid SMC numeric inventory bound")
    }
    let discovered = try client.discoverKeys()
    var readings: [SMCNumericReading] = []
    readings.reserveCapacity(min(maximumReadings, discovered.keys.count))
    var failures = discovered.failures
    var truncated = false

    for key in discovered.keys where key != "#KEY" {
      if readings.count >= maximumReadings {
        truncated = true
        break
      }
      let infoResult = captureMetric { try client.keyInfo(key) }
      guard case .success(let info) = infoResult else {
        if case .failure(let error) = infoResult { failures[key] = error }
        continue
      }
      guard Self.isNumeric(info) else { continue }
      switch captureMetric({
        let raw = try client.value(key)
        let value = try SMCCodec.numeric(type: raw.info.type, bytes: raw.bytes)
        guard value.isFinite else {
          throw TelemetryError.invalidData("Non-finite SMC numeric value for \(key)")
        }
        return SMCNumericReading(key: key, type: raw.info.type, value: value)
      }) {
      case .success(let reading): readings.append(reading)
      case .failure(let error): failures[key] = error
      }
    }
    guard !readings.isEmpty else {
      throw TelemetryError.unavailable("No supported numeric SMC channels discovered")
    }
    return SMCNumericMetrics(
      readings: readings.sorted { $0.key < $1.key }, failures: failures, truncated: truncated)
  }

  private static func isNumeric(_ info: SMCKeyInfo) -> Bool {
    switch info.type {
    case "flt ": return info.size == 4
    case "ui8 ", "si8 ": return info.size == 1
    case "ui16", "si16": return info.size == 2
    case "ui32", "si32": return info.size == 4
    default:
      let chars = Array(info.type)
      guard chars.count == 4, info.size == 2,
        chars[0] == "s" || chars[0] == "f", chars[1] == "p",
        Int(String(chars[2]), radix: 16) != nil,
        Int(String(chars[3]), radix: 16) != nil
      else { return false }
      return true
    }
  }
}

actor SMCNumericProvider {
  private var reader: SMCNumericReader?

  func reset() { reader = nil }

  /// Deliberately on-demand. Enumerating many undocumented SMC keys is useful
  /// for an Expert view but does not belong in the normal background cadence.
  func sample(maximumReadings: Int = 512) -> MetricSample<SMCNumericMetrics> {
    let capturedAt = Date()
    let capturedTicks = HostClock.now
    let result = captureMetric {
      if reader == nil {
        reader = SMCNumericReader(client: SMCClient(transport: try SMCIOKitTransport()))
      }
      guard let reader else {
        throw TelemetryError.unavailable("SMC numeric inventory unavailable")
      }
      return try reader.read(maximumReadings: maximumReadings)
    }
    if case .failure = result { reader = nil }
    return MetricSample(result, capturedAt: capturedAt, capturedTicks: capturedTicks)
  }
}
