import Foundation

struct DiagnosticsCompatibilityEvidence: Sendable {
  let rawHardware: DiagnosticsRawHardware
  let thermalClassifications: [DiagnosticsThermalClassification]
  let fanTopologyClass: DiagnosticsFanTopologyClass
  let safelyObservedFanCount: Int?
  let compatibilityState: DiagnosticsCompatibilityState
}

enum DiagnosticsCompatibilityAssembler {
  static func report(
    common: DiagnosticsCommonFields,
    evidence: DiagnosticsCompatibilityEvidence,
    generatedAt: Date
  ) -> DiagnosticsCompatibilityReport {
    let system = DiagnosticsSystem(
      macOSVersion: common.system.macOSVersion, macOSBuild: common.system.macOSBuild,
      machineModel: common.system.machineModel, architecture: common.system.architecture,
      appleSiliconFamily: common.system.appleSiliconFamily,
      memoryBucketGiB: common.system.memoryBucketGiB,
      fanCount: evidence.safelyObservedFanCount ?? common.system.fanCount,
      batteryPresent: common.system.batteryPresent)
    return DiagnosticsCompatibilityReport(
      schemaVersion: 1, reportType: .manualCompatibility,
      generatedAt: DiagnosticsTimestamp.minuteUTC(generatedAt),
      reportReason: .userInitiatedCompatibility, helios: common.helios, system: system,
      capabilities: common.capabilities, providers: common.providers, helper: common.helper,
      runtime: common.runtime, stability: common.stability, rawHardware: evidence.rawHardware,
      heliosClassification: DiagnosticsHeliosClassification(
        thermalChannels: evidence.thermalClassifications,
        fanTopologyClass: evidence.fanTopologyClass,
        compatibilityState: evidence.compatibilityState))
  }
}

/// Runs only after the user explicitly requests compatibility-report generation.
/// Its transport can express SMC reads only; raw bytes never leave this actor.
actor DiagnosticsCompatibilityProbe {
  private let transportFactory: @Sendable () throws -> any SMCReadTransport
  private let classifierFactory: @Sendable () -> ThermalClassifier

  init(
    transportFactory: @escaping @Sendable () throws -> any SMCReadTransport = {
      try SMCIOKitTransport()
    },
    classifierFactory: @escaping @Sendable () -> ThermalClassifier = {
      (try? ThermalClassifier.native()) ?? ThermalClassifier(cpuBrand: "")
    }
  ) {
    self.transportFactory = transportFactory
    self.classifierFactory = classifierFactory
  }

  func gather() -> DiagnosticsCompatibilityEvidence {
    let client: SMCClient
    do {
      client = SMCClient(transport: try transportFactory())
    } catch let error as TelemetryError {
      return unavailableEvidence(error, stage: .open)
    } catch {
      return unavailableEvidence(.unavailable("SMC open unavailable"), stage: .open)
    }

    let classifier = classifierFactory()
    var diagnostics: [DiagnosticsProviderDiagnostic] = []
    var thermal: [DiagnosticsSMCThermalDiscovery] = []
    var classifications: [DiagnosticsThermalClassification] = []

    do {
      let discovery = try client.discoverKeys()
      if !discovery.failures.isEmpty {
        diagnostics.append(
          diagnostic(
            provider: .thermal, stage: .discover, error: .invalidData("Discovery gaps"),
            occurrences: discovery.failures.count))
      }
      let thermalKeys = discovery.keys.filter { $0.hasPrefix("T") }
      if thermalKeys.count > 512 {
        diagnostics.append(
          diagnostic(
            provider: .thermal, stage: .validate,
            error: .invalidData("Thermal discovery exceeded report bound"),
            occurrences: thermalKeys.count - 512))
      }
      for key in thermalKeys.prefix(512) {
        let item = thermalItem(key: key, client: client)
        thermal.append(item)
        classifications.append(
          DiagnosticsThermalClassification(
            key: key, semanticGroup: semanticGroup(classifier.group(for: key)),
            classificationSource: "helios_rule_v1"))
        if let category = item.failureCategory {
          diagnostics.append(
            DiagnosticsProviderDiagnostic(
              provider: .thermal,
              stage: item.readState == .decodeFailed ? .decode : .read,
              category: category, codeDomain: nil, numericCode: nil, occurrences: .one))
        }
      }
    } catch let error as TelemetryError {
      diagnostics.append(diagnostic(provider: .thermal, stage: .discover, error: error))
    } catch {
      diagnostics.append(
        diagnostic(
          provider: .thermal, stage: .discover,
          error: .unavailable("SMC discovery unavailable")))
    }

    let fanResult = fanEvidence(client: client)
    diagnostics.append(contentsOf: fanResult.diagnostics)

    let thermalGroups = Dictionary(
      uniqueKeysWithValues: classifications.map { ($0.key, $0.semanticGroup) })

    // Raw/unclassified channels are compatibility evidence, not trusted
    // thermal-health inputs. Missing classification fails closed.
    let hasTrustedThermalFailure = thermal.contains { item in
      guard item.readState != .readable else { return false }
      return thermalGroups[item.key] != .unclassified
    }

    // Discovery/validation failures can hide real hardware capabilities and
    // therefore remain blocking. Per-channel raw read/decode evidence is
    // blocking only through hasTrustedThermalFailure above.
    let hasBlockingDiagnostic = diagnostics.contains { diagnostic in
      guard diagnostic.provider == .thermal else { return true }
      switch diagnostic.stage {
      case .open, .discover, .validate:
        return true
      default:
        return false
      }
    }

    let hasUnclassified = classifications.contains { $0.semanticGroup == .unclassified }
    let state: DiagnosticsCompatibilityState
    if fanResult.fanCount == nil || hasTrustedThermalFailure || hasBlockingDiagnostic {
      state = thermal.isEmpty && fanResult.fanCount == nil ? .unsupported : .partial
    } else if hasUnclassified {
      state = .needsReview
    } else {
      state = .supportedReadOnly
    }
    return DiagnosticsCompatibilityEvidence(
      rawHardware: DiagnosticsRawHardware(
        smcThermalDiscovery: thermal, fanTopology: fanResult.entries,
        providerDiagnostics: Array(diagnostics.prefix(64))),
      thermalClassifications: classifications,
      fanTopologyClass: fanResult.topologyClass,
      safelyObservedFanCount: fanResult.fanCount,
      compatibilityState: state)
  }

  private func thermalItem(key: String, client: SMCClient) -> DiagnosticsSMCThermalDiscovery {
    let info: SMCKeyInfo
    do {
      info = try client.keyInfo(key)
    } catch let error as TelemetryError {
      return DiagnosticsSMCThermalDiscovery(
        key: key, dataType: nil, dataSize: nil, readState: .unreadable,
        decodedCelsius: nil, failureCategory: failureCategory(error))
    } catch {
      return DiagnosticsSMCThermalDiscovery(
        key: key, dataType: nil, dataSize: nil, readState: .unreadable,
        decodedCelsius: nil, failureCategory: .other)
    }

    do {
      let value = try client.value(key)
      do {
        let celsius = try SMCCodec.temperature(type: value.info.type, bytes: value.bytes)
        guard (-100...250).contains(celsius) else {
          throw TelemetryError.invalidData("Temperature outside diagnostics bounds")
        }
        let boundedCelsius = (celsius * 1_000).rounded() / 1_000
        return DiagnosticsSMCThermalDiscovery(
          key: key, dataType: info.type, dataSize: Int(info.size), readState: .readable,
          decodedCelsius: boundedCelsius, failureCategory: nil)
      } catch let error as TelemetryError {
        return DiagnosticsSMCThermalDiscovery(
          key: key, dataType: info.type, dataSize: Int(info.size), readState: .decodeFailed,
          decodedCelsius: nil, failureCategory: failureCategory(error))
      }
    } catch let error as TelemetryError {
      return DiagnosticsSMCThermalDiscovery(
        key: key, dataType: info.type, dataSize: Int(info.size), readState: .unreadable,
        decodedCelsius: nil, failureCategory: failureCategory(error))
    } catch {
      return DiagnosticsSMCThermalDiscovery(
        key: key, dataType: info.type, dataSize: Int(info.size), readState: .unreadable,
        decodedCelsius: nil, failureCategory: .other)
    }
  }

  private func fanEvidence(client: SMCClient) -> (
    entries: [DiagnosticsFanTopologyEntry], topologyClass: DiagnosticsFanTopologyClass,
    fanCount: Int?, diagnostics: [DiagnosticsProviderDiagnostic]
  ) {
    let inventory: FanInventory
    do {
      inventory = try SMCFanReader(client: client).read()
    } catch let error as TelemetryError {
      return (
        [], .unknown, nil, [diagnostic(provider: .fanTelemetry, stage: .read, error: error)])
    } catch {
      return (
        [], .unknown, nil,
        [
          diagnostic(
            provider: .fanTelemetry, stage: .read,
            error: .unavailable("Fan topology unavailable"))
        ])
    }

    var diagnostics: [DiagnosticsProviderDiagnostic] = []
    var entries: [DiagnosticsFanTopologyEntry] = []
    var representedIndexes = Set<Int>()
    var invalidTopology = false

    for fan in inventory.fans {
      guard (0...7).contains(fan.id), representedIndexes.insert(fan.id).inserted else {
        invalidTopology = true
        continue
      }
      let minimum = rpm(fan.minimumRPM)
      let maximum = rpm(fan.maximumRPM)
      let rangeState: DiagnosticsFanRangeState
      switch (minimum, maximum) {
      case (.some, .some): rangeState = .available
      case (.some, .none), (.none, .some): rangeState = .partial
      case (.none, .none):
        if unavailable(fan.minimumRPM), unavailable(fan.maximumRPM) {
          rangeState = .unavailable
        } else {
          rangeState = .readFailed
        }
      }
      if rangeState == .readFailed {
        diagnostics.append(
          diagnostic(
            provider: .fanTelemetry, stage: .read,
            error: firstError(fan.minimumRPM, fan.maximumRPM) ?? .invalidData("Fan range")))
      }
      entries.append(
        DiagnosticsFanTopologyEntry(
          index: fan.id, rangeState: rangeState, minimumRPM: minimum, maximumRPM: maximum,
          actualRPM: rpm(fan.actualRPM)))
    }

    if invalidTopology {
      diagnostics.append(
        diagnostic(
          provider: .fanTelemetry, stage: .validate,
          error: .invalidData("Fan topology indexes outside diagnostics bounds")))
      return (entries.sorted { $0.index < $1.index }, .unknown, nil, diagnostics)
    }

    let fanCount = inventory.fans.count
    let topology: DiagnosticsFanTopologyClass = switch fanCount {
    case 0: .fanless
    case 1: .singleFan
    case 2: .dualFan
    case 3...8: .multiFan
    default: .unknown
    }
    guard topology != .unknown, representedIndexes == Set(0..<fanCount) else {
      return (entries.sorted { $0.index < $1.index }, .unknown, nil, diagnostics)
    }
    return (entries.sorted { $0.index < $1.index }, topology, fanCount, diagnostics)
  }

  private func rpm(_ result: MetricResult<Double>) -> Int? {
    guard case .success(let value) = result, value.isFinite, (0...100_000).contains(value)
    else { return nil }
    return Int(value.rounded())
  }

  private func unavailable(_ result: MetricResult<Double>) -> Bool {
    guard case .failure(let error) = result, case .unavailable = error else { return false }
    return true
  }

  private func firstError(
    _ first: MetricResult<Double>, _ second: MetricResult<Double>
  ) -> TelemetryError? {
    if case .failure(let error) = first { return error }
    if case .failure(let error) = second { return error }
    return nil
  }

  private func unavailableEvidence(
    _ error: TelemetryError, stage: DiagnosticsProviderStage
  ) -> DiagnosticsCompatibilityEvidence {
    DiagnosticsCompatibilityEvidence(
      rawHardware: DiagnosticsRawHardware(
        smcThermalDiscovery: [], fanTopology: [],
        providerDiagnostics: [diagnostic(provider: .thermal, stage: stage, error: error)]),
      thermalClassifications: [], fanTopologyClass: .unknown, safelyObservedFanCount: nil,
      compatibilityState: .unsupported)
  }

  private func diagnostic(
    provider: DiagnosticsProviderName, stage: DiagnosticsProviderStage,
    error: TelemetryError, occurrences: Int = 1
  ) -> DiagnosticsProviderDiagnostic {
    let code: (DiagnosticsCodeDomain, Int32)? = switch error {
    case .kernel(_, let value): (.posix, value)
    case .ioKit(_, let value): (.iokit, value)
    case .smc(_, let value): (.smc, Int32(value))
    default: nil
    }
    return DiagnosticsProviderDiagnostic(
      provider: provider, stage: stage, category: failureCategory(error),
      codeDomain: code?.0, numericCode: code?.1,
      occurrences: DiagnosticsFailureCount(count: max(1, occurrences)))
  }

  private func failureCategory(_ error: TelemetryError) -> DiagnosticsFailureCategory {
    switch error {
    case .unavailable, .warmingUp: .noData
    case .invalidData: .invalidData
    case .kernel, .ioKit, .smc: .ioError
    }
  }

  private func semanticGroup(_ group: ThermalGroup) -> DiagnosticsThermalSemanticGroup {
    switch group {
    case .performanceCPU: .performanceCore
    case .efficiencyCPU: .efficiencyCore
    case .gpu: .gpu
    case .validatedHotspot: .validatedHotspot
    case .unclassified: .unclassified
    }
  }
}
