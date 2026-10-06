import Foundation

/// Non-launching value checks. No app entry point, service construction, provider
/// sampling, async task, permission request, defaults or history store is reachable.
@main
@MainActor
struct UIFixtureChecks {
  private static func require(_ condition: Bool, _ message: String = "UI fixture invariant") {
    precondition(condition, message)
  }

  static func main() throws {
    let now = UIFixtureCatalog.now
    let all = UIFixtureCatalog.all
    require(all.count == UIFixtureCatalog.Scenario.allCases.count)
    require(Set(all.map { $0.scenario.rawValue }).count == all.count)
    for fixture in all {
      require(fixture.snapshot.cpu.capturedTicks == UIFixtureCatalog.ticks)
      require(fixture.snapshot.clock.capturedAt == now)
      require(fixture.snapshot.clock.capturedTicks == UIFixtureCatalog.ticks)
      require(!fixture.fanControlAvailable && fixture.fanMode == .system,
        "Fixture helper presentation must never grant write authority")
    }
    let healthy = UIFixtureCatalog.make(.healthy)
    require(try healthy.presentation.thermals.get().maximumSoCCelsius.get() == 56)
    let group = try healthy.presentation.temperatures(.performanceCPU).get()
    require(group.average == 52 && group.maximum == 56)
    for value in [Double.nan, Double.infinity] {
      let invalid = ThermalMetrics(
        readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: value)],
        failures: [:], trustedFailures: [:], advisoryReadingsCapturedAt: now)
      do {
        _ = try ThermalGroupSummary.summarize(invalid, group: .performanceCPU)
        preconditionFailure("Invalid presentation group temperature was accepted")
      } catch TelemetryError.invalidData(_) {}
    }
    let overflowing = ThermalMetrics(readings: [
      ThermalReading(key: "Tp01", group: .performanceCPU, celsius: .greatestFiniteMagnitude),
      ThermalReading(key: "Tp05", group: .performanceCPU, celsius: .greatestFiniteMagnitude),
    ], failures: [:], trustedFailures: [:], advisoryReadingsCapturedAt: now)
    do {
      _ = try ThermalGroupSummary.summarize(overflowing, group: .performanceCPU)
      preconditionFailure("Non-finite presentation group total was accepted")
    } catch TelemetryError.invalidData(_) {}
    do {
      _ = try ThermalGroupSummary.summarize(
        UIFixtureCatalog.make(.rawThermals).snapshot.thermals.result.get(), group: .unclassified)
      preconditionFailure("Unclassified readings supplied a trusted group summary")
    } catch TelemetryError.unavailable(_) {}
    let inventory = ThermalInventoryPresentation(try healthy.presentation.thermals.get())
    require(inventory.identified.count == 4 && inventory.raw.count == 1)
    require(inventory.unknown.count == 1 && inventory.auxiliary.isEmpty)
    require(inventory.summaries.count == 3 && inventory.advisoryFailures.isEmpty)
    require(TelemetryFormatting.processCPUShareText(120, logicalProcessorCount: 10) == "12.0%")
    let appRows = [
      InstalledApplicationMetrics(path: "/fixture/A.app", name: "A", bundleIdentifier: nil,
        version: nil, architecture: .appleSilicon, estimatedSizeBytes: 32, sizeTruncated: false),
      InstalledApplicationMetrics(path: "/fixture/B.app", name: "B", bundleIdentifier: nil,
        version: nil, architecture: .universal, estimatedSizeBytes: 64, sizeTruncated: false),
      InstalledApplicationMetrics(path: "/fixture/C.app", name: "C", bundleIdentifier: nil,
        version: nil, architecture: .intel, estimatedSizeBytes: nil, sizeTruncated: true),
    ]
    let appSummary = ApplicationsInventoryPresentation(ApplicationsMetrics(applications: appRows))
    require(appSummary.appleSiliconCount == 1 && appSummary.universalCount == 1
      && appSummary.intelCount == 1)
    require(appSummary.largestFirst.map(\.name) == ["B", "A", "C"])
    require(appSummary.largestFirst.last?.estimatedSizeBytes == nil,
      "Presentation manufactured a zero size for an unmeasured application")
    require(try UIFixtureCatalog.make(.twoFans).presentation.fans.get().fans.count == 2)
    require(try UIFixtureCatalog.make(.oneFan).presentation.fans.get().fans.count == 1)
    if case .success = UIFixtureCatalog.make(.desktop).presentation.battery {
      preconditionFailure("Desktop fixture must not invent battery measurements")
    }
    let connected = UIFixtureCatalog.make(.helperConnected)
    require(connected.helper.connectionState == .connected)
    require(connected.helper.installationState == .installed)
    require(!connected.fanControlAvailable)
    require(UIFixtureCatalog.make(.helperMissing).helper.installationState == .missing)
    require(UIFixtureCatalog.make(.fanControlUnavailable).helper.connectionState == .disconnected)
    require(try UIFixtureCatalog.make(.fanOSUnvalidated).presentation.fanOwnershipPreflight.get().state == .blocked)
    let partial = try UIFixtureCatalog.make(.thermalPartial).presentation.thermals.get()
    require(!partial.trustedFailures.isEmpty && partial.readings.count == 1)
    for scenario in [UIFixtureCatalog.Scenario.thermalNoData, .rawThermals] {
      let thermal = try UIFixtureCatalog.make(scenario).presentation.thermals.get()
      if case .success = thermal.maximumSoCCelsius {
        preconditionFailure("Empty/raw-only thermals must not produce a trusted SoC maximum")
      }
    }
    let stale = UIFixtureCatalog.make(.staleTelemetry).snapshot.cpu
    let staleObservation = TelemetryFormatting.observation(stale, maxAge: 5, now: now)
    require(staleObservation.state == .stale && staleObservation.isStale)
    require(try staleObservation.source.get().usagePercent == 12)
    let missing = UIFixtureCatalog.make(.providerUnavailable).snapshot.cpu
    let failed = TelemetryFormatting.observation(missing, maxAge: 5, now: now)
    require(failed.state == .unavailable && !failed.isStale)
    if case .failure(.kernel("Fixture CPU read", 5)) = failed.source {} else {
      preconditionFailure("Provider failure must survive observation interpretation")
    }
    let waiting = UIFixtureCatalog.make(.waitingForFirstSample).snapshot.cpu
    require(TelemetryFormatting.observation(waiting, maxAge: 5, now: now).state == .waiting)
    let oldWaiting = TelemetryFormatting.observation(waiting, maxAge: 5, now: now.addingTimeInterval(6))
    require(oldWaiting.state == .waiting && oldWaiting.isStale)
    let field = try UIFixtureCatalog.make(.fieldUnavailable).presentation.gpu.get()
    if case .success = field.deviceUtilizationPercent {
      preconditionFailure("Container success does not imply field availability")
    }
    require(try field.rendererUtilizationPercent.get() == 12)
    require(try UIFixtureCatalog.make(.memoryWarning).presentation.memory.get().pressure.get() == .warning)
    require(HealthEvaluator.evaluate(UIFixtureCatalog.make(.memoryWarning).snapshot, now: now)
      .contains { $0.id == "memory-warning" })
    require(try UIFixtureCatalog.make(.storageWarning).presentation.storage.get().smartHealth.get().state == .critical)
    require(HealthEvaluator.evaluate(UIFixtureCatalog.make(.storageWarning).snapshot, now: now)
      .contains { $0.id == "ssd-smart-critical" })
    require(try UIFixtureCatalog.make(.batteryWarning).presentation.battery.get().healthPercent.get() == 65)
    require(HealthEvaluator.evaluate(UIFixtureCatalog.make(.batteryWarning).snapshot, now: now)
      .contains { $0.id == "battery-health-critical" })
    require(UIFixtureCatalog.make(.notificationsDenied).notificationAuthorization == .denied)
    if case .available(let release) = UIFixtureCatalog.make(.updateAvailable).update {
      require(release.tag == "v0.1.0")
    } else { preconditionFailure("Update fixture lost its production outcome") }
    require(UIFixtureCatalog.make(.noUpdate).update == .upToDate)
    require(UIFixtureCatalog.make(.updateFailure).update == .failed)

    // The same container is valid at the hidden polling deadline and stale only
    // after the presentation allowance, for both Classic and capability consumers.
    let assertions = healthy.snapshot.powerAssertions
    for seconds in [60.0, 90.0] {
      let date = now.addingTimeInterval(seconds)
      _ = try TelemetryFormatting.fresh(assertions, maxAge: 90, now: date).get()
      let report = CapabilityEvaluator.evaluate(healthy.snapshot, now: date)
      require(report.items.first { $0.id == "power-assertions" }?.state == .available)
    }
    require(CapabilityEvaluator.evaluate(healthy.snapshot, now: now.addingTimeInterval(91))
      .items.first { $0.id == "power-assertions" }?.state == .unavailable)
    require(TelemetryFormatting.percent(.nan) == "—")
    require(TelemetryFormatting.temperature(.infinity) == "—")
    require(TelemetryFormatting.watts(-1) == "—")
    require(TelemetryFormatting.watts(-12.4, signed: true) == "-12.4 W")
    require(TelemetryFormatting.watts(12.4, signed: true) == "+12.4 W")
    require(TelemetryFormatting.watts(12.4, signed: true, showPositiveSign: false) == "12.4 W")
    require(TelemetryFormatting.watts(-12.4, signed: true, showPositiveSign: false) == "-12.4 W")
    require(TelemetryFormatting.fanRPM(-1) == "—")
    require(TelemetryFormatting.fanRPM(0) == "Fan off")
    require(TelemetryFormatting.fanRPM(50) == "50 RPM")
    require(TelemetryFormatting.ageSeconds(since: now.addingTimeInterval(-15), now: now) == "15s")
    require(TelemetryFormatting.ageSeconds(since: now.addingTimeInterval(1), now: now) == "0s")
    require(TelemetryFormatting.ageSeconds(since: Date(timeIntervalSince1970: -.infinity), now: now) == "—")
    require(TelemetryFormatting.percent(12.26, decimals: 1) == "12.3%")
    require(TelemetryFormatting.storageBytes(999) == "999 B")
    require(TelemetryFormatting.storageBytes(1_000) == "1.0 KB")
    require(TelemetryFormatting.storageBytes(.max) == TelemetryFormatting.decimalBytes(Double(UInt64.max)))

    HeliosAssessmentChecks.run()
    print("PASS deterministic UI values, observation semantics and formatting")
  }
}
