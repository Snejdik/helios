import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

// Mouse tools (PLAN_0_3_0 M6.7): an experimental module, hidden behind a switch in
// Settings › Advanced and off by default. It changes only how a *wheel* mouse scrolls:
// the direction (so a trackpad keeps natural scrolling while the wheel scrolls the
// traditional way) and how far one notch goes. Trackpads and Magic Mouse send continuous
// scroll events and pass through untouched. It needs Accessibility permission for an event
// tap that sees scroll events only; Helios reads no keys, clicks or pointer positions.

struct HeliosMouseScrollSettings: Codable, Equatable, Sendable {
  /// Reverse the direction of wheel mice only.
  var reverseWheel = true
  /// How far one notch scrolls, as a multiple of macOS's own distance (1 = unchanged).
  var wheelSpeed = 1

  static let speedRange = 1...5

  var isNeutral: Bool { !reverseWheel && wheelSpeed == 1 }
}

enum HeliosMouseScroll {
  /// The deltas of one scroll event: lines, points and fixed-point, vertical and horizontal.
  struct Deltas: Equatable, Sendable {
    var lines: (vertical: Int64, horizontal: Int64)
    var points: (vertical: Double, horizontal: Double)
    var fixed: (vertical: Double, horizontal: Double)

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.lines == rhs.lines && lhs.points == rhs.points && lhs.fixed == rhs.fixed
    }
  }

  /// The new deltas for a wheel event, or nil when the event should pass unchanged
  /// (continuous devices, neutral settings).
  static func transform(_ deltas: Deltas, continuous: Bool, settings: HeliosMouseScrollSettings) -> Deltas? {
    guard !continuous, !settings.isNeutral else { return nil }
    let sign: Int64 = settings.reverseWheel ? -1 : 1
    let speed = Int64(min(max(settings.wheelSpeed, HeliosMouseScrollSettings.speedRange.lowerBound),
                          HeliosMouseScrollSettings.speedRange.upperBound))
    let factor = Double(sign * speed)
    return Deltas(
      lines: (deltas.lines.vertical.multipliedReportingOverflow(by: sign * speed).partialValue,
              deltas.lines.horizontal.multipliedReportingOverflow(by: sign * speed).partialValue),
      points: (deltas.points.vertical * factor, deltas.points.horizontal * factor),
      fixed: (deltas.fixed.vertical * factor, deltas.fixed.horizontal * factor))
  }
}

/// The running tap. Settings live behind a lock because the tap callback is a C function.
final class HeliosMouseTap: @unchecked Sendable {
  static let shared = HeliosMouseTap()
  private let lock = NSLock()
  private var settings = HeliosMouseScrollSettings()
  private var port: CFMachPort?
  private var source: CFRunLoopSource?
  private let logger = Logger(subsystem: "com.snejda.Helios", category: "MouseTools")

  var isRunning: Bool { lock.withLock { port != nil } }

  func update(_ settings: HeliosMouseScrollSettings) { lock.withLock { self.settings = settings } }

  /// Installs the scroll-only tap on the main run loop. False without Accessibility permission.
  @MainActor
  func start() -> Bool {
    if isRunning { return true }
    guard AXIsProcessTrusted() else { return false }
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    guard let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: heliosMouseTapCallback, userInfo: nil)
    else {
      logger.error("Mouse tools: the scroll event tap could not be created")
      return false
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    lock.withLock {
      self.port = port
      self.source = source
    }
    logger.notice("Mouse tools: scroll tap on")
    return true
  }

  @MainActor
  func stop() {
    let (port, source) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?) in
      defer { self.port = nil; self.source = nil }
      return (self.port, self.source)
    }
    if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if port != nil { logger.notice("Mouse tools: scroll tap off") }
  }

  fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent {
    // macOS turns a slow tap off; turn it straight back on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
      return event
    }
    guard type == .scrollWheel else { return event }
    let settings = lock.withLock { self.settings }
    let current = HeliosMouseScroll.Deltas(
      lines: (event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
              event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
      points: (event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
               event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
      fixed: (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
              event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)))
    let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    guard let changed = HeliosMouseScroll.transform(current, continuous: continuous, settings: settings) else {
      return event
    }
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: changed.lines.vertical)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: changed.lines.horizontal)
    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: changed.points.vertical)
    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: changed.points.horizontal)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: changed.fixed.vertical)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: changed.fixed.horizontal)
    return event
  }
}

private func heliosMouseTapCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  Unmanaged.passUnretained(HeliosMouseTap.shared.handle(type, event))
}

/// The switch and settings the user sees (Settings › Advanced). Nothing runs while off.
@MainActor
final class HeliosMouseTools: ObservableObject {
  static let shared = HeliosMouseTools()
  static let enabledKey = "HeliosMouseTools.enabled"
  static let settingsKey = "HeliosMouseTools.settings"

  enum State: Equatable { case off, needsPermission, active }

  @Published private(set) var enabled: Bool
  @Published private(set) var state: State = .off
  @Published var settings: HeliosMouseScrollSettings {
    didSet {
      guard settings != oldValue else { return }
      if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
      HeliosMouseTap.shared.update(settings)
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.bool(forKey: Self.enabledKey)
    settings = defaults.data(forKey: Self.settingsKey)
      .flatMap { try? JSONDecoder().decode(HeliosMouseScrollSettings.self, from: $0) } ?? HeliosMouseScrollSettings()
  }

  /// At launch, and whenever Helios becomes active (the user may just have granted access).
  func start() {
    guard enabled, state != .active else { return }
    activate()
  }

  func setEnabled(_ on: Bool) {
    enabled = on
    defaults.set(on, forKey: Self.enabledKey)
    if on { activate() } else { HeliosMouseTap.shared.stop(); state = .off }
  }

  /// Asks macOS to show Helios in Privacy & Security › Accessibility.
  func requestPermission() {
    // The key behind kAXTrustedCheckOptionPrompt, spelled out: the C global is not concurrency-safe.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  private func activate() {
    HeliosMouseTap.shared.update(settings)
    state = HeliosMouseTap.shared.start() ? .active : .needsPermission
  }
}
