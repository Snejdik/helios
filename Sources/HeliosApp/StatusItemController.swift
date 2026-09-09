import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
  private let preferences: HeliosPreferences
  private let model = OverviewViewModel()
  private let service: DaemonService
  private lazy var windows = HeliosWindowCoordinator(
    service: service, preferences: preferences, model: model)

  private var snapshot = TelemetrySnapshot()
  private var subscriptions: Set<AnyCancellable> = []
  private var lastMenuBarFingerprint: String?

  private var compactStatusItem: NSStatusItem?
  private var compactReadout: MenuBarView?
  private var hubStatusItem: NSStatusItem?
  private var hubReadout: MenuBarView?
  private var nativeItems: [HeliosMenuBarMetric: NSStatusItem] = [:]
  private var nativeReadouts: [HeliosMenuBarMetric: MenuBarView] = [:]
  private var nativeTargets: [HeliosMenuBarMetric: MetricStatusTarget] = [:]

  private let dashboardPopover = NSPopover()
  private var metricPopovers: [HeliosMenuBarMetric: NSPopover] = [:]
  private weak var highlightedButton: NSStatusBarButton?
  private weak var highlightedPopover: NSPopover?
  private var localDismissMonitor: Any?
  private var globalDismissMonitor: Any?

  init(service: DaemonService, preferences: HeliosPreferences) {
    self.service = service
    self.preferences = preferences
    super.init()

    dashboardPopover.behavior = .transient
    dashboardPopover.animates = true
    dashboardPopover.delegate = self

    preferences.objectWillChange
      .sink { [weak self] _ in
        // objectWillChange fires before the preference mutates. Defer once, then
        // rebuild only when a menu-bar-specific fingerprint actually changed.
        // Graph range/style changes must never churn native status items.
        DispatchQueue.main.async { [weak self] in self?.rebuildMenuBarIfNeeded() }
      }
      .store(in: &subscriptions)

    rebuildMenuBarIfNeeded(force: true)
    update(snapshot)
  }

  func update(_ snapshot: TelemetrySnapshot) {
    self.snapshot = snapshot
    // UI8 keeps one shared presentation/history model alive for menu popups,
    // Full Monitor and the compact dashboard. No surface duplicates persistence.
    model.accept(snapshot)

    compactReadout?.update(snapshot)
    hubReadout?.update(snapshot)
    for readout in nativeReadouts.values { readout.update(snapshot) }

    windows.update(snapshot)
    let summary = accessibilitySummary(snapshot)
    compactStatusItem?.button?.toolTip = summary
    compactStatusItem?.button?.setAccessibilityValue(summary)
    hubStatusItem?.button?.toolTip = "Helios dashboard"
    for (metric, item) in nativeItems {
      let text = accessibilityValue(metric, snapshot: snapshot)
      item.button?.toolTip = "\(metric.label): \(text)"
      item.button?.setAccessibilityValue(text)
    }

    if dashboardPopover.isShown,
      let overview = dashboardPopover.contentViewController as? OverviewViewController
    {
      overview.update(snapshot)
    }
  }

  func showOnboardingIfNeeded() { windows.showOnboardingIfNeeded() }

  func popoverDidClose(_ notification: Notification) {
    guard let popover = notification.object as? NSPopover else { return }
    // Popovers are cheap to rebuild and their SwiftUI trees can retain charts,
    // diagnostic arrays and observation state. Drop the tree as soon as the
    // transient surface closes instead of keeping hidden presentation memory.
    popover.contentViewController = nil
    HeliosAppIconCache.shared.purge()
    guard highlightedPopover === popover else { return }
    clearHighlight()
    stopDismissMonitoring()
  }

  private func rebuildMenuBarIfNeeded(force: Bool = false) {
    let fingerprint = menuBarFingerprint()
    guard force || fingerprint != lastMenuBarFingerprint else { return }
    lastMenuBarFingerprint = fingerprint
    removeAllStatusItems()
    switch preferences.menuBarLayout {
    case .compactGroup:
      buildCompactItem()
    case .nativeModules:
      buildNativeItems()
    }
    update(snapshot)
  }

  private func menuBarFingerprint() -> String {
    let metrics = preferences.menuBarMetricsForPresentation.map { metric in
      let content = preferences.menuBarContent(for: metric)
      return [
        metric.rawValue, String(content.bitMask), preferences.identityStyle(for: metric).rawValue,
        preferences.label(for: metric),
      ]
      .joined(separator: ":")
    }
    return
      ([
        preferences.menuBarLayout.rawValue,
        preferences.showMenuBarHub ? "hub" : "nohub",
        preferences.coolingFeaturesEnabled ? "cooling" : "nocooling",
        String(format: "spacing:%.2f", preferences.menuBarSpacing),
      ] + metrics).joined(separator: "|")
  }

  private func removeAllStatusItems() {
    closeAllPopovers()
    if let item = compactStatusItem { NSStatusBar.system.removeStatusItem(item) }
    if let item = hubStatusItem { NSStatusBar.system.removeStatusItem(item) }
    for item in nativeItems.values { NSStatusBar.system.removeStatusItem(item) }
    compactStatusItem = nil
    compactReadout = nil
    hubStatusItem = nil
    hubReadout = nil
    nativeItems.removeAll()
    nativeReadouts.removeAll()
    nativeTargets.removeAll()
    for popover in metricPopovers.values { popover.contentViewController = nil }
    metricPopovers.removeAll()
  }

  private func buildCompactItem() {
    let metrics = preferences.menuBarMetricsForPresentation
    let content = Dictionary(
      uniqueKeysWithValues: metrics.map {
        ($0, preferences.menuBarContent(for: $0))
      })
    let labels = Dictionary(
      uniqueKeysWithValues: metrics.map {
        ($0, preferences.label(for: $0))
      })
    let readout = MenuBarView(
      frame: NSRect(x: 0, y: 0, width: MenuBarView.fixedWidth, height: 22),
      metrics: metrics,
      identityStyle: preferences.menuBarIdentityStyle)
    readout.setModuleSpacing(preferences.menuBarSpacing)
    readout.configure(metrics: metrics, content: content, labels: labels)
    let item = NSStatusBar.system.statusItem(withLength: readout.configuredWidth)
    item.autosaveName = "com.snejda.Helios.status.compact"
    guard let button = item.button else { return }
    install(readout: readout, in: button)
    button.setAccessibilityLabel("Helios system monitor")
    button.target = self
    button.action = #selector(toggleDashboard(_:))
    compactStatusItem = item
    compactReadout = readout
  }

  private func buildNativeItems() {
    let metrics = preferences.menuBarMetricsForPresentation
    if preferences.showMenuBarHub || metrics.isEmpty {
      let readout = MenuBarView(
        frame: NSRect(x: 0, y: 0, width: 24, height: 22), metrics: [], identityStyle: .symbol)
      let item = NSStatusBar.system.statusItem(withLength: 24)
      item.autosaveName = "com.snejda.Helios.status.hub"
      if let button = item.button {
        install(readout: readout, in: button)
        button.setAccessibilityLabel("Helios dashboard")
        button.target = self
        button.action = #selector(toggleDashboard(_:))
      }
      hubStatusItem = item
      hubReadout = readout
    }

    for metric in metrics.reversed() {
      // Creating status items in reverse keeps the user's logical left-to-right
      // order stable beside the optional Helios hub on current macOS versions.
      let style = preferences.identityStyle(for: metric)
      let content = preferences.menuBarContent(for: metric)
      let readout = MenuBarView(
        frame: NSRect(x: 0, y: 0, width: CGFloat(metric.statusWidth), height: 22),
        metrics: [metric], identityStyle: style)
      readout.setModuleSpacing(preferences.menuBarSpacing)
      readout.configure(
        metrics: [metric], content: [metric: content],
        labels: [metric: preferences.label(for: metric)])
      let item = NSStatusBar.system.statusItem(withLength: readout.configuredWidth)
      item.autosaveName = "com.snejda.Helios.status.\(metric.rawValue)"
      guard let button = item.button else { continue }
      install(readout: readout, in: button)
      button.setAccessibilityLabel("Helios \(metric.label)")
      let target = MetricStatusTarget(metric: metric, owner: self)
      button.target = target
      button.action = #selector(MetricStatusTarget.activate(_:))
      nativeItems[metric] = item
      nativeReadouts[metric] = readout
      nativeTargets[metric] = target
    }
  }

  private func install(readout: MenuBarView, in button: NSStatusBarButton) {
    button.title = ""
    button.image = nil
    readout.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(readout)
    NSLayoutConstraint.activate([
      readout.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      readout.trailingAnchor.constraint(equalTo: button.trailingAnchor),
      readout.topAnchor.constraint(equalTo: button.topAnchor),
      readout.bottomAnchor.constraint(equalTo: button.bottomAnchor),
    ])
  }

  fileprivate func activate(metric: HeliosMenuBarMetric, sender: NSStatusBarButton) {
    let popover = metricPopover(for: metric)
    if popover.isShown, highlightedButton === sender {
      popover.performClose(sender)
      return
    }

    dashboardPopover.performClose(nil)
    closeMetricPopovers(except: popover)
    setHighlighted(sender, for: popover)

    // Service state is already monitored continuously. Opening a menu-bar
    // surface must stay presentation-only and avoid synchronous registration/XPC
    // work on the click path.
    let content = HeliosMetricPopoverView(
      metric: metric,
      model: model,
      service: service,
      preferences: preferences,
      openRoute: { [weak self, weak popover] route in
        popover?.performClose(nil)
        self?.windows.showMonitor(snapshot: self?.snapshot ?? TelemetrySnapshot(), route: route)
      },
      openEnergyInspector: { [weak self, weak popover] in
        popover?.performClose(nil)
        self?.windows.showEnergyInspector()
      }
    )
    .onExitCommand { [weak self] in
      self?.forceCloseAllPopovers()
    }
    let hosting = NSViewController()
    hosting.view = HeliosEscapableHostingView(
      rootView: content,
      onCancel: { [weak self] in self?.forceCloseAllPopovers() })
    popover.contentViewController = hosting
    popover.contentSize = NSSize(
      width: 344, height: HeliosMetricPopoverView.preferredHeight(for: metric))
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    startDismissMonitoring(sourceButton: sender, popover: popover)
    DispatchQueue.main.async { [weak hosting] in
      guard let view = hosting?.view, let window = view.window else { return }
      // A status-item click does not necessarily activate a menu-bar app. Make
      // the popover window key so standard AppKit cancelOperation/Escape routing
      // reaches the hosting responder without requiring Accessibility privileges.
      window.makeKey()
      window.makeFirstResponder(view)
    }
  }

  private func metricPopover(for metric: HeliosMenuBarMetric) -> NSPopover {
    if let existing = metricPopovers[metric] { return existing }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    metricPopovers[metric] = popover
    return popover
  }

  private func closeMetricPopovers(except preserved: NSPopover? = nil) {
    for popover in metricPopovers.values where popover !== preserved && popover.isShown {
      if highlightedPopover === popover { clearHighlight(ifOwnedBy: popover) }
      popover.performClose(nil)
    }
  }

  private func closeAllPopovers() {
    dashboardPopover.performClose(nil)
    closeMetricPopovers()
    clearHighlight()
  }

  private func forceCloseAllPopovers() {
    dashboardPopover.close()
    for popover in metricPopovers.values where popover.isShown { popover.close() }
    clearHighlight()
    stopDismissMonitoring()
  }

  @objc private func toggleDashboard(_ sender: Any?) {
    if dashboardPopover.isShown {
      dashboardPopover.performClose(sender)
      return
    }
    closeMetricPopovers()
    let sourceButton =
      (sender as? NSStatusBarButton) ?? compactStatusItem?.button ?? hubStatusItem?.button
    guard let button = sourceButton else { return }
    setHighlighted(button, for: dashboardPopover)

    // Keep menu interaction presentation-only; DaemonService refreshes its
    // registration/connection state independently in the background.
    let overview =
      (dashboardPopover.contentViewController as? OverviewViewController)
      ?? OverviewViewController(
        model: model,
        service: service,
        preferences: preferences,
        openMonitor: { [weak self] in
          self?.windows.showMonitor(snapshot: self?.snapshot ?? TelemetrySnapshot())
        },
        openCooling: { [weak self] in
          self?.windows.showMonitor(
            snapshot: self?.snapshot ?? TelemetrySnapshot(), route: .thermals)
        },
        openSettings: { [weak self] in self?.windows.showSettings() },
        openRoute: { [weak self] route in
          self?.windows.showMonitor(snapshot: self?.snapshot ?? TelemetrySnapshot(), route: route)
        })
    _ = overview.view
    overview.update(snapshot)
    overview.preferredContentSize = NSSize(width: 420, height: 600)
    dashboardPopover.contentViewController = overview
    dashboardPopover.contentSize = NSSize(width: 420, height: 600)
    dashboardPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    startDismissMonitoring(sourceButton: button, popover: dashboardPopover)
  }

  private func startDismissMonitoring(sourceButton: NSStatusBarButton, popover: NSPopover) {
    stopDismissMonitoring()

    // NSPopover.transient normally handles outside clicks. Tahoe can still leave
    // a status-item popover alive when focus moves between status-bar windows,
    // so UI8 adds a tiny defensive monitor. It never consumes events; it only
    // closes the currently owned popover after an outside click or Escape.
    localDismissMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .keyDown]
    ) { [weak self, weak sourceButton, weak popover] event in
      guard let self, let popover, popover.isShown else { return event }
      if event.type == .keyDown, event.keyCode == 53 {
        DispatchQueue.main.async { [weak self] in self?.forceCloseAllPopovers() }
        return event
      }
      guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return event }
      let popoverWindow = popover.contentViewController?.view.window
      let sourceWindow = sourceButton?.window
      if event.window !== popoverWindow, event.window !== sourceWindow {
        DispatchQueue.main.async { [weak self] in self?.closeAllPopovers() }
      }
      return event
    }

    globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in self?.closeAllPopovers() }
    }
  }

  private func stopDismissMonitoring() {
    if let monitor = localDismissMonitor { NSEvent.removeMonitor(monitor) }
    if let monitor = globalDismissMonitor { NSEvent.removeMonitor(monitor) }
    localDismissMonitor = nil
    globalDismissMonitor = nil
  }

  private func setHighlighted(_ button: NSStatusBarButton, for popover: NSPopover) {
    clearHighlight()
    highlightedButton = button
    highlightedPopover = popover
    // UI8 deliberately uses AppKit's transient selected-state pill only while
    // this popover is open. The state is cleared on close, rebuild, or before
    // another status item becomes active.
    button.highlight(true)
  }

  private func clearHighlight(ifOwnedBy popover: NSPopover? = nil) {
    if let popover, highlightedPopover !== popover { return }
    highlightedButton?.highlight(false)
    highlightedButton = nil
    highlightedPopover = nil
  }

  private func accessibilitySummary(_ snapshot: TelemetrySnapshot) -> String {
    let parts = preferences.menuBarMetricsForPresentation.map {
      "\($0.label) \(accessibilityValue($0, snapshot: snapshot))"
    }
    return parts.isEmpty ? "Helios" : parts.joined(separator: ", ")
  }

  private func accessibilityValue(_ metric: HeliosMenuBarMetric, snapshot: TelemetrySnapshot)
    -> String
  {
    let presentation = OverviewPresentation(snapshot)
    switch metric {
    case .cpu:
      return DisplayValue(presentation.cpu.map(\.usagePercent)) {
        String(format: "%.0f percent", $0)
      }.text
    case .memory:
      return DisplayValue(presentation.memory.map(\.usagePercent)) {
        String(format: "%.0f percent", $0)
      }.text
    case .gpu:
      return DisplayValue(presentation.gpu.flatMap(\.deviceUtilizationPercent)) {
        String(format: "%.0f percent", $0)
      }.text
    case .temperature:
      return DisplayValue(presentation.thermals.flatMap(\.maximumSoCCelsius)) {
        String(format: "%.0f degrees Celsius", $0)
      }.text
    case .cooling:
      let temperature = DisplayValue(presentation.thermals.flatMap(\.maximumSoCCelsius)) {
        String(format: "%.0f degrees Celsius", $0)
      }.text
      if let rpm = presentationSnapshotFan(snapshot) {
        return rpm < 50
          ? "\(temperature), fan off" : "\(temperature), fan \(String(format: "%.0f RPM", rpm))"
      }
      return "\(temperature), fan unavailable"
    case .fan:
      return presentationSnapshotFan(snapshot).map {
        $0 < 50 ? "fan off" : String(format: "%.0f RPM", $0)
      } ?? "unavailable"
    case .battery:
      return DisplayValue(presentation.battery.flatMap(\.stateOfChargePercent)) {
        String(format: "%.0f percent", $0)
      }.text
    case .power:
      return DisplayValue(presentation.systemPower.flatMap(\.totalSystemWatts)) {
        String(format: "%.1f watts", $0)
      }.text
    case .network:
      return DisplayValue(presentation.network.flatMap(\.throughput)) {
        TelemetryFormatting.bytesPerSecond($0.downloadBytesPerSecond)
      }.text
    }
  }

  private func presentationSnapshotFan(_ snapshot: TelemetrySnapshot) -> Double? {
    guard case .success(let inventory) = TelemetryFormatting.fresh(snapshot.fans, maxAge: 6),
      let fan = inventory.fans.first
    else { return nil }
    return try? fan.actualRPM.get()
  }
}

@MainActor
private final class HeliosEscapableHostingView<Content: View>: NSHostingView<Content> {
  private let onCancel: () -> Void

  required init(rootView: Content) {
    self.onCancel = {}
    super.init(rootView: rootView)
  }

  init(rootView: Content, onCancel: @escaping () -> Void) {
    self.onCancel = onCancel
    super.init(rootView: rootView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { true }

  override func cancelOperation(_ sender: Any?) {
    onCancel()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onCancel()
      return
    }
    super.keyDown(with: event)
  }
}

@MainActor
private final class MetricStatusTarget: NSObject {
  let metric: HeliosMenuBarMetric
  weak var owner: StatusItemController?

  init(metric: HeliosMenuBarMetric, owner: StatusItemController) {
    self.metric = metric
    self.owner = owner
  }

  @objc func activate(_ sender: NSStatusBarButton) {
    owner?.activate(metric: metric, sender: sender)
  }
}
