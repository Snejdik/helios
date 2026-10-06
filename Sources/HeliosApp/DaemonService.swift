import AppKit
import Combine
import OSLog
import ServiceManagement

enum DaemonRegistrationState: String {
  case missing = "Missing"
  case requiresApproval = "Requires Approval"
  case installed = "Installed"
  case unavailable = "Unavailable"

  init(_ status: SMAppService.Status) {
    switch status {
    case .notRegistered, .notFound: self = .missing
    case .requiresApproval: self = .requiresApproval
    case .enabled: self = .installed
    @unknown default: self = .unavailable
    }
  }
}

@MainActor
protocol ServiceRegistrationDriver {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() async throws
}

@MainActor
final class NativeServiceRegistration: ServiceRegistrationDriver {
  private var service: SMAppService {
    SMAppService.daemon(plistName: HeliosServiceIdentity.launchDaemonPlistName)
  }
  var status: SMAppService.Status { service.status }
  func register() throws { try service.register() }
  func unregister() async throws { try await service.unregister() }
}

@MainActor
final class DaemonService: NSObject, ObservableObject {
  @Published private(set) var state = DaemonRegistrationState.missing
  @Published private(set) var busy = false
  @Published private(set) var message: String?
  @Published private(set) var errorDetail: String?
  @Published private(set) var launchAtLoginEnabled = false
  @Published private(set) var launchAtLoginRequiresApproval = false
  @Published private(set) var launchAtLoginBusy = false
  @Published private(set) var launchAtLoginMessage: String?
  let client: DaemonClient
  let fanControl: FanControlModel
  private let driver: any ServiceRegistrationDriver
  private let connectAutomatically: Bool
  private let logger = Logger(
    subsystem: HeliosServiceIdentity.appIdentifier, category: "Registration")
  private var monitor: Task<Void, Never>?
  private var sleeping = false

  init(
    driver: any ServiceRegistrationDriver = NativeServiceRegistration(),
    connectAutomatically: Bool = true
  ) {
    self.driver = driver
    self.connectAutomatically = connectAutomatically
    let client = DaemonClient()
    self.client = client
    self.fanControl = FanControlModel(client: client)
    super.init()
    refresh()
    refreshLaunchAtLogin()
  }

  func start() {
    guard monitor == nil else { return }
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(refreshAfterActivation),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    monitor = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard let self else { return }
        if self.state != .missing { self.refresh() }
      }
    }
  }

  func shutdown() {
    monitor?.cancel()
    monitor = nil
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    client.disconnect()
  }

  func refresh() {
    guard !busy else { return }
    state = DaemonRegistrationState(driver.status)
    if state == .installed && !sleeping && connectAutomatically {
      client.connect()
    } else if client.state != .disconnected {
      client.disconnect()
    }
    refreshLaunchAtLogin()
  }

  func refreshLaunchAtLogin() {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      launchAtLoginEnabled = false
      launchAtLoginRequiresApproval = false
      return
    }
    let status = SMAppService.mainApp.status
    launchAtLoginEnabled = status == .enabled
    launchAtLoginRequiresApproval = status == .requiresApproval
  }

  @discardableResult
  func setLaunchAtLogin(_ enabled: Bool) async -> Bool {
    guard Bundle.main.bundleURL.pathExtension == "app", !launchAtLoginBusy else { return false }
    launchAtLoginBusy = true
    launchAtLoginMessage = nil
    var succeeded = true
    do {
      let appService = SMAppService.mainApp
      if enabled {
        if appService.status != .enabled { try appService.register() }
      } else if appService.status == .enabled || appService.status == .requiresApproval {
        try await appService.unregister()
      }
    } catch {
      succeeded = false
      let error = error as NSError
      launchAtLoginMessage = "Startup setting could not be changed: \(error.localizedDescription)"
      logger.error(
        "Launch at login update failed: \(error.domain, privacy: .public) (\(error.code)): \(error.localizedDescription, privacy: .private)"
      )
    }
    refreshLaunchAtLogin()
    launchAtLoginBusy = false
    let reachedRequestedState =
      enabled
      ? launchAtLoginEnabled
      : (!launchAtLoginEnabled && !launchAtLoginRequiresApproval)
    return succeeded && reachedRequestedState
  }

  func install() {
    guard !busy else { return }
    busy = true
    clearError()
    do { try driver.register() } catch { report(error, operation: "Installation") }
    busy = false
    refresh()
  }

  @discardableResult
  func uninstall() async -> Bool {
    guard !busy else { return false }
    busy = true
    clearError()
    client.disconnect()
    var succeeded = true
    do { try await unregisterAndWait() } catch {
      succeeded = false
      report(error, operation: "Removal")
    }
    busy = false
    refresh()
    return succeeded && state == .missing
  }

  func reinstall() async {
    guard !busy else { return }
    busy = true
    clearError()
    client.disconnect()
    do {
      // Await process termination, then observe removal before asking
      // ServiceManagement to resolve the replacement bundle/signature.
      if driver.status == .enabled || driver.status == .requiresApproval {
        try await unregisterAndWait()
      }
      try driver.register()
    } catch { report(error, operation: "Reinstallation") }
    busy = false
    refresh()
  }

  func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

  private func unregisterAndWait() async throws {
    try await driver.unregister()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var missingSince: ContinuousClock.Instant?
    while true {
      // On Tahoe, launchd removal and the completion callback can precede
      // BTM's disposition update. Immediate re-registration then returns
      // error 1 even while status says notRegistered. Require a stable
      // removal window; never modify or override approval state.
      if driver.status == .notRegistered {
        if let missingSince, missingSince.duration(to: .now) >= .seconds(1) { break }
        if missingSince == nil { missingSince = .now }
      } else {
        missingSince = nil
      }
      guard ContinuousClock.now < deadline else {
        throw NSError(
          domain: "com.snejda.Helios.Registration", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Service removal has not settled; replacement registration was not attempted."
          ])
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    logger.notice("Helper unregistered; previous process termination and removal completed.")
  }

  @objc private func refreshAfterActivation() { refresh() }
  @objc private func didWake() {
    sleeping = false
    refresh()
  }
  @objc private func willSleep() {
    sleeping = true
    client.disconnect()
  }

  private func clearError() {
    message = nil
    errorDetail = nil
  }

  private func report(_ error: Error, operation: String) {
    let error = error as NSError
    errorDetail = "\(error.domain) (\(error.code)): \(error.localizedDescription)"
    if error.code == kSMErrorInvalidSignature,
      error.domain == "SMAppServiceErrorDomain"
    {
      message =
        "macOS rejected this build's signature. Configure Apple Development signing and rebuild."
    } else if driver.status == .requiresApproval {
      message = "Approve Helios in System Settings → Login Items & Extensions."
    } else {
      message =
        "\(operation) could not be completed. Check this build's signing and helper registration."
    }
    logger.error(
      "\(operation, privacy: .public): \(error.domain, privacy: .public) (\(error.code)): \(self.errorDetail ?? "Unknown failure", privacy: .private)")
  }
}

#if DEBUG
  /// Explicit development invocation from the built app bundle. It never changes
  /// a pre-existing registration and removes only the registration it creates.
  @MainActor
  enum DaemonRegistrationProbe {
    /// Explicit development operations on this bundle's real SMAppService.
    /// Approval remains exclusively under System Settings control.
    static func manage(reinstall: Bool) async -> Int32 {
      let service = DaemonService(connectAutomatically: false)
      defer { service.shutdown() }
      print("Bundle: \(Bundle.main.bundleURL.path)")
      if reinstall { await service.reinstall() } else { await service.uninstall() }
      print("Helper status: \(service.state.rawValue)")
      if let error = service.errorDetail {
        print(error)
        return 1
      }
      return reinstall ? (service.state == .installed ? 0 : 2) : (service.state == .missing ? 0 : 1)
    }

    /// Uses the shipping client, production signing requirements and system
    /// Mach service. No anonymous listener, injected trust, or control requests.
    static func verifyConnection() async -> Int32 {
      let driver = NativeServiceRegistration()
      print("Bundle: \(Bundle.main.bundleURL.path)")
      print("App PID: \(getpid()), UID: \(geteuid())")
      print("Helper status: \(DaemonRegistrationState(driver.status).rawValue)")
      guard driver.status == .enabled else { return 2 }
      let client = DaemonClient()
      defer { client.disconnect() }
      client.connect()
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while client.state == .connecting && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard client.state == .connected, let version = client.negotiatedVersion,
        let pid = client.peerPID, let uid = client.peerUID, uid == 0, pid != getpid()
      else {
        print("FAIL: \(client.state.rawValue): \(client.detail ?? "No authenticated root peer")")
        return 1
      }
      print("PASS: Connected; handshake v\(version); authenticated daemon PID \(pid), UID \(uid)")
      let start = ContinuousClock.now
      var observed: UInt64 = 0
      while start.duration(to: .now) < .seconds(12) {
        try? await Task.sleep(for: .milliseconds(100))
        guard client.state == .connected, client.peerPID == pid else {
          print("FAIL: \(client.detail ?? "Connection lost")")
          return 1
        }
        if client.completedHeartbeats != observed {
          observed = client.completedHeartbeats
          print("PASS: heartbeat \(observed), elapsed \(start.duration(to: .now))")
        }
      }
      guard observed >= 10 else {
        print("FAIL: Fewer than ten completed heartbeats")
        return 1
      }
      print(
        "PASS: Installed, authenticated cross-process handshake and \(observed) heartbeats over 12 seconds"
      )
      return 0
    }

    static func run() async -> Int32 {
      let driver = NativeServiceRegistration()
      let before = driver.status
      print("Bundle: \(Bundle.main.bundleURL.path)")
      print("Before: \(DaemonRegistrationState(before).rawValue) (\(before.rawValue))")
      guard before == .notRegistered || before == .notFound else {
        print("Preserved pre-existing registration; lifecycle mutation skipped.")
        return 0
      }
      do {
        try driver.register()
        print("register(): succeeded")
      } catch {
        let error = error as NSError
        print("register(): \(error.domain) (\(error.code)): \(error.localizedDescription)")
      }
      let after = driver.status
      print("After registration: \(DaemonRegistrationState(after).rawValue) (\(after.rawValue))")
      if after == .enabled || after == .requiresApproval {
        do {
          try await driver.unregister()
          print("unregister(): succeeded")
        } catch {
          print("Cleanup failed: \(error)")
          return 1
        }
      }
      let final = driver.status
      print("Final: \(DaemonRegistrationState(final).rawValue) (\(final.rawValue))")
      return final == .notRegistered || final == .notFound ? 0 : 1
    }
  }

  /// Development-only, explicitly invoked checks of the fan layer against the
  /// installed helper. Stage 1 is the most conservative physical check: hold
  /// the factory minimum for a short, capped time, then return to macOS and
  /// verify by reading back. Any anomaly releases immediately.
  @MainActor
  enum FanLayerDevelopmentProbe {
    static let maximumHoldSeconds = 45.0
    static let abortCelsius = 85.0
    static let abortRPMOverTarget = 800.0

    private static func connected() async -> DaemonClient? {
      let client = DaemonClient()
      client.connect()
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while ContinuousClock.now < deadline, client.state != .connected || client.fanLayer == nil {
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard client.state == .connected else {
        print("FAIL: helper not connected: \(client.state.rawValue) \(client.detail ?? "")")
        client.disconnect()
        return nil
      }
      try? await Task.sleep(for: .milliseconds(1_500)) // let fanStatus arrive with a heartbeat
      return client
    }

    private static func describe(_ client: DaemonClient) {
      if let layer = client.fanLayer {
        print("Layer: tier=\(layer.tier.label) consented=\(layer.consented) machine=\(layer.machine)")
        print("Layer detail: \(layer.detail)")
      } else {
        print("Layer: no information")
      }
      print("Fan control available=\(client.fanControlAvailable) state=\(client.fanState) detail=\(client.fanDetail)")
    }

    static func info() async -> Int32 {
      guard let client = await connected() else { return 1 }
      defer { client.disconnect() }
      describe(client)
      return 0
    }

    static func consent(_ accepted: Bool) async -> Int32 {
      guard let client = await connected() else { return 1 }
      defer { client.disconnect() }
      describe(client)
      var result: (Bool, String)?
      guard client.setFanLayerConsent(accepted, completion: { result = ($0, $1) }) else {
        print("FAIL: request not sent")
        return 1
      }
      let deadline = ContinuousClock.now.advanced(by: .seconds(4))
      while result == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
      guard let result else { print("FAIL: no reply"); return 1 }
      print("Consent \(accepted ? "on" : "off"): ok=\(result.0) \(result.1)")
      return result.0 ? 0 : 1
    }

    private struct Readback {
      let ftst: UInt8
      let fans: [(mode: UInt8, target: Double, actual: Double, minimum: Double)]
      let celsius: Double?

      var text: String {
        let fanText = fans.enumerated().map { index, fan in
          "F\(index)Md=\(fan.mode) F\(index)Tg=\(Int(fan.target)) F\(index)Ac=\(Int(fan.actual))"
        }.joined(separator: " ")
        return "Ftst=\(ftst) \(fanText) T=\(celsius.map { String(format: "%.1f", $0) } ?? "?")°C"
      }
    }

    private static func readback(_ reader: SMCFanReader) throws -> Readback {
      let ftst = try reader.client.value("Ftst").bytes.first ?? 255
      let count = try FanCodec.count(reader.client.value("FNum"))
      let fans = try (0..<count).map { id in
        (mode: try reader.mode(id), target: try reader.rpm(id, "Tg"), actual: try reader.rpm(id, "Ac"),
         minimum: try reader.rpm(id, "Mn"))
      }
      var hottest: Double?
      for key in FanLayerTrustedThermals.m4PerformanceCPU.union(FanLayerTrustedThermals.m4EfficiencyCPU)
        .union(FanLayerTrustedThermals.m4GPU) {
        guard let value = try? reader.client.value(key),
          let celsius = try? SMCCodec.temperature(type: value.info.type, bytes: value.bytes),
          (5.0...130.0).contains(celsius) else { continue }
        hottest = max(hottest ?? celsius, celsius)
      }
      return Readback(ftst: ftst, fans: fans, celsius: hottest)
    }

    /// Stage 1: Manual at the factory minimum for `seconds` (≤ 45 s).
    /// `stall`: after takeover stop sending calculations (heartbeats continue)
    /// and expect the helper's lease to return the fans to macOS by itself.
    static func stage1(seconds requested: Double, stall: Bool = false) async -> Int32 {
      let seconds = min(maximumHoldSeconds, max(5, requested.isFinite ? requested : 20))
      let reader: SMCFanReader
      do { reader = SMCFanReader(client: SMCClient(transport: try SMCIOKitTransport())) } catch {
        print("FAIL: SMC read: \(error)"); return 1
      }
      guard let before = try? readback(reader) else { print("FAIL: baseline unreadable"); return 1 }
      print("BEFORE: \(before.text)")
      guard before.ftst == 0, before.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }),
        let celsius = before.celsius, celsius < abortCelsius, let minimum = before.fans.map(\.minimum).max()
      else {
        print("FAIL: baseline is not a clean macOS state or the Mac is too warm; nothing written")
        return 1
      }
      guard let client = await connected() else { return 1 }
      describe(client)
      guard client.fanLayer?.consented == true, client.fanControlAvailable else {
        print("FAIL: fan layer is not enabled on the helper; nothing written")
        client.disconnect()
        return 1
      }

      var failure: String?
      var engaged = false
      var stalledAt: ContinuousClock.Instant?
      var leaseRestoreSeconds: Double?
      let started = ContinuousClock.now
      while started.duration(to: .now) < .seconds(seconds) {
        guard client.state == .connected else { failure = "helper disconnected"; break }
        let live: Readback
        do { live = try readback(reader) } catch { failure = "readback failed: \(error)"; break }
        let t = live.celsius ?? .nan
        print(String(format: "t=%5.1fs ", Double(started.duration(to: .now).components.seconds)) + live.text
          + " state=\(client.fanState) detail=\(client.fanDetail)")
        guard t.isFinite, t < abortCelsius else { failure = "temperature limit"; break }
        if client.fanState == .override || client.fanState == .boost { engaged = true }
        if client.fanState == .recoveryRequired { failure = "helper reports recovery required"; break }
        if live.fans.contains(where: { $0.actual > minimum + abortRPMOverTarget }) {
          failure = "fan faster than expected"; break
        }
        if client.fanControlFaultRevision > 0 { failure = "helper reported a fan control fault: \(client.fanDetail)"; break }
        if stall, engaged {
          if stalledAt == nil { stalledAt = .now; print("STALL: no more calculations; expecting lease expiry") }
          if live.ftst == 0, live.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }), let stalledAt {
            leaseRestoreSeconds = Double(stalledAt.duration(to: .now).components.seconds)
              + Double(stalledAt.duration(to: .now).components.attoseconds) / 1e18
            print(String(format: "LEASE: helper returned the fans to macOS %.1f s after the last calculation",
              leaseRestoreSeconds ?? 0))
            break
          }
          try? await Task.sleep(for: .milliseconds(250))
          continue
        }
        client.calculate(mode: .override, rpm: minimum, temperature: t, sampleTicks: HostClock.now, response: .balanced)
        try? await Task.sleep(for: .milliseconds(500))
      }

      print("RELEASE: returning control to macOS")
      var released: HeliosFanState?
      if !client.releaseFans(graceful: false, completion: { released = $0 }) {
        print("Release request not sent; disconnecting so the helper restores System")
      }
      let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(8))
      while released == nil, ContinuousClock.now < releaseDeadline { try? await Task.sleep(for: .milliseconds(100)) }
      client.disconnect()
      try? await Task.sleep(for: .seconds(2))
      var verified = false
      for _ in 0..<20 {
        if let after = try? readback(reader) {
          print("AFTER: \(after.text)")
          if after.ftst == 0, after.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) { verified = true; break }
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
      print("Helper release reply: \(released.map { "\($0)" } ?? "none")")
      guard verified else { print("FAIL: macOS control not verified by readback"); return 2 }
      if let failure { print("STOPPED EARLY (released safely): \(failure)"); return 1 }
      if stall {
        guard let leaseRestoreSeconds, leaseRestoreSeconds <= 8 else {
          print("FAIL: lease expiry did not return the fans to macOS in time")
          return 1
        }
        print("PASS: lease expiry returned the fans to macOS without any app request")
        return 0
      }
      print(engaged ? "PASS: held the factory minimum, released and verified macOS control"
        : "PASS (no takeover needed): macOS was already at or above the minimum; verified macOS control")
      return 0
    }

    /// Takeover window while macOS is cooling: at most +300 RPM over macOS, never
    /// above 3,200 RPM, at most 20 s. Reads the fan every 0.25 s from Ftst=1 until
    /// Helios holds it and reports the lowest speed in that window. Nothing is
    /// written unless macOS is already spinning the fan.
    static func takeoverWindow(seconds requested: Double) async -> Int32 {
      let seconds = min(20, max(8, requested.isFinite ? requested : 20))
      let ceiling = 3_200.0
      let abort = 80.0
      let reader: SMCFanReader
      do { reader = SMCFanReader(client: SMCClient(transport: try SMCIOKitTransport())) } catch {
        print("FAIL: SMC read: \(error)"); return 1
      }
      guard let before = try? readback(reader) else { print("FAIL: baseline unreadable"); return 1 }
      print("BEFORE: \(before.text)")
      guard before.ftst == 0, before.fans.allSatisfy({ $0.mode == 3 }), let celsius = before.celsius, celsius < abort else {
        print("FAIL: macOS is not driving the fans (mode 3) or the Mac is too warm; nothing written")
        return 1
      }
      let macOSLevel = before.fans.map { max($0.target, $0.actual) }.max() ?? 0
      guard macOSLevel > 0 else { print("FAIL: macOS is not spinning the fan; nothing written"); return 1 }
      let request = min(ceiling, macOSLevel + 300)
      guard request > macOSLevel + FanLayerPolicy.engagementMarginRPM else {
        print("FAIL: macOS is already at \(Int(macOSLevel)) RPM; the approved ceiling leaves no room; nothing written")
        return 1
      }
      guard let client = await connected() else { return 1 }
      describe(client)
      guard client.fanLayer?.consented == true, client.fanControlAvailable else {
        print("FAIL: fan layer is not enabled on the helper; nothing written")
        client.disconnect()
        return 1
      }
      print("macOS level \(Int(macOSLevel)) RPM · request \(Int(request)) RPM")
      var failure: String?
      var ownedAt: Double?
      var ftstAt: Double?
      var windowMinimum = Double.infinity
      var lastSend = -1.0
      let started = ContinuousClock.now
      func elapsed() -> Double {
        let value = started.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
      }
      while elapsed() < seconds {
        guard client.state == .connected else { failure = "helper disconnected"; break }
        let live: Readback
        do { live = try readback(reader) } catch { failure = "readback failed: \(error)"; break }
        let t = live.celsius ?? .nan
        let now = elapsed()
        if live.ftst == 1, ftstAt == nil { ftstAt = now }
        if ftstAt != nil, ownedAt == nil { windowMinimum = min(windowMinimum, live.fans.map(\.actual).min() ?? 0) }
        if ownedAt == nil, client.fanState == .override { ownedAt = now }
        print(String(format: "t=%5.2fs ", now) + live.text + " state=\(client.fanState)")
        guard t.isFinite, t < abort else { failure = "temperature limit"; break }
        if live.fans.contains(where: { $0.actual > request + abortRPMOverTarget }) { failure = "fan faster than expected"; break }
        if client.fanState == .recoveryRequired { failure = "helper reports recovery required"; break }
        if client.fanControlFaultRevision > 0 { failure = "helper reported a fault: \(client.fanDetail)"; break }
        if now - lastSend >= 0.5 {
          client.calculate(mode: .override, rpm: request, temperature: t, sampleTicks: HostClock.now, response: .balanced)
          lastSend = now
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
      print("RELEASE: returning control to macOS")
      var released: HeliosFanState?
      _ = client.releaseFans(graceful: false, completion: { released = $0 })
      let deadline = ContinuousClock.now.advanced(by: .seconds(FanLayerTimings.clientReleaseTimeoutSeconds))
      while released == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
      client.disconnect()
      var verified = false
      for _ in 0..<40 {
        if let after = try? readback(reader) {
          print("AFTER: \(after.text)")
          if after.ftst == 0, after.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) { verified = true; break }
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
      guard verified else { print("FAIL: macOS control not verified by readback"); return 2 }
      let window = ownedAt.map { owned in ftstAt.map { owned - $0 } ?? 0 }
      print(String(format: "WINDOW: macOS level %d RPM · Ftst=1 at %@ · Helios holds at %@ · lowest speed in between %@",
                   Int(macOSLevel), ftstAt.map { String(format: "%.2f s", $0) } ?? "never",
                   ownedAt.map { String(format: "%.2f s", $0) } ?? "never",
                   windowMinimum.isFinite ? "\(Int(windowMinimum)) RPM" : "n/a")
            + (window.map { String(format: " · window %.2f s", $0) } ?? ""))
      if let failure { print("STOPPED EARLY (released safely): \(failure)"); return 1 }
      return 0
    }

    /// Re-acquisition after a release: hold the factory
    /// minimum, release, wait `gap` seconds on macOS, take over again and
    /// record how long the handover took or whether macOS refused it. Same
    /// abort rules as stage 1; every release is verified by readback.
    static func reacquire(gap requested: Double) async -> Int32 {
      let gap = min(60, max(0, requested.isFinite ? requested : 10))
      let hold = 10.0
      let reader: SMCFanReader
      do { reader = SMCFanReader(client: SMCClient(transport: try SMCIOKitTransport())) } catch {
        print("FAIL: SMC read: \(error)"); return 1
      }
      guard let before = try? readback(reader) else { print("FAIL: baseline unreadable"); return 1 }
      print("BEFORE: \(before.text)")
      guard before.ftst == 0, before.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }),
        let celsius = before.celsius, celsius < abortCelsius, let minimum = before.fans.map(\.minimum).max()
      else {
        print("FAIL: baseline is not a clean macOS state or the Mac is too warm; nothing written")
        return 1
      }
      guard let client = await connected() else { return 1 }
      describe(client)
      guard client.fanLayer?.consented == true, client.fanControlAvailable else {
        print("FAIL: fan layer is not enabled on the helper; nothing written")
        client.disconnect()
        return 1
      }

      func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      }

      /// Takes over (waiting up to 30 s) and holds the minimum. Returns the
      /// handover time, or nil when macOS refused it.
      func holdMinimum(_ label: String) async -> (acquired: Double?, failure: String?) {
        let started = ContinuousClock.now
        let faults = client.fanControlFaultRevision
        var acquiredAt: Double?
        while true {
          guard client.state == .connected else { return (acquiredAt, "helper disconnected") }
          let live: Readback
          do { live = try readback(reader) } catch { return (acquiredAt, "readback failed: \(error)") }
          let t = live.celsius ?? .nan
          let elapsed = seconds(since: started)
          print(String(format: "%@ t=%5.1fs ", label, elapsed) + live.text + " state=\(client.fanState)")
          guard t.isFinite, t < abortCelsius else { return (acquiredAt, "temperature limit") }
          if client.fanState == .recoveryRequired { return (acquiredAt, "helper reports recovery required") }
          if live.fans.contains(where: { $0.actual > minimum + abortRPMOverTarget }) {
            return (acquiredAt, "fan faster than expected")
          }
          if client.fanControlFaultRevision != faults {
            print("\(label) REFUSED after \(String(format: "%.1f", elapsed)) s: \(client.fanDetail)")
            return (nil, nil)
          }
          if acquiredAt == nil, client.fanState == .override || client.fanState == .boost {
            acquiredAt = elapsed
            print("\(label) ACQUIRED after \(String(format: "%.1f", elapsed)) s")
          }
          if let acquiredAt, elapsed - acquiredAt >= hold { return (acquiredAt, nil) }
          if acquiredAt == nil, elapsed > 30 { return (nil, "no handover within 30 s") }
          client.calculate(mode: .override, rpm: minimum, temperature: t, sampleTicks: HostClock.now,
                           response: .balanced)
          try? await Task.sleep(for: .milliseconds(500))
        }
      }

      /// Releases and verifies macOS control by readback.
      func release(_ label: String) async -> Bool {
        var released: HeliosFanState?
        let started = ContinuousClock.now
        if !client.releaseFans(graceful: false, completion: { released = $0 }) {
          print("\(label): release request not sent")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(FanLayerTimings.clientReleaseTimeoutSeconds))
        while released == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        for _ in 0..<20 {
          if let after = try? readback(reader), after.ftst == 0, after.fans.allSatisfy({ $0.mode == 0 || $0.mode == 3 }) {
            print(String(format: "%@: macOS control verified %.1f s after the release request · ", label,
                         seconds(since: started)) + after.text)
            return true
          }
          try? await Task.sleep(for: .milliseconds(250))
        }
        print("\(label): macOS control NOT verified")
        return false
      }

      let first = await holdMinimum("FIRST")
      guard await release("RELEASE 1") else { client.disconnect(); return 2 }
      if let failure = first.failure {
        client.disconnect()
        print("STOPPED EARLY (released safely): \(failure)")
        return 1
      }
      let waitStarted = ContinuousClock.now
      while seconds(since: waitStarted) < gap {
        if let live = try? readback(reader) {
          print(String(format: "GAP t=%5.1fs ", seconds(since: waitStarted)) + live.text)
          if let t = live.celsius, t >= abortCelsius { client.disconnect(); print("STOPPED: temperature"); return 1 }
        }
        try? await Task.sleep(for: .milliseconds(1_000))
      }
      let second = await holdMinimum("SECOND")
      let verified = await release("RELEASE 2")
      client.disconnect()
      guard verified else { return 2 }
      if let failure = second.failure { print("STOPPED EARLY (released safely): \(failure)"); return 1 }
      func text(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "refused" }
      print("REACQUIRE gap=\(Int(gap)) s · first handover \(text(first.acquired)) · second handover \(text(second.acquired))")
      return 0
    }
  }
#endif
