import Foundation

struct DiagnosticsHelperObservation: Sendable, Equatable {
  var installationState: DiagnosticsHelperInstallationState = .missing
  var connectionState: DiagnosticsHelperConnectionState = .disconnected
  var protocolCompatibility: DiagnosticsProtocolCompatibility = .notChecked
  var failureCategory: DiagnosticsHelperFailureCategory?
}

private struct DiagnosticsProviderObservation {
  let state: DiagnosticsProviderState
  let category: DiagnosticsFailureCategory?
}

/// Launch-scoped observation state. It never reads UI/module preferences and
/// never persists provider failures, counters, or timing history.
@MainActor
final class DiagnosticsSessionTracker {
  let launchStartedAt: Date
  private(set) var latestSnapshot = TelemetrySnapshot()
  private(set) var helper = DiagnosticsHelperObservation()
  private(set) var diagnosticsErrorCategory = DiagnosticsErrorCategory.none

  private var lastTicks: [DiagnosticsProviderName: UInt64] = [:]
  private var hasObservation: Set<DiagnosticsProviderName> = []
  private var failureCounts: [DiagnosticsProviderName: Int] = [:]

  init(launchStartedAt: Date = Date()) {
    self.launchStartedAt = launchStartedAt
  }

  func accept(_ snapshot: TelemetrySnapshot) {
    latestSnapshot = snapshot
    observe(.cpu, sample: snapshot.cpu)
    observe(.memory, sample: snapshot.memory)
    observe(.gpu, sample: snapshot.gpu)
    observe(.thermal, sample: snapshot.thermals) { metrics in
      metrics.failures.isEmpty ? nil : (.invalidData, metrics.failures.count)
    }
    observe(.fanTelemetry, sample: snapshot.fans)
    observe(.battery, sample: snapshot.battery)
    observe(.storage, sample: snapshot.storage)
    observe(.network, sample: snapshot.network)
    observe(.wifi, sample: snapshot.wifi)
    observe(.bluetooth, sample: snapshot.bluetooth)
    observe(.energyProcess, sample: snapshot.processes)
    observeNVMe(snapshot.storage)
  }

  func updateHelper(_ observation: DiagnosticsHelperObservation) { helper = observation }

  func recordDiagnosticsError(_ category: DiagnosticsErrorCategory) {
    guard category != .none else { return }
    diagnosticsErrorCategory = category
  }

  func buildHealth(
    type: DiagnosticsReportType,
    reason: DiagnosticsReportReason,
    generatedAt: Date = Date(),
    bundle: Bundle = .main
  ) throws -> DiagnosticsHealthReport {
    guard type == .automaticHealth || type == .manualHealth else {
      throw DiagnosticsPayloadError.invalid("$.report_type")
    }
    let common = buildCommon(generatedAt: generatedAt, bundle: bundle)
    return DiagnosticsHealthReport(
      schemaVersion: 1, reportType: type,
      generatedAt: DiagnosticsTimestamp.minuteUTC(generatedAt), reportReason: reason,
      helios: common.helios, system: common.system, capabilities: common.capabilities,
      providers: common.providers, helper: common.helper, runtime: common.runtime,
      stability: common.stability)
  }

  func commonFields(generatedAt: Date = Date(), bundle: Bundle = .main) -> DiagnosticsCommonFields {
    buildCommon(generatedAt: generatedAt, bundle: bundle)
  }

  private func observe<Value: Sendable>(
    _ name: DiagnosticsProviderName,
    sample: MetricSample<Value>,
    partial: (Value) -> (DiagnosticsFailureCategory, Int)? = { _ in nil }
  ) {
    let previous = lastTicks[name]
    let changed = previous != sample.capturedTicks
    lastTicks[name] = sample.capturedTicks

    if previous == nil {
      switch sample.result {
      case .success: hasObservation.insert(name)
      case .failure(let error):
        if establishesInitialObservation(error) { hasObservation.insert(name) }
      }
    } else if changed {
      hasObservation.insert(name)
    }
    guard changed, hasObservation.contains(name) else { return }
    switch sample.result {
    case .success(let value):
      if let (_, count) = partial(value) { failureCounts[name, default: 0] += max(1, count) }
    case .failure(let error):
      if isActualFailure(error) { failureCounts[name, default: 0] += 1 }
    }
  }

  private func observeNVMe(_ sample: MetricSample<StorageMetrics>) {
    let name = DiagnosticsProviderName.nvmeSmart
    let previous = lastTicks[name]
    let changed = previous != sample.capturedTicks
    lastTicks[name] = sample.capturedTicks
    guard case .success(let storage) = sample.result else {
      if previous != nil, changed { hasObservation.insert(name) }
      if changed, hasObservation.contains(name), case .failure(let error) = sample.result,
        isActualFailure(error)
      { failureCounts[name, default: 0] += 1 }
      return
    }
    if previous == nil {
      if case .success = storage.smartHealth { hasObservation.insert(name) }
      if case .failure(let error) = storage.smartHealth, establishesInitialObservation(error) {
        hasObservation.insert(name)
      }
    } else if changed {
      hasObservation.insert(name)
    }
    if changed, hasObservation.contains(name), case .failure(let error) = storage.smartHealth,
      isActualFailure(error)
    { failureCounts[name, default: 0] += 1 }
  }

  private func buildCommon(generatedAt: Date, bundle: Bundle) -> DiagnosticsCommonFields {
    let providerValues = DiagnosticsProviders(
      cpu: summary(.cpu, latestSnapshot.cpu),
      memory: summary(.memory, latestSnapshot.memory),
      gpu: summary(.gpu, latestSnapshot.gpu),
      thermal: summary(.thermal, latestSnapshot.thermals) { metrics in
        metrics.failures.isEmpty ? nil : .invalidData
      },
      fanTelemetry: summary(.fanTelemetry, latestSnapshot.fans),
      battery: summary(.battery, latestSnapshot.battery),
      storage: summary(.storage, latestSnapshot.storage),
      nvmeSmart: nvmeSummary(latestSnapshot.storage),
      network: summary(.network, latestSnapshot.network),
      wifi: summary(.wifi, latestSnapshot.wifi),
      bluetooth: summary(.bluetooth, latestSnapshot.bluetooth),
      energyProcess: summary(.energyProcess, latestSnapshot.processes))
    let capabilityValues = DiagnosticsCapabilities(
      cpu: capability(providerValues.cpu), memory: capability(providerValues.memory),
      gpu: capability(providerValues.gpu), thermal: capability(providerValues.thermal),
      fanTelemetry: capability(providerValues.fanTelemetry),
      battery: capability(providerValues.battery), storage: capability(providerValues.storage),
      nvmeSmart: capability(providerValues.nvmeSmart), network: capability(providerValues.network),
      wifi: capability(providerValues.wifi), bluetooth: capability(providerValues.bluetooth),
      energyProcess: capability(providerValues.energyProcess))

    let systemMetrics: SystemMetrics? = {
      guard case .success(let metrics) = latestSnapshot.system.result else { return nil }
      return metrics
    }()
    let fanCount: Int? = {
      guard hasObservation.contains(.fanTelemetry), case .success(let inventory) = latestSnapshot.fans.result
      else { return nil }
      return inventory.fans.count
    }()
    let batteryPresent: Bool? = {
      guard hasObservation.contains(.battery), case .success = latestSnapshot.battery.result else {
        return nil
      }
      return true
    }()
    let model: String? = systemMetrics.flatMap { metrics in
      guard case .success(let candidate) = metrics.modelIdentifier,
        DiagnosticsFieldRules.validMachineModel(candidate)
      else { return nil }
      return candidate
    }
    let osBuild: String = systemMetrics.flatMap { try? $0.osBuild.get() }
      .flatMap { DiagnosticsFieldRules.validOSBuild($0) ? $0 : nil } ?? "unknown"
    let osVersion = systemMetrics.map { DiagnosticsFieldRules.macOSVersion(from: $0.osVersion) }
      ?? DiagnosticsFieldRules.currentMacOSVersion
    let memory = systemMetrics.map { DiagnosticsFieldRules.memoryBucket(bytes: $0.physicalMemoryBytes) }
      ?? .unknown
    let family = systemMetrics.flatMap { try? $0.chipName.get() }
      .map(DiagnosticsFieldRules.appleSiliconFamily)

    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let total = failureCounts.values.reduce(0, +)
    return DiagnosticsCommonFields(
      helios: DiagnosticsHelios(
        version: DiagnosticsFieldRules.validVersion(version) ? version! : "0.0.0",
        build: DiagnosticsFieldRules.validBuild(build) ? build! : "0"),
      system: DiagnosticsSystem(
        macOSVersion: osVersion, macOSBuild: osBuild, machineModel: model,
        architecture: DiagnosticsFieldRules.architecture,
        appleSiliconFamily: family, memoryBucketGiB: memory, fanCount: fanCount,
        batteryPresent: batteryPresent),
      capabilities: capabilityValues,
      providers: providerValues,
      helper: DiagnosticsHelper(
        installationState: helper.installationState, connectionState: helper.connectionState,
        protocolCompatibility: helper.protocolCompatibility, failureCategory: helper.failureCategory),
      runtime: DiagnosticsRuntime(
        memoryFootprintMiB: .unknown, cpuPercent: .unknown,
        sessionDuration: DiagnosticsFieldRules.duration(generatedAt.timeIntervalSince(launchStartedAt)),
        providerFailureTotal: DiagnosticsFailureCount(count: total),
        diagnosticsErrorCategory: diagnosticsErrorCategory),
      stability: DiagnosticsStability(
        previousSessionEndedUncleanly: false, previousSessionDuration: nil,
        lifecycleCategory: .unknown))
  }

  private func summary<Value: Sendable>(
    _ name: DiagnosticsProviderName,
    _ sample: MetricSample<Value>,
    partial: (Value) -> DiagnosticsFailureCategory? = { _ in nil }
  ) -> DiagnosticsProviderSummary {
    guard hasObservation.contains(name) else {
      return DiagnosticsProviderSummary(
        state: .notObserved, failureCategory: nil, failureCount: .zero)
    }
    let observation: DiagnosticsProviderObservation
    switch sample.result {
    case .success(let value):
      if let category = partial(value) {
        observation = DiagnosticsProviderObservation(state: .partial, category: category)
      } else {
        observation = DiagnosticsProviderObservation(state: .available, category: nil)
      }
    case .failure(let error): observation = providerObservation(error)
    }
    return DiagnosticsProviderSummary(
      state: observation.state, failureCategory: observation.category,
      failureCount: DiagnosticsFailureCount(count: failureCounts[name, default: 0]))
  }

  private func nvmeSummary(_ sample: MetricSample<StorageMetrics>) -> DiagnosticsProviderSummary {
    guard hasObservation.contains(.nvmeSmart) else {
      return DiagnosticsProviderSummary(
        state: .notObserved, failureCategory: nil, failureCount: .zero)
    }
    let observation: DiagnosticsProviderObservation
    switch sample.result {
    case .failure(let error): observation = providerObservation(error)
    case .success(let storage):
      switch storage.smartHealth {
      case .success: observation = DiagnosticsProviderObservation(state: .available, category: nil)
      case .failure(let error): observation = providerObservation(error)
      }
    }
    return DiagnosticsProviderSummary(
      state: observation.state, failureCategory: observation.category,
      failureCount: DiagnosticsFailureCount(count: failureCounts[.nvmeSmart, default: 0]))
  }

  private func providerObservation(_ error: TelemetryError) -> DiagnosticsProviderObservation {
    switch error {
    case .warmingUp:
      DiagnosticsProviderObservation(state: .notObserved, category: nil)
    case .unavailable:
      DiagnosticsProviderObservation(state: .unavailable, category: .noData)
    case .invalidData:
      DiagnosticsProviderObservation(state: .failed, category: .invalidData)
    case .kernel, .ioKit, .smc:
      DiagnosticsProviderObservation(state: .failed, category: .ioError)
    }
  }

  private func isActualFailure(_ error: TelemetryError) -> Bool {
    if case .warmingUp = error { return false }
    return true
  }

  private func establishesInitialObservation(_ error: TelemetryError) -> Bool {
    switch error {
    case .warmingUp, .unavailable: false
    case .invalidData, .kernel, .ioKit, .smc: true
    }
  }

  private func capability(_ provider: DiagnosticsProviderSummary) -> DiagnosticsCapabilityState {
    switch provider.state {
    case .available: .available
    case .partial: .partial
    case .unavailable: .unavailable
    case .failed: .failed
    case .notObserved: .unknown
    }
  }
}

struct DiagnosticsCommonFields: Sendable {
  let helios: DiagnosticsHelios
  let system: DiagnosticsSystem
  let capabilities: DiagnosticsCapabilities
  let providers: DiagnosticsProviders
  let helper: DiagnosticsHelper
  let runtime: DiagnosticsRuntime
  let stability: DiagnosticsStability
}

enum DiagnosticsFieldRules {
  static var architecture: String {
    #if arch(arm64)
      "arm64"
    #else
      "unsupported"
    #endif
  }

  static var currentMacOSVersion: String {
    let value = ProcessInfo.processInfo.operatingSystemVersion
    return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
  }

  static func macOSVersion(from value: String) -> String {
    guard let match = value.range(of: #"[0-9]+(?:\.[0-9]+){1,2}"#, options: .regularExpression)
    else { return currentMacOSVersion }
    return String(value[match])
  }

  static func validMachineModel(_ value: String) -> Bool {
    value.utf8.count >= 4 && value.utf8.count <= 32
      && value.range(
        of: #"^[A-Za-z][A-Za-z0-9]*[0-9],[0-9]{1,3}$"#, options: .regularExpression) != nil
  }

  static func validOSBuild(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 32
      && value.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil
  }

  static func validVersion(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.isEmpty && value.utf8.count <= 32
      && value.range(
        of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?$"#,
        options: .regularExpression) != nil
  }

  static func validBuild(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.isEmpty && value.utf8.count <= 32
      && value.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
  }

  static func appleSiliconFamily(_ chipName: String) -> String {
    for family in ["M1", "M2", "M3", "M4", "M5"] where chipName.contains(family) {
      return family
    }
    return chipName.localizedCaseInsensitiveContains("Apple") ? "future" : "unknown"
  }

  static func memoryBucket(bytes: UInt64) -> DiagnosticsMemoryBucket {
    let gib = Double(bytes) / 1_073_741_824
    return switch gib {
    case ...8: .upToEight
    case ...16: .nineToSixteen
    case ...32: .seventeenToThirtyTwo
    case ...64: .thirtyThreeToSixtyFour
    case ...128: .sixtyFiveToOneTwentyEight
    default: .overOneTwentyEight
    }
  }

  static func duration(_ seconds: TimeInterval) -> DiagnosticsDurationBucket {
    guard seconds.isFinite, seconds >= 0 else { return .unknown }
    return switch seconds {
    case ..<300: .underFiveMinutes
    case ..<900: .fiveToFifteenMinutes
    case ..<3_600: .fifteenMinutesToOneHour
    case ..<21_600: .oneToSixHours
    case ..<86_400: .sixToTwentyFourHours
    default: .overTwentyFourHours
    }
  }
}
