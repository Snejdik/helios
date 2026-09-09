import Darwin
import Foundation
import OSLog

struct ThermalClassifier {
  let cpuBrand: String

  // Curated M4-family thermal-zone keys. Do not classify an arbitrary `Tp`,
  // `Te`, or `Tg` prefix as trusted SoC temperature data: undocumented SMC
  // namespaces evolve and a newly discovered key must not silently become a
  // fan-control input. The sets are the currently source-visible Stats M4
  // mappings plus the M4 Pro replacements independently reported in 2026.
  // References:
  // - github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
  // - github.com/exelban/stats/issues/3270
  // Missing keys are harmless because discovery only reads keys present on
  // this Mac; unknown keys remain visible as `.unclassified` diagnostics.
  private static let m4PerformanceCPUKeys: Set<String> = [
    "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
  ]
  private static let m4EfficiencyCPUKeys: Set<String> = [
    "Te05", "Te06", "Te09", "Te0H", "Te0S", "Te0T",
  ]
  private static let m4GPUKeys: Set<String> = [
    "Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k",
  ]

  func group(for key: String) -> ThermalGroup {
    guard cpuBrand == "Apple M4" || cpuBrand.hasPrefix("Apple M4 ") else { return .unclassified }
    if Self.m4PerformanceCPUKeys.contains(key) { return .performanceCPU }
    if Self.m4EfficiencyCPUKeys.contains(key) { return .efficiencyCPU }
    if Self.m4GPUKeys.contains(key) { return .gpu }
    return .unclassified
  }

  static func native() throws -> Self {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else {
      throw TelemetryError.kernel("Read CPU identity", errno)
    }
    guard size > 0, size <= 256 else {
      throw TelemetryError.invalidData("Invalid CPU identity size")
    }
    var bytes = [UInt8](repeating: 0, count: size)
    let status = bytes.withUnsafeMutableBytes {
      sysctlbyname("machdep.cpu.brand_string", $0.baseAddress, &size, nil, 0)
    }
    guard status == 0 else { throw TelemetryError.kernel("Read CPU identity", errno) }
    guard size <= bytes.count else { throw TelemetryError.invalidData("Truncated CPU identity") }
    return Self(
      cpuBrand: String(decoding: bytes.prefix(size).prefix(while: { $0 != 0 }), as: UTF8.self))
  }
}

/// UI-only interpretation of raw thermal channels. This layer deliberately does
/// not alter `ThermalGroup`, Max SoC, Cooling Rules, health thresholds, or fan
/// safety. Apple does not publish the meaning of most Apple Silicon SMC keys;
/// names below are conservative community mappings used only to make the expert
/// inventory understandable.
enum ThermalDisplayKind: String, Sendable {
  case knownAuxiliary
  case communityAuxiliary
  case virtualOrDerived
  case placeholderCandidate
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
  /// Exact auxiliary mappings that are independently present in the public
  /// Stats Apple-Silicon sensor catalogue. "Known" here means corroborated by
  /// open monitoring projects, not documented by Apple. They remain display-
  /// only in Helios.
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

  /// Exact community Apple-SMC mappings corroborated by open sensor catalogs.
  /// Apple does not publish these meanings, so they are advisory only.
  private static let communityAuxiliary: [String: String] = [
    "TCMz": "CPU die maximum",
    "TCMb": "CPU die average",
    "TCDX": "CPU die aggregate",
    "TaLT": "Thunderbolt left proximity",
    "TaRT": "Thunderbolt right proximity",
    "TaLW": "Airflow left wall",
    "TaRW": "Airflow right wall",
    "TaFL": "Airflow front left",
    "TaFR": "Airflow front right",
    "TaRL": "Airflow rear left",
    "TaRR": "Airflow rear right",
    "TAOL": "Ambient outside lid",
    "TaTP": "Ambient top proximity",
    "TS0P": "SSD proximity 1",
    "TS1P": "SSD proximity 2",
    "TSVR": "SoC regulator V",
    "TSWR": "SoC regulator W",
    "TSXR": "SoC regulator X",
    "TSG1": "Thermal sensor group 1",
    "TSG2": "Thermal sensor group 2",
    "TPSD": "Power-supply diode",
    "TT0P": "Thunderbolt proximity",
    "TDBP": "Board diode · battery proximity",
    "TDEL": "Board diode · edge left",
    "TDER": "Board diode · edge right",
    "TDeL": "Board diode · edge left (case variant)",
    "TDeR": "Board diode · edge right (case variant)",
    "TDTP": "Board diode · top proximity",
    "TDTC": "Board diode · top center",
    "TDCR": "Board diode · center right",
    "TDEC": "Board diode · edge center",
    "TDVx": "Board diode · virtual",
    "TR0Z": "RF thermal reference",
    "TR1d": "RF thermal probe 1",
    "TR2d": "RF thermal probe 2",
    "TR3d": "RF thermal probe 3",
    "TR4d": "RF thermal probe 4",
    "TR5d": "RF thermal probe 5",
  ]

  /// Case-sensitive TVM keys explicitly catalogued by community projects.
  /// The user's observed `TVMS` is intentionally *not* collapsed into this
  /// table: SMC keys are case-sensitive, so an unknown case variant receives a
  /// family-level label rather than a false exact identity.
  private static let virtualMemoryExact: [String: String] = [
    "TVMR": "Virtual memory",
    "TVMr": "Virtual memory r",
    "TVmS": "Virtual memory summary",
    "TVms": "Virtual memory summary",
    "TVMX": "Virtual memory summary",
    "TVM0": "Virtual memory 0",
    "TVM4": "Virtual memory hottest channel",
    "TVm0": "Virtual memory m0",
    "TVm1": "Virtual memory m1",
    "TVm2": "Virtual memory m2",
    "TVh0": "Virtual memory bank h0",
    "TVh1": "Virtual memory bank h1",
    "TVh2": "Virtual memory bank h2",
    "TVMC": "Virtual memory cluster",
  ]

  static func classify(_ readings: [ThermalReading]) -> [ThermalDisplayReading] {
    readings.map { reading in
      ThermalDisplayReading(reading: reading, info: info(for: reading, allReadings: readings))
    }
  }

  static func info(for reading: ThermalReading, allReadings: [ThermalReading]) -> ThermalDisplayInfo
  {
    if let title = knownAuxiliary[reading.key] {
      return ThermalDisplayInfo(
        title: title,
        kind: .knownAuxiliary,
        detail:
          "Corroborated community Apple-Silicon mapping. Informational only; not a fan-safety input."
      )
    }
    if let title = communityAuxiliary[reading.key] {
      return ThermalDisplayInfo(
        title: title,
        kind: .communityAuxiliary,
        detail:
          "Community SMC mapping. Apple does not document this key; Helios keeps it advisory only."
      )
    }
    if let title = virtualMemoryExact[reading.key] {
      return ThermalDisplayInfo(
        title: title,
        kind: .virtualOrDerived,
        detail:
          "Community-mapped TVM virtual/derived thermal channel. It may differ substantially from physical CPU/GPU temperatures and never enters fan safety."
      )
    }

    if looksLikeInactiveAmbientPlaceholder(reading, among: allReadings) {
      return ThermalDisplayInfo(
        title: "Inactive / placeholder-like ambient channel",
        kind: .placeholderCandidate,
        detail:
          "Several Ta0* channels report the same unusually low value on this Mac. Helios preserves the raw reading but does not treat it as a validated ambient temperature."
      )
    }

    let key = reading.key
    let lower = key.lowercased()
    if lower.hasPrefix("tvm") {
      let exactCaseNote =
        key == "TVMS"
        ? " The exact uppercase TVMS key is not an exact match for the case-sensitive community catalogue, so Helios labels only the TVM* family rather than asserting a precise sensor identity."
        : ""
      return ThermalDisplayInfo(
        title: "TVM* virtual / derived thermal channel",
        kind: .virtualOrDerived,
        detail:
          "Community mappings describe the TVM* family as virtual/derived memory thermal channels. A high value is not automatically a physical hotspot and never enters fan safety.\(exactCaseNote)"
      )
    }
    if lower.hasPrefix("tvd") {
      return ThermalDisplayInfo(
        title: "Virtual die thermal channel",
        kind: .virtualOrDerived,
        detail:
          "Community-mapped firmware-derived/virtual die family. Displayed for diagnostics only."
      )
    }
    if lower.hasPrefix("tva") || lower.hasPrefix("tvs") || lower.hasPrefix("tvv") {
      return ThermalDisplayInfo(
        title: "Virtual thermal channel",
        kind: .virtualOrDerived,
        detail:
          "Community-mapped firmware-derived/virtual sensor family. Displayed for diagnostics only."
      )
    }
    if isSoCThermalDiodeProbe(key) {
      let cluster = Int(String(key[key.index(key.startIndex, offsetBy: 2)])) ?? 0
      return ThermalDisplayInfo(
        title: "SoC thermal-diode cluster \(cluster + 1) probe",
        kind: .communityAuxiliary,
        detail:
          "Community family mapping for TD0*/TD1*/TD2* SoC thermal-diode probes. Exact probe roles are undocumented; advisory only."
      )
    }
    if lower.hasPrefix("tpd") {
      return ThermalDisplayInfo(
        title: lower == "tpdx" ? "Power-delivery maximum" : "Power-delivery thermal channel",
        kind: .communityAuxiliary,
        detail: "Community mapping for the Apple power-delivery thermal family. Informational only."
      )
    }
    if lower.hasPrefix("trd") {
      return ThermalDisplayInfo(
        title: lower == "trdx" ? "RF-delivery maximum" : "RF-delivery thermal channel",
        kind: .communityAuxiliary,
        detail: "Community mapping for the RF-delivery thermal family. Informational only."
      )
    }
    if lower.hasPrefix("th") {
      return ThermalDisplayInfo(
        title: "Heatsink / storage thermal family",
        kind: .communityAuxiliary,
        detail:
          "The TH*/Th* namespace is used by community sensor catalogues for heatsink and storage/NAND probes. Exact identity is not asserted for this key."
      )
    }
    if lower.hasPrefix("tm") {
      return ThermalDisplayInfo(
        title: "Memory thermal family",
        kind: .communityAuxiliary,
        detail:
          "Community family classification only. Exact memory sensor identity is not documented by Apple and is not a safety input."
      )
    }
    if lower.hasPrefix("tb") {
      return ThermalDisplayInfo(
        title: "Battery thermal family",
        kind: .communityAuxiliary,
        detail:
          "Community family classification only. Battery health/charging remains read-only and this raw key does not drive fan policy."
      )
    }
    if lower.hasPrefix("tw") {
      return ThermalDisplayInfo(
        title: "Wi-Fi / wireless thermal family",
        kind: .communityAuxiliary,
        detail: "Community family classification only. Exact role remains undocumented."
      )
    }
    if lower.hasPrefix("ta") {
      return ThermalDisplayInfo(
        title: "Ambient / airflow thermal family",
        kind: .communityAuxiliary,
        detail:
          "Community family classification only. Exact role remains undocumented; unusually-low repeated Ta0* values are separated as placeholder-like instead."
      )
    }
    if lower.hasPrefix("tp") || lower.hasPrefix("te") || lower.hasPrefix("tg") {
      let family: String
      if lower.hasPrefix("tg") {
        family = "GPU-family"
      } else if lower.hasPrefix("te") {
        family = "E-core / die-family"
      } else {
        family = "P-core / processor-family"
      }
      return ThermalDisplayInfo(
        title: "Unvalidated \(family) thermal channel",
        kind: .communityAuxiliary,
        detail:
          "The prefix is associated with this hardware family in community mappings, but this exact key is not in Helios' curated M4 safety allowlist. It remains advisory only."
      )
    }

    return ThermalDisplayInfo(
      title: "Unclassified SMC temperature",
      kind: .unknown,
      detail: "Undocumented raw SMC temperature key. No meaning or safety role is inferred."
    )
  }

  private static func isSoCThermalDiodeProbe(_ key: String) -> Bool {
    guard key.count == 4 else { return false }
    return key.hasPrefix("TD0") || key.hasPrefix("TD1") || key.hasPrefix("TD2")
  }

  private static func looksLikeInactiveAmbientPlaceholder(
    _ reading: ThermalReading, among readings: [ThermalReading]
  ) -> Bool {
    guard reading.key.hasPrefix("Ta0"), reading.celsius < 12 else { return false }
    let family = readings.filter { $0.key.hasPrefix("Ta0") && $0.celsius < 12 }
    guard family.count >= 3,
      let minimum = family.map(\.celsius).min(),
      let maximum = family.map(\.celsius).max()
    else { return false }
    return maximum - minimum <= 0.35
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
