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

extension HealthAlertRule {
  func hasCurrentObservation(in snapshot: TelemetrySnapshot, now: Date) -> Bool {
    if defaultThreshold != nil { return numericValue(in: snapshot, now: now) != nil }
    switch self {
    case .thermalSerious, .thermalCritical:
      if case .success = TelemetryFormatting.fresh(snapshot.system, maxAge: 30, now: now) { return true }
    case .memoryWarning, .memoryCritical:
      if case .success(let memory) = TelemetryFormatting.fresh(snapshot.memory, maxAge: 5, now: now),
        case .success = memory.pressure { return true }
    case .smartAttention, .smartCritical, .mediaErrors:
      if case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 10, now: now),
        case .success = storage.smartHealth { return true }
    default: break
    }
    return false
  }

  func numericValue(in snapshot: TelemetrySnapshot, now: Date) -> Double? {
    let result: MetricResult<Double>
    switch self {
    case .socHot, .socCritical:
      result = TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now)
        .flatMap(\.maximumSoCCelsius)
    case .batteryHealthLow, .batteryHealthCritical:
      result = TelemetryFormatting.fresh(snapshot.battery, maxAge: 20, now: now)
        .flatMap(\.healthPercent)
    case .batteryTempHot, .batteryTempCritical:
      result = TelemetryFormatting.fresh(snapshot.battery, maxAge: 20, now: now)
        .flatMap(\.temperatureCelsius)
    case .ssdTempHot, .ssdTempCritical:
      guard case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 10, now: now),
        case .success(let smart) = storage.smartHealth else { return nil }
      return smart.temperatureCelsius.flatMap { $0.isFinite ? $0 : nil }
    default: return nil
    }
    guard case .success(let value) = result, value.isFinite else { return nil }
    return value
  }
}

enum HealthEvaluator {
  static func evaluate(_ snapshot: TelemetrySnapshot, now: Date = Date(),
    configuration: HealthAlertConfiguration = .defaults,
    previouslyActive: Set<String> = []) -> [HealthIssue] {
    var issues: [HealthIssue] = []

    if case .success(let thermals) = TelemetryFormatting.fresh(
      snapshot.thermals, maxAge: 6, now: now),
      case .success(let maximum) = thermals.maximumSoCCelsius
    {
      if configuration.crossed(.socCritical, value: maximum, previouslyActive: previouslyActive) {
        issues.append(
          HealthIssue(
            id: "soc-critical", severity: .critical, title: "Critical SoC temperature",
            detail:
              "Max SoC \(TelemetryFormatting.temperature(maximum, decimals: 1)) — informational alert; fan safety is configured separately."))
      } else if configuration.crossed(.socHot, value: maximum, previouslyActive: previouslyActive) {
        issues.append(
          HealthIssue(
            id: "soc-hot", severity: .attention, title: "High SoC temperature",
            detail: "Max SoC \(TelemetryFormatting.temperature(maximum, decimals: 1))"))
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
        if configuration.crossed(.batteryHealthCritical, value: health, previouslyActive: previouslyActive) {
          issues.append(
            HealthIssue(
              id: "battery-health-critical", severity: .critical,
              title: "Battery health is very low",
              detail: String(format: "Full-charge capacity is %.1f%% of design capacity.", health)))
        } else if configuration.crossed(.batteryHealthLow, value: health, previouslyActive: previouslyActive) {
          issues.append(
            HealthIssue(
              id: "battery-health-low", severity: .attention, title: "Battery health is reduced",
              detail: String(format: "Full-charge capacity is %.1f%% of design capacity.", health)))
        }
      }
      if case .success(let temperature) = battery.temperatureCelsius {
        if configuration.crossed(.batteryTempCritical, value: temperature, previouslyActive: previouslyActive) {
          issues.append(
            HealthIssue(
              id: "battery-temp-critical", severity: .critical,
              title: "Battery temperature is critical",
              detail: "Battery \(TelemetryFormatting.temperature(temperature, decimals: 1))"))
        } else if configuration.crossed(.batteryTempHot, value: temperature, previouslyActive: previouslyActive) {
          issues.append(
            HealthIssue(
              id: "battery-temp-hot", severity: .attention, title: "Battery temperature is high",
              detail: "Battery \(TelemetryFormatting.temperature(temperature, decimals: 1))"))
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
        if configuration.crossed(.ssdTempCritical, value: temperature, previouslyActive: previouslyActive) {
          issues.append(
            HealthIssue(
              id: "ssd-temp-critical", severity: .critical, title: "SSD temperature is critical",
              detail: "SSD \(TelemetryFormatting.temperature(temperature, decimals: 1))"))
        } else if configuration.crossed(.ssdTempHot, value: temperature, previouslyActive: previouslyActive) {
          issues.append(
            HealthIssue(
              id: "ssd-temp-hot", severity: .attention, title: "SSD temperature is high",
              detail: "SSD \(TelemetryFormatting.temperature(temperature, decimals: 1))"))
        }
      }
    }

    return issues.filter { issue in
      HealthAlertRule(rawValue: issue.id).map { configuration[$0].enabled } ?? true
    }.sorted { lhs, rhs in
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

  /// An immediate critical escalation remains independent of a prior warning.
  /// A downgrade inside the critical cooldown must not create a second warning
  /// notification for the same ongoing problem (including loaded event history).
  static func criticalCounterpart(ofAttentionID id: String) -> String? {
    switch id {
    case "soc-hot": "soc-critical"
    case "battery-health-low": "battery-health-critical"
    case "battery-temp-hot": "battery-temp-critical"
    case "ssd-temp-hot": "ssd-temp-critical"
    case "thermal-state-serious": "thermal-state-critical"
    case "memory-warning": "memory-critical"
    case "ssd-smart-attention": "ssd-smart-critical"
    default: nil
    }
  }

  static func suppressDowngrade(_ issue: HealthIssue, activeSince: Date,
    lastNotifiedAtByID: [String: Date]) -> Bool {
    guard issue.severity == .attention,
      let criticalID = criticalCounterpart(ofAttentionID: issue.id),
      let notified = lastNotifiedAtByID[criticalID] else { return false }
    let elapsed = activeSince.timeIntervalSince(notified)
    return !elapsed.isFinite || elapsed < criticalRepeatCooldown
  }

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

  static func activationAllowsNotification(
    issue: HealthIssue, activeSince: Date, lastNotifiedAt: Date?
  ) -> Bool {
    guard let lastNotifiedAt else { return true }
    let elapsed = activeSince.timeIntervalSince(lastNotifiedAt)
    return elapsed.isFinite && elapsed >= repeatCooldown(for: issue)
  }

  static func notificationDetail(
    for issue: HealthIssue, activeSince: Date, now: Date
  ) -> String {
    let activeSeconds = max(0, now.timeIntervalSince(activeSince))
    let cooldownMinutes = Int((repeatCooldown(for: issue) / 60).rounded())
    if minimumActiveDuration(for: issue) > 0 {
      return
        "\(issue.detail) · Notification queued after \(Int(activeSeconds.rounded())) s continuously active. Repeats for this condition are suppressed for \(cooldownMinutes) min."
    }
    return
      "\(issue.detail) · Critical notification queued without a sustain delay. Repeats for this condition are suppressed for \(cooldownMinutes) min."
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
    case notDetermined = "Not requested"
    case denied = "Denied"
    case enabled = "Enabled"
  }

  @Published private(set) var issues: [HealthIssue] = []
  @Published private(set) var events: [HealthEventRecord] = []
  @Published private(set) var authorization: Authorization = .unknown
  private var issueByID: [String: HealthIssue] = [:]
  private var hasEvaluationBaseline = false
  private var baselinePendingRules = Set(HealthAlertRule.allCases.map(\.rawValue))
  private var activeSinceByID: [String: Date] = [:]
  // Unlike the sustain baseline, this never moves on a missing measurement.
  private var activationBeganAtByID: [String: Date] = [:]
  private var activationIDByID: [String: UUID] = [:]
  private var notifiedThisActivation = Set<String>()
  private var lastNotifiedAtByID: [String: Date] = [:]
  private let fixtureDelivery: (@MainActor (HealthIssue) async throws -> Void)?
  // Fixture callbacks receive handles without retaining completed tasks in production.
  private let fixtureTaskObserver: (@MainActor (Task<Void, Never>) -> Void)?
  private var stopped = false
  private let configuration: @MainActor () -> HealthAlertConfiguration
  private var lastConfiguration: HealthAlertConfiguration?
  private var lastEvaluationAt: Date?
  private var observationSnapshot: TelemetrySnapshot?
  private var observationReceivedAt: Date?
  private let observationClock: @MainActor () -> Date
  private var deliveryTasks: [String: Task<Void, Never>] = [:]
  private var eventWriteTask: Task<Void, Never>?
  private var pendingEventRecords: [HealthEventRecord] = []
  private var retryAfterByID: [String: Date] = [:]
  private var activationGeneration: UInt64 = 0
  @Published private(set) var deliveryFailed = false
  private var authorizationRequestInFlight = false
  private var authorizationRefreshAt = Date.distantPast
  private var authorizationRefreshInFlight = false
  private var historyLoaded = false
  private let center: UNUserNotificationCenter?
  private let eventStore: HealthEventStore?

  /// Presentation/unit-test executables are not application bundles. Constructing
  /// UNUserNotificationCenter.current() from those processes raises an Objective-C
  /// exception before Swift can handle it. Runtime Helios keeps the default live
  /// services; deterministic fixtures opt out and still exercise health evaluation.
  init(runtimeServicesEnabled: Bool = true,
    configuration: @escaping @MainActor () -> HealthAlertConfiguration = { .defaults },
    fixtureDelivery: (@MainActor (HealthIssue) async throws -> Void)? = nil,
    fixtureHistory: (@MainActor () async -> [HealthEventRecord])? = nil,
    fixtureTaskObserver: (@MainActor (Task<Void, Never>) -> Void)? = nil,
    fixtureObservationClock: (@MainActor () -> Date)? = nil) {
    self.configuration = configuration
    self.fixtureDelivery = runtimeServicesEnabled ? nil : fixtureDelivery
    self.fixtureTaskObserver = runtimeServicesEnabled ? nil : fixtureTaskObserver
    if !runtimeServicesEnabled, let fixtureObservationClock {
      observationClock = fixtureObservationClock
    } else {
      observationClock = { Date() }
    }
    guard runtimeServicesEnabled else {
      center = nil
      eventStore = nil
      historyLoaded = fixtureHistory == nil
      if fixtureDelivery != nil { authorization = .enabled }
      if let fixtureHistory {
        let task = Task { @MainActor [weak self] in
          let history = await fixtureHistory()
          guard let self, !self.stopped else { return }
          self.applyHistory(history)
        }
        self.fixtureTaskObserver?(task)
      }
      return
    }

    let center = UNUserNotificationCenter.current()
    let eventStore = HealthEventStore()
    self.center = center
    self.eventStore = eventStore
    Task { @MainActor [weak self, eventStore] in
      let history = await eventStore.current()
      guard let self, !self.stopped else { return }
      self.applyHistory(history)
      await self.refreshAuthorization()
    }
  }

  private func applyHistory(_ history: [HealthEventRecord]) {
    historyLoaded = true
    events = history
    lastNotifiedAtByID = Dictionary(
      history.filter { $0.change == .notified }.map { ($0.issueID, $0.capturedAt) },
      uniquingKeysWith: { previous, newer in max(previous, newer) })
  }

  func shutdown() {
    stopped = true
    for task in deliveryTasks.values { task.cancel() }
    deliveryTasks.removeAll()
    eventWriteTask?.cancel()
    eventWriteTask = nil
    pendingEventRecords.removeAll()
  }

  func accept(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    guard !stopped else { return }
    observationSnapshot = snapshot
    observationReceivedAt = observationClock()
    if snapshot.isSuspended {
      hasEvaluationBaseline = false
      baselinePendingRules = Set(HealthAlertRule.allCases.map(\.rawValue))
      lastEvaluationAt = nil
      activationGeneration &+= 1
      for task in deliveryTasks.values { task.cancel() }
      deliveryTasks.removeAll()
      issues = []
      issueByID.removeAll()
      activeSinceByID.removeAll()
      activationBeganAtByID.removeAll()
      activationIDByID.removeAll()
      notifiedThisActivation.removeAll()
      retryAfterByID.removeAll()
      return
    }
    let configuration = configuration()
    let gap = lastEvaluationAt.map { now.timeIntervalSince($0) } ?? 0
    var changedRules: Set<String> = []
    if let previous = lastConfiguration, previous != configuration {
      changedRules = Set(HealthAlertRule.allCases.filter { previous[$0] != configuration[$0] }.map(\.rawValue))
    }
    if lastConfiguration == nil || gap < 0 || gap > 30 {
      // Sleep/wake establishes a fresh baseline, never replaying already-active
      // conditions or carrying a sustained duration across a gap.
      if lastConfiguration == nil { hasEvaluationBaseline = false }
      baselinePendingRules = Set(HealthAlertRule.allCases.map(\.rawValue))
      // A publication gap silences existing conditions without inventing a
      // recovery or replacing their original activation/cooldown identity.
      notifiedThisActivation.formUnion(issueByID.keys)
      activeSinceByID.removeAll()
      activationGeneration &+= 1
      for task in deliveryTasks.values { task.cancel() }
      deliveryTasks.removeAll()
      retryAfterByID.removeAll()
    }
    // Changing one preference must not reset another alert's sustained time or
    // delivery state. The changed rule alone gets a silent current baseline.
    for id in changedRules {
      baselinePendingRules.insert(id)
      issueByID.removeValue(forKey: id)
      activeSinceByID.removeValue(forKey: id)
      activationBeganAtByID.removeValue(forKey: id)
      activationIDByID.removeValue(forKey: id)
      notifiedThisActivation.remove(id)
      deliveryTasks.removeValue(forKey: id)?.cancel()
      retryAfterByID.removeValue(forKey: id)
    }
    lastConfiguration = configuration
    lastEvaluationAt = now
    var next = HealthEvaluator.evaluate(snapshot, now: now, configuration: configuration,
      previouslyActive: hasEvaluationBaseline ? Set(issueByID.keys) : [])
    if hasEvaluationBaseline {
      // Missing evidence is never recovery, for numeric or reported-state rules.
      // Preserve the activation/cooldown latch, cancel delivery and pause sustain
      // until a fresh triggering observation starts a new continuous interval.
      for previous in issueByID.values {
        guard let rule = HealthAlertRule(rawValue: previous.id),
          configuration[rule].enabled,
          !rule.hasCurrentObservation(in: snapshot, now: now) else { continue }
        let suffix = " Awaiting a fresh measurement; recovery is not yet confirmed."
        next.append(HealthIssue(id: previous.id, severity: previous.severity,
          title: previous.title, detail: previous.detail.hasSuffix(suffix)
            ? previous.detail : previous.detail + suffix))
        pauseDelivery(for: previous.id)
      }
    }
    if center != nil, !authorizationRefreshInFlight,
      now.timeIntervalSince(authorizationRefreshAt) >= 60 {
      authorizationRefreshAt = now
      authorizationRefreshInFlight = true
      Task { [weak self] in
        await self?.refreshAuthorization()
        self?.authorizationRefreshInFlight = false
      }
    }
    // Initial/wake publications can contain only pending samples. Wait for
    // each source's first real observation before declaring its baseline ready.
    let silentBaselineRules = Set(HealthAlertRule.allCases.filter {
      baselinePendingRules.contains($0.rawValue) && $0.hasCurrentObservation(in: snapshot, now: now)
    }.map(\.rawValue))
    baselinePendingRules.subtract(silentBaselineRules)
    let previousIssues = issueByID
    // Publish only real changes; observers otherwise redraw on every 1 Hz sample.
    if issues != next { issues = next }
    issueByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })

    // Establish the first live sample as a baseline. Restarting Helios while a
    // condition is already active must not replay a notification. Treat those
    // baseline issues as already handled for that activation; they can notify
    // only after a real resolve -> re-activate transition observed while running.
    guard hasEvaluationBaseline else {
      hasEvaluationBaseline = true
      activeSinceByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, now) })
      activationBeganAtByID = activeSinceByID
      activationIDByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, UUID()) })
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
      activationBeganAtByID.removeValue(forKey: resolvedID)
      activationIDByID.removeValue(forKey: resolvedID)
      notifiedThisActivation.remove(resolvedID)
      deliveryTasks.removeValue(forKey: resolvedID)?.cancel()
      retryAfterByID.removeValue(forKey: resolvedID)
    }
    for activated in transition.newlyActive {
      activeSinceByID[activated.id] = now
      activationBeganAtByID[activated.id] = now
      activationIDByID[activated.id] = UUID()
      if silentBaselineRules.contains(activated.id) {
        notifiedThisActivation.insert(activated.id)
      } else {
        notifiedThisActivation.remove(activated.id)
      }
    }
    // Defensive recovery for an issue that somehow entered without a transition.
    for issue in next where activeSinceByID[issue.id] == nil {
      guard let rule = HealthAlertRule(rawValue: issue.id),
        rule.hasCurrentObservation(in: snapshot, now: now) else { continue }
      activeSinceByID[issue.id] = now
      if activationBeganAtByID[issue.id] == nil { activationBeganAtByID[issue.id] = now }
      if activationIDByID[issue.id] == nil { activationIDByID[issue.id] = UUID() }
    }

    guard historyLoaded else { return }
    for issue in next {
      guard let rule = HealthAlertRule(rawValue: issue.id),
        rule.hasCurrentObservation(in: snapshot, now: now),
        !notifiedThisActivation.contains(issue.id),
        let activeSince = activeSinceByID[issue.id],
        let activationBeganAt = activationBeganAtByID[issue.id]
      else { continue }
      let lastNotified = lastNotifiedAtByID[issue.id]
      if HealthNotificationPolicy.suppressDowngrade(issue, activeSince: activationBeganAt,
        lastNotifiedAtByID: lastNotifiedAtByID) {
        notifiedThisActivation.insert(issue.id)
        continue
      }
      guard HealthNotificationPolicy.activationAllowsNotification(
        issue: issue, activeSince: activationBeganAt, lastNotifiedAt: lastNotified)
      else {
        // Decide using the original activation time, even when history or
        // authorization becomes ready after cooldown expiry. Suppress this
        // whole activation independently of its sustain/readiness gates.
        notifiedThisActivation.insert(issue.id)
        continue
      }
      guard authorization == .enabled, deliveryTasks[issue.id] == nil,
        retryAfterByID[issue.id].map({ now >= $0 }) ?? true
      else { continue }
      guard HealthNotificationPolicy.shouldNotify(
        issue: issue, activeSince: activeSince, lastNotifiedAt: lastNotified, now: now)
      else { continue }

      schedule(issue, activeSince: activeSince, now: now)
    }
  }

  private func appendEventRecords(_ records: [HealthEventRecord], now: Date) {
    guard !records.isEmpty else { return }
    if let eventStore {
      pendingEventRecords = HealthEventEngine.sanitized(pendingEventRecords + records, now: now)
      guard eventWriteTask == nil else { return }
      eventWriteTask = Task { @MainActor [weak self, eventStore] in
        while !Task.isCancelled {
          guard let self, !self.stopped else { return }
          guard !self.pendingEventRecords.isEmpty else {
            self.eventWriteTask = nil
            return
          }
          let batch = self.pendingEventRecords
          self.pendingEventRecords.removeAll(keepingCapacity: true)
          let updated = await eventStore.append(batch, now: batch.last?.capturedAt ?? now)
          guard !Task.isCancelled, !self.stopped else { return }
          self.events = updated
        }
      }
    } else {
      // Fixture mode is intentionally side-effect free but keeps the observable
      // transition/notification history meaningful for deterministic rendering.
      events = HealthEventEngine.sanitized(events + records, now: now)
    }
  }

  func requestAuthorization() {
    guard !stopped, center != nil, !authorizationRequestInFlight else { return }
    authorizationRequestInFlight = true
    Task { @MainActor [weak self] in
      guard let self, let center = self.center else { return }
      defer { authorizationRequestInFlight = false }
      await refreshAuthorization()
      guard !stopped, authorization == .notDetermined else { return }
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
      authorization = fixtureDelivery == nil ? .unknown : .enabled
      return
    }
    let settings = await center.notificationSettings()
    guard !stopped else { return }
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: authorization = .enabled
    case .denied: authorization = .denied
    case .notDetermined: authorization = .notDetermined
    @unknown default: authorization = .unknown
    }
  }

  private func schedule(_ issue: HealthIssue, activeSince: Date, now: Date) {
    guard center != nil || fixtureDelivery != nil,
      hasCurrentDeliveryObservation(for: issue.id) else { return }
    let center = center
    let fixtureDelivery = fixtureDelivery
    let generation = activationGeneration
    let activationID = activationIDByID[issue.id]
    let content = UNMutableNotificationContent()
    content.title = issue.title
    content.body = issue.detail
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "helios-health-\(issue.id)", content: content, trigger: nil)
    let task = Task { @MainActor [weak self] in
      guard let self, !self.stopped, !Task.isCancelled,
        self.activationGeneration == generation,
        self.activationIDByID[issue.id] == activationID else { return }
      // A delayed task can outlive freshness even without another publication.
      // Cancelled tasks must never clear a replacement for the same activation.
      defer {
        if !Task.isCancelled, self.activationGeneration == generation,
          self.activationIDByID[issue.id] == activationID {
          self.deliveryTasks.removeValue(forKey: issue.id)
        }
      }
      guard self.hasCurrentDeliveryObservation(for: issue.id) else { return }
      do {
        if let fixtureDelivery {
          try await fixtureDelivery(issue)
        } else if let center {
          try await center.add(request)
        } else { return }
        guard !self.stopped, !Task.isCancelled, self.activationGeneration == generation,
          self.activationIDByID[issue.id] == activationID,
          self.hasCurrentDeliveryObservation(for: issue.id) else { return }
        self.deliveryFailed = false
        self.retryAfterByID.removeValue(forKey: issue.id)
        self.notifiedThisActivation.insert(issue.id)
        let acknowledgedAt = max(now, self.lastEvaluationAt ?? now)
        self.lastNotifiedAtByID[issue.id] = acknowledgedAt
        self.appendEventRecords([HealthEventRecord(
          capturedAt: acknowledgedAt, change: .notified, issueID: issue.id,
          severity: issue.severity.rawValue, title: issue.title,
          detail: HealthNotificationPolicy.notificationDetail(
            for: issue, activeSince: activeSince, now: acknowledgedAt))], now: acknowledgedAt)
      } catch {
        guard !self.stopped, !Task.isCancelled, self.activationGeneration == generation,
          self.activationIDByID[issue.id] == activationID,
          self.hasCurrentDeliveryObservation(for: issue.id) else { return }
        self.deliveryFailed = true
        // A failed enqueue is not a delivery. Retry at most once per minute
        // while still active; authorization is refreshed without another prompt.
        self.retryAfterByID[issue.id] = now.addingTimeInterval(60)
        await self.refreshAuthorization()
      }
    }
    deliveryTasks[issue.id] = task
    fixtureTaskObserver?(task)
  }

  private func hasCurrentDeliveryObservation(for id: String) -> Bool {
    guard let rule = HealthAlertRule(rawValue: id) else { return false }
    // Preference edits can precede the next shared publication. A task evaluated
    // under an older setting must neither enqueue nor acknowledge delivery;
    // compare only this rule so unrelated edits retain their own activation.
    let currentSetting = configuration()[rule]
    guard currentSetting.enabled, lastConfiguration?[rule] == currentSetting else {
      pauseDelivery(for: id)
      return false
    }
    guard issueByID[id] != nil, let snapshot = observationSnapshot, !snapshot.isSuspended,
      let evaluatedAt = lastEvaluationAt, let receivedAt = observationReceivedAt else { return false }
    let elapsed = observationClock().timeIntervalSince(receivedAt)
    guard elapsed.isFinite, elapsed >= 0,
      rule.hasCurrentObservation(in: snapshot, now: evaluatedAt.addingTimeInterval(elapsed)) else {
      pauseDelivery(for: id)
      return false
    }
    return true
  }

  private func pauseDelivery(for id: String) {
    activeSinceByID.removeValue(forKey: id)
    deliveryTasks.removeValue(forKey: id)?.cancel()
  }
}
