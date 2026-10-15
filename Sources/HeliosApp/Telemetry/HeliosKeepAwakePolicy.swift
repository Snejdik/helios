import Foundation

/// Keep Awake (PLAN_0_3_0 M6.1): what the user asked for and when Helios lets go.
/// Pure; the controller only turns `decision` into an IOPMAssertion. No helper, no root.
struct HeliosKeepAwakeRequest: Codable, Equatable, Sendable {
  enum Until: Codable, Equatable, Sendable {
    /// Ends at a fixed time.
    case time(Date)
    /// Ends when this app (bundle identifier) is no longer running.
    case appQuits(bundleID: String, name: String)
    /// Ends when the Mac leaves the power adapter.
    case onPowerAdapter
    /// Until the user stops it (still subject to the safety stops).
    case stopped
  }

  var until: Until
  /// Also keep the display on (otherwise only the system stays awake).
  var keepDisplayOn: Bool
  var startedAt: Date

  /// Common choices for the menu and the palette.
  static func forDuration(_ seconds: TimeInterval, from now: Date, display: Bool = false) -> Self {
    Self(until: .time(now.addingTimeInterval(seconds)), keepDisplayOn: display, startedAt: now)
  }

  var summary: String {
    let what = keepDisplayOn ? "Mac and display" : "Mac"
    switch until {
    case .time(let end): return "Keeping the \(what) awake until \(end.formatted(date: .omitted, time: .shortened))"
    case .appQuits(_, let name): return "Keeping the \(what) awake while \(name) runs"
    case .onPowerAdapter: return "Keeping the \(what) awake while on the power adapter"
    case .stopped: return "Keeping the \(what) awake until you stop it"
    }
  }
}

/// What the policy needs to know about the Mac right now.
struct HeliosKeepAwakeConditions: Equatable, Sendable {
  var now: Date
  var onBattery: Bool?
  var chargePercent: Double?
  var thermalState: SystemThermalState?
  /// Bundle identifiers of running apps (only consulted for `.appQuits`).
  var runningBundleIDs: Set<String> = []
}

enum HeliosKeepAwakePolicy {
  /// Below this charge on battery Keep Awake ends, so it never drains the Mac flat.
  static let minimumBatteryPercent = 10.0

  enum Decision: Equatable, Sendable {
    case hold
    /// Stop, with the reason shown to the user.
    case release(String)
  }

  static func decision(_ request: HeliosKeepAwakeRequest, _ c: HeliosKeepAwakeConditions) -> Decision {
    // Safety stops first: they apply to every request.
    if c.onBattery == true, let charge = c.chargePercent, charge <= minimumBatteryPercent {
      return .release("Keep Awake stopped because the battery is at \(Int(charge.rounded())) %.")
    }
    if c.thermalState == .critical {
      return .release("Keep Awake stopped because the Mac is critically hot.")
    }
    switch request.until {
    case .time(let end):
      if c.now >= end { return .release("Keep Awake ended at the time you chose.") }
    case .appQuits(let bundleID, let name):
      if !c.runningBundleIDs.contains(bundleID) { return .release("Keep Awake ended because \(name) quit.") }
    case .onPowerAdapter:
      if c.onBattery == true { return .release("Keep Awake ended because the Mac left the power adapter.") }
    case .stopped:
      break
    }
    return .hold
  }

  /// Seconds until a `.time` request ends; nil otherwise.
  static func remaining(_ request: HeliosKeepAwakeRequest, now: Date) -> TimeInterval? {
    guard case .time(let end) = request.until else { return nil }
    return max(0, end.timeIntervalSince(now))
  }

  static let closedLidNote = "With the lid closed a MacBook sleeps unless an external display, power and a keyboard or mouse are connected; Helios cannot change that without administrator rights."
}
