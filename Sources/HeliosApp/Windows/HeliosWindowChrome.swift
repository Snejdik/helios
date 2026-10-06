import OSLog
import AppKit

/// Opt-in (HELIOS_WINDOW_DIAGNOSTICS=1) check of the title-bar buttons: which
/// view and which window would receive a click on each of them. Read-only.
@MainActor
enum HeliosWindowChromeDiagnostics {
  private static let logger = Logger(subsystem: "com.snejda.Helios", category: "WindowChrome")

  private static var clickMonitor: Any?

  static func logLater(_ window: NSWindow) {
    guard ProcessInfo.processInfo.environment["HELIOS_WINDOW_DIAGNOSTICS"] == "1" else { return }
    if clickMonitor == nil {
      // Every real click: which window got it and whether it was on a title-bar button.
      clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
        let window = event.window
        let onButton = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind -> String? in
          guard let button = window?.standardWindowButton(kind) else { return nil }
          let local = button.convert(event.locationInWindow, from: nil)
          return button.bounds.contains(local) ? "\(kind.rawValue)" : nil
        }.first
        logger.notice("click \(event.type == .leftMouseDown ? "down" : "up", privacy: .public) window='\(window?.title ?? "none", privacy: .public)' button=\(onButton ?? "-", privacy: .public) at=\(NSStringFromPoint(event.locationInWindow), privacy: .public) appActive=\(NSApp.isActive) key=\(window?.isKeyWindow ?? false)")
        return event
      }
      NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil,
                                             queue: .main) { note in
        let window = note.object as? NSWindow
        MainActor.assumeIsolated {
          // Buttons live in the full-screen title bar window once revealed.
          if let window { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { log(window) } }
        }
      }
      for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                   NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                   NSWindow.didResignKeyNotification,
                   NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
          let window = note.object as? NSWindow
          MainActor.assumeIsolated {
            logger.notice("event \(name.rawValue, privacy: .public) \(window?.title ?? "app", privacy: .public)")
          }
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
      guard let window else { return }
      log(window)
    }
  }

  static func log(_ window: NSWindow) {
    let policy = NSApp.activationPolicy().rawValue
    logger.notice("Window \(window.title, privacy: .public): key=\(window.isKeyWindow) main=\(window.isMainWindow) appActive=\(NSApp.isActive) policy=\(policy) level=\(window.level.rawValue) ignoresMouse=\(window.ignoresMouseEvents) style=\(window.styleMask.rawValue) behavior=\(window.collectionBehavior.rawValue) toolbar=\(window.toolbar != nil)")
    guard let frameView = window.contentView?.superview else { return }
    let buttons: [(String, NSWindow.ButtonType)] = [("close", .closeButton), ("minimize", .miniaturizeButton), ("zoom", .zoomButton)]
    for (name, kind) in buttons {
      guard let button = window.standardWindowButton(kind) else {
        logger.notice("  \(name, privacy: .public): no button")
        continue
      }
      let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
      let hit = frameView.hitTest(center)
      let screen = window.convertPoint(toScreen: center)
      let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
      let owner = NSApp.windows.first { $0.windowNumber == top }
      logger.notice("  \(name, privacy: .public): enabled=\(button.isEnabled) hidden=\(button.isHidden) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil", privacy: .public) hitsButton=\(hit === button || hit?.isDescendant(of: button) == true) topWindowIsThis=\(top == window.windowNumber) topWindow=\(owner.map { "\(type(of: $0)) \($0.title) level \($0.level.rawValue)" } ?? "other app #\(top)", privacy: .public)")
    }
    if ProcessInfo.processInfo.environment["HELIOS_WINDOW_CLICK_TEST"] == "1",
       let button = window.standardWindowButton(.miniaturizeButton) {
      // Same queue path as a real click: monitors, sendEvent, the widget's tracking.
      let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
          NSApp.postEvent(event, atStart: false)
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
        logger.notice("  click test: miniaturized=\(window?.isMiniaturized ?? false)")
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
      }
    }
    for other in NSApp.windows where other !== window && other.isVisible {
      logger.notice("  other window \(String(describing: type(of: other)), privacy: .public) '\(other.title, privacy: .public)' frame=\(NSStringFromRect(other.frame), privacy: .public) level=\(other.level.rawValue) alpha=\(other.alphaValue) ignoresMouse=\(other.ignoresMouseEvents)")
    }
  }
}

extension NSWindow {
  /// Standard window chrome for every Helios window with a sidebar: a real
  /// (empty) unified toolbar and full-screen support. Without an NSToolbar the
  /// SwiftUI split view never revealed the title bar in full screen, so the
  /// traffic-light buttons could not be reached there.
  func applyHeliosChrome(toolbar identifier: String) {
    let toolbar = NSToolbar(identifier: identifier)
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    self.toolbar = toolbar
    toolbarStyle = .unified
    collectionBehavior.insert(.fullScreenPrimary)
  }

  /// A restored frame saved by an older build can be smaller than today's minimum
  /// layout (for example 700 pt wide against a 720 pt split view). AppKit does not
  /// clamp it, so the first frame drew the sidebar cut off until SwiftUI resized.
  func clampContentToMinimum() {
    let content = contentRect(forFrameRect: frame).size
    let minimum = contentMinSize
    guard content.width < minimum.width || content.height < minimum.height else { return }
    setContentSize(NSSize(width: max(content.width, minimum.width),
                          height: max(content.height, minimum.height)))
  }
}
