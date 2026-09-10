import Combine
import Foundation
import UserNotifications

struct HealthIssue: Sendable, Equatable, Identifiable {
  enum Severity: Int, Sendable, Comparable {
    case attention = 1
    case critical = 2
    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  let id: String
  let severity: Severity
  let title: String
  let detail: String
}

enum HealthEvaluator {
  static func evaluate(_ snapshot: TelemetrySnapshot, now: Date = Date()) -> [HealthIssue] {
    var issues: [HealthIssue] = []

    if case .success(let thermals) = TelemetryFormatting.fresh(
      snapshot.thermals, maxAge: 6, now: now),
      case .success(let maximum) = thermals.maximumSoCCelsius
    {
      if maximum >= 95 {
        issues.append(
          HealthIssue(
            id: "soc-critical", severity: .critical, title: "Critical SoC temperature",
            detail: String(
              format: "Max SoC %.1f°C — emergency cooling floor is active at this boundary.",
              maximum)))
      } else if maximum >= 90 {
        issues.append(
          HealthIssue(
            id: "soc-hot", severity: .attention, title: "High SoC temperature",
            detail: String(format: "Max SoC %.1f°C", maximum)))
      }
    }

    if case .success(let system) = TelemetryFormatting.fresh(snapshot.system, maxAge: 30, now: now)
    {
      switch system.thermalState {
      case .critical:
        issues.append(
          HealthIssue(
            id: "thermal-state-critical", severity: .critical,
            title: "macOS thermal state is Critical",
            detail: "The system reports critical thermal pressure."))
      case .serious:
        issues.append(
          HealthIssue(
            id: "thermal-state-serious", severity: .attention,
            title: "macOS thermal state is Serious",
            detail: "The system reports elevated thermal pressure."))
      default: break
      }
    }

    if case .success(let memory) = TelemetryFormatting.fresh(snapshot.memory, maxAge: 5, now: now),
      case .success(let pressure) = memory.pressure
    {
      switch pressure {
      case .critical:
        issues.append(
          HealthIssue(
            id: "memory-critical", severity: .critical, title: "Critical memory pressure",
            detail: "macOS reports critical memory pressure."))
      case .warning:
        issues.append(
          HealthIssue(
            id: "memory-warning", severity: .attention, title: "Elevated memory pressure",
            detail: "macOS reports warning-level memory pressure."))
      case .normal: break
      }
    }

    if case .success(let battery) = TelemetryFormatting.fresh(
      snapshot.battery, maxAge: 20, now: now)
    {
      if case .success(let health) = battery.healthPercent {
        if health < 70 {
          issues.append(
            HealthIssue(
              id: "battery-health-critical", severity: .critical,
              title: "Battery health is very low",
              detail: String(format: "Full-charge capacity is %.1f%% of design capacity.", health)))
        } else if health < 80 {
          issues.append(
            HealthIssue(
              id: "battery-health-low", severity: .attention, title: "Battery health is reduced",
              detail: String(format: "Full-charge capacity is %.1f%% of design capacity.", health)))
        }
      }
      if case .success(let temperature) = battery.temperatureCelsius {
        if temperature >= 50 {
          issues.append(
            HealthIssue(
              id: "battery-temp-critical", severity: .critical,
              title: "Battery temperature is critical",
              detail: String(format: "Battery %.1f°C", temperature)))
        } else if temperature >= 45 {
          issues.append(
            HealthIssue(
              id: "battery-temp-hot", severity: .attention, title: "Battery temperature is high",
              detail: String(format: "Battery %.1f°C", temperature)))
        }
      }
    }

    if case .success(let storage) = TelemetryFormatting.fresh(
      snapshot.storage, maxAge: 10, now: now),
      case .success(let smart) = storage.smartHealth
    {
      switch smart.state {
      case .critical:
        issues.append(
          HealthIssue(
            id: "ssd-smart-critical", severity: .critical, title: "SSD SMART is critical",
            detail: "NVMe SMART reports a critical condition."))
      case .attention:
        issues.append(
          HealthIssue(
            id: "ssd-smart-attention", severity: .attention, title: "SSD SMART needs attention",
            detail: "NVMe SMART health is outside the normal range."))
      case .verified: break
      }
      if smart.mediaErrors.approximateValue > 0 {
        issues.append(
          HealthIssue(
            id: "ssd-media-errors", severity: .critical, title: "SSD media errors detected",
            detail: "NVMe SMART reports one or more media/data-integrity errors."))
      }
      if let temperature = smart.temperatureCelsius {
        if temperature >= 80 {
          issues.append(
            HealthIssue(
              id: "ssd-temp-critical", severity: .critical, title: "SSD temperature is critical",
              detail: String(format: "SSD %.1f°C", temperature)))
        } else if temperature >= 70 {
          issues.append(
            HealthIssue(
              id: "ssd-temp-hot", severity: .attention, title: "SSD temperature is high",
              detail: String(format: "SSD %.1f°C", temperature)))
        }
      }
    }

    return issues.sorted { lhs, rhs in
      if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
      return lhs.title < rhs.title
    }
  }
}

struct HealthEventRecord: Codable, Sendable, Equatable, Identifiable {
  enum Change: String, Codable, Sendable, Hashable {
    case activated
    case resolved
    case notified
  }

  let capturedAt: Date
  let change: Change
  let issueID: String
  let severity: Int
  let title: String
  let detail: String

  var id: String { "\(capturedAt.timeIntervalSince1970)-\(change.rawValue)-\(issueID)" }
}

enum HealthEventEngine {
  static let retention: TimeInterval = 7 * 24 * 60 * 60
  static let maximumRecords = 1_000

  static func sanitized(_ records: [HealthEventRecord], now: Date) -> [HealthEventRecord] {
    let cutoff = now.addingTimeInterval(-retention)
    var result: [HealthEventRecord] = []
    result.reserveCapacity(min(records.count, maximumRecords))
    for record in records
    where record.capturedAt >= cutoff && record.capturedAt <= now.addingTimeInterval(300) {
      if let last = result.last, record.capturedAt < last.capturedAt { continue }
      result.append(record)
    }
    if result.count > maximumRecords { result.removeFirst(result.count - maximumRecords) }
    return result
  }

  static func decodeLines(_ data: Data, decoder: JSONDecoder = JSONDecoder()) -> [HealthEventRecord]
  {
    data.split(separator: 0x0A).compactMap { line in
      guard !line.isEmpty else { return nil }
      return try? decoder.decode(HealthEventRecord.self, from: Data(line))
    }
  }

  static func transitionRecords(previous: [String: HealthIssue], current: [HealthIssue], now: Date)
    -> (records: [HealthEventRecord], newlyActive: [HealthIssue])
  {
    let currentIDs = Set(current.map(\.id))
    let previousIDs = Set(previous.keys)
    let newlyActive = current.filter { !previousIDs.contains($0.id) }
    let resolved = previousIDs.subtracting(currentIDs).compactMap { previous[$0] }
    let records =
      newlyActive.map {
        HealthEventRecord(
          capturedAt: now, change: .activated, issueID: $0.id, severity: $0.severity.rawValue,
          title: $0.title, detail: $0.detail)
      }
      + resolved.map {
        HealthEventRecord(
          capturedAt: now, change: .resolved, issueID: $0.id, severity: $0.severity.rawValue,
          title: $0.title, detail: $0.detail)
      }
    return (records, newlyActive)
  }
}

enum HealthNotificationPolicy {
  /// Attention-level conditions must be sustained before bothering the user.
  /// Critical conditions remain immediate, but repeat delivery of the same
  /// condition is still bounded if a sensor hovers around a threshold.
  static let attentionMinimumActiveDuration: TimeInterval = 15
  static let attentionRepeatCooldown: TimeInterval = 30 * 60
  static let criticalRepeatCooldown: TimeInterval = 10 * 60

  static func minimumActiveDuration(for issue: HealthIssue) -> TimeInterval {
    issue.severity == .critical ? 0 : attentionMinimumActiveDuration
  }

  static func repeatCooldown(for issue: HealthIssue) -> TimeInterval {
    issue.severity == .critical ? criticalRepeatCooldown : attentionRepeatCooldown
  }

  static func shouldNotify(
    issue: HealthIssue,
    activeSince: Date,
    lastNotifiedAt: Date?,
    now: Date
  ) -> Bool {
    let activeDuration = now.timeIntervalSince(activeSince)
    guard activeDuration.isFinite,
      activeDuration >= minimumActiveDuration(for: issue)
    else { return false }
    guard let lastNotifiedAt else { return true }
    let elapsed = now.timeIntervalSince(lastNotifiedAt)
    // A backwards wall-clock jump must not bypass the cooldown and create a
    // duplicate notification storm. Wait until the timestamp is sane again.
    return elapsed.isFinite && elapsed >= repeatCooldown(for: issue)
  }

  static func notificationDetail(
    for issue: HealthIssue, activeSince: Date, now: Date
  ) -> String {
    let activeSeconds = max(0, now.timeIntervalSince(activeSince))
    let cooldownMinutes = Int((repeatCooldown(for: issue) / 60).rounded())
    if minimumActiveDuration(for: issue) > 0 {
      return
        "\(issue.detail) · Notification sent after \(Int(activeSeconds.rounded())) s continuously active. Repeats for this condition are suppressed for \(cooldownMinutes) min."
    }
    return
      "\(issue.detail) · Critical notification sent immediately. Repeats for this condition are suppressed for \(cooldownMinutes) min."
  }
}

actor HealthEventStore {
  private let url: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var records: [HealthEventRecord]?

  init(url: URL = HealthEventStore.defaultURL()) {
    self.url = url
    encoder = JSONEncoder()
    decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    decoder.dateDecodingStrategy = .millisecondsSince1970
  }

  static func defaultURL() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Helios", isDirectory: true).appendingPathComponent(
      "health-events-v1.ndjson")
  }

  func current(now: Date = Date()) -> [HealthEventRecord] { loadIfNeeded(now: now) }

  func append(_ newRecords: [HealthEventRecord], now: Date = Date()) -> [HealthEventRecord] {
    guard !newRecords.isEmpty else { return loadIfNeeded(now: now) }
    var loaded = loadIfNeeded(now: now)
    loaded.append(contentsOf: newRecords)
    loaded = HealthEventEngine.sanitized(loaded, now: now)
    records = loaded
    rewrite(loaded)
    return loaded
  }

  private func loadIfNeeded(now: Date) -> [HealthEventRecord] {
    if let records { return records }
    let data = (try? Data(contentsOf: url)) ?? Data()
    let decoded = HealthEventEngine.decodeLines(data, decoder: decoder)
    let clean = HealthEventEngine.sanitized(decoded, now: now)
    records = clean
    let rawCount = data.split(separator: 0x0A).reduce(into: 0) { count, line in
      if !line.isEmpty { count += 1 }
    }
    if clean.count != decoded.count || decoded.count != rawCount { rewrite(clean) }
    return clean
  }

  private func rewrite(_ records: [HealthEventRecord]) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var data = Data()
      for record in records {
        data.append(try encoder.encode(record))
        data.append(0x0A)
      }
      try data.write(to: url, options: .atomic)
    } catch {
      // Health event history is observability-only. Alert evaluation remains live.
    }
  }
}

@MainActor
final class HealthAlertCenter: ObservableObject {
  enum Authorization: String {
    case unknown = "Unknown"
    case notDetermined = "Off"
    case denied = "Denied"
    case enabled = "Enabled"
  }

  @Published private(set) var issues: [HealthIssue] = []
  @Published private(set) var events: [HealthEventRecord] = []
  @Published private(set) var authorization: Authorization = .unknown
  private var issueByID: [String: HealthIssue] = [:]
  private var hasEvaluationBaseline = false
  private var activeSinceByID: [String: Date] = [:]
  private var notifiedThisActivation = Set<String>()
  private var lastNotifiedAtByID: [String: Date] = [:]
  private let center: UNUserNotificationCenter?
  private let eventStore: HealthEventStore?

  /// Presentation/unit-test executables are not application bundles. Constructing
  /// UNUserNotificationCenter.current() from those processes raises an Objective-C
  /// exception before Swift can handle it. Runtime Helios keeps the default live
  /// services; deterministic fixtures opt out and still exercise health evaluation.
  init(runtimeServicesEnabled: Bool = true) {
    guard runtimeServicesEnabled else {
      center = nil
      eventStore = nil
      return
    }

    let center = UNUserNotificationCenter.current()
    let eventStore = HealthEventStore()
    self.center = center
    self.eventStore = eventStore
    Task { @MainActor [weak self, eventStore] in
      let history = await eventStore.current()
      guard let self else { return }
      self.events = history
      self.lastNotifiedAtByID = Dictionary(
        history.filter { $0.change == .notified }.map { ($0.issueID, $0.capturedAt) },
        uniquingKeysWith: { previous, newer in max(previous, newer) })
      await self.refreshAuthorization()
    }
  }

  func accept(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    let next = HealthEvaluator.evaluate(snapshot, now: now)
    let previousIssues = issueByID
    issues = next
    issueByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })

    // Establish the first live sample as a baseline. Restarting Helios while a
    // condition is already active must not replay a notification. Treat those
    // baseline issues as already handled for that activation; they can notify
    // only after a real resolve -> re-activate transition observed while running.
    guard hasEvaluationBaseline else {
      hasEvaluationBaseline = true
      activeSinceByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, now) })
      notifiedThisActivation = Set(next.map(\.id))
      return
    }

    let transition = HealthEventEngine.transitionRecords(
      previous: previousIssues, current: next, now: now)
    if !transition.records.isEmpty { appendEventRecords(transition.records, now: now) }

    let currentIDs = Set(next.map(\.id))
    let previousIDs = Set(previousIssues.keys)
    for resolvedID in previousIDs.subtracting(currentIDs) {
      activeSinceByID.removeValue(forKey: resolvedID)
      notifiedThisActivation.remove(resolvedID)
    }
    for activated in transition.newlyActive {
      activeSinceByID[activated.id] = now
      notifiedThisActivation.remove(activated.id)
    }
    // Defensive recovery for an issue that somehow entered without a transition.
    for issue in next where activeSinceByID[issue.id] == nil {
      activeSinceByID[issue.id] = now
    }

    guard authorization == .enabled else { return }
    for issue in next {
      guard !notifiedThisActivation.contains(issue.id),
        let activeSince = activeSinceByID[issue.id]
      else { continue }

      let minimumActive = HealthNotificationPolicy.minimumActiveDuration(for: issue)
      let activeDuration = now.timeIntervalSince(activeSince)
      guard activeDuration.isFinite, activeDuration >= minimumActive else { continue }

      let lastNotified = lastNotifiedAtByID[issue.id]
      guard
        HealthNotificationPolicy.shouldNotify(
          issue: issue, activeSince: activeSince, lastNotifiedAt: lastNotified, now: now)
      else {
        // A reactivation inside the cooldown is intentionally silent for the
        // whole activation. It does not suddenly notify just because the cooldown
        // expires while the condition has remained continuously active.
        notifiedThisActivation.insert(issue.id)
        continue
      }

      schedule(issue)
      notifiedThisActivation.insert(issue.id)
      lastNotifiedAtByID[issue.id] = now
      let record = HealthEventRecord(
        capturedAt: now, change: .notified, issueID: issue.id,
        severity: issue.severity.rawValue, title: issue.title,
        detail: HealthNotificationPolicy.notificationDetail(
          for: issue, activeSince: activeSince, now: now))
      appendEventRecords([record], now: now)
    }
  }

  private func appendEventRecords(_ records: [HealthEventRecord], now: Date) {
    guard !records.isEmpty else { return }
    if let eventStore {
      Task { @MainActor [weak self, eventStore] in
        let updated = await eventStore.append(records, now: now)
        self?.events = updated
      }
    } else {
      // Fixture mode is intentionally side-effect free but keeps the observable
      // transition/notification history meaningful for deterministic rendering.
      events = HealthEventEngine.sanitized(events + records, now: now)
    }
  }

  func requestAuthorization() {
    guard center != nil else { return }
    Task { @MainActor [weak self] in
      guard let self, let center = self.center else { return }
      do {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
      } catch {
        // The system remains the source of truth; refresh below maps denial/failure.
      }
      await refreshAuthorization()
    }
  }

  func refreshAuthorization() async {
    guard let center else {
      authorization = .unknown
      return
    }
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: authorization = .enabled
    case .denied: authorization = .denied
    case .notDetermined: authorization = .notDetermined
    @unknown default: authorization = .unknown
    }
  }

  private func schedule(_ issue: HealthIssue) {
    guard center != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = issue.title
    content.body = issue.detail
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "helios-health-\(issue.id)", content: content, trigger: nil)
    Task { @MainActor [weak self] in
      guard let center = self?.center else { return }
      try? await center.add(request)
    }
  }
}
