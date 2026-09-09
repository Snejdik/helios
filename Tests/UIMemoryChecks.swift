// Test-only native presentation lifecycle stress. No live collectors, persistence,
// notification services, helper connection, or fan writes. Compile with the
// production UI and the generated deterministic PresentationChecks fixture.
import AppKit
import Darwin
import ServiceManagement
import SwiftUI

@MainActor
private final class MemoryRegistration: ServiceRegistrationDriver {
  var status: SMAppService.Status { .notRegistered }
  func register() throws { fatalError("Memory test must not register a helper") }
  func unregister() async throws { fatalError("Memory test must not unregister a helper") }
}

@MainActor
private final class WeakPresentation {
  weak var controller: NSWindowController?
  weak var hosting: NSViewController?
  init(_ window: NSWindow) {
    controller = window.windowController
    hosting = window.contentViewController
  }
}

@main
@MainActor
private struct UIMemoryChecks {
  static func settle(_ seconds: Double = 1) async {
    try? await Task.sleep(for: .seconds(seconds))
  }

  static func measure(_ label: String) {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    precondition(status == 0, "Memory query failed")
    print(String(format: "%@,%.3f,%.3f", label, Double(info.ri_resident_size) / 1048576,
                 Double(info.ri_phys_footprint) / 1048576))
    fflush(stdout)
  }

  static func closeWindows() -> [WeakPresentation] {
    let windows = NSApp.windows.filter { $0.isVisible && $0.windowController != nil }
    let weakReferences = windows.map(WeakPresentation.init)
    windows.forEach { $0.close() }
    return weakReferences
  }

  static func verifyReleased(_ references: [WeakPresentation]) {
    precondition(!references.isEmpty, "Lifecycle test did not actually open a window")
    precondition(references.allSatisfy { $0.controller == nil && $0.hosting == nil },
                 "Closed coordinator window retained its controller or hosting controller")
  }

  static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { await run() }
    // Match the shipping AppKit event/autorelease lifecycle. An async CLI main
    // alone is not an equivalent memory-reclamation environment.
    NSApplication.shared.run()
  }

  static func run() async {
    let suite = "Helios.UIMemoryChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let preferences = HeliosPreferences(defaults: defaults)
    preferences.applyInterfacePreset(.all)
    let service = DaemonService(driver: MemoryRegistration(), connectAutomatically: false)
    let model = OverviewViewModel(runtimeServicesEnabled: false)
    let now = Date()
    let snapshot = UIMemoryFixture.fixture(cpu: 24, temperature: 56, now: now)
    func dated<Value>(_ sample: MetricSample<Value>, at date: Date) -> MetricSample<Value> {
      MetricSample(sample.result, capturedAt: date, capturedTicks: sample.capturedTicks)
    }
    for offset in 0..<3600 {
      let date = now.addingTimeInterval(Double(offset - 3599))
      var historical = snapshot
      historical.cpu = dated(snapshot.cpu, at: date)
      historical.memory = dated(snapshot.memory, at: date)
      historical.gpu = dated(snapshot.gpu, at: date)
      historical.systemPower = dated(snapshot.systemPower, at: date)
      historical.battery = dated(snapshot.battery, at: date)
      historical.thermals = dated(snapshot.thermals, at: date)
      historical.fans = dated(snapshot.fans, at: date)
      historical.storage = dated(snapshot.storage, at: date)
      historical.network = dated(snapshot.network, at: date)
      historical.processes = dated(snapshot.processes, at: date)
      model.accept(historical, now: date)
    }
    precondition(model.history.points.filter { $0.cpuPercent != nil }.count == 3600,
                 "Memory fixture must render real sample geometry, not stale/nil history")
    model.appEnergy = AppEnergyHistoryEngine.summary((0..<360).map { index in
      AppEnergyBucket(capturedAt: now.addingTimeInterval(Double(index - 359) * 60),
        durationSeconds: 60, onBattery: index % 2 == 0, batteryPercent: 80,
        entries: [AppEnergyEntry(appKey: "app:/System/Applications/Music.app", displayName: "Music",
          energyWattHours: 0.01, cpuCoreSeconds: 4, wakeups: 20, peakMemoryBytes: 80_000_000)])
    })
    let coordinator = HeliosWindowCoordinator(service: service, preferences: preferences, model: model)
    await settle(3)
    print("stage,rss_mib,physical_mib")
    measure("baseline")
    for cycle in 1...5 {
      for route in [HeliosMonitorRoute.overview, .storage, .processes, .expert] {
        model.accept(UIMemoryFixture.fixture(cpu: 24, temperature: 56, now: Date()))
        coordinator.showMonitor(snapshot: model.snapshot, route: route)
        await settle()
      }
      var references = closeWindows()
      await settle(2)
      verifyReleased(references)
      measure("cycle-\(cycle)-monitor")
      model.accept(UIMemoryFixture.fixture(cpu: 24, temperature: 56, now: Date()))
      coordinator.showEnergyInspector()
      for range in [HeliosGraphRange.oneHour, .sixHours, .twentyFourHours] {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Helios Energy Inspector" }),
          let hosting = window.contentViewController as? NSHostingController<HeliosEnergyInspectorView>
        else { preconditionFailure("Energy Inspector fixture did not mount its production root") }
        hosting.rootView.state.range = range
        await settle()
      }
      references = closeWindows()
      await settle(2)
      verifyReleased(references)
      measure("cycle-\(cycle)-energy")
      coordinator.showSettings()
      await settle()
      references = closeWindows()
      await settle(2)
      verifyReleased(references)
      // Construct/destroy the exact dashboard and metric roots. This is not a
      // substitute for transient status-button/highlight interaction testing.
      model.accept(UIMemoryFixture.fixture(cpu: 24, temperature: 56, now: Date()))
      for metric in [HeliosMenuBarMetric.cpu, .memory, .battery] {
        autoreleasepool {
          let host = NSHostingController(rootView: HeliosMetricPopoverView(
            metric: metric, model: model, service: service, preferences: preferences, openRoute: { _ in }))
          host.view.layoutSubtreeIfNeeded()
        }
        await settle()
      }
      autoreleasepool {
        let host = OverviewViewController(model: model, service: service, preferences: preferences)
        host.view.layoutSubtreeIfNeeded()
      }
      HeliosAppIconCache.shared.purge()
      await settle(15)
      measure("cycle-\(cycle)-closed")
    }
    await settle(45)
    measure("final")
    print("PASS five cycles released every coordinator window/hosting controller; inspect footprint plateau separately")
    // exit() does not unwind Swift defers. Explicitly clean up test-only state.
    service.shutdown()
    defaults.removePersistentDomain(forName: suite)
    exit(0)
  }
}
