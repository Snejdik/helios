import Foundation

// Tools that save hands (PLAN_0_3_0 M6): the `helios://` URL scheme, "if → then" rules
// and "tell me when it's done" watchers. Pure parts only; the app executes the resulting
// actions through `HeliosActionRegistry` and fan changes only through FanControlModel.

// MARK: - URL scheme

/// Commands a `helios://` link may carry. Any app or web page can open a URL, so only
/// harmless actions exist here: nothing takes the fans from macOS (returning them to
/// System is the only fan command), nothing quits apps, nothing sends data.
enum HeliosURLCommand: Equatable, Sendable {
  case openPage(String)
  case ask(HeliosLens)
  case keepAwake(minutes: Int)
  case stopKeepAwake
  case networkCheck
  case fansToSystem

  static let pages: Set<String> = [
    "overview", "cpu", "gpu", "memory", "thermals", "battery", "energy", "storage", "network", "hardware",
    "activity", "history", "diagnostics", "longevity",
  ]

  /// helios://open/thermals · helios://why/slowMac · helios://keep-awake?minutes=30 ·
  /// helios://keep-awake/stop · helios://network-check · helios://fans/system
  static func parse(_ url: URL) -> Self? {
    guard url.scheme?.lowercased() == "helios", let host = url.host?.lowercased() else { return nil }
    let parts = url.path.split(separator: "/").map { String($0) }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    switch host {
    case "open":
      guard parts.count == 1, pages.contains(parts[0].lowercased()) else { return nil }
      return .openPage(parts[0].lowercased())
    case "why":
      guard parts.count == 1, let lens = HeliosLens(rawValue: parts[0]) else { return nil }
      return .ask(lens)
    case "keep-awake":
      if parts == ["stop"] { return .stopKeepAwake }
      guard parts.isEmpty else { return nil }
      let minutes = query.first { $0.name == "minutes" }?.value.flatMap(Int.init) ?? 60
      guard (1...1_440).contains(minutes) else { return nil }
      return .keepAwake(minutes: minutes)
    case "network-check":
      return parts.isEmpty ? .networkCheck : nil
    case "fans":
      return parts == ["system"] ? .fansToSystem : nil
    default:
      return nil
    }
  }
}

// MARK: - Rules

/// "If → then" rules. Versioned, bounded, edge-triggered, rate-limited.
struct HeliosRule: Codable, Equatable, Sendable, Identifiable {
  enum Trigger: Codable, Equatable, Sendable {
    case temperatureAbove(Double)
    case batteryBelow(Double)
    case powerSourceIs(battery: Bool)
    case appRunning(bundleID: String, name: String)
    case timeOfDay(hour: Int, minute: Int)
    case cpuAbove(Double)

    var title: String {
      switch self {
      case .temperatureAbove(let c): "Hottest sensor above \(Int(c)) °C"
      case .batteryBelow(let p): "Battery below \(Int(p)) %"
      case .powerSourceIs(let battery): battery ? "Mac switches to battery" : "Mac is plugged in"
      case .appRunning(_, let name): "\(name) is running"
      case .timeOfDay(let h, let m): String(format: "At %02d:%02d", h, m)
      case .cpuAbove(let p): "CPU busier than \(Int(p)) %"
      }
    }
  }

  /// Only this safe set (PLAN §3 M6.3), no scripts. A rule can return the fans to System or
  /// arm Auto; both go through FanControlModel.setMode and its gates, so a rule can never do
  /// more with the fans than the Thermals page can. Links (`HeliosURLCommand`) only return them.
  enum Action: Codable, Equatable, Sendable {
    case notify(String)
    case keepAwake(minutes: Int)
    case stopKeepAwake
    case fansToSystem
    /// Arms Auto through FanControlModel.setMode; its gates (helper, consent, entry test,
    /// confirmed sensor map) decide whether that is possible at all.
    case fansAuto
    case runShortcut(String)

    var title: String {
      switch self {
      case .notify(let text): "Notify: \(text)"
      case .keepAwake(let minutes): "Keep awake for \(minutes) min"
      case .stopKeepAwake: "Stop Keep Awake"
      case .fansToSystem: "Return the fans to macOS"
      case .fansAuto: "Turn on Auto fan control"
      case .runShortcut(let name): "Run Shortcut “\(name)”"
      }
    }
  }

  var id: UUID = UUID()
  var enabled = true
  var trigger: Trigger
  var action: Action

  static let maximumCount = 20
  static let maximumShortcutNameLength = 100
}

struct HeliosRuleInputs: Equatable, Sendable {
  var now: Date
  var hottestCelsius: Double?
  var batteryPercent: Double?
  var onBattery: Bool?
  var runningBundleIDs: Set<String> = []
  var cpuBusyPercent: Double?
  var calendar: Calendar = .current
}

/// Edge-triggered evaluation: a rule fires when its condition becomes true, not while it
/// stays true. One firing per rule per minimum interval, and a global cap per hour stops
/// any loop (for example a Shortcut that changes what the rule watches).
struct HeliosRuleEngine: Sendable {
  static let schemaVersion = 1
  static let minimumIntervalSeconds: TimeInterval = 60
  static let maximumFiringsPerHour = 30

  private(set) var lastState: [UUID: Bool] = [:]
  private(set) var lastFired: [UUID: Date] = [:]
  private(set) var recentFirings: [Date] = []

  static func condition(_ trigger: HeliosRule.Trigger, _ inputs: HeliosRuleInputs) -> Bool? {
    switch trigger {
    case .temperatureAbove(let limit): return inputs.hottestCelsius.map { $0 > limit }
    case .batteryBelow(let limit):
      guard inputs.onBattery == true else { return inputs.onBattery == nil ? nil : false }
      return inputs.batteryPercent.map { $0 < limit }
    case .powerSourceIs(let battery): return inputs.onBattery.map { $0 == battery }
    case .appRunning(let bundleID, _): return inputs.runningBundleIDs.contains(bundleID)
    case .timeOfDay(let hour, let minute):
      let parts = inputs.calendar.dateComponents([.hour, .minute], from: inputs.now)
      return parts.hour == hour && parts.minute == minute
    case .cpuAbove(let limit): return inputs.cpuBusyPercent.map { $0 > limit }
    }
  }

  /// Rules that fire now. Unknown inputs (nil) never fire and do not reset the edge.
  mutating func evaluate(_ rules: [HeliosRule], _ inputs: HeliosRuleInputs) -> [HeliosRule] {
    recentFirings.removeAll { inputs.now.timeIntervalSince($0) > 3_600 }
    var fired: [HeliosRule] = []
    for rule in rules.prefix(HeliosRule.maximumCount) where rule.enabled {
      guard let now = Self.condition(rule.trigger, inputs) else { continue }
      let was = lastState[rule.id] ?? now // the first observation is never an edge
      lastState[rule.id] = now
      guard now, !was else { continue }
      if let last = lastFired[rule.id], inputs.now.timeIntervalSince(last) < Self.minimumIntervalSeconds { continue }
      guard recentFirings.count < Self.maximumFiringsPerHour else { continue }
      lastFired[rule.id] = inputs.now
      recentFirings.append(inputs.now)
      fired.append(rule)
    }
    return fired
  }
}

enum HeliosRuleStore {
  static let defaultsKey = "HeliosRules.v1"

  private struct Stored: Codable {
    let version: Int
    let rules: [HeliosRule]
  }

  static func load(_ defaults: UserDefaults = .standard) -> [HeliosRule] {
    guard let data = defaults.data(forKey: defaultsKey), data.count <= 64 * 1024,
      let stored = try? JSONDecoder().decode(Stored.self, from: data),
      stored.version == HeliosRuleEngine.schemaVersion
    else { return [] }
    return Array(stored.rules.prefix(HeliosRule.maximumCount)).filter(valid)
  }

  static func save(_ rules: [HeliosRule], _ defaults: UserDefaults = .standard) {
    let stored = Stored(version: HeliosRuleEngine.schemaVersion,
                        rules: Array(rules.prefix(HeliosRule.maximumCount)).filter(valid))
    if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: defaultsKey) }
  }

  static func valid(_ rule: HeliosRule) -> Bool {
    switch rule.trigger {
    case .temperatureAbove(let c): guard (30...110).contains(c) else { return false }
    case .batteryBelow(let p), .cpuAbove(let p): guard (1...99).contains(p) else { return false }
    case .timeOfDay(let h, let m): guard (0...23).contains(h), (0...59).contains(m) else { return false }
    case .appRunning(let id, let name): guard !id.isEmpty, id.count <= 255, name.count <= 100 else { return false }
    case .powerSourceIs: break
    }
    switch rule.action {
    case .notify(let text): return !text.isEmpty && text.count <= 200
    case .keepAwake(let minutes): return (1...1_440).contains(minutes)
    case .runShortcut(let name): return !name.isEmpty && name.count <= HeliosRule.maximumShortcutNameLength
    case .stopKeepAwake, .fansToSystem, .fansAuto: return true
    }
  }
}

// MARK: - "Tell me when it's done"

struct HeliosDoneWatch: Equatable, Sendable, Identifiable {
  enum Kind: Equatable, Sendable {
    /// The process exits.
    case processExits(pid: Int32, name: String)
    /// Total CPU stays below 20 % for 30 s.
    case cpuCalms
    /// Download drops below 50 KB/s for 20 s after having been above 1 MB/s.
    case downloadFinishes
  }

  var id = UUID()
  let kind: Kind
  let startedAt: Date
  var quietSince: Date? = nil
  var sawTraffic = false

  var title: String {
    switch kind {
    case .processExits(_, let name): "When \(name) finishes"
    case .cpuCalms: "When the Mac calms down"
    case .downloadFinishes: "When the download finishes"
    }
  }
}

struct HeliosDoneInputs: Equatable, Sendable {
  var now: Date
  var runningPIDs: Set<Int32>?
  var cpuBusyPercent: Double?
  var downloadBytesPerSecond: Double?
}

enum HeliosDoneWatcher {
  static let cpuQuietPercent = 20.0
  static let cpuQuietSeconds: TimeInterval = 30
  static let downloadQuietBytes = 50_000.0
  static let downloadBusyBytes = 1_000_000.0
  static let downloadQuietSeconds: TimeInterval = 20
  /// Watches end by themselves after this long.
  static let maximumSeconds: TimeInterval = 24 * 3_600

  /// Updated watch, and the notification text when it completed (or expired).
  static func step(_ watch: HeliosDoneWatch, _ inputs: HeliosDoneInputs) -> (HeliosDoneWatch, String?) {
    var watch = watch
    if inputs.now.timeIntervalSince(watch.startedAt) > maximumSeconds {
      return (watch, "Helios stopped waiting (\(watch.title.lowercased())) after a day.")
    }
    switch watch.kind {
    case .processExits(let pid, let name):
      guard let running = inputs.runningPIDs else { return (watch, nil) }
      return (watch, running.contains(pid) ? nil : "\(name) has finished.")
    case .cpuCalms:
      guard let busy = inputs.cpuBusyPercent else { return (watch, nil) }
      if busy < cpuQuietPercent {
        watch.quietSince = watch.quietSince ?? inputs.now
        if inputs.now.timeIntervalSince(watch.quietSince!) >= cpuQuietSeconds { return (watch, "Your Mac has calmed down.") }
      } else {
        watch.quietSince = nil
      }
      return (watch, nil)
    case .downloadFinishes:
      guard let rate = inputs.downloadBytesPerSecond else { return (watch, nil) }
      if rate > downloadBusyBytes { watch.sawTraffic = true; watch.quietSince = nil; return (watch, nil) }
      guard watch.sawTraffic, rate < downloadQuietBytes else { watch.quietSince = nil; return (watch, nil) }
      watch.quietSince = watch.quietSince ?? inputs.now
      return (watch, inputs.now.timeIntervalSince(watch.quietSince!) >= downloadQuietSeconds ? "The download has finished." : nil)
    }
  }
}

// MARK: - Command-line status

/// The summary `helios status` prints. Plain numbers and words; no app names, paths,
/// network addresses or identifiers, so the file is safe to paste into a forum post.
enum HeliosStatusSummary {
  static let version = 1

  static func make(_ snapshot: TelemetrySnapshot, now: Date, keepAwake: Bool) -> [String: Any] {
    var result: [String: Any] = [
      "version": version,
      "generated_at": ISO8601DateFormatter().string(from: now),
      "keep_awake": keepAwake,
    ]
    if case .success(let cpu) = TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now) {
      result["cpu_percent"] = Int((100 - cpu.idlePercent).rounded())
    }
    if case .success(let memory) = TelemetryFormatting.fresh(snapshot.memory, maxAge: 5, now: now),
      case .success(let pressure) = memory.pressure
    {
      result["memory_pressure"] = pressure.rawValue.lowercased()
    }
    if case .success(let thermals) = TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now),
      case .success(let hottest) = thermals.maximumSoCCelsius
    {
      result["hottest_celsius"] = (hottest * 10).rounded() / 10
      if let status = thermals.maximumSoCMapStatus { result["sensor_map"] = status.rawValue }
    }
    if case .success(let system) = TelemetryFormatting.fresh(snapshot.system, maxAge: 30, now: now) {
      result["thermal_pressure"] = system.thermalState.rawValue.lowercased()
      result["low_power_mode"] = system.lowPowerModeEnabled
    }
    if case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 30, now: now) {
      var entry: [String: Any] = [:]
      if case .success(let percent) = battery.stateOfChargePercent { entry["percent"] = Int(percent.rounded()) }
      if case .success(let source) = battery.powerSource { entry["on_battery"] = source == .battery }
      if case .success(let health) = battery.healthPercent { entry["health_percent"] = Int(health.rounded()) }
      if !entry.isEmpty { result["battery"] = entry }
    }
    if case .success(let fans) = TelemetryFormatting.fresh(snapshot.fans, maxAge: 6, now: now) {
      result["fan_rpm"] = fans.fans.compactMap { try? $0.actualRPM.get() }.map { Int($0.rounded()) }
    }
    if case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 30, now: now),
      case .success(let root) = storage.rootVolume
    {
      result["disk_free_bytes"] = root.freeBytes
    }
    return result
  }
}
