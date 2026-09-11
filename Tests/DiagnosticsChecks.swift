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

private func schemaChecks() throws {
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
  let controller = DiagnosticsController(preferences: preferences) {
    factoryCount += 1
    return mock
  }
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

  init(values: [String: MockSMCValue], unavailableKeys: Set<String> = []) {
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
  }

  func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
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

@main
@MainActor
struct DiagnosticsChecks {
  static func main() async throws {
    try schemaChecks()
    print("PASS diagnostics v1 closed DTOs, model grammar, omission, enums and strict validation")
    try preferencesChecks()
    print("PASS diagnostics consent defaults OFF, survives relaunch, fails safe and stays independent")
    try builderChecks()
    print("PASS diagnostics allowlist builder is preference-blind and launch-scoped")
    try frozenPayloadChecks()
    print("PASS diagnostics preview is one frozen buffer with expiring generation-bound approval")
    try await transportChecks()
    print("PASS diagnostics transport endpoint, body, consent gate, retry and cooldown contract")
    try await compatibilityChecks()
    print("PASS manual compatibility probe, topology, raw-SMC bounds, provenance and zero-network preview")
  }
}
