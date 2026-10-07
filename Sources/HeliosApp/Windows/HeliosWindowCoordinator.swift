import AppKit
import Darwin
import SwiftUI

/// Hands freed heap pages back to the system once a window or popover has closed.
/// Tearing down a SwiftUI tree frees tens of megabytes, but the allocator keeps
/// those pages resident, so a menu-bar app that was merely looked at would sit
/// at its peak. Two passes: after teardown, and after late releases settle.
@MainActor
enum HeliosMemoryRelief {
  private static var scheduled = false

  static func schedule() {
    guard !scheduled else { return }
    scheduled = true
    for (index, delay) in [3.0, 20.0].enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        if index == 1 { scheduled = false }
        DispatchQueue.global(qos: .utility).async { _ = malloc_zone_pressure_relief(nil, 0) }
      }
    }
  }
}

@MainActor
final class HeliosWindowCoordinator: NSObject, NSWindowDelegate {
  private let service: DaemonService
  private let preferences: HeliosPreferences
  private let model: OverviewViewModel
  private let diagnostics: DiagnosticsController
  private var monitorController: HeliosMonitorWindowController?
  /// Helios main window. At most one of this and the Legacy monitor exists.
  private var mainController: HeliosMainWindowController?
  private var lastPage: HeliosPage = .overview
  private var energyInspectorController: NSWindowController?
  private var settingsController: NSWindowController?
  private var onboardingController: NSWindowController?
  private var whatsNewController: NSWindowController?
  private var lastMonitorRoute: HeliosMonitorRoute = .overview
  private let energyInspectorState = HeliosEnergyInspectorState()
  private let settingsState = HeliosSettingsState()

  init(
    service: DaemonService, preferences: HeliosPreferences, model: OverviewViewModel,
    diagnostics: DiagnosticsController
  ) {
    self.service = service
    self.preferences = preferences
    self.model = model
    self.diagnostics = diagnostics
    super.init()
  }

  /// Legacy callers pass a Legacy route; the Helios interface maps it to a page.
  func showMonitor(snapshot: TelemetrySnapshot, route: HeliosMonitorRoute? = nil) {
    guard preferences.interface.style == .legacy else {
      showMain(page: route.map(HeliosPage.init(legacyRoute:)))
      return
    }
    let isNew = monitorController == nil
    let controller =
      monitorController
      ?? HeliosMonitorWindowController(
        model: model, service: service, preferences: preferences,
        openEnergyInspector: { [weak self] in self?.showEnergyInspector() },
        onRouteChange: { [weak self] in self?.refreshDetailDemand() })
    monitorController = controller
    controller.window?.delegate = self
    if let route {
      controller.select(route)
    } else if isNew {
      controller.select(lastMonitorRoute)
    }
    show(controller.window)
  }

  func showMain(page: HeliosPage? = nil) {
    guard preferences.interface.style == .helios else {
      showMonitor(snapshot: model.snapshot, route: page?.legacyRoute)
      return
    }
    let isNew = mainController == nil
    let controller = mainController ?? HeliosMainWindowController(
      model: model, preferences: preferences, service: service,
      actions: windowActions, diagnosticsPreferences: diagnostics.preferences,
      onPageChange: { [weak self] in self?.refreshDetailDemand() })
    mainController = controller
    controller.window?.delegate = self
    if let page {
      controller.select(page)
    } else if isNew {
      controller.select(lastPage)
    }
    show(controller.window)
  }

  /// Called after the interface preference changes. The open main window (if
  /// any) is replaced by the other style's window; no runtime service changes.
  func interfaceStyleDidChange() {
    let wasOpen = monitorController != nil || mainController != nil
    monitorController?.window?.close()
    mainController?.window?.close()
    if wasOpen { showMain() }
  }

  private var windowActions: HeliosActions {
    HeliosActions(
      openSettings: { [weak self] in self?.showSettings() },
      openSettingsRoute: { [weak self] route in self?.showSettings(route: route) },
      openEnergyInspector: { [weak self] in self?.showEnergyInspector() },
      openPage: { [weak self] page in self?.showMain(page: page) },
      copySystemSnapshot: { [weak self] in self?.copySystemSnapshot() })
  }

  func copySystemSnapshot() {
    Self.copySystemSnapshot(diagnostics.session.commonFields())
  }

  static func copySystemSnapshot(_ fields: DiagnosticsCommonFields) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(DiagnosticsSystemSnapshot.text(fields), forType: .string)
  }

  func showEnergyInspector() {
    let controller: NSWindowController
    if let energyInspectorController {
      controller = energyInspectorController
    } else {
      let content = HeliosEnergyInspectorView(
        model: model, preferences: preferences, state: energyInspectorState)
      let hosting = NSHostingController(rootView: content)
      let window = NSWindow(contentViewController: hosting)
      window.title = "Helios Energy Inspector"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.minSize = NSSize(width: 700, height: 500)
      window.setContentSize(NSSize(width: 820, height: 620))
      window.applyHeliosChrome(toolbar: "Helios.EnergyInspector.Toolbar")
      window.titlebarAppearsTransparent = true
      window.isReleasedWhenClosed = false
      window.center()
      controller = NSWindowController(window: window)
      window.delegate = self
      energyInspectorController = controller
    }
    show(controller.window)
  }

  func showSettings(route: HeliosSettingsRoute? = nil) {
    if let route { settingsState.selection = route }
    if preferences.onboardingCompleted { HeliosUpdatePresenter.shared.check(manual: false) }
    let controller: NSWindowController
    if let settingsController {
      controller = settingsController
    } else {
      let content = HeliosSettingsView(
        preferences: preferences, service: service, diagnostics: diagnostics,
        healthCenter: model.healthCenter, state: settingsState)
      let hosting = NSHostingController(rootView: content)
      let window = NSWindow(contentViewController: hosting)
      window.title = "Helios Settings"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      window.applyHeliosChrome(toolbar: "Helios.Settings.Toolbar")
      window.contentMinSize = NSSize(width: 720, height: 520)
      window.setContentSize(NSSize(width: 720, height: 520))
      window.isReleasedWhenClosed = false
      window.center()
      controller = NSWindowController(window: window)
      window.delegate = self
      // Autosave persists changes; restoration is a separate AppKit operation.
      // Restore before registering autosave so the default centered frame cannot
      // replace a previously saved size/position during reconstruction.
      _ = window.setFrameUsingName("Helios.Settings")
      window.clampContentToMinimum()
      _ = window.setFrameAutosaveName("Helios.Settings")
      settingsController = controller
    }
    show(controller.window)
  }

  func showOnboardingIfNeeded() {
    showWhatsNewIfNeeded()
    guard !preferences.onboardingCompleted else { return }
    if let onboardingController {
      show(onboardingController.window)
      return
    }

    let content = HeliosOnboardingView(
      preferences: preferences, diagnostics: diagnostics, service: service, model: model,
      onFinish: { [weak self] in
        self?.onboardingController?.close()
        self?.onboardingController = nil
        if self?.preferences.onboardingCompleted == true {
          HeliosUpdatePresenter.shared.check(manual: false)
        }
      })
    let hosting = NSHostingController(rootView: content)
    let window = NSWindow(contentViewController: hosting)
    window.title = "Welcome to Helios"
    window.styleMask = [.titled, .closable, .resizable]
    window.titlebarAppearsTransparent = true
    window.contentMinSize = NSSize(width: 600, height: 440)
    window.setContentSize(NSSize(width: 720, height: 560))
    window.isReleasedWhenClosed = false
    window.center()
    let controller = NSWindowController(window: window)
    window.delegate = self
    onboardingController = controller
    show(window)
  }

  /// Shown once per updated release, never on a fresh installation (see HeliosWhatsNew.decide).
  func showWhatsNewIfNeeded(defaults: UserDefaults = .standard) {
    let current = HeliosReleaseVersion.current()
    let decision = HeliosWhatsNew.decide(
      lastSeen: defaults.string(forKey: HeliosWhatsNew.lastSeenReleaseKey), current: current,
      onboardingCompleted: preferences.onboardingCompleted)
    guard decision != .nothing, let current else { return }
    // Recorded before showing, so a crash or a closed window never repeats it.
    defaults.set(current.tag, forKey: HeliosWhatsNew.lastSeenReleaseKey)
    guard decision == .show, whatsNewController == nil else { return }

    let content = HeliosWhatsNewView(
      preferences: preferences, service: service, release: current, diagnostics: diagnostics,
      onContinue: { [weak self] in self?.whatsNewController?.close() })
    let window = NSWindow(contentViewController: NSHostingController(rootView: content))
    window.title = "What’s New in Helios"
    window.styleMask = [.titled, .closable, .resizable]
    window.titlebarAppearsTransparent = true
    window.contentMinSize = NSSize(width: 480, height: 480)
    window.setContentSize(NSSize(width: 560, height: 760))
    window.isReleasedWhenClosed = false
    window.center()
    let controller = NSWindowController(window: window)
    window.delegate = self
    whatsNewController = controller
    show(window)
  }

  func refreshDetailDemand() {
    func visible(_ window: NSWindow?) -> Bool {
      guard let window else { return false }
      return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    let monitorDemand: TelemetryDetailDemand
    if visible(monitorController?.window) {
      monitorDemand = preferences.detailedMonitorContent ? .all
        : (monitorController?.selectedRoute ?? .overview).detailDemand
    } else if visible(mainController?.window) {
      monitorDemand = (mainController?.selectedPage ?? .overview).detailDemand
    } else { monitorDemand = [] }
    model.setDetailDemand(monitorDemand, owner: "monitor-window")
    model.setDetailDemand(visible(energyInspectorController?.window) ? .processes : [],
      owner: "energy-inspector")
  }

  func windowDidChangeOcclusionState(_ notification: Notification) { refreshDetailDemand() }
  func windowDidMiniaturize(_ notification: Notification) { refreshDetailDemand() }
  func windowDidDeminiaturize(_ notification: Notification) { refreshDetailDemand() }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    HeliosMemoryRelief.schedule()

    // A closed NSWindow can outlive the coordinator's strong reference inside
    // AppKit. Merely nil-ing our NSWindowController therefore does not prove
    // that a large NSHostingController/AttributeGraph tree is gone. Tear the
    // presentation hierarchy off the window explicitly before releasing our
    // controller. The shared telemetry model/preferences/service stay alive;
    // only reconstructible UI state is discarded.
    if window === monitorController?.window {
      // This reconstructible Expert cache is owned by the shared model. Release it on
      // close rather than retaining raw inventory for the shared model's lifetime.
      model.cancelSMCNumericInventory(clearCachedSample: true)
      let controller = monitorController
      lastMonitorRoute = controller?.selectedRoute ?? lastMonitorRoute
      monitorController = nil
      model.setDetailDemand([], owner: "monitor-window")
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === mainController?.window {
      model.cancelSMCNumericInventory(clearCachedSample: true)
      mainController?.prepareForClose()
      let controller = mainController
      lastPage = controller?.selectedPage ?? lastPage
      mainController = nil
      model.setDetailDemand([], owner: "monitor-window")
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === energyInspectorController?.window {
      let controller = energyInspectorController
      energyInspectorController = nil
      model.setDetailDemand([], owner: "energy-inspector")
      energyInspectorState.clearDerivedCache()
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === settingsController?.window {
      // AppKit may retain the closed NSWindow. Save before detaching its content,
      // then release the name so a reconstructed window can restore/reuse it.
      window.saveFrame(usingName: "Helios.Settings")
      _ = window.setFrameAutosaveName("")
      let controller = settingsController
      settingsController = nil
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === onboardingController?.window {
      let controller = onboardingController
      onboardingController = nil
      detachPresentationTree(from: window)
      controller?.window = nil
    } else if window === whatsNewController?.window {
      let controller = whatsNewController
      whatsNewController = nil
      detachPresentationTree(from: window)
      controller?.window = nil
    }

    // Application icons are reconstructible presentation data. Never keep a
    // workspace-icon cache alive merely because a heavy window was visited.
    HeliosAppIconCache.shared.purge()
    // The closing window is still visible during this callback.
    DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
  }

  /// A menu-bar app with a window open behaves like a regular app (Dock icon,
  /// ⌘-Tab, main menu); with no windows it returns to the menu bar only.
  private func updateActivationPolicy() {
    let anyOpen = [monitorController?.window, mainController?.window,
      settingsController?.window, energyInspectorController?.window, onboardingController?.window,
      whatsNewController?.window]
      .contains { $0?.isVisible == true || $0?.isMiniaturized == true }
    let policy: NSApplication.ActivationPolicy = anyOpen ? .regular : .accessory
    if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
  }

  private func detachPresentationTree(from window: NSWindow) {
    // Break responder/view/controller ownership in a deterministic order. This
    // is intentionally UI-only: no telemetry collector, helper, lease, fan or
    // persistence state is touched. A fresh hosting tree is built on reopen.
    window.makeFirstResponder(nil)
    window.delegate = nil
    window.contentViewController = nil
    window.contentView = NSView(frame: .zero)
  }

  private func show(_ window: NSWindow?) {
    guard let window else { return }
    if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    refreshDetailDemand()
    HeliosWindowChromeDiagnostics.logLater(window)
  }
}

@MainActor
final class HeliosMonitorWindowController: NSWindowController {
  private let model: OverviewViewModel
  private let navigation = HeliosMonitorNavigation()

  init(
    model: OverviewViewModel,
    service: DaemonService,
    preferences: HeliosPreferences,
    openEnergyInspector: @escaping () -> Void,
    onRouteChange: @escaping () -> Void = {}
  ) {
    self.model = model
    let root = HeliosMonitorWindowView(
      model: model, service: service, preferences: preferences, navigation: navigation,
      openEnergyInspector: openEnergyInspector)
    let hosting = NSHostingController(rootView: root)
    let window = NSWindow(contentViewController: hosting)
    window.title = "Helios"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.minSize = NSSize(width: 720, height: 500)
    window.setContentSize(NSSize(width: 860, height: 600))
    window.applyHeliosChrome(toolbar: "Helios.Monitor.Toolbar")
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    super.init(window: window)
    navigation.onSelectionChange = onRouteChange
  }

  required init?(coder: NSCoder) { nil }
  func select(_ route: HeliosMonitorRoute) { navigation.selection = route }
  var selectedRoute: HeliosMonitorRoute { navigation.selection ?? .overview }
}
