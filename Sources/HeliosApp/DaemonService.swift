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
        "Launch at login update failed: \(error.domain, privacy: .public) (\(error.code)): \(error.localizedDescription, privacy: .public)"
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
      "\(operation, privacy: .public): \(self.errorDetail ?? "Unknown failure", privacy: .public)")
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
#endif
