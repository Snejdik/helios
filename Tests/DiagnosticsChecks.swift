import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw CheckFailure(description: message) }
}

private func provider(_ state: DiagnosticsProviderState = .available) -> DiagnosticsProviderSummary {
  DiagnosticsProviderSummary(
    state: state, failureCategory: nil, failureCount: .zero)
}

private func providers() -> DiagnosticsProviders {
  DiagnosticsProviders(
    cpu: provider(), memory: provider(), gpu: provider(), thermal: provider(),
    fanTelemetry: provider(), battery: provider(), storage: provider(), nvmeSmart: provider(),
    network: provider(), wifi: provider(), bluetooth: provider(), energyProcess: provider(.notObserved))
}

private func capabilities() -> DiagnosticsCapabilities {
  DiagnosticsCapabilities(
    cpu: .available, memory: .available, gpu: .available, thermal: .available,
    fanTelemetry: .available, battery: .available, storage: .available, nvmeSmart: .available,
    network: .available, wifi: .partial, bluetooth: .available, energyProcess: .unknown)
}

private func health(
  type: DiagnosticsReportType = .automaticHealth,
  reason: DiagnosticsReportReason = .daily,
  model: String? = "Mac16,1",
  fanCount: Int? = 1,
  battery: Bool? = true
) -> DiagnosticsHealthReport {
  DiagnosticsHealthReport(
    schemaVersion: 1, reportType: type, generatedAt: "2026-09-10T12:34:00Z",
    reportReason: reason, helios: DiagnosticsHelios(version: "0.1.0", build: "1"),
    system: DiagnosticsSystem(
      macOSVersion: "26.6.2", macOSBuild: "25G83", machineModel: model,
      architecture: "arm64", appleSiliconFamily: "M4", memoryBucketGiB: .nineToSixteen,
      fanCount: fanCount, batteryPresent: battery),
    capabilities: capabilities(), providers: providers(),
    helper: DiagnosticsHelper(
      installationState: .installed, connectionState: .connected,
      protocolCompatibility: .compatible, failureCategory: nil),
    runtime: DiagnosticsRuntime(
      memoryFootprintMiB: .seventeenToThirtyTwo, cpuPercent: .pointTwoToOne,
      sessionDuration: .fifteenMinutesToOneHour, providerFailureTotal: .zero,
      diagnosticsErrorCategory: .none),
    stability: DiagnosticsStability(
      previousSessionEndedUncleanly: false, previousSessionDuration: nil,
      lifecycleCategory: .normalLaunch))
}

@MainActor
private func systemSnapshotChecks() throws {
  let tracker = DiagnosticsSessionTracker()
  let unknown = DiagnosticsSystemSnapshot.text(tracker.commonFields())
  try require(unknown.contains("Model: unknown") && unknown.contains("Fan count: unknown"),
    "Pending identity fabricated a system snapshot")
  var snapshot = TelemetrySnapshot()
  snapshot.system = MetricSample(.success(SystemMetrics(
    modelIdentifier: .success("private-hostname"), chipName: .success("Apple M4"),
    osVersion: "Version 26.6.2 (Build 25G83)", osBuild: .success("25G83"),
    uptimeSeconds: 100, logicalProcessorCount: 8, physicalMemoryBytes: 16 * 1_073_741_824,
    loadAverage1: .success(1), loadAverage5: .success(1), loadAverage15: .success(1),
    thermalState: .nominal, lowPowerModeEnabled: false)))
  snapshot.network = MetricSample(.failure(.unavailable("secret-network-address")))
  snapshot.processes = MetricSample(.failure(.kernel("/Users/private-user/secret", 5)))
  tracker.accept(snapshot)
  let text = DiagnosticsSystemSnapshot.text(tracker.commonFields())
  try require(text.contains("Apple Silicon family: M4") && text.contains("Memory bucket: 9-16 GiB")
    && text.contains("macOS 26.6.2 (build 25G83)"), "Snapshot lost sanitized support identity")
  for forbidden in ["private-hostname", "secret-network-address", "private-user", "/Users/", "secret"] {
    try require(!text.contains(forbidden), "System snapshot leaked raw private evidence: \(forbidden)")
  }
  try require(text.contains("energy_process: failed / io_error"), "Snapshot lost coarse provider state")
  try require(text.contains("capability failed") && unknown.contains("capability unknown"),
    "Snapshot must distinguish observed capability from pending data")
}

private func schemaChecks() throws {
  try require(DiagnosticsFieldRules.appleSiliconFamily("Apple M4 Pro") == "M4",
    "A recognized complete Apple Silicon family token was lost")
  try require(DiagnosticsFieldRules.appleSiliconFamily("Apple M10") == "future"
    && DiagnosticsFieldRules.appleSiliconFamily("Apple M50 Ultra") == "future"
    && DiagnosticsFieldRules.appleSiliconFamily("unrecognized") == "unknown",
    "Substring matching invented a known mapping for a future Silicon family")
  for version in ["0.1.0", "0.1.0-prebeta.3", "0.1.0-prebeta.3+offline"] {
    try require(DiagnosticsFieldRules.validVersion(version), "Server-compatible version rejected")
  }
  for version in ["0.1", "0.1.0.3", "0.1.0+meta-prebeta+extra"] {
    try require(!DiagnosticsFieldRules.validVersion(version), "Server-incompatible version accepted")
  }

  for model in [
    "MacBookAir10,1", "MacBookPro17,1", "Macmini9,1", "iMac21,1", "Mac14,2",
    "Mac16,1", "MacFuture42,7",
  ] {
    _ = try DiagnosticsPayloadEncoder.freeze(health(model: model), reportType: .automaticHealth)
  }
  _ = try DiagnosticsPayloadEncoder.freeze(
    health(model: nil, fanCount: nil, battery: nil), reportType: .automaticHealth)

  let automatic = try DiagnosticsPayloadEncoder.freeze(health(), reportType: .automaticHealth)
  try require(automatic.preview.contains(#""report_type" : "automatic_health""#), "automatic type missing")
  try require(!automatic.preview.contains("raw_hardware"), "raw hardware leaked into health report")
  try require(!automatic.preview.contains(": null"), "optional values encoded as null")

  let manual = try DiagnosticsPayloadEncoder.freeze(
    health(type: .manualHealth, reason: .userInitiated), reportType: .manualHealth)
  try require(manual.preview.contains(#""report_type" : "manual_health""#), "manual type missing")

  var object = try JSONSerialization.jsonObject(with: automatic.data) as! [String: Any]
  for version in ["0.1", "0.1.0.3"] {
    var changed = object
    var identity = changed["helios"] as! [String: Any]
    identity["version"] = version
    changed["helios"] = identity
    do {
      try DiagnosticsPayloadValidator.validate(JSONSerialization.data(withJSONObject: changed))
      throw CheckFailure(description: "Closed client validator accepted server-incompatible version")
    } catch DiagnosticsPayloadError.invalid { }
  }
  object["device_id"] = "forbidden"
  let unknown = try JSONSerialization.data(withJSONObject: object)
  do {
    try DiagnosticsPayloadValidator.validate(unknown)
    throw CheckFailure(description: "unknown field was accepted")
  } catch DiagnosticsPayloadError.invalid { }

  object.removeValue(forKey: "device_id")
  var system = object["system"] as! [String: Any]
  system["fan_count"] = NSNull()
  object["system"] = system
  let withNull = try JSONSerialization.data(withJSONObject: object)
  do {
    try DiagnosticsPayloadValidator.validate(withNull)
    throw CheckFailure(description: "JSON null was accepted")
  } catch DiagnosticsPayloadError.invalid { }

  for invalid in ["Mac", "Mac16", "Mac16,", "Mac 16,1", "Mac16,1234", "1Mac16,1"] {
    do {
      _ = try DiagnosticsPayloadEncoder.freeze(
        health(model: invalid), reportType: .automaticHealth)
      throw CheckFailure(description: "invalid model accepted: \(invalid)")
    } catch DiagnosticsPayloadError.invalid { }
  }

  try require(DiagnosticsCapabilityState.allCases.map(\.rawValue) == [
    "available", "partial", "unavailable", "failed", "unknown",
  ], "capability enum drift")
  try require(DiagnosticsProviderState.allCases.map(\.rawValue) == [
    "available", "partial", "unavailable", "failed", "not_observed",
  ], "provider enum drift")
  try require(DiagnosticsThermalSemanticGroup.validatedHotspot.rawValue == "validated_hotspot", "hotspot provenance case missing")
}

@MainActor
private func preferencesChecks() throws {
  let suiteName = "DiagnosticsChecks.\(ProcessInfo.processInfo.processIdentifier)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    throw CheckFailure(description: "could not create isolated defaults")
  }
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }

  var preferences = DiagnosticsPreferences(defaults: defaults)
  try require(preferences.consent == .notDecided, "clean consent was not OFF")
  try require(!preferences.automaticEnabled, "clean consent enabled automatic diagnostics")

  preferences.setConsent(.disabled)
  preferences = DiagnosticsPreferences(defaults: defaults)
  try require(preferences.consent == .disabled, "disabled consent did not survive relaunch")

  preferences.setConsent(.enabled)
  preferences = DiagnosticsPreferences(defaults: defaults)
  try require(preferences.consent == .enabled, "enabled consent did not survive relaunch")

  defaults.set("corrupt", forKey: DiagnosticsPreferences.namespace + "consent")
  preferences = DiagnosticsPreferences(defaults: defaults)
  try require(preferences.consent == .notDecided, "corrupt consent did not fail OFF")

  preferences.setConsent(.enabled)
  defaults.set(false, forKey: "next23.ui.onboardingCompleted")
  preferences = DiagnosticsPreferences(defaults: defaults)
  try require(preferences.consent == .enabled, "welcome reset changed diagnostics consent")

  var cancelled = false
  preferences.automaticWorkCancellation = { cancelled = true }
  preferences.setConsent(.disabled)
  try require(cancelled, "opt-out did not synchronously cancel automatic work")
  try require(preferences.nextEligibleTime == nil, "opt-out retained queued eligibility")

  let manualSuccess = Date(timeIntervalSince1970: 20_000)
  preferences.recordLocalStatus(.success, category: .none, at: manualSuccess)
  try require(
    preferences.lastSuccessfulReport == manualSuccess,
    "manual success did not update the user-visible report date")
  try require(
    preferences.lastSuccessfulAutomaticSend == nil,
    "manual success incorrectly advanced automatic scheduling state")

  preferences.eraseAllDiagnosticsPreferences()
  try require(preferences.consent == .notDecided, "erase-all did not restore undecided/OFF")
  try require(preferences.lastSuccessfulReport == nil, "erase-all retained report status history")
}

@MainActor
private func builderChecks() throws {
  let launch = Date(timeIntervalSince1970: 1_000)
  let tracker = DiagnosticsSessionTracker(launchStartedAt: launch)
  let pending = TelemetrySnapshot()
  tracker.accept(pending)
  var report = try tracker.buildHealth(
    type: .automaticHealth, reason: .daily,
    generatedAt: launch.addingTimeInterval(60))
  try require(report.providers.cpu.state == .notObserved, "pending CPU was not cause-free")
  try require(report.capabilities.cpu == .unknown, "unobserved capability was not unknown")
  try require(report.providers.cpu.failureCategory == nil, "not_observed inferred a failure")
  try require(report.providers.cpu.failureCount == .zero, "not_observed inferred a count")

  var snapshot = pending
  snapshot.system = MetricSample(
    .success(
      SystemMetrics(
        modelIdentifier: .success("MacBookAir10,1"), chipName: .success("Apple M1"),
        osVersion: "Version 26.6.2", osBuild: .success("25G83"), uptimeSeconds: 100,
        logicalProcessorCount: 8, physicalMemoryBytes: 8 * 1_073_741_824,
        loadAverage1: .success(1), loadAverage5: .success(1), loadAverage15: .success(1),
        thermalState: .nominal, lowPowerModeEnabled: false)),
    capturedTicks: 10)
  snapshot.cpu = MetricSample(
    .success(
      CPUMetrics(
        userPercent: 4, systemPercent: 2, nicePercent: 0, idlePercent: 94,
        perCoreUsagePercent: [6])), capturedTicks: 11)
  snapshot.fans = MetricSample(.success(FanInventory(fans: [])), capturedTicks: 12)
  tracker.accept(snapshot)
  report = try tracker.buildHealth(
    type: .automaticHealth, reason: .daily,
    generatedAt: launch.addingTimeInterval(16 * 60))
  try require(report.providers.cpu.state == .available, "observed CPU was not available")
  try require(report.system.machineModel == "MacBookAir10,1", "safe model was not copied")
  try require(report.system.appleSiliconFamily == "M1", "safe family derivation failed")
  try require(report.system.fanCount == 0, "positively observed fanless count was omitted")
  try require(report.system.batteryPresent == nil, "unknown battery state was fabricated")
  try require(
    report.runtime.sessionDuration == .fifteenMinutesToOneHour,
    "session duration was not current-launch scoped")

  snapshot.cpu = MetricSample(.failure(.invalidData("must never be transmitted")), capturedTicks: 13)
  tracker.accept(snapshot)
  tracker.accept(snapshot)
  report = try tracker.buildHealth(type: .automaticHealth, reason: .daily, generatedAt: launch)
  try require(report.providers.cpu.state == .failed, "observed failure state missing")
  try require(report.providers.cpu.failureCategory == .invalidData, "failure was not coarsened")
  try require(report.providers.cpu.failureCount == .one, "one sample was counted more than once")
  try require(report.runtime.providerFailureTotal == .one, "current-launch total was wrong")

  snapshot.cpu = MetricSample(.failure(.ioKit("secret operation", -1)), capturedTicks: 14)
  tracker.accept(snapshot)
  report = try tracker.buildHealth(type: .automaticHealth, reason: .daily, generatedAt: launch)
  try require(report.providers.cpu.failureCount == .twoToFive, "failure bucket did not advance")
  let frozen = try DiagnosticsPayloadEncoder.freeze(report, reportType: .automaticHealth)
  try require(!frozen.preview.contains("secret operation"), "raw error text leaked")
  try require(!frozen.preview.contains("must never be transmitted"), "invalid-data text leaked")

  for tick in 15...50 {
    snapshot.cpu = MetricSample(.failure(.ioKit("private", -1)), capturedTicks: UInt64(tick))
    tracker.accept(snapshot)
  }
  report = try tracker.buildHealth(type: .automaticHealth, reason: .daily, generatedAt: launch)
  try require(report.providers.cpu.failureCount == .twoToFive, "Persistent source inflated failure episodes")

  let thermalTracker = DiagnosticsSessionTracker(launchStartedAt: launch)
  var thermalSnapshot = TelemetrySnapshot()
  let identified = ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 60)
  for tick in 1...30 {
    thermalSnapshot.thermals = MetricSample(.success(ThermalMetrics(
      readings: [identified], failures: ["Traw": .invalidData("optional")], trustedFailures: [:])),
      capturedTicks: UInt64(tick))
    thermalTracker.accept(thermalSnapshot)
  }
  var thermalReport = try thermalTracker.buildHealth(type: .manualHealth, reason: .userInitiated)
  try require(thermalReport.providers.thermal.state == .available
    && thermalReport.providers.thermal.failureCount == .zero, "Optional failures became core degradation")
  thermalSnapshot.thermals = MetricSample(.success(ThermalMetrics(
    readings: [ThermalReading(key: "Traw", group: .unclassified, celsius: 60)],
    failures: [:], trustedFailures: [:])), capturedTicks: 31)
  thermalTracker.accept(thermalSnapshot)
  thermalReport = try thermalTracker.buildHealth(type: .manualHealth, reason: .userInitiated)
  try require(thermalReport.providers.thermal.state == .partial
    && thermalReport.providers.thermal.failureCategory == .noData,
    "Raw-only data must not claim main temperature availability")
  for tick in 32...70 {
    thermalSnapshot.thermals = MetricSample(.success(ThermalMetrics(readings: [identified],
      failures: ["Te05": .ioKit("private", -1)], trustedFailures: ["Te05": .ioKit("private", -1)])),
      capturedTicks: UInt64(tick))
    thermalTracker.accept(thermalSnapshot)
  }
  thermalReport = try thermalTracker.buildHealth(type: .manualHealth, reason: .userInitiated)
  try require(thermalReport.providers.thermal.failureCategory == .ioError
    && thermalReport.providers.thermal.failureCount == .one, "Trusted I/O category/episode semantics")
  for (tick, error) in [(UInt64(71), TelemetryError.warmingUp),
    (72, .unavailable("Capability only")), (73, .ioKit("private", -1))] {
    thermalSnapshot.thermals = MetricSample(.success(ThermalMetrics(readings: [identified],
      failures: ["Te05": error], trustedFailures: ["Te05": error])), capturedTicks: tick)
    thermalTracker.accept(thermalSnapshot)
  }
  thermalReport = try thermalTracker.buildHealth(type: .manualHealth, reason: .userInitiated)
  try require(thermalReport.providers.thermal.failureCount == .one,
    "Capability-only trusted-key observations inflated or reset an active episode")
  thermalSnapshot.thermals = MetricSample(.success(ThermalMetrics(readings: [identified],
    failures: [:], trustedFailures: [:])), capturedTicks: 74)
  thermalTracker.accept(thermalSnapshot)
  thermalSnapshot.thermals = MetricSample(.success(ThermalMetrics(readings: [identified],
    failures: ["Te05": .ioKit("private", -1)], trustedFailures: ["Te05": .ioKit("private", -1)])),
    capturedTicks: 75)
  thermalTracker.accept(thermalSnapshot)
  thermalReport = try thermalTracker.buildHealth(type: .manualHealth, reason: .userInitiated)
  try require(thermalReport.providers.thermal.failureCount == .twoToFive,
    "Trusted key did not begin a new episode after an observed recovery")
  let capabilityTracker = DiagnosticsSessionTracker(launchStartedAt: launch)
  thermalSnapshot.thermals = MetricSample(.success(ThermalMetrics(readings: [identified],
    failures: ["Te05": .warmingUp], trustedFailures: ["Te05": .warmingUp])), capturedTicks: 76)
  capabilityTracker.accept(thermalSnapshot)
  let capabilityReport = try capabilityTracker.buildHealth(type: .manualHealth, reason: .userInitiated)
  try require(capabilityReport.providers.thermal.failureCount == .zero,
    "Trusted-key warm-up became an actual failure episode")
  thermalTracker.recordDiagnosticsError(.transport)
  thermalTracker.recordDiagnosticsError(.none)
  thermalReport = try thermalTracker.buildHealth(type: .manualHealth, reason: .userInitiated)
  try require(thermalReport.runtime.diagnosticsErrorCategory == .none, "Recovered transport remained sticky")

  let nextLaunch = DiagnosticsSessionTracker(launchStartedAt: launch.addingTimeInterval(3_600))
  nextLaunch.accept(pending)
  let reset = try nextLaunch.buildHealth(
    type: .automaticHealth, reason: .daily, generatedAt: launch.addingTimeInterval(3_601))
  try require(reset.runtime.providerFailureTotal == .zero, "failure counters survived relaunch")
  try require(reset.runtime.diagnosticsErrorCategory == .none, "diagnostics error survived relaunch")
}

@MainActor
private func frozenPayloadChecks() throws {
  let approval = DiagnosticsManualApproval()
  let firstDate = Date(timeIntervalSince1970: 10_000)
  try approval.replace(
    with: health(type: .manualHealth, reason: .userInitiated),
    reportType: .manualHealth, now: firstDate)
  guard let displayed = approval.payload else {
    throw CheckFailure(description: "manual preview was not frozen")
  }
  try require(approval.approve(at: firstDate) == displayed, "displayed payload was not approved")
  try require(
    approval.approvedPayload(at: firstDate)?.data == Data(approval.preview.utf8),
    "preview UTF-8 bytes differ from approved body")

  try approval.replace(
    with: health(type: .manualHealth, reason: .userInitiated, model: "Mac14,2"),
    reportType: .manualHealth, now: firstDate.addingTimeInterval(1))
  try require(approval.approvedPayload(at: firstDate.addingTimeInterval(1)) == nil, "regeneration retained approval")
  try require(approval.approve(at: firstDate.addingTimeInterval(902)) == nil, "stale payload was approved")
}

@MainActor
private final class MockDiagnosticsTransport: DiagnosticsTransporting {
  var received: [Data] = []
  var result = DiagnosticsTransportResult.accepted
  func send(_ payload: FrozenDiagnosticsPayload) async -> DiagnosticsTransportResult {
    received.append(payload.data)
    return result
  }
  func cancel() {}
}

@MainActor
private func transportChecks() async throws {
  let now = Date()
  let frozen = try DiagnosticsPayloadEncoder.freeze(
    health(type: .manualHealth, reason: .userInitiated),
    reportType: .manualHealth, now: now)
  let request = try DiagnosticsURLSessionTransport.makeRequest(frozen)
  try require(request.url == DiagnosticsURLSessionTransport.endpoint, "endpoint drift")
  try require(request.url?.scheme == "https", "diagnostics endpoint is not HTTPS")
  try require(request.httpMethod == "POST", "diagnostics method drift")
  try require(request.timeoutInterval == 8, "diagnostics timeout drift")
  try require(request.httpShouldHandleCookies == false, "cookies were enabled")
  try require(
    request.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8",
    "content type drift")
  try require(
    request.value(forHTTPHeaderField: "Accept") == "application/json", "accept header drift")
  try require(request.httpBody == frozen.data, "HTTP body differs from preview buffer")
  try require(Data(frozen.preview.utf8) == request.httpBody, "preview bytes differ from request body")
  try require(DiagnosticsURLSessionTransport.retryAfter("999999") == 21_600, "Retry-After was not bounded")

  let success = Date(timeIntervalSince1970: 100_000)
  let failedChain = success.addingTimeInterval(10_000)
  let decision = DiagnosticsSchedulePolicy.decision(
    DiagnosticsScheduleInput(
      now: failedChain, launchStartedAt: success, lastSuccessfulSend: success,
      lastChainStartedAt: failedChain, persistedNextEligible: nil,
      lastVersion: "1.0.0", lastBuild: "1", lastMacOSBuild: "25G83",
      currentVersion: "2.0.0", currentBuild: "2", currentMacOSBuild: "26A1"))
  try require(decision.reason == .heliosVersionChanged, "version reason drift")
  try require(
    decision.eligibleAt == failedChain.addingTimeInterval(86_400),
    "version change bypassed failed-chain cooldown")
  try require(DiagnosticsSchedulePolicy.retryDelays == [900, 7_200], "retry chain drift")
  try require(
    DiagnosticsSchedulePolicy.retryDelay(index: 2, jitter: 1, retryAfter: nil) == nil,
    "third invisible retry was allowed")

  let suiteName = "DiagnosticsTransportChecks.\(ProcessInfo.processInfo.processIdentifier)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    throw CheckFailure(description: "could not create isolated transport defaults")
  }
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = DiagnosticsPreferences(defaults: defaults)
  let mock = MockDiagnosticsTransport()
  var factoryCount = 0
  let controller = DiagnosticsController(preferences: preferences, transportFactory: {
    factoryCount += 1
    return mock
  })
  controller.start()
  await Task.yield()
  try require(factoryCount == 0, "transport was created before automatic consent")

  preferences.setConsent(.disabled)
  let manual = try controller.makeHealthPayload(type: .manualHealth, reason: .userInitiated)
  let result = await controller.sendManual(manual)
  try require(result == .accepted, "manual report failed while automatic diagnostics was OFF")
  try require(factoryCount == 1, "manual send did not lazily create transport")
  try require(mock.received == [manual.data], "manual transport did not receive frozen bytes")
  try require(preferences.lastSuccessfulReport != nil, "manual success was not shown locally")
  try require(
    preferences.lastSuccessfulAutomaticSend == nil,
    "manual success advanced the automatic-success cadence")
  try require(preferences.nextEligibleTime == nil, "manual success scheduled automatic work")
  controller.shutdown()
}


private struct MockSMCValue: Sendable {
  let type: String
  let bytes: [UInt8]
}

private final class MockSMCReadTransport: SMCReadTransport, @unchecked Sendable {
  private let values: [String: MockSMCValue]
  private let keys: [String]
  private let unavailableKeys: Set<String>
  private let ioErrorKeys: Set<String>
  private let readCountLock = NSLock()
  private var byteReadCounts: [String: Int] = [:]
  private var keyInfoFailuresRemaining: [String: Int]

  func byteReadCount(_ key: String) -> Int {
    readCountLock.withLock { byteReadCounts[key, default: 0] }
  }

  init(values: [String: MockSMCValue], unavailableKeys: Set<String> = [],
    ioErrorKeys: Set<String> = [], keyInfoFailuresRemaining: [String: Int] = [:]) {
    var complete = values
    let discoveredKeys = Array(Set(values.keys).union(["#KEY"])).sorted()
    let count = UInt32(discoveredKeys.count)
    complete["#KEY"] = MockSMCValue(
      type: "ui32",
      bytes: [
        UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
        UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count),
      ])
    self.values = complete
    self.keys = discoveredKeys
    self.unavailableKeys = unavailableKeys
    self.ioErrorKeys = ioErrorKeys
    self.keyInfoFailuresRemaining = keyInfoFailuresRemaining
  }

  func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
    if request.command == .keyInfo {
      let fail = readCountLock.withLock {
        guard keyInfoFailuresRemaining[request.key, default: 0] > 0 else { return false }
        keyInfoFailuresRemaining[request.key, default: 0] -= 1
        return true
      }
      if fail { throw TelemetryError.smc(request.key, 0x84) }
    }
    if request.command == .bytes {
      readCountLock.withLock { byteReadCounts[request.key, default: 0] += 1 }
      if ioErrorKeys.contains(request.key) { throw TelemetryError.smc(request.key, 0x84) }
    }
    if unavailableKeys.contains(request.key) {
      throw TelemetryError.unavailable("Unavailable in compatibility fixture")
    }
    switch request.command {
    case .keyAtIndex:
      guard Int(request.index) < keys.count else {
        throw TelemetryError.invalidData("Fixture key index outside bounds")
      }
      var reply = emptyReply()
      try putFourCC(keys[Int(request.index)], in: &reply, at: 0)
      return reply
    case .keyInfo:
      guard let value = values[request.key] else { throw TelemetryError.smc(request.key, 0x84) }
      var reply = emptyReply()
      putUInt32LE(UInt32(value.bytes.count), in: &reply, at: 28)
      try putFourCC(value.type, in: &reply, at: 32)
      return reply
    case .bytes:
      guard let value = values[request.key] else { throw TelemetryError.smc(request.key, 0x84) }
      var reply = emptyReply()
      guard value.bytes.count <= 32 else { throw TelemetryError.invalidData("Fixture value too large") }
      reply.replaceSubrange(48..<(48 + value.bytes.count), with: value.bytes)
      return reply
    }
  }

  private func emptyReply() -> [UInt8] {
    [UInt8](repeating: 0, count: SMCCodec.frameSize)
  }

  private func putFourCC(_ value: String, in bytes: inout [UInt8], at offset: Int) throws {
    putUInt32LE(try SMCCodec.fourCC(value), in: &bytes, at: offset)
  }

  private func putUInt32LE(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
    for index in 0..<4 {
      bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
    }
  }
}

private func sp78(_ celsius: Double) -> MockSMCValue {
  let raw = Int16((celsius * 256).rounded())
  let bits = UInt16(bitPattern: raw)
  return MockSMCValue(
    type: "sp78",
    bytes: [UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)])
}

private func flt(_ value: Float) -> MockSMCValue {
  let bits = value.bitPattern
  return MockSMCValue(
    type: "flt ",
    bytes: [
      UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
      UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24),
    ])
}

private func fpe2(_ rpm: Int) -> MockSMCValue {
  let raw = UInt16(clamping: rpm * 4)
  return MockSMCValue(
    type: "fpe2",
    bytes: [UInt8(truncatingIfNeeded: raw >> 8), UInt8(truncatingIfNeeded: raw)])
}

private func ui8(_ value: UInt8) -> MockSMCValue {
  MockSMCValue(type: "ui8 ", bytes: [value])
}

private func fanValues(
  count: Int, minimum: MockSMCValue? = fpe2(2_000), maximum: MockSMCValue? = fpe2(6_000),
  actual: MockSMCValue? = fpe2(2_500)
) -> [String: MockSMCValue] {
  var values: [String: MockSMCValue] = ["FNum": ui8(UInt8(count))]
  for index in 0..<count {
    if let minimum { values["F\(index)Mn"] = minimum }
    if let maximum { values["F\(index)Mx"] = maximum }
    if let actual { values["F\(index)Ac"] = actual }
  }
  return values
}

private func compatibilityCommon(fanCount: Int? = nil) -> DiagnosticsCommonFields {
  let report = health(fanCount: fanCount)
  return DiagnosticsCommonFields(
    helios: report.helios, system: report.system, capabilities: report.capabilities,
    providers: report.providers, helper: report.helper, runtime: report.runtime,
    stability: report.stability)
}

private func compatibilityReport(
  evidence: DiagnosticsCompatibilityEvidence, commonFanCount: Int? = nil
) -> DiagnosticsCompatibilityReport {
  DiagnosticsCompatibilityAssembler.report(
    common: compatibilityCommon(fanCount: commonFanCount), evidence: evidence,
    generatedAt: Date(timeIntervalSince1970: 10_000))
}

private func fixtureProbe(
  values: [String: MockSMCValue], unavailableKeys: Set<String> = [],
  classifier: ThermalClassifier = ThermalClassifier(cpuBrand: "")
) -> DiagnosticsCompatibilityProbe {
  let cpuBrand = classifier.cpuBrand
  let machineModel = classifier.machineModel
  let osBuild = classifier.osBuild
  return DiagnosticsCompatibilityProbe(
    transportFactory: { MockSMCReadTransport(values: values, unavailableKeys: unavailableKeys) },
    classifierFactory: {
      ThermalClassifier(cpuBrand: cpuBrand, machineModel: machineModel, osBuild: osBuild)
    })
}

@MainActor
private func thermalFailureEvidenceChecks() throws {
  let mixed = SMCThermalReader(client: SMCClient(transport: MockSMCReadTransport(
    values: ["Tp01": sp78(42), "Tbad": sp78(0)], ioErrorKeys: ["Tp01"])),
    classifier: ThermalClassifier(cpuBrand: "Apple M4"))
  let batch = try mixed.read(rawDetailsVisible: false)
  try require(batch.readings.isEmpty && batch.failures["Tbad"] != nil
    && batch.trustedFailures["Tp01"] != nil,
    "Empty thermal batches must retain optional and trusted evidence separately")
  try require({ if case .failure = batch.maximumSoCCelsius { true } else { false } }(),
    "An empty decoded batch fabricated a safe maximum")
  let tracker = DiagnosticsSessionTracker()
  var snapshot = TelemetrySnapshot()
  snapshot.thermals = MetricSample(.success(batch), capturedTicks: 1)
  tracker.accept(snapshot)
  let mixedReport = try tracker.buildHealth(type: .automaticHealth, reason: .daily)
  try require(mixedReport.providers.thermal.state == .partial
    && mixedReport.providers.thermal.failureCategory == .ioError
    && mixedReport.providers.thermal.failureCount == .one,
    "An optional alphabetically earlier decode error masked trusted I/O failure")

  let optionalOnly = SMCThermalReader(client: SMCClient(transport: MockSMCReadTransport(
    values: ["Tbad": sp78(0)])), classifier: ThermalClassifier(cpuBrand: ""))
  let rawBatch = try optionalOnly.read(rawDetailsVisible: false)
  try require(rawBatch.readings.isEmpty && rawBatch.failures["Tbad"] != nil
    && rawBatch.trustedFailures.isEmpty,
    "Optional-only invalid readings disappeared or became trusted failures")
  let rawTracker = DiagnosticsSessionTracker()
  snapshot.thermals = MetricSample(.success(rawBatch), capturedTicks: 1)
  rawTracker.accept(snapshot)
  let rawReport = try rawTracker.buildHealth(type: .automaticHealth, reason: .daily)
  try require(rawReport.providers.thermal.state == .partial
    && rawReport.providers.thermal.failureCategory == .noData
    && rawReport.providers.thermal.failureCount == .zero,
    "Optional-only absence invented a trusted provider failure episode")

  let metadataFailure = SMCThermalReader(client: SMCClient(transport: MockSMCReadTransport(
    values: ["Tp01": MockSMCValue(type: "x!  ", bytes: [1, 2])])),
    classifier: ThermalClassifier(cpuBrand: "Apple M4"))
  let metadataBatch = try metadataFailure.read()
  try require(metadataBatch.readings.isEmpty && metadataBatch.trustedFailures["Tp01"] != nil,
    "Trusted metadata failure disappeared when no valid temperature keys remained")

  // Do not slow the legacy frozen fan-readiness prefix evidence while hidden.
  let legacyTransport = MockSMCReadTransport(
    values: ["Tp01": sp78(42), "TpZZ": sp78(0)])
  let legacy = SMCThermalReader(client: SMCClient(transport: legacyTransport),
    classifier: ThermalClassifier(cpuBrand: "Apple M4"))
  let now = ContinuousClock.now
  _ = try legacy.read(rawDetailsVisible: false, now: now)
  _ = try legacy.read(rawDetailsVisible: false, now: now.advanced(by: .seconds(10)))
  try require(legacyTransport.byteReadCount("TpZZ") == 1,
    "Legacy advisory guard needlessly repeated a raw read inside its existing cadence")
  let repeated = try legacy.read(rawDetailsVisible: false, now: now.advanced(by: .seconds(16)))
  try require(legacyTransport.byteReadCount("TpZZ") == 2,
    "Hidden detail demand reduced the frozen fan-readiness evidence cadence")
  try require(repeated.trustedFailures["TpZZ"] == nil,
    "Preserving a conservative legacy fan guard invented an unknown sensor identity")

  let transientTransport = MockSMCReadTransport(values: ["Tp01": sp78(42)],
    keyInfoFailuresRemaining: ["Tp01": 1])
  let transient = SMCThermalReader(client: SMCClient(transport: transientTransport),
    classifier: ThermalClassifier(cpuBrand: "Apple M4"))
  let failed = try transient.read(rawDetailsVisible: false, now: now)
  let stillWaiting = try transient.read(rawDetailsVisible: false, now: now.advanced(by: .seconds(10)))
  try require(failed.trustedFailures["Tp01"] != nil && stillWaiting.readings.isEmpty,
    "Transient metadata failure vanished or caused unbounded immediate discovery retries")
  let recovered = try transient.read(rawDetailsVisible: false, now: now.advanced(by: .seconds(31)))
  try require(recovered.trustedFailures.isEmpty && (try recovered.maximumSoCCelsius.get()) == 42,
    "Bounded rediscovery did not recover from transient trusted metadata failure")
}

@MainActor
private func compatibilityChecks() async throws {
  var thermalAndFanless = fanValues(count: 0)
  thermalAndFanless["Tp01"] = sp78(47.5)
  thermalAndFanless["Te06"] = flt(48.7564)
  thermalAndFanless["T! x"] = MockSMCValue(type: "x!  ", bytes: [0x01, 0x02])
  let exactClassifier = ThermalClassifier(
    cpuBrand: "Apple M4", machineModel: "Mac16,1", osBuild: "25G83")
  let thermalEvidence = await fixtureProbe(
    values: thermalAndFanless, classifier: exactClassifier
  ).gather()
  try require(thermalEvidence.fanTopologyClass == .fanless, "fanless topology was not recognized")
  try require(thermalEvidence.safelyObservedFanCount == 0, "fanless count was not safely observed")
  try require(thermalEvidence.rawHardware.fanTopology.isEmpty, "fanless topology encoded fan entries")
  guard let te06 = thermalEvidence.rawHardware.smcThermalDiscovery.first(where: { $0.key == "Te06" }) else {
    throw CheckFailure(description: "Te06 fixture was not discovered")
  }
  try require(te06.dataType == "flt ", "SMC type lost its exact four-character form")
  try require(te06.dataSize == 4, "SMC data size was not preserved")
  try require(te06.decodedCelsius == 48.756, "decoded temperature was not bounded to three decimals")
  try require(
    thermalEvidence.thermalClassifications.first(where: { $0.key == "Te06" })?.semanticGroup
      == .validatedHotspot,
    "validated_hotspot exact-profile provenance was lost")
  guard let futureType = thermalEvidence.rawHardware.smcThermalDiscovery.first(where: { $0.key == "T! x" }) else {
    throw CheckFailure(description: "printable punctuation SMC key was not preserved")
  }
  try require(futureType.dataType == "x!  ", "future printable SMC type was normalized")
  try require(futureType.readState == .decodeFailed, "unknown SMC temperature type did not stay decode_failed")
  try require(
    thermalEvidence.compatibilityState == .needsReview,
    "unclassified raw SMC decode evidence incorrectly downgraded compatibility to partial")
  try require(
    thermalEvidence.rawHardware.providerDiagnostics.contains {
      $0.provider == .thermal && $0.stage == .decode && $0.category == .invalidData
    },
    "unclassified raw SMC decode evidence was not preserved")

  let liveReader = SMCThermalReader(
    client: SMCClient(transport: MockSMCReadTransport(values: thermalAndFanless)),
    classifier: exactClassifier)
  let liveThermals = try liveReader.read()
  try require(
    liveThermals.failures["T! x"] != nil,
    "unsupported unclassified T-prefixed SMC metadata disappeared from raw evidence")
  try require(
    liveThermals.trustedFailures["T! x"] == nil,
    "unsupported unclassified T-prefixed SMC metadata polluted trusted thermal health")

  var trustedFailureValues = fanValues(count: 0)
  trustedFailureValues["Tp01"] = sp78(47.5)
  let trustedFailure = await fixtureProbe(
    values: trustedFailureValues,
    unavailableKeys: ["Tp01"],
    classifier: exactClassifier
  ).gather()
  try require(
    trustedFailure.compatibilityState == .partial,
    "trusted thermal read failure did not keep compatibility partial")

  var boundedThermals = fanValues(count: 0)
  for index in 0...512 {
    boundedThermals[String(format: "T%03X", index)] = sp78(40)
  }
  let boundedEvidence = await fixtureProbe(values: boundedThermals).gather()
  try require(
    boundedEvidence.rawHardware.smcThermalDiscovery.count == 512,
    "manual compatibility exceeded the 512-thermal-entry bound")
  try require(
    boundedEvidence.rawHardware.providerDiagnostics.contains {
      $0.provider == .thermal && $0.stage == .validate && $0.category == .invalidData
    }, "truncated thermal discovery was not reported as coarse partial evidence")

  var unclassifiedValues = fanValues(count: 0)
  unclassifiedValues["Tp01"] = sp78(42)
  let unclassified = await fixtureProbe(values: unclassifiedValues).gather()
  try require(
    unclassified.thermalClassifications.first(where: { $0.key == "Tp01" })?.semanticGroup
      == .unclassified,
    "unknown hardware acquired an unsupported thermal identity")

  for count in 0...3 {
    let evidence = await fixtureProbe(values: fanValues(count: count)).gather()
    let expected: DiagnosticsFanTopologyClass = switch count {
    case 0: .fanless
    case 1: .singleFan
    case 2: .dualFan
    default: .multiFan
    }
    try require(evidence.fanTopologyClass == expected, "complete fan topology class drifted for count \(count)")
    try require(evidence.safelyObservedFanCount == count, "complete fan count was not preserved")
    try require(
      evidence.rawHardware.fanTopology.map(\.index) == Array(0..<count),
      "complete fan indexes were not contiguous")
  }

  let available = await fixtureProbe(values: fanValues(count: 1)).gather()
  try require(available.rawHardware.fanTopology.first?.rangeState == .available, "available fan range drift")
  let partial = await fixtureProbe(values: fanValues(count: 1, maximum: nil)).gather()
  try require(partial.rawHardware.fanTopology.first?.rangeState == .partial, "partial fan range drift")
  let unavailable = await fixtureProbe(
    values: fanValues(count: 1, minimum: nil, maximum: nil),
    unavailableKeys: ["F0Mn", "F0Mx"]
  ).gather()
  try require(
    unavailable.rawHardware.fanTopology.first?.rangeState == .unavailable,
    "unavailable fan range drift")
  let readFailed = await fixtureProbe(
    values: fanValues(count: 1, minimum: nil, maximum: nil)
  ).gather()
  try require(
    readFailed.rawHardware.fanTopology.first?.rangeState == .readFailed,
    "read_failed fan range drift")
  try require(
    readFailed.rawHardware.providerDiagnostics.contains {
      $0.provider == .fanTelemetry && $0.stage == .read && $0.category == .ioError
    }, "fan range read failure was not coarsened")

  let unknown = await fixtureProbe(
    values: [:], unavailableKeys: ["FNum"]
  ).gather()
  try require(unknown.fanTopologyClass == .unknown, "unknown fan topology was fabricated")
  try require(unknown.safelyObservedFanCount == nil, "unknown fan count was fabricated")
  try require(unknown.rawHardware.fanTopology.isEmpty, "unknown topology fabricated fan entries")
  let unknownWithSafeCommonCount = compatibilityReport(evidence: unknown, commonFanCount: 2)
  _ = try DiagnosticsPayloadEncoder.freeze(
    unknownWithSafeCommonCount, reportType: .manualCompatibility)

  let oneFanEntry = DiagnosticsFanTopologyEntry(
    index: 0, rangeState: .available, minimumRPM: 2_000, maximumRPM: 6_000, actualRPM: 2_500)
  let dishonestUnknown = DiagnosticsCompatibilityEvidence(
    rawHardware: DiagnosticsRawHardware(
      smcThermalDiscovery: [], fanTopology: [oneFanEntry], providerDiagnostics: []),
    thermalClassifications: [], fanTopologyClass: .unknown, safelyObservedFanCount: 1,
    compatibilityState: .partial)
  do {
    _ = try DiagnosticsPayloadEncoder.freeze(
      compatibilityReport(evidence: dishonestUnknown), reportType: .manualCompatibility)
    throw CheckFailure(description: "unknown topology masked a complete known topology")
  } catch DiagnosticsPayloadError.invalid { }

  let duplicateEntries = DiagnosticsCompatibilityEvidence(
    rawHardware: DiagnosticsRawHardware(
      smcThermalDiscovery: [], fanTopology: [oneFanEntry, oneFanEntry], providerDiagnostics: []),
    thermalClassifications: [], fanTopologyClass: .unknown, safelyObservedFanCount: nil,
    compatibilityState: .partial)
  do {
    _ = try DiagnosticsPayloadEncoder.freeze(
      compatibilityReport(evidence: duplicateEntries), reportType: .manualCompatibility)
    throw CheckFailure(description: "duplicate compatibility fan indexes were accepted")
  } catch DiagnosticsPayloadError.invalid { }

  let invalidIndexEntry = DiagnosticsFanTopologyEntry(
    index: 8, rangeState: .unavailable, minimumRPM: nil, maximumRPM: nil, actualRPM: nil)
  let invalidIndexEvidence = DiagnosticsCompatibilityEvidence(
    rawHardware: DiagnosticsRawHardware(
      smcThermalDiscovery: [], fanTopology: [invalidIndexEntry], providerDiagnostics: []),
    thermalClassifications: [], fanTopologyClass: .unknown, safelyObservedFanCount: nil,
    compatibilityState: .partial)
  do {
    _ = try DiagnosticsPayloadEncoder.freeze(
      compatibilityReport(evidence: invalidIndexEvidence), reportType: .manualCompatibility)
    throw CheckFailure(description: "out-of-range compatibility fan index was accepted")
  } catch DiagnosticsPayloadError.invalid { }

  let compatibilityPayload = try DiagnosticsPayloadEncoder.freeze(
    compatibilityReport(evidence: thermalEvidence), reportType: .manualCompatibility)
  var compatibilityObject = try JSONSerialization.jsonObject(with: compatibilityPayload.data) as! [String: Any]
  var rawHardware = compatibilityObject["raw_hardware"] as! [String: Any]
  var rawThermals = rawHardware["smc_thermal_discovery"] as! [[String: Any]]
  rawThermals[0]["raw_bytes"] = [1, 2, 3]
  rawHardware["smc_thermal_discovery"] = rawThermals
  compatibilityObject["raw_hardware"] = rawHardware
  do {
    try DiagnosticsPayloadValidator.validate(
      JSONSerialization.data(withJSONObject: compatibilityObject), expectedType: .manualCompatibility)
    throw CheckFailure(description: "raw SMC bytes were accepted by compatibility schema")
  } catch DiagnosticsPayloadError.invalid { }

  rawThermals[0].removeValue(forKey: "raw_bytes")
  rawThermals[0]["data_type"] = 1234
  rawHardware["smc_thermal_discovery"] = rawThermals
  compatibilityObject["raw_hardware"] = rawHardware
  do {
    try DiagnosticsPayloadValidator.validate(
      JSONSerialization.data(withJSONObject: compatibilityObject), expectedType: .manualCompatibility)
    throw CheckFailure(description: "non-string SMC data_type was accepted")
  } catch DiagnosticsPayloadError.invalid { }

  let suiteName = "DiagnosticsCompatibilityChecks.\(ProcessInfo.processInfo.processIdentifier)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    throw CheckFailure(description: "could not create isolated compatibility defaults")
  }
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = DiagnosticsPreferences(defaults: defaults)
  preferences.setConsent(.disabled)
  var diagnosticsTransportCreations = 0
  let transport = MockDiagnosticsTransport()
  let previewProbe = fixtureProbe(values: fanValues(count: 0))
  let controller = DiagnosticsController(
    preferences: preferences,
    transportFactory: {
      diagnosticsTransportCreations += 1
      return transport
    },
    compatibilityProbeFactory: { previewProbe })
  let preview = try await controller.makeCompatibilityPayload()
  try require(preview.reportType == .manualCompatibility, "compatibility preview type drift")
  try require(
    diagnosticsTransportCreations == 0,
    "Generate Preview created a diagnostics network transport")
  try require(!preferences.automaticEnabled, "compatibility preview enabled automatic diagnostics")
}

// Foundation owns URLProtocol's synchronization; this fixture adds no mutable shared state.
private class DiagnosticsHTTPFixture: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  var status: Int { 200 }
  override func startLoading() {
    var body = request.httpBody
    if body == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
      }
      body = bytes
    }
    let expected = try? DiagnosticsPayloadEncoder.freeze(
      health(type: .manualHealth, reason: .userInitiated), reportType: .manualHealth)
    guard body == expected?.data,
      request.value(forHTTPHeaderField: "X-Private-Fixture") == nil,
      request.value(forHTTPHeaderField: "Authorization") == nil,
      request.value(forHTTPHeaderField: "Cookie") == nil
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: status,
      httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "600"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"status":"accepted"}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
private final class DiagnosticsRejectedFixture: DiagnosticsHTTPFixture, @unchecked Sendable {
  override var status: Int { 400 }
}
private final class DiagnosticsRetryFixture: DiagnosticsHTTPFixture, @unchecked Sendable {
  override var status: Int { 429 }
}

@MainActor
private func urlSessionChecks() async throws {
  let payload = try DiagnosticsPayloadEncoder.freeze(
    health(type: .manualHealth, reason: .userInitiated), reportType: .manualHealth)
  for (fixture, expected) in [
    (DiagnosticsHTTPFixture.self, DiagnosticsTransportResult.accepted),
    (DiagnosticsRejectedFixture.self, .rejected),
    (DiagnosticsRetryFixture.self, .retryable(retryAfter: 600))]
  {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [fixture]
    configuration.httpAdditionalHeaders = ["X-Private-Fixture": "must be removed"]
    let transport = DiagnosticsURLSessionTransport(configuration: configuration)
    let result = await transport.send(payload)
    try require(result == expected, "URLSession bytes/headers/status mapping: \(expected)")
  }
  let session = URLSession(configuration: .ephemeral)
  defer { session.invalidateAndCancel() }
  let task = session.dataTask(with: DiagnosticsURLSessionTransport.endpoint)
  var redirected: URLRequest? = URLRequest(url: URL(string: "https://example.invalid")!)
  DiagnosticsRedirectDelegate().urlSession(session, task: task,
    willPerformHTTPRedirection: HTTPURLResponse(url: DiagnosticsURLSessionTransport.endpoint,
      statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: redirected!) {
      redirected = $0
    }
  try require(redirected == nil, "redirect could forward diagnostics")
}

@MainActor
private func runtimeAndLifecycleChecks() throws {
  let now = Date(timeIntervalSince1970: 50_000)
  let tracker = DiagnosticsSessionTracker(launchStartedAt: now.addingTimeInterval(-600))
  let own = ProcessActivity(pid: ProcessInfo.processInfo.processIdentifier,
    name: "FORBIDDEN_PROCESS_NAME", executablePath: "/Users/FORBIDDEN/path",
    physicalFootprintBytes: 80 * 1_048_576, neuralFootprintBytes: 0, cpuPercent: 2,
    powerWatts: nil, performanceCorePowerWatts: nil, diskReadBytesPerSecond: nil,
    diskWriteBytesPerSecond: nil, wakeupsPerSecond: nil, instructionsPerSecond: nil,
    cyclesPerSecond: nil, instructionsPerCycle: nil)
  var snapshot = TelemetrySnapshot()
  snapshot.processes = MetricSample(.success(ProcessMetrics(accessibleProcessCount: 1,
    topByCPU: [], topByEnergy: [], topByMemory: [], heliosActivity: own)),
    capturedAt: now, capturedTicks: 1)
  tracker.accept(snapshot)
  tracker.updateHelper(DiagnosticsHelperObservation(connectionState: .signingRequired))
  let report = try tracker.buildHealth(type: .automaticHealth, reason: .daily, generatedAt: now)
  try require(report.runtime.memoryFootprintMiB == .sixtyFiveToOneTwentyEight, "self memory bucket")
  try require(report.runtime.cpuPercent == .oneToFive, "self CPU bucket")
  try require(report.helper.failureCategory == .signing, "helper signing category")
  let frozen = try DiagnosticsPayloadEncoder.freeze(report, reportType: .automaticHealth)
  try require(!frozen.preview.contains("FORBIDDEN"), "self process identity leaked")
  let stale = try tracker.buildHealth(type: .automaticHealth, reason: .daily, generatedAt: now.addingTimeInterval(16))
  try require(stale.runtime.cpuPercent == .unknown && stale.runtime.memoryFootprintMiB == .unknown, "stale runtime was uploaded")
  try require(DiagnosticsFieldRules.runtimeCPU(.nan) == .unknown, "NaN CPU")
  try require(DiagnosticsFieldRules.runtimeCPU(-1) == .unknown, "negative CPU")
  try require(DiagnosticsFieldRules.runtimeCPU(0.2) == .pointTwoToOne, "CPU 0.2 boundary")
  try require(DiagnosticsFieldRules.runtimeCPU(1) == .pointTwoToOne, "CPU 1 boundary")
  try require(DiagnosticsFieldRules.runtimeCPU(20.1) == .overTwenty, "multicore CPU")
  try require(DiagnosticsFieldRules.runtimeMemory(bytes: 0) == .unknown, "missing memory")
  try require(DiagnosticsFieldRules.runtimeMemory(bytes: 16 * 1_048_576) == .upToSixteen, "memory boundary")
  snapshot.cpu = MetricSample(.failure(.invalidData("private")), capturedTicks: 2)
  tracker.accept(snapshot)
  snapshot.cpu = MetricSample(.failure(.warmingUp), capturedTicks: 3)
  tracker.accept(snapshot)
  _ = try DiagnosticsPayloadEncoder.freeze(
    tracker.buildHealth(type: .automaticHealth, reason: .daily), reportType: .automaticHealth)

  let suite = "Helios.LifecycleChecks.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let identity = DiagnosticsHelios(version: "0.1.0", build: "1")
  let first = DiagnosticsLifecycleStore(defaults: defaults)
  try require(defaults.data(forKey: DiagnosticsLifecycleStore.key) == nil, "constructing marker wrote before consent")
  first.begin(helios: identity, macOSBuild: "25G83")
  try require(first.summary.lifecycleCategory == .firstLaunch, "first tracked launch")
  first.update(duration: .oneToSixHours, macOSBuild: "25G83")
  let unclean = DiagnosticsLifecycleStore(defaults: defaults)
  unclean.begin(helios: identity, macOSBuild: "25G83")
  try require(unclean.summary.previousSessionEndedUncleanly, "unclean marker lost")
  try require(unclean.summary.previousSessionDuration == .oneToSixHours, "coarse previous duration")
  try require(unclean.summary.lifecycleCategory == .afterUncleanExit, "unclean category")
  unclean.end()
  let normal = DiagnosticsLifecycleStore(defaults: defaults)
  normal.begin(helios: identity, macOSBuild: "25G83")
  try require(!normal.summary.previousSessionEndedUncleanly, "clean exit marked unclean")
  try require(normal.summary.lifecycleCategory == .normalLaunch, "normal lifecycle")
  normal.end()
  let update = DiagnosticsLifecycleStore(defaults: defaults)
  update.begin(helios: DiagnosticsHelios(version: "0.1.0", build: "2"), macOSBuild: "25G83")
  try require(update.summary.lifecycleCategory == .afterUpdate, "app build lifecycle")
  update.clear()
  try require(defaults.data(forKey: DiagnosticsLifecycleStore.key) == nil, "opt-out retained marker")
  try require(update.summary.lifecycleCategory == .unknown, "opt-out retained lifecycle summary")
  let preferences = DiagnosticsPreferences(defaults: defaults)
  preferences.setConsent(.enabled)
  let transport = MockDiagnosticsTransport()
  let controller = DiagnosticsController(preferences: preferences,
    sleep: { _ in throw CancellationError() }, transportFactory: { transport })
  controller.start()
  try require(controller.session.stability.lifecycleCategory == .firstLaunch, "opt-in marker not started")
  preferences.eraseAllDiagnosticsPreferences()
  try require(controller.session.stability.lifecycleCategory == .unknown, "erase-all retained in-memory stability")
  try require(defaults.data(forKey: DiagnosticsLifecycleStore.key) == nil, "erase-all retained local marker")
  controller.shutdown()
  try require(transport.received.isEmpty, "Lifecycle-only fixture attempted diagnostics delivery")
}

private func exactScheduleChecks() throws {
  let launch = Date(timeIntervalSince1970: 100_000)
  func decision(success: Date? = nil, chain: Date? = nil, next: Date? = nil,
    version: String = "0.1.0", build: String = "1", os: String = "25G83") -> DiagnosticsScheduleDecision {
    DiagnosticsSchedulePolicy.decision(DiagnosticsScheduleInput(now: launch,
      launchStartedAt: launch, lastSuccessfulSend: success, lastChainStartedAt: chain,
      persistedNextEligible: next, lastVersion: "0.1.0", lastBuild: "1", lastMacOSBuild: "25G83",
      currentVersion: version, currentBuild: build, currentMacOSBuild: os))
  }
  try require(decision().eligibleAt == launch.addingTimeInterval(300), "initial five-minute eligibility")
  try require(decision(success: launch).eligibleAt == launch.addingTimeInterval(86400), "daily cadence")
  let daily = launch.addingTimeInterval(86400)
  try require(decision(success: launch, next: daily, build: "2").eligibleAt == launch.addingTimeInterval(3600), "persisted daily deadline hid app update")
  try require(decision(success: launch, next: daily, os: "26A1").eligibleAt == launch.addingTimeInterval(3600), "macOS update floor")
  try require(decision(success: launch, os: "unknown").reason == .daily, "unknown OS invented an update")
  try require(decision(success: launch, chain: launch.addingTimeInterval(30), build: "2").eligibleAt == launch.addingTimeInterval(86430), "failed-chain floor")
  try require(DiagnosticsSchedulePolicy.retryDelay(index: 0, jitter: 0, retryAfter: nil) == 720, "first retry lower jitter")
  try require(DiagnosticsSchedulePolicy.retryDelay(index: 1, jitter: 2, retryAfter: nil) == 8640, "second retry upper jitter")
  try require(DiagnosticsSchedulePolicy.retryDelay(index: 0, jitter: 1, retryAfter: 999999) == 21600, "Retry-After maximum")
}

@MainActor
private final class SuspendedDiagnosticsTransport: DiagnosticsTransporting {
  var received = 0
  var cancellations = 0
  var continuation: CheckedContinuation<DiagnosticsTransportResult, Never>?
  func send(_ payload: FrozenDiagnosticsPayload) async -> DiagnosticsTransportResult {
    received += 1
    return await withCheckedContinuation { continuation = $0 }
  }
  func cancel() { cancellations += 1 }
  func finish(_ result: DiagnosticsTransportResult) {
    continuation?.resume(returning: result)
    continuation = nil
  }
}

@MainActor
private func cancellationChecks() async throws {
  for shutdown in [false, true] {
    let suite = "Helios.ConsentRace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = DiagnosticsPreferences(defaults: defaults)
    preferences.setConsent(.enabled)
    let transport = SuspendedDiagnosticsTransport()
    let now = Date()
    let controller = DiagnosticsController(preferences: preferences,
      session: DiagnosticsSessionTracker(launchStartedAt: now.addingTimeInterval(-301)),
      now: { now }, transportFactory: { transport })
    controller.start()
    for _ in 0..<1000 where transport.received == 0 { await Task.yield() }
    try require(transport.received == 1, "automatic request never reached suspension")
    if shutdown { controller.shutdown() } else { controller.setAutomaticEnabled(false) }
    transport.finish(.accepted) // Simulate a late reply despite cancellation.
    for _ in 0..<1000 where controller.sending { await Task.yield() }
    try require(!controller.sending, "cancelled request never settled")
    try require(preferences.lastSuccessfulAutomaticSend == nil, "late reply changed automatic history")
    if !shutdown {
      try require(preferences.nextEligibleTime == nil, "opt-out was rescheduled by late reply")
      try require(defaults.data(forKey: DiagnosticsLifecycleStore.key) == nil, "opt-out kept marker")
    }
    try require(transport.cancellations == 1, "active automatic transport not cancelled exactly once")
    controller.shutdown()
  }
}

/// Optional offline native-to-server contract artifacts. These are controlled
/// fixtures, not hardware captures; only fake providers and a metadata-only
/// bundle feed the production builder, assembler and frozen encoder.
@MainActor
private func exportNativeContractFixturesIfRequested() async throws {
  guard let path = ProcessInfo.processInfo.environment["HELIOS_NATIVE_CONTRACT_FIXTURES"] else { return }
  try require(!path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    "Contract fixture export directory must not be empty")
  let directory = URL(fileURLWithPath: path, isDirectory: true)
  let manager = FileManager.default
  try manager.createDirectory(at: directory, withIntermediateDirectories: true)
  try require(try manager.contentsOfDirectory(atPath: directory.path).isEmpty,
    "Contract fixture export refuses to overwrite a nonempty directory")
  let identityURL = directory.appendingPathComponent(".contract-identity.bundle", isDirectory: true)
  let contents = identityURL.appendingPathComponent("Contents", isDirectory: true)
  try manager.createDirectory(at: contents, withIntermediateDirectories: true)
  let metadata: [String: String] = [
    "CFBundleIdentifier": "invalid.helios.contractfixture",
    "CFBundlePackageType": "BNDL",
    "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "4",
  ]
  try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
    .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
  guard let bundle = Bundle(url: identityURL) else {
    throw CheckFailure(description: "Could not read controlled contract identity metadata")
  }
  let generatedAt = Date(timeIntervalSince1970: 1_790_985_600)
  let tracker = DiagnosticsSessionTracker(launchStartedAt: generatedAt.addingTimeInterval(-600))
  var snapshot = TelemetrySnapshot()
  snapshot.system = MetricSample(.success(SystemMetrics(
    modelIdentifier: .success("Mac16,1"), chipName: .success("Apple M4"),
    osVersion: "Version 26.6.2 (Build 25G83)", osBuild: .success("25G83"),
    uptimeSeconds: 600, logicalProcessorCount: 8,
    physicalMemoryBytes: 16 * 1_073_741_824,
    loadAverage1: .success(0), loadAverage5: .success(0), loadAverage15: .success(0),
    thermalState: .nominal, lowPowerModeEnabled: false)))
  snapshot.cpu = MetricSample(.failure(.invalidData("controlled fixture")), capturedTicks: 1)
  tracker.accept(snapshot)
  snapshot.cpu = MetricSample(.success(CPUMetrics(
    userPercent: 2, systemPercent: 1, nicePercent: 0, idlePercent: 97)), capturedTicks: 2)
  snapshot.thermals = MetricSample(.success(ThermalMetrics(
    readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 42)],
    failures: ["T! x": .invalidData("controlled raw fixture")], trustedFailures: [:])),
    capturedTicks: 2)
  tracker.accept(snapshot)
  let automatic = try tracker.buildHealth(
    type: .automaticHealth, reason: .daily, generatedAt: generatedAt, bundle: bundle)
  try require(automatic.helios.version == "0.2.0" && automatic.helios.build == "4",
    "Native contract fixture identity must represent 0.2.0 beta 1/build 4")
  try require(automatic.providers.cpu.state == .available
    && automatic.providers.cpu.failureCount == .one
    && automatic.providers.thermal.state == .available,
    "Recovered episode/raw-only failure fixture lost its intended semantics")
  let automaticBytes = try DiagnosticsPayloadEncoder.freeze(
    automatic, reportType: .automaticHealth, now: generatedAt)

  snapshot.thermals = MetricSample(.success(ThermalMetrics(
    readings: [ThermalReading(key: "Tzzz", group: .unclassified, celsius: 141)],
    failures: [:], trustedFailures: [:])), capturedTicks: 3)
  tracker.accept(snapshot)
  let manual = try tracker.buildHealth(
    type: .manualHealth, reason: .userInitiated, generatedAt: generatedAt, bundle: bundle)
  try require(manual.providers.thermal.state == .partial
    && manual.providers.thermal.failureCategory == .noData
    && manual.providers.thermal.failureCount == .zero,
    "Raw-only manual fixture must preserve no_data without inventing failure episodes")
  let manualBytes = try DiagnosticsPayloadEncoder.freeze(
    manual, reportType: .manualHealth, now: generatedAt)

  var values = fanValues(count: 1)
  values["Tp01"] = sp78(42)
  values["Tzzz"] = flt(141)
  values["T! x"] = MockSMCValue(type: "x!  ", bytes: [1, 2])
  let evidence = await fixtureProbe(values: values, classifier: ThermalClassifier(
    cpuBrand: "Apple M4", machineModel: "Mac16,1", osBuild: "25G83")).gather()
  let compatibility = DiagnosticsCompatibilityAssembler.report(
    common: tracker.commonFields(generatedAt: generatedAt, bundle: bundle),
    evidence: evidence, generatedAt: generatedAt)
  let compatibilityBytes = try DiagnosticsPayloadEncoder.freeze(
    compatibility, reportType: .manualCompatibility, now: generatedAt)
  tracker.fanLayerSource = { sampleFanLayer() }
  let withFanLayer = try tracker.buildHealth(
    type: .automaticHealth, reason: .daily, generatedAt: generatedAt, bundle: bundle)
  let fanLayerBytes = try DiagnosticsPayloadEncoder.freeze(
    withFanLayer, reportType: .automaticHealth, now: generatedAt)
  try require(Data(fanLayerBytes.preview.utf8) == fanLayerBytes.data,
    "Native contract export must preserve exact frozen preview bytes")
  try fanLayerBytes.data.write(
    to: directory.appendingPathComponent("automatic_health_fan_layer.json"), options: .atomic)
  for payload in [automaticBytes, manualBytes, compatibilityBytes] {
    try require(Data(payload.preview.utf8) == payload.data,
      "Native contract export must preserve exact frozen preview bytes")
    try payload.data.write(
      to: directory.appendingPathComponent("\(payload.reportType.rawValue).json"), options: .atomic)
  }
  print("PASS exported all three native-frozen contract fixture types (fake evidence, no network/hardware)")
}


/// A fixed fan-layer section used by the grammar checks and the contract fixture.
private func sampleFanLayer() -> DiagnosticsFanLayer {
  var data = FanDiagnosticsData()
  for seconds in [6.2, 7.1, 8.0] { data.append(FanDiagnosticRecord(event: .takeoverHeld, seconds: seconds)) }
  data.append(FanDiagnosticRecord(event: .takeoverRefused, onBattery: true, lowPowerMode: true))
  data.append(FanDiagnosticRecord(event: .takeoverRefused, onBattery: false))
  data.append(FanDiagnosticRecord(event: .handbackOverLimit))
  data.append(FanDiagnosticRecord(event: .mode(.auto)))
  data.append(FanDiagnosticRecord(event: .mode(.boost)))
  data.observe(temperatureCelsius: 99.4, fanSharePercent: 71)
  data.observe(temperatureCelsius: 80, fanSharePercent: 95)
  return FanDiagnosticsSummary.report(
    data: data,
    settings: FanDiagnosticsSettings(
      tier: .experimental, controlEnabled: true, speedLimitUnlocked: false, autoUsesCurve: true,
      restoreAuto: false))
}

@MainActor
private func fanLayerChecks() throws {
  try require(
    DiagnosticsTakeoverDuration(seconds: nil) == .none
      && DiagnosticsTakeoverDuration(seconds: 2.9) == .underThree
      && DiagnosticsTakeoverDuration(seconds: 6) == .sixToTen
      && DiagnosticsTakeoverDuration(seconds: 15) == .overFifteen
      && DiagnosticsPeakTemperature(celsius: 94.9) == .from85
      && DiagnosticsPeakTemperature(celsius: 105) == .from105
      && DiagnosticsPeakTemperature(celsius: nil) == .unknown
      && DiagnosticsFanShare(percent: 89.9) == .from75
      && DiagnosticsFanShare(percent: 90) == .from90,
    "Fan-layer bucket edges")

  let layer = sampleFanLayer()
  try require(
    layer.takeovers.held == .twoToFive && layer.takeovers.refused == .twoToFive
      && layer.takeovers.timedOut == .zero && layer.takeoverDuration == .sixToTen
      && layer.refusalsOnBattery == .one && layer.refusalsInLowPowerMode == .one
      && layer.handbacks.overLimit == .one && layer.modesUsed == [.auto, .boost]
      && layer.peakTemperatureC == .from95 && layer.peakFanShare == .from90,
    "Fan-layer summary buckets, medians, refusal context and peaks")
  try require(
    FanDiagnosticsSummary.failureEvent(forDetail: "Fan control did not reply within 13 seconds; closed") == .takeoverTimedOut
      && FanDiagnosticsSummary.failureEvent(forDetail: "Fan 0 did not reach manual mode before the bounded deadline") == .takeoverRefused
      && FanDiagnosticsSummary.failureEvent(forDetail: "macOS did not hand over the fan this time") == .takeoverRefused
      && FanDiagnosticsSummary.failureEvent(forDetail: "anything else") == .takeoverFailed,
    "Takeover failures are classified by message")
  var capped = FanDiagnosticsData()
  capped.append(FanDiagnosticRecord(event: .mode(.manual)))
  for _ in 0..<(FanDiagnosticsData.maximumRecordsPerEvent + 25) { capped.append(FanDiagnosticRecord(event: .cooldownWait)) }
  try require(
    capped.records.filter { $0.event == .cooldownWait }.count == FanDiagnosticsData.maximumRecordsPerEvent
      && capped.records.contains { $0.event == .mode(.manual) },
    "Fan-layer records are bounded per kind and never forget a kind")

  let now = Date(timeIntervalSince1970: 1_790_985_600)
  let tracker = DiagnosticsSessionTracker(launchStartedAt: now.addingTimeInterval(-600))
  let plain = try tracker.buildHealth(type: .manualHealth, reason: .userInitiated, generatedAt: now)
  let plainPayload = try DiagnosticsPayloadEncoder.freeze(plain, reportType: .manualHealth, now: now)
  try require(plain.fanLayer == nil && !plainPayload.preview.contains("fan_layer"),
    "Without the opt-in the report must not mention the fan layer")
  tracker.fanLayerSource = { layer }
  let health = try tracker.buildHealth(type: .manualHealth, reason: .userInitiated, generatedAt: now)
  let payload = try DiagnosticsPayloadEncoder.freeze(health, reportType: .manualHealth, now: now)
  try require(payload.preview.contains("\"fan_layer\"") && payload.preview.contains("\"refusals_in_low_power_mode\""),
    "Opted-in report must contain the exact fan_layer section")

  // The validator refuses contradictory or open-ended sections.
  func expectInvalid(_ name: String, _ change: (inout [String: Any]) -> Void) throws {
    guard var root = try JSONSerialization.jsonObject(with: payload.data) as? [String: Any],
      var section = root["fan_layer"] as? [String: Any]
    else { throw CheckFailure(description: "fan_layer missing from the frozen payload") }
    change(&section)
    root["fan_layer"] = section
    let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    do {
      try DiagnosticsPayloadValidator.validate(data, expectedType: .manualHealth)
      throw CheckFailure(description: "Fan-layer validation accepted: \(name)")
    } catch is DiagnosticsPayloadError {}
  }
  try expectInvalid("no duration although takeovers were held") { $0["takeover_duration"] = "none" }
  try expectInvalid("a duration without any held takeover") {
    var takeovers = $0["takeovers"] as? [String: Any] ?? [:]
    takeovers["held"] = "0"
    $0["takeovers"] = takeovers
  }
  try expectInvalid("more refusals on battery than refusals") { $0["refusals_on_battery"] = "21+" }
  try expectInvalid("an unsupported Mac that controls fans") { $0["tier"] = "unsupported" }
  try expectInvalid("unsorted modes") { $0["modes_used"] = ["boost", "auto"] }
  try expectInvalid("repeated modes") { $0["modes_used"] = ["auto", "auto"] }
  try expectInvalid("an unknown property") { $0["note"] = "free text" }
  try expectInvalid("an unknown bucket") { $0["peak_temperature_c"] = "95" }
  try expectInvalid("a missing property") { $0.removeValue(forKey: "peak_fan_share") }

  // The compatibility report has no fan_layer section.
  var compat: [String: Any] = try JSONSerialization.jsonObject(with: payload.data) as? [String: Any] ?? [:]
  compat["report_type"] = "manual_compatibility"
  compat["report_reason"] = "user_initiated_compatibility"
  let compatData = try JSONSerialization.data(withJSONObject: compat, options: [.sortedKeys])
  do {
    try DiagnosticsPayloadValidator.validate(compatData, expectedType: .manualCompatibility)
    throw CheckFailure(description: "fan_layer accepted in a compatibility report")
  } catch is DiagnosticsPayloadError {}

  // Statistics are an independent preference, off until the user turns them on.
  let suite = "Helios.DiagnosticsFanStats.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure(description: "defaults") }
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = DiagnosticsPreferences(defaults: defaults)
  var discarded = 0
  preferences.fanStatisticsDiscarded = { discarded += 1 }
  try require(!preferences.fanStatisticsEnabled && !preferences.automaticEnabled,
    "Fan statistics must default to off")
  preferences.setFanStatisticsEnabled(true)
  try require(preferences.fanStatisticsEnabled && !preferences.automaticEnabled
    && DiagnosticsPreferences(defaults: defaults).fanStatisticsEnabled,
    "Fan statistics persist and never turn on automatic reports")
  preferences.setFanStatisticsEnabled(false)
  try require(discarded == 1 && !DiagnosticsPreferences(defaults: defaults).fanStatisticsEnabled,
    "Turning fan statistics off discards what was recorded")
}

@main
@MainActor
struct DiagnosticsChecks {
  static func main() async throws {
    try await urlSessionChecks()
    print("PASS real URLSession interception: exact preview bytes, no extra headers, status mapping, redirects refused")
    try runtimeAndLifecycleChecks()
    try exactScheduleChecks()
    try await cancellationChecks()
    print("PASS runtime buckets, lifecycle markers, exact schedule and late-reply cancellation")
    try schemaChecks()
    print("PASS diagnostics v1 closed DTOs, model grammar, omission, enums and strict validation")
    try preferencesChecks()
    print("PASS diagnostics consent defaults OFF, survives relaunch, fails safe and stays independent")
    try builderChecks()
    try systemSnapshotChecks()
    try thermalFailureEvidenceChecks()
    print("PASS diagnostics allowlist builder is preference-blind and launch-scoped")
    try frozenPayloadChecks()
    print("PASS diagnostics preview is one frozen buffer with expiring generation-bound approval")
    try await transportChecks()
    print("PASS diagnostics transport endpoint, body, consent gate, retry and cooldown contract")
    try await compatibilityChecks()
    print("PASS manual compatibility probe, topology, raw-SMC bounds, provenance and zero-network preview")
    try fanLayerChecks()
    print("PASS optional fan_layer section: opt-in only, closed enums and buckets, consistency rules, no free text")
    try await exportNativeContractFixturesIfRequested()
  }
}
