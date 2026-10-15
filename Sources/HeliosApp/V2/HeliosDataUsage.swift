import Network
import SwiftUI

/// Data usage per day and app (PLAN_0_3_0 M4), an opt-in module: off by default, and
/// while off nothing is sampled. While on, one `nettop` sample every ten minutes, a path
/// monitor to notice personal hotspots, and a notification when a hotspot day crosses
/// 250 MB, 1 GB or 3 GB. Everything stays in ~/Library/Application Support/Helios.
@MainActor
final class HeliosDataUsageMonitor: ObservableObject {
  static let shared = HeliosDataUsageMonitor()
  static let enabledKey = "HeliosDataUsage.enabled"
  static let interval: TimeInterval = 600

  @Published private(set) var enabled: Bool
  @Published private(set) var days: [HeliosDataUsageDay] = []
  @Published private(set) var metered = false
  private var tracker = HeliosDataUsageTracker()
  private var lastSample: Date?
  private var sampling = false
  private var path: NWPathMonitor?

  private init() {
    enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    if enabled { start() }
  }

  func setEnabled(_ on: Bool) {
    enabled = on
    UserDefaults.standard.set(on, forKey: Self.enabledKey)
    on ? start() : stop()
  }

  private func start() {
    days = HeliosDataUsageStore.load()
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
      let expensive = path.isExpensive
      Task { @MainActor in HeliosDataUsageMonitor.shared.metered = expensive }
    }
    monitor.start(queue: DispatchQueue(label: "com.snejda.Helios.data-usage-path", qos: .utility))
    path = monitor
    lastSample = nil
    sample()
  }

  private func stop() {
    path?.cancel()
    path = nil
    tracker = HeliosDataUsageTracker()
  }

  /// Called with every telemetry publication; samples only when due.
  func observe(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    guard enabled, !sampling, lastSample.map({ now.timeIntervalSince($0) >= Self.interval }) ?? true else { return }
    sample(now: now)
  }

  private func sample(now: Date = Date()) {
    sampling = true
    lastSample = now
    Task { [weak self] in
      let totals = await HeliosNetworkProbe.cumulativeTotals()
      guard let self else { return }
      self.sampling = false
      guard self.enabled, let totals else { return }
      let deltas = self.tracker.deltas(totals)
      guard !deltas.isEmpty else { return }
      let key = HeliosDataUsageStore.dayKey(now)
      let before = self.days.first { $0.day == key }?.metered ?? 0
      self.days = HeliosDataUsageStore.merge(self.days, deltas: deltas, metered: self.metered, now: now)
      HeliosDataUsageStore.save(self.days)
      let after = self.days.first { $0.day == key }?.metered ?? 0
      if let threshold = HeliosDataUsageStore.crossed(previous: before, current: after) {
        HeliosAutomationCenter.shared.notify(
          title: "Hotspot data", body: "This Mac has used \(TelemetryFormatting.storageBytes(threshold)) over a personal hotspot today.")
      }
    }
  }
}

/// Network page: today and the last seven days by app, with the opt-in switch.
struct HeliosDataUsageSection: View {
  @ObservedObject private var usage = HeliosDataUsageMonitor.shared

  var body: some View {
    HeliosSection("Data usage") {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Count data per app", isOn: Binding(get: { usage.enabled }, set: { usage.setEnabled($0) }))
        if usage.enabled {
          let now = Date()
          let today = usage.days.first { $0.day == HeliosDataUsageStore.dayKey(now) }
          HeliosGroup {
            HeliosFactRow(label: "Today", value: TelemetryFormatting.storageBytes(today?.total ?? 0),
                          detail: (today?.metered ?? 0) > 0
                            ? "\(TelemetryFormatting.storageBytes(today?.metered ?? 0)) over a personal hotspot" : nil)
            ForEach(Array(HeliosDataUsageStore.top(usage.days, last: 7, now: now).enumerated()), id: \.offset) { index, item in
              HeliosFactRow(label: item.app, value: TelemetryFormatting.storageBytes(item.bytes),
                            detail: index == 0 ? "Most in the last 7 days" : nil, showsDivider: index < 4)
            }
          }
          if usage.metered {
            Label("You are on a personal hotspot or another metered connection.", systemImage: "antenna.radiowaves.left.and.right")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        Text("Counts bytes per app every ten minutes from macOS's network statistics. It stays on this Mac and is never part of diagnostics. Off by default.")
          .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

// MARK: - Latency over time

/// Latency history (PLAN_0_3_0 M4), an opt-in module like data usage: off by default, and
/// while off nothing runs. While on, three echoes to the router and to 1.1.1.1 every five
/// minutes (about 200 bytes each time), kept for seven days in
/// ~/Library/Application Support/Helios/latency-v1.ndjson. Never part of diagnostics.
@MainActor
final class HeliosLatencyMonitor: ObservableObject {
  static let shared = HeliosLatencyMonitor()
  static let enabledKey = "HeliosLatencyHistory.enabled"

  @Published private(set) var enabled: Bool
  @Published private(set) var samples: [HeliosLatencySample] = []
  private var lastSample: Date?
  private var sampling = false
  private var rawLines = 0

  private init() {
    enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    if enabled { load() }
  }

  func setEnabled(_ on: Bool) {
    enabled = on
    UserDefaults.standard.set(on, forKey: Self.enabledKey)
    if on {
      load()
      lastSample = nil
    } else {
      samples = []
    }
  }

  /// Called with every telemetry publication; measures only when due and connected.
  func observe(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    guard enabled, !sampling, !snapshot.isSuspended,
      lastSample.map({ now.timeIntervalSince($0) >= HeliosLatencyHistory.interval || now < $0 }) ?? true
    else { return }
    if case .success(let network) = snapshot.network.result, (try? network.isRunning.get()) == false { return }
    lastSample = now
    sampling = true
    Task { [weak self] in
      let sample = await HeliosNetworkProbe.latencySample(now: now)
      guard let self else { return }
      self.sampling = false
      self.record(sample, now: now)
    }
  }

  /// A manual network check counts as a look too (only while the history is on).
  func record(_ check: HeliosNetworkCheck) {
    guard enabled, check.connected else { return }
    record(HeliosLatencySample(at: check.checkedAt, router: check.gateway, internet: check.internet),
           now: check.checkedAt)
  }

  private func record(_ sample: HeliosLatencySample, now: Date) {
    guard enabled else { return }
    samples = HeliosLatencyHistory.appended(samples, sample, now: now)
    append(sample)
  }

  // MARK: File (append-only lines, rewritten only when mostly expired)

  static var url: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("latency-v1.ndjson")
  }

  private func load() {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let data = HistoryCompactionPolicy.read(Self.url)
    var decoded: [HeliosLatencySample] = []
    for line in data.split(separator: 0x0A) where !line.isEmpty {
      if let sample = try? decoder.decode(HeliosLatencySample.self, from: Data(line)) { decoded.append(sample) }
    }
    rawLines = decoded.count
    samples = HeliosLatencyHistory.sanitized(decoded, now: Date())
    if rawLines > samples.count + 300 { rewrite() }
  }

  private func append(_ sample: HeliosLatencySample) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    guard var line = try? encoder.encode(sample) else { return }
    line.append(0x0A)
    let folder = Self.url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: Self.url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    } else {
      try? line.write(to: Self.url, options: .atomic)
    }
    rawLines += 1
    if rawLines > samples.count + 300 { rewrite() }
  }

  private func rewrite() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    if (try? HistoryCompactionPolicy.writeLines(samples, encoder: encoder, to: Self.url)) != nil {
      rawLines = samples.count
    }
  }
}

/// Network page: the switch, a chart of the last day or week, and a plain summary.
struct HeliosLatencySection: View {
  @ObservedObject private var monitor = HeliosLatencyMonitor.shared
  @State private var week = false

  var body: some View {
    HeliosSection("Latency over time") {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Measure latency every 5 minutes", isOn: Binding(get: { monitor.enabled }, set: { monitor.setEnabled($0) }))
        if monitor.enabled {
          let now = Date()
          let since = now.addingTimeInterval(week ? -HeliosLatencyHistory.retention : -86_400)
          let window = monitor.samples.filter { $0.at >= since }
          Picker("Range", selection: $week) {
            Text("24 Hours").tag(false)
            Text("7 Days").tag(true)
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
          if window.count < 2 {
            Text("Helios is collecting. The first line appears after two measurements, ten minutes from now.")
              .font(.subheadline).foregroundStyle(.secondary)
          } else {
            HeliosLatencyChart(samples: window, start: since, end: now)
            summary(HeliosLatencyHistory.summary(window, since: since))
          }
        }
        Text("Three tiny echoes to your router and to the internet (1.1.1.1) every five minutes, kept for seven days on this Mac and never part of diagnostics. Off by default.")
          .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder
  private func summary(_ summary: HeliosLatencyHistory.Summary) -> some View {
    HeliosGroup {
      HeliosFactRow(label: "Internet, typical", value: summary.internetMedian.map(Self.ms) ?? "—",
                    detail: summary.internetSlowest.map { "Slowest 5 % above \(Self.ms($0))" })
      HeliosFactRow(label: "Router, typical", value: summary.routerMedian.map(Self.ms) ?? "—")
      HeliosFactRow(label: "Lost packets", value: summary.lossBeyondRouter + summary.lossAtRouter == 0
        ? "None" : "\(summary.lossBeyondRouter + summary.lossAtRouter) of \(summary.count) measurements",
                    detail: summary.lossAtRouter > 0 ? "\(summary.lossAtRouter) already at the router (Wi-Fi or router)"
                      : summary.lossBeyondRouter > 0 ? "Beyond the router (provider or further out)" : nil,
                    showsDivider: false)
    }
  }

  static func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }
}

/// Two lines (internet, router) over time; lost measurements as marks along the bottom.
/// Drawn with paths: a few hundred points, no chart framework.
struct HeliosLatencyChart: View {
  let samples: [HeliosLatencySample]
  let start: Date
  let end: Date

  var body: some View {
    let values = samples.flatMap { [$0.internetMilliseconds, $0.routerMilliseconds] }.compactMap { $0 }
    let top = max(20, HeliosLatencyHistory.percentile(values.sorted(), 0.98) ?? 20) * 1.15
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geometry in
        let size = geometry.size
        ZStack(alignment: .topLeading) {
          line(\.routerMilliseconds, size: size, top: top).stroke(Color.secondary.opacity(0.7), lineWidth: 1.2)
          line(\.internetMilliseconds, size: size, top: top).stroke(Color.accentColor, lineWidth: 1.6)
          ForEach(Array(samples.filter(\.internetLost).enumerated()), id: \.offset) { _, sample in
            Circle().fill(sample.routerLost ? Color.red : Color.orange).frame(width: 5, height: 5)
              .position(x: x(sample.at, width: size.width), y: size.height - 3)
          }
          Text(Self.label(top / 1.15)).font(.caption).foregroundStyle(.tertiary)
        }
      }
      .frame(height: 90)
      HStack(spacing: 12) {
        Label("Internet", systemImage: "circle.fill").foregroundStyle(Color.accentColor)
        Label("Router", systemImage: "circle.fill").foregroundStyle(.secondary)
        Label("Lost packets", systemImage: "circle.fill").foregroundStyle(.orange)
        Spacer()
      }
      .font(.caption).labelStyle(HeliosSmallDotLabelStyle())
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Latency over time")
    .accessibilityValue(samples.last?.internetMilliseconds.map { "Latest internet \(Self.label($0))" } ?? "No data")
  }

  private func x(_ date: Date, width: CGFloat) -> CGFloat {
    let span = max(1, end.timeIntervalSince(start))
    return width * CGFloat(min(1, max(0, date.timeIntervalSince(start) / span)))
  }

  /// Breaks the line across gaps longer than three intervals (sleep, Helios closed).
  private func line(_ value: KeyPath<HeliosLatencySample, Double?>, size: CGSize, top: Double) -> Path {
    Path { path in
      var previous: Date?
      for sample in samples {
        guard let ms = sample[keyPath: value] else { previous = nil; continue }
        let point = CGPoint(x: x(sample.at, width: size.width),
                            y: size.height * CGFloat(1 - min(1, ms / top)))
        if let previous, sample.at.timeIntervalSince(previous) <= HeliosLatencyHistory.interval * 3 {
          path.addLine(to: point)
        } else {
          path.move(to: point)
        }
        previous = sample.at
      }
    }
  }

  static func label(_ value: Double) -> String { "\(Int(value.rounded())) ms" }
}

private struct HeliosSmallDotLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 6))
      configuration.title.foregroundStyle(.secondary)
    }
  }
}
