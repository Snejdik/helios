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

  /// Read-only display maps for the other Apple Silicon generations, derived from the
  /// MIT-licensed Stats sensor catalogue (see THIRD_PARTY_NOTICES.md). They are exact
  /// per-generation key lists: the same key means different things on different chips
  /// (`Tp09` is an efficiency core on M1 but a performance core on M2), and a prefix is
  /// never trusted. Only the M4 family is physically validated, so these maps are used
  /// for showing temperatures and never for fan control or the privileged helper.
  /// M5/M6 "super" cores are folded into the performance group.
  private struct DisplayMap {
    let performance: Set<String>
    let efficiency: Set<String>
    let gpu: Set<String>
  }

  private static let displayMaps: [Int: DisplayMap] = [
    1: DisplayMap(
      performance: ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
      efficiency: ["Tp09", "Tp0T"],
      gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"]),
    2: DisplayMap(
      performance: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
      efficiency: ["Tp1h", "Tp1t", "Tp1p", "Tp1l"],
      gpu: ["Tg0f", "Tg0j"]),
    3: DisplayMap(
      performance: [
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D",
        "Tf4E",
      ],
      efficiency: ["Te05", "Te0L", "Te0P", "Te0S"],
      gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]),
    5: DisplayMap(
      performance: [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u",
        "Tp0y",
      ],
      efficiency: [],
      gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]),
    6: DisplayMap(
      performance: [
        "Tp0j", "Tp0g", "Tp09", "Tp07",
        "Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05",
      ],
      efficiency: ["Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"],
      gpu: [
        "Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g",
        "Tg1h",
      ]),
  ]

  /// "Apple M2 Max" -> 2. Anything that is not an exact `Apple M<number>[ variant]` is nil,
  /// so "Apple M10" can never be mistaken for M1.
  static func generation(ofCPUBrand brand: String) -> Int? {
    guard brand.hasPrefix("Apple M") else { return nil }
    let rest = brand.dropFirst("Apple M".count)
    let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
    guard !digits.isEmpty, digits.count <= 2,
      rest.dropFirst(digits.count).isEmpty || rest.dropFirst(digits.count).first == " "
    else { return nil }
    return Int(digits)
  }

  /// Identity for showing and summarizing a temperature. Equal to `group(for:)` wherever that
  /// is known (so the M4 family is unchanged); otherwise the read-only catalogue map for this
  /// chip generation, else unclassified.
  func displayGroup(for key: String) -> ThermalGroup {
    let trusted = group(for: key)
    if trusted != .unclassified { return trusted }
    guard let generation = Self.generation(ofCPUBrand: cpuBrand),
      let map = Self.displayMaps[generation]
    else { return .unclassified }
    if map.performance.contains(key) { return .performanceCPU }
    if map.efficiency.contains(key) { return .efficiencyCPU }
    if map.gpu.contains(key) { return .gpu }
    return .unclassified
  }

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

  /// Display-only sensors below this are treated as not measuring (values such as 6.2 or 6.7 °C
  /// are reported on some chips by inactive channels). Not a thermal safety limit.
  private static let displayMinimumCelsius = 10.0

  private let client: SMCClient
  private let classifier: ThermalClassifier

  private var trustedTemperatureKeys: [String]?
  private var advisoryTemperatureKeys: [String]?
  /// Keys identified only by the read-only display map (chips other than the M4 family).
  /// Sampled at the fast cadence so the headline temperature stays live, but their
  /// failures are raw evidence and never count as trusted thermal health or fan-guard input.
  private var displayTemperatureKeys: [String]?
  private var discoveryFailures: [String: TelemetryError] = [:]
  private var trustedDiscoveryFailures: [String: TelemetryError] = [:]
  private var nextDiscoveryRetry: ContinuousClock.Instant?

  private var cachedAdvisoryReadings: [ThermalReading] = []
  private var cachedAdvisoryFailures: [String: TelemetryError] = [:]
  private var advisoryReadingsCapturedAt: Date?
  private var nextAdvisoryRefresh: ContinuousClock.Instant?

  init(client: SMCClient, classifier: ThermalClassifier) {
    self.client = client
    self.classifier = classifier
  }

  private var rawDetailsWereVisible = false

  func read(rawDetailsVisible: Bool = true, forceRawRefresh: Bool = false,
    now: ContinuousClock.Instant = .now) throws -> ThermalMetrics {
    let newlyVisible = rawDetailsVisible && !rawDetailsWereVisible
    rawDetailsWereVisible = rawDetailsVisible
    try discoverTemperatureKeysIfNeeded(now: now)

    let trustedKeys = trustedTemperatureKeys ?? []
    let advisoryKeys = advisoryTemperatureKeys ?? []
    let displayKeys = displayTemperatureKeys ?? []
    guard !trustedKeys.isEmpty || !displayKeys.isEmpty || !advisoryKeys.isEmpty
      || !discoveryFailures.isEmpty
    else {
      throw TelemetryError.unavailable("No supported SMC temperature keys discovered")
    }

    // Safety-relevant curated keys are always fresh on every thermal poll.
    let trustedBatch = read(keys: trustedKeys)
    // Display-identified keys are live too, but only plausible temperatures count: some chips
    // report constant low values (single digits) from sensors that are not really measuring.
    let displayBatch = read(keys: displayKeys, minimumCelsius: Self.displayMinimumCelsius)

    // Raw/unclassified keys are expert diagnostics, not control inputs. Reading
    // 100+ undocumented SMC channels every 1–2 seconds is needless monitoring
    // overhead, so refresh them at a relaxed cadence and expose their age.
    let shouldRefreshAdvisory =
      !advisoryKeys.isEmpty
      && (forceRawRefresh || newlyVisible || advisoryReadingsCapturedAt == nil
        || nextAdvisoryRefresh.map { now >= $0 } ?? true)

    if shouldRefreshAdvisory {
      // Age the advisory batch from its first read, not the end of potentially
      // slow driver calls. This is diagnostic freshness only, never safety data.
      let advisoryStartedAt = Date()
      let advisoryBatch = read(keys: advisoryKeys)
      cachedAdvisoryReadings = advisoryBatch.readings
      cachedAdvisoryFailures = advisoryBatch.failures
      advisoryReadingsCapturedAt = advisoryStartedAt
      // Frozen FanControlModel conservatively checks raw Tp/Te/Tg failures.
      // Keep its existing 15-second advisory evidence cadence even when hidden;
      // do not reinterpret those prefixes as trusted temperature identities.
      let hasLegacyFanGuardKeys = advisoryKeys.contains {
        $0.hasPrefix("Tp") || $0.hasPrefix("Te") || $0.hasPrefix("Tg")
      }
      nextAdvisoryRefresh = now.advanced(by: TelemetryDetailPolicy.interval(
        visible: rawDetailsVisible || hasLegacyFanGuardKeys,
        foreground: Self.advisoryRefreshInterval,
        background: TelemetryDetailPolicy.backgroundRawSensorInterval))
    }

    let readings = trustedBatch.readings + displayBatch.readings + cachedAdvisoryReadings

    // Preserve the complete raw/per-key failure inventory for expert surfaces.
    var failures = discoveryFailures
    failures.merge(trustedBatch.failures, uniquingKeysWith: { _, newest in newest })
    failures.merge(displayBatch.failures, uniquingKeysWith: { _, newest in newest })
    failures.merge(cachedAdvisoryFailures, uniquingKeysWith: { _, newest in newest })

    // Ordinary provider health uses only exact classifier-trusted failures.
    // Frozen fan readiness remains additionally conservative about raw prefixes,
    // as noted in the cadence policy above; its guard is not broadened here.
    var trustedFailures = trustedDiscoveryFailures
    trustedFailures.merge(trustedBatch.failures, uniquingKeysWith: { _, newest in newest })

    // Keep even an empty decoded batch as explicit per-key evidence. Choosing
    // an arbitrary raw error here could mask a trusted I/O failure, turn an
    // optional decode error into a provider failure episode, and lose the raw
    // inventory. No valid trusted maximum still means no usable temperature;
    // the diagnostics builder classifies trusted failures/no_data separately,
    // and frozen fan readiness still requires all trusted groups and a maximum.
    return ThermalMetrics(
      readings: readings,
      failures: failures,
      trustedFailures: trustedFailures,
      advisoryReadingsCapturedAt: advisoryReadingsCapturedAt)
  }

  private func discoverTemperatureKeysIfNeeded(now: ContinuousClock.Instant) throws {
    if let nextDiscoveryRetry, now >= nextDiscoveryRetry {
      // Retry incomplete discovery at a bounded cadence. Cached metadata/read
      // failures must not permanently hide a key after its transport recovers.
      trustedTemperatureKeys = nil
      advisoryTemperatureKeys = nil
      displayTemperatureKeys = nil
      cachedAdvisoryReadings = []
      cachedAdvisoryFailures = [:]
      advisoryReadingsCapturedAt = nil
      nextAdvisoryRefresh = nil
      self.nextDiscoveryRetry = nil
    }
    guard trustedTemperatureKeys == nil || advisoryTemperatureKeys == nil
      || displayTemperatureKeys == nil
    else { return }

    let discovered = try client.discoverKeys()
    discoveryFailures = discovered.failures

    // A discovery gap has no trustworthy key identity. It may have hidden a
    // safety-relevant thermal channel, so unknown enumeration failures remain
    // health-blocking even though known unclassified channels do not.
    trustedDiscoveryFailures = discovered.failures

    var trusted: [String] = []
    var advisory: [String] = []
    var display: [String] = []

    for key in discovered.keys where key.hasPrefix("T") {
      let group = classifier.group(for: key)
      let displayOnly = group == .unclassified && classifier.displayGroup(for: key) != .unclassified

      switch captureMetric({ try client.keyInfo(key) }) {
      case .success(let info):
        guard (info.type == "sp78" && info.size == 2) || (info.type == "flt " && info.size == 4)
        else {
          let error = TelemetryError.unsupportedSensorFormat(key)
          discoveryFailures[key] = error

          if group != .unclassified {
            trustedDiscoveryFailures[key] = error
          }
          continue
        }

        if displayOnly {
          display.append(key)
        } else if group == .unclassified {
          advisory.append(key)
        } else {
          trusted.append(key)
        }

      case .failure(let error):
        discoveryFailures[key] = error

        if group != .unclassified {
          trustedDiscoveryFailures[key] = error
        }
      }
    }

    trustedTemperatureKeys = trusted.sorted()
    advisoryTemperatureKeys = advisory.sorted()
    displayTemperatureKeys = display.sorted()
    let needsRetry = !trustedDiscoveryFailures.isEmpty || discoveryFailures.values.contains { error in
      switch error {
      case .kernel, .ioKit, .smc, .unavailable: true
      case .invalidData, .warmingUp: false
      }
    }
    nextDiscoveryRetry = needsRetry ? now.advanced(by: .seconds(30)) : nil
  }

  private func read(keys: [String], minimumCelsius: Double = 0) -> (
    readings: [ThermalReading], failures: [String: TelemetryError]
  ) {
    var readings: [ThermalReading] = []
    readings.reserveCapacity(keys.count)
    var failures: [String: TelemetryError] = [:]

    for key in keys {
      switch captureMetric({
        let value = try client.value(key)
        let celsius = try SMCCodec.temperature(type: value.info.type, bytes: value.bytes)
        // A power-gated cluster reports zero or a small negative value (GPU keys read -4.5 °C on
        // Mac16,1 while the GPU sleeps). That is a sensor not measuring right now, not a fault.
        // The key stays in `failures` as evidence. Data validation, not a safety limit.
        guard celsius > minimumCelsius else { throw TelemetryError.inactiveSensor(key) }
        guard celsius <= 150 else {
          throw TelemetryError.invalidData("\(key) outside plausible temperature range")
        }
        return ThermalReading(
          key: key, group: classifier.group(for: key), celsius: celsius,
          displayGroup: classifier.displayGroup(for: key))
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

extension TelemetryError {
  /// A temperature sensor that is switched off right now (for example a power-gated GPU
  /// cluster) rather than failing. It is not measuring, so it is neither a reading nor a fault.
  static func inactiveSensor(_ key: String) -> TelemetryError { .unavailable("\(key) inactive") }

  var isInactiveSensor: Bool {
    if case .unavailable(let reason) = self { return reason.hasSuffix(" inactive") }
    return false
  }

  /// A temperature key stored in a format Helios does not decode (for example the 8-byte
  /// `ioft` keys on Apple Silicon). Known limitation, kept as raw evidence.
  static func unsupportedSensorFormat(_ key: String) -> TelemetryError {
    .invalidData("Unsupported temperature type/size for \(key)")
  }

  var isUnsupportedSensorFormat: Bool {
    if case .invalidData(let reason) = self { return reason.hasPrefix("Unsupported temperature type/size") }
    return false
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

  func sample(rawDetailsVisible: Bool = true, forceRawRefresh: Bool = false) -> MetricSample<ThermalMetrics> {
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
      return try reader.read(rawDetailsVisible: rawDetailsVisible, forceRawRefresh: forceRawRefresh)
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
    try Task.checkCancellation()
    guard (1...2_048).contains(maximumReadings) else {
      throw TelemetryError.invalidData("Invalid SMC numeric inventory bound")
    }
    let discovered = try client.discoverKeys()
    // Frozen discovery and an in-flight IOKit call cannot be interrupted.
    try Task.checkCancellation()
    var readings: [SMCNumericReading] = []
    readings.reserveCapacity(min(maximumReadings, discovered.keys.count))
    var failures = discovered.failures
    var truncated = false

    for key in discovered.keys where key != "#KEY" {
      try Task.checkCancellation()
      if readings.count >= maximumReadings {
        truncated = true
        break
      }
      let infoResult = captureMetric { try client.keyInfo(key) }
      try Task.checkCancellation()
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
      try Task.checkCancellation()
      if reader == nil {
        reader = SMCNumericReader(client: SMCClient(transport: try SMCIOKitTransport()))
      }
      try Task.checkCancellation()
      guard let reader else {
        throw TelemetryError.unavailable("SMC numeric inventory unavailable")
      }
      return try reader.read(maximumReadings: maximumReadings)
    }
    if case .failure = result { reader = nil }
    return MetricSample(result, capturedAt: capturedAt, capturedTicks: capturedTicks)
  }
}
