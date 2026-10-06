import Foundation

/// One entry of the Activity timeline. Events are derived only from data Helios
/// already stores; a future event engine adds kinds/sources, not a new UI.
struct HeliosActivityEvent: Identifiable, Equatable, Sendable {
  enum Kind: String, Sendable {
    case issueStarted, issueResolved, powerConnected, powerDisconnected, peak
  }
  enum Tone: Sendable { case neutral, positive, attention, critical }
  enum Source: String, Sendable {
    /// Local health event log (HealthEventStore, 7 days).
    case healthLog
    /// 24-hour persistent telemetry history (~30 s resolution).
    case history
  }

  let id: String
  let date: Date
  let kind: Kind
  let tone: Tone
  let title: String
  var detail: String? = nil
  /// Issue episodes: how long the condition lasted, when known.
  var duration: TimeInterval? = nil
  let source: Source
  /// Chart the event belongs to, used for markers.
  var metric: HeliosChartMetric? = nil
}

extension HeliosActivityEvent {
  /// The health area an event belongs to, for the Activity filter. Power-adapter
  /// changes belong to Battery; events without a known metric have no area.
  var area: HeliosArea? {
    switch kind {
    case .powerConnected, .powerDisconnected: return .battery
    default: break
    }
    switch metric {
    case .cpu?, .gpu?, .memory?, .network?, .networkUpload?: return .performance
    case .temperature?, .fan?: return .thermals
    case .battery?, .power?: return .battery
    case .disk?: return .storage
    case nil: return nil
    }
  }
}

/// Events are filtered by the health area they belong to (Activity page).
enum HeliosActivityFilter: Hashable, Identifiable {
  case all
  case area(HeliosArea)
  var id: String {
    switch self {
    case .all: "all"
    case .area(let area): area.rawValue
    }
  }
  static let allCases: [HeliosActivityFilter] = [.all] + HeliosArea.allCases.map(HeliosActivityFilter.area)
  var title: String {
    switch self {
    case .all: "All"
    case .area(let area): area.title
    }
  }

  func includes(_ event: HeliosActivityEvent, problemsOnly: Bool = false) -> Bool {
    if problemsOnly, event.kind != .issueStarted, event.kind != .issueResolved { return false }
    switch self {
    case .all: return true
    case .area(let area): return event.area == area
    }
  }
}

/// Vertical event marker drawn on a time-series chart.
struct HeliosChartMarker: Equatable, Sendable, Identifiable {
  let date: Date
  let tone: HeliosActivityEvent.Tone
  let label: String
  var id: String { "\(date.timeIntervalSince1970)-\(label)" }
}

enum HeliosActivityTimeline {
  /// Pure derivation. `activeIssueIDs` distinguishes an ongoing issue from one
  /// whose end was never recorded (for example because Helios quit).
  static func events(
    health records: [HealthEventRecord], history points: [PersistedTelemetryPoint],
    activeIssueIDs: Set<String>, calendar: Calendar = .current
  ) -> [HeliosActivityEvent] {
    var events = healthEvents(records, activeIssueIDs: activeIssueIDs, calendar: calendar)
    events += powerEvents(points)
    events += peakEvents(points, calendar: calendar)
    return events.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
  }

  /// A condition that clears and returns within this long is one episode, not two:
  /// a reading hovering around its threshold must not fill the timeline.
  static let flapMergeGap: TimeInterval = 10 * 60

  /// Merges flapping: a resolve followed by a re-activation of the same issue within
  /// `gap` is dropped, so the episode runs from the first start to the last end.
  /// Returns the surviving records and, per episode head (first activation), how
  /// many activations were folded into it. The stored event log is not changed.
  static func mergingFlaps(_ records: [HealthEventRecord], gap: TimeInterval = flapMergeGap)
    -> (records: [HealthEventRecord], activations: [String: Int])
  {
    var output: [HealthEventRecord?] = []
    var lastResolved: [String: Int] = [:]
    var head: [String: String] = [:]
    var activations: [String: Int] = [:]
    for record in records.sorted(by: { $0.capturedAt < $1.capturedAt }) {
      switch record.change {
      case .notified:
        output.append(record)
      case .resolved:
        output.append(record)
        lastResolved[record.issueID] = output.count - 1
      case .activated:
        if let index = lastResolved[record.issueID], let resolved = output[index],
          record.capturedAt.timeIntervalSince(resolved.capturedAt) <= gap,
          let headID = head[record.issueID]
        {
          output[index] = nil
          lastResolved[record.issueID] = nil
          activations[headID, default: 1] += 1
        } else {
          output.append(record)
          head[record.issueID] = record.id
          lastResolved[record.issueID] = nil
        }
      }
    }
    return (output.compactMap { $0 }, activations)
  }

  /// An episode this short is a blip. Several of them for one issue on one day are
  /// shown as a single line instead of a start/resolved pair each.
  static let briefEpisode: TimeInterval = 2 * 60
  static let minimumBriefEpisodesToCollapse = 3

  /// One period during which an issue was active, as far as the log records it.
  private struct Episode {
    let begin: HealthEventRecord
    var end: HealthEventRecord?
    /// Why there is no end: still active, or the log never recorded one.
    var note: String?
    var repeats = 1

    var duration: TimeInterval? {
      guard let end else { return nil }
      let value = end.capturedAt.timeIntervalSince(begin.capturedAt)
      return value >= 0 ? value : nil
    }
  }

  static func healthEvents(
    _ rawRecords: [HealthEventRecord], activeIssueIDs: Set<String>, calendar: Calendar = .current
  ) -> [HeliosActivityEvent] {
    let merged = mergingFlaps(rawRecords)
    var open: [String: Episode] = [:]
    var episodes: [Episode] = []
    var orphanResolutions: [HealthEventRecord] = []
    for record in merged.records.sorted(by: { $0.capturedAt < $1.capturedAt }) {
      switch record.change {
      case .notified:
        continue
      case .activated:
        if var previous = open[record.issueID] {
          // A second activation without a recorded resolution (e.g. relaunch).
          previous.note = "End not recorded"
          episodes.append(previous)
        }
        open[record.issueID] = Episode(
          begin: record, repeats: merged.activations[record.id] ?? 1)
      case .resolved:
        if var episode = open.removeValue(forKey: record.issueID) {
          episode.end = record
          episodes.append(episode)
        } else {
          // Resolved without a recorded start (it began before the log's retention).
          orphanResolutions.append(record)
        }
      }
    }
    for var episode in open.values {
      episode.note = activeIssueIDs.contains(episode.begin.issueID) ? "Ongoing" : "End not recorded"
      episodes.append(episode)
    }

    // Collapse runs of brief, closed episodes of one issue within a calendar day.
    var briefGroups: [String: [Int]] = [:]
    for (index, episode) in episodes.enumerated() {
      guard let duration = episode.duration, duration < briefEpisode else { continue }
      let day = calendar.startOfDay(for: episode.begin.capturedAt).timeIntervalSince1970
      briefGroups["\(episode.begin.issueID)|\(day)", default: []].append(index)
    }
    var collapsed = Set<Int>()
    var events: [HeliosActivityEvent] = orphanResolutions.map {
      HeliosActivityEvent(
        id: "health-resolved-\($0.id)", date: $0.capturedAt, kind: .issueResolved,
        tone: .positive, title: "\($0.title) — resolved", source: .healthLog,
        metric: metric(forIssue: $0.issueID))
    }
    for (key, indices) in briefGroups where indices.count >= minimumBriefEpisodesToCollapse {
      collapsed.formUnion(indices)
      let members = indices.map { episodes[$0] }
      guard let last = members.max(by: { $0.begin.capturedAt < $1.begin.capturedAt }) else { continue }
      let count = members.reduce(0) { $0 + $1.repeats }
      var event = Self.start(last.begin, duration: nil, detail:
        "Brief spikes: \(count) times that day, each under \(Int(briefEpisode / 60)) min")
      event = HeliosActivityEvent(
        id: "health-brief-\(key)", date: event.date, kind: event.kind, tone: event.tone,
        title: event.title, detail: event.detail, duration: nil, source: .healthLog,
        metric: event.metric)
      events.append(event)
    }
    for (index, episode) in episodes.enumerated() where !collapsed.contains(index) {
      var event = Self.start(episode.begin, duration: episode.duration, detail: episode.note)
      if episode.repeats > 1 {
        event.detail = "Happened \(episode.repeats) times in a row · \(episode.note ?? episode.begin.detail)"
      }
      events.append(event)
      if let end = episode.end {
        events.append(HeliosActivityEvent(
          id: "health-resolved-\(end.id)", date: end.capturedAt, kind: .issueResolved,
          tone: .positive, title: "\(end.title) — resolved", source: .healthLog,
          metric: metric(forIssue: end.issueID)))
      }
    }
    return events
  }

  private static func start(_ record: HealthEventRecord, duration: TimeInterval?, detail: String?)
    -> HeliosActivityEvent
  {
    HeliosActivityEvent(
      id: "health-start-\(record.id)", date: record.capturedAt, kind: .issueStarted,
      tone: record.severity >= HealthIssue.Severity.critical.rawValue ? .critical : .attention,
      title: record.title, detail: detail ?? record.detail, duration: duration,
      source: .healthLog, metric: metric(forIssue: record.issueID))
  }

  static func metric(forIssue id: String) -> HeliosChartMetric? {
    if id.hasPrefix("soc-") || id.hasPrefix("thermal-state") { return .temperature }
    if id.hasPrefix("memory-") { return .memory }
    if id.hasPrefix("battery-") { return .battery }
    if id.hasPrefix("ssd-") { return .disk }
    return nil
  }

  /// Persistent samples are ~30 s apart; a transition across a longer gap is
  /// reported with its uncertainty instead of a precise time.
  static func powerEvents(_ points: [PersistedTelemetryPoint]) -> [HeliosActivityEvent] {
    var events: [HeliosActivityEvent] = []
    var previous: PersistedTelemetryPoint?
    for point in points {
      guard let onAC = point.batteryOnAC else { continue }
      defer { previous = point }
      guard let last = previous, let wasOnAC = last.batteryOnAC, wasOnAC != onAC else { continue }
      let gap = point.capturedAt.timeIntervalSince(last.capturedAt)
      events.append(HeliosActivityEvent(
        id: "power-\(point.capturedAt.timeIntervalSince1970)",
        date: point.capturedAt,
        kind: onAC ? .powerConnected : .powerDisconnected, tone: .neutral,
        title: onAC ? "Power adapter connected" : "Switched to battery",
        detail: gap > PersistentHistoryEngine.maximumEnergyGap
          ? "Changed while Helios wasn’t recording" : nil,
        source: .history, metric: .battery))
    }
    return events
  }

  /// One temperature peak per calendar day, and a CPU peak when it was substantial.
  static func peakEvents(_ points: [PersistedTelemetryPoint], calendar: Calendar)
    -> [HeliosActivityEvent]
  {
    var temperature: [Date: PersistedTelemetryPoint] = [:]
    var cpu: [Date: PersistedTelemetryPoint] = [:]
    // Points are in time order, so the day boundaries are looked up once per day.
    var day = Date.distantPast
    var dayEnd = Date.distantPast
    for point in points {
      if point.capturedAt >= dayEnd || point.capturedAt < day {
        day = calendar.startOfDay(for: point.capturedAt)
        dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? point.capturedAt
      }
      if let value = point.maxSoCCelsius, value.isFinite,
        value > (temperature[day]?.maxSoCCelsius ?? -.infinity)
      {
        temperature[day] = point
      }
      if let value = point.cpuPercent, value.isFinite, value > (cpu[day]?.cpuPercent ?? -.infinity) {
        cpu[day] = point
      }
    }
    var events: [HeliosActivityEvent] = []
    for point in temperature.values {
      guard let value = point.maxSoCCelsius else { continue }
      events.append(HeliosActivityEvent(
        id: "peak-temp-\(point.capturedAt.timeIntervalSince1970)", date: point.capturedAt,
        kind: .peak, tone: .neutral, title: "Day’s peak temperature \(TelemetryFormatting.temperature(value))",
        detail: "Hottest recorded sensor reading (Max SoC)", source: .history, metric: .temperature))
    }
    for point in cpu.values {
      guard let value = point.cpuPercent, value >= 50 else { continue }
      events.append(HeliosActivityEvent(
        id: "peak-cpu-\(point.capturedAt.timeIntervalSince1970)", date: point.capturedAt,
        kind: .peak, tone: .neutral, title: "Day’s peak CPU \(TelemetryFormatting.percent(value))",
        detail: "30-second sample of total CPU usage", source: .history, metric: .cpu))
    }
    return events
  }

  /// Markers for one chart: issue episodes and power changes inside the window.
  static func markers(_ events: [HeliosActivityEvent], metric: HeliosChartMetric, from start: Date, to end: Date)
    -> [HeliosChartMarker]
  {
    events.compactMap { event in
      guard event.date >= start, event.date <= end, event.kind != .peak else { return nil }
      let relevant = event.metric == metric
        || event.kind == .powerConnected || event.kind == .powerDisconnected
      guard relevant else { return nil }
      return HeliosChartMarker(date: event.date, tone: event.tone, label: event.title)
    }
  }
}
