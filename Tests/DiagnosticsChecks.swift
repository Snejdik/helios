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

  preferences.eraseAllDiagnosticsPreferences()
  try require(preferences.consent == .notDecided, "erase-all did not restore undecided/OFF")
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

@main
@MainActor
struct DiagnosticsChecks {
  static func main() throws {
    try schemaChecks()
    print("PASS diagnostics v1 closed DTOs, model grammar, omission, enums and strict validation")
    try preferencesChecks()
    print("PASS diagnostics consent defaults OFF, survives relaunch, fails safe and stays independent")
    try builderChecks()
    print("PASS diagnostics allowlist builder is preference-blind and launch-scoped")
  }
}
