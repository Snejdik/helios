import AppKit
import SwiftUI

// MARK: - Window and analysis (pure)

enum HeliosEnergyRange: String, CaseIterable, Identifiable, Sendable {
  case oneHour, sixHours, twentyFourHours, threeDays, sevenDays, custom

  var id: String { rawValue }
  var label: String {
    switch self {
    case .oneHour: "1h"
    case .sixHours: "6h"
    case .twentyFourHours: "24h"
    case .threeDays: "3d"
    case .sevenDays: "7d"
    case .custom: "Custom"
    }
  }
  /// Nil for a custom range, which the user picks by date.
  var seconds: TimeInterval? {
    switch self {
    case .oneHour: 3_600
    case .sixHours: 6 * 3_600
    case .twentyFourHours: 24 * 3_600
    case .threeDays: 3 * 86_400
    case .sevenDays: 7 * 86_400
    case .custom: nil
    }
  }
}

/// One app that used clearly more energy in the window than in the equally long
/// window before it.
struct HeliosEnergyRise: Equatable, Identifiable, Sendable {
  let appKey: String
  let displayName: String
  let extraWattHours: Double
  /// Nil when the app used nothing in the previous window.
  let changePercent: Double?
  var id: String { appKey }
}

struct HeliosEnergyAnalysis: Sendable {
  let window: DateInterval
  let summary: AppEnergySummary
  /// Ranking for the chosen filter (on battery only, or all activity).
  let entries: [AppEnergyEntry]
  let buckets: [AppEnergyBucket]
  let rises: [HeliosEnergyRise]
  /// Time inside the window that no sample covers: asleep, or Helios not running.
  let unobservedSeconds: TimeInterval
  let unobserved: [DateInterval]
  /// Battery level change over the window's on-battery samples, in points.
  let batteryChangePoints: Double?
  /// Whether older history exists for the comparison window.
  let hasPreviousWindow: Bool

  static let minimumRiseWattHours = 0.01
  static let minimumRisePercent = 25.0

  static func make(
    buckets: [AppEnergyBucket], window: DateInterval, onBatteryOnly: Bool
  ) -> HeliosEnergyAnalysis {
    func within(_ interval: DateInterval, includingEnd: Bool = true) -> [AppEnergyBucket] {
      buckets.filter {
        $0.capturedAt >= interval.start
          && (includingEnd ? $0.capturedAt <= interval.end : $0.capturedAt < interval.end)
      }
    }
    let visible = within(window)
    let summary = AppEnergyHistoryEngine.summary(visible)
    let entries = onBatteryOnly ? summary.topOnBattery : summary.topAll

    let previousWindow = DateInterval(
      start: window.start.addingTimeInterval(-window.duration), end: window.start)
    let before = AppEnergyHistoryEngine.energyByApp(
      within(previousWindow, includingEnd: false), onBatteryOnly: onBatteryOnly)
    let hasPrevious = !before.isEmpty
    let rises: [HeliosEnergyRise] = hasPrevious
      ? entries.compactMap { entry in
        let earlier = before[entry.appKey] ?? 0
        let extra = entry.energyWattHours - earlier
        guard extra >= minimumRiseWattHours else { return nil }
        let percent = earlier > 0 ? extra / earlier * 100 : nil
        if let percent, percent < minimumRisePercent { return nil }
        return HeliosEnergyRise(
          appKey: entry.appKey, displayName: entry.displayName, extraWattHours: extra,
          changePercent: percent)
      }
      .sorted { $0.extraWattHours > $1.extraWattHours }
      .prefix(4).map { $0 }
      : []

    let gaps = unobservedPeriods(visible, window: window)
    let levels = visible.filter { $0.onBattery == true }.compactMap { bucket -> Double? in
      guard let percent = bucket.batteryPercent, (0...100).contains(percent) else { return nil }
      return percent
    }
    let change = levels.count >= 2 ? levels[levels.count - 1] - levels[0] : nil
    return HeliosEnergyAnalysis(
      window: window, summary: summary, entries: entries, buckets: visible, rises: rises,
      unobservedSeconds: gaps.reduce(0) { $0 + $1.duration }, unobserved: gaps,
      batteryChangePoints: change, hasPreviousWindow: hasPrevious)
  }

  /// Stretches between samples longer than a few sample lengths, plus the part of
  /// the window before the first and after the last sample. History that does not
  /// reach back to the window start is not "unobserved": Helios did not exist yet.
  static func unobservedPeriods(_ buckets: [AppEnergyBucket], window: DateInterval) -> [DateInterval] {
    guard let first = buckets.first, let last = buckets.last else { return [] }
    var gaps: [DateInterval] = []
    for (previous, next) in zip(buckets, buckets.dropFirst()) {
      let gap = next.capturedAt.timeIntervalSince(previous.capturedAt)
      let expected = max(next.durationSeconds, previous.durationSeconds)
      if gap > max(180, expected * 2.5) {
        gaps.append(DateInterval(start: previous.capturedAt, end: next.capturedAt))
      }
    }
    // The window's newest part counts only when it is well past the last sample.
    if window.end.timeIntervalSince(last.capturedAt) > max(180, last.durationSeconds * 2.5) {
      gaps.append(DateInterval(start: last.capturedAt, end: window.end))
    }
    _ = first
    return gaps
  }
}

/// CSV and JSON of the ranking on screen.
enum HeliosEnergyJSON {
  static func make(entries: [AppEnergyEntry], window: DateInterval, onBatteryOnly: Bool) -> Data? {
    let formatter = ISO8601DateFormatter()
    let apps: [[String: Any]] = entries.map {
      [
        "app": $0.displayName, "energy_wh": $0.energyWattHours,
        "cpu_core_seconds": $0.cpuCoreSeconds, "wakeups": $0.wakeups,
        "peak_memory_bytes": $0.peakMemoryBytes,
      ]
    }
    let root: [String: Any] = [
      "from": formatter.string(from: window.start), "to": formatter.string(from: window.end),
      "on_battery_only": onBatteryOnly, "apps": apps,
    ]
    return try? JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }
}

// MARK: - State

@MainActor
final class HeliosEnergyPageState: ObservableObject {
  @Published var range: HeliosEnergyRange = .twentyFourHours
  @Published var customStart = Date().addingTimeInterval(-86_400)
  @Published var customEnd = Date()
  @Published var onBatteryOnly = true
  @Published var selectedAppKey: String?

  func window(now: Date = Date()) -> DateInterval {
    if let seconds = range.seconds { return DateInterval(start: now.addingTimeInterval(-seconds), end: now) }
    let start = min(customStart, customEnd)
    // A custom range is at least five minutes long, so a chart always has a span.
    return DateInterval(start: start, end: max(customEnd, start.addingTimeInterval(300)))
  }

  private struct AnalysisKey: Equatable {
    let bucketCount: Int
    let first: Date?
    let last: Date?
    let range: HeliosEnergyRange
    let customStart: Date
    let customEnd: Date
    let onBatteryOnly: Bool
    let minute: Int
  }
  private var cachedAnalysis: (key: AnalysisKey, value: HeliosEnergyAnalysis)?

  /// The analysis changes about once a minute (new buckets, the window moving), not
  /// on every one-second refresh of the page, so it is recomputed only then.
  func analysis(buckets: [AppEnergyBucket], now: Date = Date()) -> HeliosEnergyAnalysis {
    let minute = Int(now.timeIntervalSince1970 / 60)
    let key = AnalysisKey(
      bucketCount: buckets.count, first: buckets.first?.capturedAt, last: buckets.last?.capturedAt,
      range: range, customStart: customStart, customEnd: customEnd, onBatteryOnly: onBatteryOnly,
      minute: minute)
    if let cachedAnalysis, cachedAnalysis.key == key { return cachedAnalysis.value }
    let value = HeliosEnergyAnalysis.make(
      buckets: buckets, window: window(now: now), onBatteryOnly: onBatteryOnly)
    cachedAnalysis = (key, value)
    return value
  }
}

// MARK: - Page

struct HeliosEnergyPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @StateObject private var state = HeliosEnergyPageState()

  var body: some View {
    let analysis = state.analysis(buckets: model.appEnergy.buckets)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      if !context.preferences.isTelemetryCollectionRequired(.processes) {
        HeliosCollectionOffNotice(
          title: "Process monitoring is off, so app energy isn’t tracked.", module: .processes,
          preferences: context.preferences)
      }
      controls(analysis)
      tiles(analysis)
      if analysis.hasPreviousWindow { rises(analysis) }
      HeliosSection("Battery level") { levelChart(analysis) }
      HStack(alignment: .top, spacing: 16) {
        HeliosSection("Energy by app") { ranking(analysis) }
          .frame(minWidth: 280, idealWidth: 330, maxWidth: 360)
        HeliosSection("Selected app") { detail(analysis) }
      }
      Label(
        "Relative local attribution only. System processes can be absent, apps that ran less than a minute may be missed, and process-accounted energy does not equal whole-system battery drain.",
        systemImage: "info.circle")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Controls

  private func controls(_ analysis: HeliosEnergyAnalysis) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Picker("Range", selection: $state.range) {
          ForEach(HeliosEnergyRange.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().pickerStyle(.segmented).fixedSize()
        .accessibilityLabel("Energy history range")
        Spacer(minLength: 8)
        Menu("Export") {
          Button("CSV…") { export(analysis, json: false) }
          Button("JSON…") { export(analysis, json: true) }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .disabled(analysis.entries.isEmpty)
      }
      Toggle("On battery only", isOn: $state.onBatteryOnly)
        .toggleStyle(.checkbox)
        .help("Count only the time the Mac ran on battery")
      if state.range == .custom {
        HStack(spacing: 10) {
          DatePicker("From", selection: $state.customStart, in: ...Date(),
            displayedComponents: [.date, .hourAndMinute])
          DatePicker("To", selection: $state.customEnd, in: ...Date(),
            displayedComponents: [.date, .hourAndMinute])
          Spacer(minLength: 0)
        }
        .datePickerStyle(.compact)
      }
    }
  }

  // MARK: Tiles

  private func tiles(_ analysis: HeliosEnergyAnalysis) -> some View {
    let battery = try? model.presentation.battery.get()
    return HStack(alignment: .top, spacing: 12) {
      HeliosStatTile(
        title: "Battery now",
        value: (try? battery?.stateOfChargePercent.get()).map { TelemetryFormatting.percent($0) } ?? "—",
        caption: (try? battery?.powerSource.get())?.rawValue ?? "Power source unavailable")
      HeliosStatTile(
        title: "Live flow",
        value: (try? battery?.power.get()).map { TelemetryFormatting.watts($0.signedWatts, signed: true) } ?? "—",
        caption: "− discharging · + charging")
      HeliosStatTile(
        title: "Battery change",
        value: analysis.batteryChangePoints.map { String(format: "%+.1f%%", $0) } ?? "—",
        caption: "over observed on-battery time")
      HeliosStatTile(
        title: "Not observed",
        value: analysis.unobservedSeconds > 0 ? TelemetryFormatting.duration(analysis.unobservedSeconds) : "None",
        caption: "asleep or Helios closed")
    }
  }

  // MARK: Rises

  private func rises(_ analysis: HeliosEnergyAnalysis) -> some View {
    HeliosSection("Compared with the period before") {
      HeliosGroup {
        if analysis.rises.isEmpty {
          Text("No app stands out against the equally long period before.")
            .foregroundStyle(.secondary).padding(.vertical, 8)
        } else {
          ForEach(Array(analysis.rises.enumerated()), id: \.element.id) { index, rise in
            Button { state.selectedAppKey = rise.appKey } label: {
              HStack(spacing: 8) {
                HeliosAppIdentityIcon(appKey: rise.appKey, size: 20)
                Text(rise.displayName).lineLimit(1)
                Spacer(minLength: 8)
                Text(riseText(rise)).monospacedDigit().foregroundStyle(.orange)
              }
              .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if index < analysis.rises.count - 1 { Divider() }
          }
        }
      }
    }
  }

  private func riseText(_ rise: HeliosEnergyRise) -> String {
    let extra = energy(rise.extraWattHours)
    guard let percent = rise.changePercent else { return "+\(extra) · not used before" }
    return String(format: "+%@ · +%.0f%%", extra, percent)
  }

  // MARK: Chart

  private func levelChart(_ analysis: HeliosEnergyAnalysis) -> some View {
    let points = analysis.buckets.map { bucket -> HeliosEnergyChart.Point in
      let show = !state.onBatteryOnly || bucket.onBattery == true
      return .init(date: bucket.capturedAt, value: show ? bucket.batteryPercent : nil)
    }
    return Group {
      if points.contains(where: { $0.value != nil }) {
        HeliosEnergyChart(
          points: points, window: analysis.window, gaps: analysis.unobserved,
          fixedRange: 0...100, tint: context.preferences.color(for: .battery),
          title: "Battery level", format: { TelemetryFormatting.percent($0) })
          .frame(height: 140)
      } else {
        HeliosEmptyState(
          symbol: "battery.50percent", title: "No battery-level history in this range")
      }
    }
  }

  // MARK: Ranking

  private func ranking(_ analysis: HeliosEnergyAnalysis) -> some View {
    let total = analysis.entries.reduce(0) { $0 + $1.energyWattHours }
    let selected = selectedKey(analysis)
    return HeliosGroup {
      if analysis.entries.isEmpty {
        Text(state.onBatteryOnly
          ? "No on-battery history in this range yet. Use the Mac on battery while Helios runs."
          : "No app history in this range yet.")
          .foregroundStyle(.secondary).padding(.vertical, 8)
      } else {
        ForEach(Array(analysis.entries.prefix(15).enumerated()), id: \.element.id) { index, entry in
          Button { state.selectedAppKey = entry.appKey } label: {
            rankRow(rank: index + 1, entry: entry, total: total, selected: entry.appKey == selected)
          }
          .buttonStyle(.plain)
          if index < min(14, analysis.entries.count - 1) { Divider() }
        }
      }
    }
  }

  private func rankRow(rank: Int, entry: AppEnergyEntry, total: Double, selected: Bool) -> some View {
    let share = total > 0 ? entry.energyWattHours / total : 0
    return HStack(spacing: 8) {
      Text("\(rank)").font(.subheadline.monospacedDigit()).foregroundStyle(.tertiary)
        .frame(width: 22, alignment: .trailing)
      HeliosAppIdentityIcon(appKey: entry.appKey, size: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.displayName).lineLimit(1)
        ProgressView(value: min(1, max(0, share))).progressViewStyle(.linear).tint(.orange)
      }
      Spacer(minLength: 6)
      VStack(alignment: .trailing, spacing: 1) {
        Text(TelemetryFormatting.percent(share * 100)).monospacedDigit()
        Text(energy(entry.energyWattHours)).font(.subheadline.monospacedDigit()).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 5).padding(.horizontal, 4)
    .background(selected ? Color.accentColor.opacity(0.12) : .clear,
      in: RoundedRectangle(cornerRadius: 6))
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  // MARK: Selected app

  private func selectedKey(_ analysis: HeliosEnergyAnalysis) -> String? {
    if let key = state.selectedAppKey, analysis.entries.contains(where: { $0.appKey == key }) { return key }
    return analysis.entries.first?.appKey
  }

  @ViewBuilder
  private func detail(_ analysis: HeliosEnergyAnalysis) -> some View {
    if let key = selectedKey(analysis), let entry = analysis.entries.first(where: { $0.appKey == key }) {
      let total = analysis.entries.reduce(0) { $0 + $1.energyWattHours }
      let points = analysis.buckets.map { bucket -> HeliosEnergyChart.Point in
        let show = !state.onBatteryOnly || bucket.onBattery == true
        let value = show ? bucket.entries.first(where: { $0.appKey == key })?.energyWattHours : nil
        return .init(date: bucket.capturedAt, value: value.map { $0 * 1_000 })
      }
      VStack(alignment: .leading, spacing: 10) {
        HeliosGroup {
          HStack(spacing: 10) {
            HeliosAppIdentityIcon(appKey: entry.appKey, size: 32)
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.displayName).font(.headline).lineLimit(1)
              Text(total > 0
                ? String(format: "%.1f%% of tracked app energy", entry.energyWattHours / total * 100)
                : "Share unavailable")
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(energy(entry.energyWattHours)).font(.title3.weight(.semibold)).monospacedDigit()
          }
          .padding(.vertical, 8)
          Divider()
          HeliosFactRow(label: "CPU time", value: TelemetryFormatting.duration(entry.cpuCoreSeconds))
          HeliosFactRow(label: "Wakeups", value: String(format: "%.0f", entry.wakeups))
          HeliosFactRow(label: "Peak memory",
            value: TelemetryFormatting.storageBytes(entry.peakMemoryBytes), showsDivider: false)
        }
        HeliosEnergyChart(
          points: points, window: analysis.window, gaps: analysis.unobserved, fixedRange: nil,
          tint: context.preferences.color(for: .energy), title: entry.displayName,
          format: { String(format: "%.1f mWh", $0) })
          .frame(height: 120)
        appActions(entry)
      }
    } else {
      HeliosGroup {
        Text("Select an app on the left to see its timeline.")
          .foregroundStyle(.secondary).padding(.vertical, 8)
      }
    }
  }

  @ViewBuilder
  private func appActions(_ entry: AppEnergyEntry) -> some View {
    if HeliosAppActions.bundlePath(forKey: entry.appKey) != nil {
      let running = HeliosAppActions.runningApplication(forKey: entry.appKey) != nil
      HStack(spacing: 8) {
        Button("Quit") { HeliosAppActions.quit(entry.appKey) }.disabled(!running)
        Button("Force Quit…") {
          HeliosAppActions.forceQuit(entry.appKey, displayName: entry.displayName)
        }
        .disabled(!running)
        Menu("More") {
          Button("Show in Finder") { HeliosAppActions.revealInFinder(entry.appKey) }
          Button("Open Activity Monitor") { HeliosAppActions.openActivityMonitor() }
        }
        .menuStyle(.borderlessButton).fixedSize()
        Spacer(minLength: 0)
        if !running { Text("Not running").font(.subheadline).foregroundStyle(.tertiary) }
      }
      .controlSize(.small)
    }
  }

  // MARK: Export

  private func export(_ analysis: HeliosEnergyAnalysis, json: Bool) {
    HeliosFileExport.save(
      suggestedName: "helios-app-energy.\(json ? "json" : "csv")", type: json ? .json : .commaSeparatedText
    ) {
      json
        ? HeliosEnergyJSON.make(entries: analysis.entries, window: analysis.window, onBatteryOnly: state.onBatteryOnly)
        : HeliosEnergyCSV.make(entries: analysis.entries).data(using: .utf8)
    }
  }

  private func energy(_ wattHours: Double) -> String {
    guard wattHours.isFinite, wattHours >= 0 else { return "—" }
    return wattHours < 1 ? String(format: "%.1f mWh", wattHours * 1_000) : String(format: "%.2f Wh", wattHours)
  }
}

// MARK: - Chart

/// A line over a time window with the unobserved stretches shaded and a hover
/// readout. Drawn directly: it spans days, which the shared live chart does not.
struct HeliosEnergyChart: View {
  struct Point: Equatable {
    let date: Date
    let value: Double?
  }

  let points: [Point]
  let window: DateInterval
  let gaps: [DateInterval]
  let fixedRange: ClosedRange<Double>?
  let tint: Color
  let title: String
  let format: (Double) -> String
  @State private var hover: CGFloat?

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let scale = valueScale()
      ZStack(alignment: .topLeading) {
        Canvas { context, size in
          for gap in gaps {
            let left = x(gap.start, size.width)
            let right = x(gap.end, size.width)
            context.fill(
              Path(CGRect(x: left, y: 0, width: max(1, right - left), height: size.height)),
              with: .color(.secondary.opacity(0.14)))
          }
          var path = Path()
          var previous: Point?
          for point in points {
            guard let value = point.value, point.date >= window.start, point.date <= window.end else {
              previous = nil
              continue
            }
            let location = CGPoint(
              x: x(point.date, size.width), y: y(value, size.height, scale))
            if let previous, !crossesGap(previous.date, point.date) {
              path.addLine(to: location)
            } else {
              path.move(to: location)
              // A lone sample still shows as a dot.
              path.addLine(to: CGPoint(x: location.x + 0.01, y: location.y))
            }
            previous = point
          }
          context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        axisLabels
        if let hover { readout(at: hover, size: size, scale: scale) }
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let location): hover = location.x
        case .ended: hover = nil
        }
      }
    }
    .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title) history")
    .accessibilityValue(
      points.last(where: { $0.value != nil })?.value.map(format) ?? "No data")
  }

  private var axisLabels: some View {
    VStack {
      HStack {
        Text(label(window.start)); Spacer(); Text(label(window.end))
      }
      .font(.caption2).foregroundStyle(.tertiary)
      .padding(.horizontal, 6).padding(.top, 4)
      Spacer(minLength: 0)
    }
    .allowsHitTesting(false)
  }

  private func label(_ date: Date) -> String {
    // Up to half a day the clock time is unambiguous; longer windows need the day too.
    window.duration <= 12 * 3_600
      ? date.formatted(.dateTime.hour().minute())
      : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
  }

  private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
    guard window.duration > 0 else { return 0 }
    return width * CGFloat(date.timeIntervalSince(window.start) / window.duration)
  }

  private func valueScale() -> ClosedRange<Double> {
    if let fixedRange { return fixedRange }
    let values = points.compactMap(\.value)
    guard let low = values.min(), let high = values.max() else { return 0...1 }
    return high > low ? 0...high * 1.1 : 0...max(1, high * 1.5)
  }

  private func y(_ value: Double, _ height: CGFloat, _ scale: ClosedRange<Double>) -> CGFloat {
    let span = max(0.0001, scale.upperBound - scale.lowerBound)
    let inset: CGFloat = 18
    return inset + (height - inset - 6) * CGFloat(1 - (value - scale.lowerBound) / span)
  }

  private func crossesGap(_ start: Date, _ end: Date) -> Bool {
    gaps.contains { $0.start >= start.addingTimeInterval(-1) && $0.end <= end.addingTimeInterval(1) }
  }

  @ViewBuilder
  private func readout(at location: CGFloat, size: CGSize, scale: ClosedRange<Double>) -> some View {
    let date = window.start.addingTimeInterval(window.duration * Double(max(0, min(1, location / max(1, size.width)))))
    let inGap = gaps.contains { $0.contains(date) }
    let nearest = points.filter { $0.value != nil }.min {
      abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
    }
    let text = inGap ? "Not observed" : (nearest?.value.map(format) ?? "—")
    ZStack(alignment: .topLeading) {
      Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: size.height).offset(x: location)
      Text("\(label(date)) · \(text)")
        .font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        .offset(x: min(max(4, location + 8), max(4, size.width - 150)), y: 22)
    }
    .allowsHitTesting(false)
  }
}
