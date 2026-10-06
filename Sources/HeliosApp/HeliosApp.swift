import AppKit

@main
@MainActor
enum HeliosApp {
  static func main() {
    #if DEBUG
      if DeveloperCommands.runRequested() { return }
    #endif
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItemController: StatusItemController?
  private var telemetry: TelemetryMonitor?
  private var service: DaemonService?
  private var diagnostics: DiagnosticsController?
  private var fanDiagnostics: FanDiagnosticsRecorder?
  private var preferences: HeliosPreferences?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    installApplicationMenu()
    let preferences = HeliosPreferences()
    self.preferences = preferences
    let service = DaemonService()
    let diagnosticsPreferences = DiagnosticsPreferences()
    let diagnostics = DiagnosticsController(preferences: diagnosticsPreferences)
    self.diagnostics = diagnostics
    self.service = service
    let fanDiagnostics = FanDiagnosticsRecorder(
      model: service.fanControl, client: service.client,
      isEnabled: { [diagnosticsPreferences] in diagnosticsPreferences.fanStatisticsEnabled })
    self.fanDiagnostics = fanDiagnostics
    diagnosticsPreferences.fanStatisticsDiscarded = { [weak fanDiagnostics] in fanDiagnostics?.clear() }
    diagnostics.session.fanLayerSource = { [weak fanDiagnostics] in fanDiagnostics?.report() }
    service.start()
    let controller = StatusItemController(
      service: service, preferences: preferences, diagnostics: diagnostics)
    let monitor = TelemetryMonitor { [preferences] module in
      preferences.isTelemetryCollectionRequired(module)
    }
    controller.setDetailDemandHandler { [weak monitor] demand in
      monitor?.setDetailDemand(demand)
    }
    monitor.onChange = { [weak controller, weak service, weak diagnostics, weak fanDiagnostics] snapshot in
      service?.fanControl.refresh(snapshot)
      fanDiagnostics?.observe(snapshot)
      if let service {
        diagnostics?.accept(snapshot, helper: Self.diagnosticsHelperObservation(service))
      }
      controller?.update(snapshot)
    }
    monitor.onThermalSample = { [weak service, weak monitor] sample in
      service?.fanControl.accept(sample)
      monitor?.thermalInterval = service?.fanControl.pollingInterval ?? .seconds(2)
    }
    statusItemController = controller
    telemetry = monitor
    monitor.start()
    diagnostics.start()
    controller.showOnboardingIfNeeded()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(checkForAutomaticUpdates(_:)),
      name: NSWorkspace.didWakeNotification, object: nil)
    checkForAutomaticUpdates()
  }

  private func installApplicationMenu() {
    let menu = NSMenu()
    let applicationItem = NSMenuItem(title: "Helios", action: nil, keyEquivalent: "")
    let applicationMenu = NSMenu(title: "Helios")
    let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
    settings.target = self
    applicationMenu.addItem(settings)
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(NSMenuItem(title: "Quit Helios",
      action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    applicationItem.submenu = applicationMenu
    menu.addItem(applicationItem)
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = editMenu
    menu.addItem(editItem)
    // ⌘1…⌘9, then ⌘0, open the main window at a page (both interfaces).
    let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    let viewMenu = NSMenu(title: "View")
    for (index, page) in HeliosPage.allCases.enumerated() {
      let item = NSMenuItem(
        title: page.title, action: #selector(openPage(_:)), keyEquivalent: index < 9 ? String(index + 1) : "0")
      item.target = self
      item.representedObject = page.rawValue
      viewMenu.addItem(item)
    }
    viewMenu.addItem(.separator())
    // AppKit retitles this "Exit Full Screen" while a window is in full screen.
    let fullScreen = NSMenuItem(title: "Enter Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.control, .command]
    viewMenu.addItem(fullScreen)
    viewItem.submenu = viewMenu
    menu.addItem(viewItem)
    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(NSMenuItem(title: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    windowMenu.addItem(NSMenuItem(title: "Zoom",
      action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
    windowMenu.addItem(.separator())
    windowMenu.addItem(NSMenuItem(title: "Close Window",
      action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    windowItem.submenu = windowMenu
    menu.addItem(windowItem)
    NSApplication.shared.mainMenu = menu
    NSApplication.shared.windowsMenu = windowMenu
  }

  @objc private func openSettings(_ sender: Any?) { statusItemController?.showSettings() }

  @objc private func openPage(_ sender: NSMenuItem) {
    let page = (sender.representedObject as? String).flatMap(HeliosPage.init(rawValue:))
    statusItemController?.showMainWindow(page: page)
  }

  /// Clicking the Dock icon (shown while a window is open) reopens the main window.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { statusItemController?.showMainWindow() }
    return true
  }

  @objc private func checkForAutomaticUpdates(_ notification: Notification? = nil) {
    guard preferences?.onboardingCompleted == true else { return }
    HeliosUpdatePresenter.shared.check(manual: false)
  }

  func applicationDidBecomeActive(_ notification: Notification) { checkForAutomaticUpdates() }

  func applicationWillTerminate(_ notification: Notification) {
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    HeliosUpdatePresenter.shared.shutdown()
    statusItemController?.shutdown()
    telemetry?.shutdown()
    diagnostics?.shutdown()
    service?.shutdown()
  }

  private static func diagnosticsHelperObservation(_ service: DaemonService)
    -> DiagnosticsHelperObservation
  {
    let installation: DiagnosticsHelperInstallationState = switch service.state {
    case .missing: .missing
    case .requiresApproval: .requiresApproval
    case .installed: .installed
    case .unavailable: .unavailable
    }
    let connection: DiagnosticsHelperConnectionState = switch service.client.state {
    case .disconnected: .disconnected
    case .connecting: .connecting
    case .connected: .connected
    case .signingRequired: .signingRequired
    case .versionMismatch: .versionMismatch
    case .failed: .failed
    }
    let compatibility: DiagnosticsProtocolCompatibility = switch service.client.state {
    case .connected: .compatible
    case .versionMismatch: .mismatch
    default: .notChecked
    }
    return DiagnosticsHelperObservation(
      installationState: installation, connectionState: connection,
      protocolCompatibility: compatibility, failureCategory: nil)
  }
}
