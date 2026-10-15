import SwiftUI

/// Longevity: how the battery, adapter, SSD, cooling and memory are holding up over months,
/// as word grades with the facts behind them (PLAN_0_3_0 M5, decision 5: no bare score).
struct HeliosLongevityPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @ObservedObject private var center = HeliosLongevityCenter.shared

  init(context: HeliosContext, model: OverviewViewModel) {
    self.context = context
    self.model = model
  }

  var body: some View {
    let report = center.report(snapshot: model.snapshot, battery: model.batteryHealth)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      header(report)
      HeliosLongevityGlance(report: report)
      ForEach(report.areas) { area in
        HeliosSection(area.kind.title) {
          HeliosLongevityGradeChip(grade: area.grade)
        } content: {
          VStack(alignment: .leading, spacing: 10) {
            Text(area.summary).fixedSize(horizontal: false, vertical: true)
            chart(for: area.kind)
            if !area.facts.isEmpty {
              HeliosGroup {
                ForEach(Array(area.facts.enumerated()), id: \.offset) { index, fact in
                  HeliosFactRow(label: fact.label, value: fact.value, detail: fact.detail,
                    showsDivider: index < area.facts.count - 1)
                }
              }
            }
            if let estimate = area.estimate {
              Label(estimate, systemImage: "chart.line.uptrend.xyaxis")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let advice = area.advice {
              Label(advice, systemImage: "lightbulb")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      reminders
    }
    .onAppear { center.refreshAdapter() }
  }

  private func header(_ report: LongevityReport) -> some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: HeliosLongevityGradeChip.symbol(report.overall))
            .foregroundStyle(HeliosLongevityGradeChip.color(report.overall))
            .accessibilityHidden(true)
          Text(report.overall?.title ?? "Learning")
        }
        .font(.title3.weight(.semibold))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Overall: \(report.overall?.title ?? "Learning")")
        Text(report.overallSummary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("Grades compare this Mac with its own history. Everything stays on this Mac.")
          .font(.subheadline).foregroundStyle(.tertiary)
      }
      Spacer(minLength: 16)
      Menu("Export Report") {
        Button("PDF…") { export(report, .pdf) }
        Button("HTML…") { export(report, .html) }
      }
      .fixedSize()
      .help("Saves a report of the last week. Nothing is sent anywhere.")
    }
  }

  @ViewBuilder
  private func chart(for kind: LongevityAreaKind) -> some View {
    switch kind {
    case .battery:
      HeliosBatteryTrend(summary: model.batteryHealth)
    case .storage:
      let bars = HeliosLongevityBars.dailyWrites(center.days)
      if bars.count >= 3 {
        HeliosLongevityBars(title: "Written per day", values: bars, format: LongevityEngine.bytes)
      }
    case .cooling:
      let weeks = HeliosLongevityBars.weeklyBusyTemperature(center.days)
      if weeks.count >= 2 {
        HeliosLongevityBars(title: "Temperature under load, weekly", values: weeks,
          format: { TelemetryFormatting.temperature($0) }, relative: true)
      }
    case .charger, .memory:
      EmptyView()
    }
  }

  private var reminders: some View {
    HeliosSection("Reminders") {
      HeliosGroup {
        Toggle(isOn: $center.unplugReminder) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Tell me when the battery reaches 80 % while charging")
            Text("Advice only. Helios never changes how your Mac charges.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 7)
        Divider()
        Toggle(isOn: $center.weeklySummary) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Weekly health summary")
            Text("A notification once a week with the overall grade.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 7)
      }
    }
  }

  private func export(_ report: LongevityReport, _ format: HeliosLongevityExport.Format) {
    let system = try? model.snapshot.system.result.get()
    let machine = [try? system?.modelIdentifier.get(), try? system?.chipName.get(), system.map { "macOS \($0.osVersion)" }]
      .compactMap { $0 ?? nil }.joined(separator: " · ")
    HeliosLongevityExport.save(report, machine: machine.isEmpty ? "Mac" : machine, format: format)
  }
}

/// One tile per area: the grade at a glance.
private struct HeliosLongevityGlance: View {
  let report: LongevityReport

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ForEach(report.areas) { area in
        VStack(alignment: .leading, spacing: 6) {
          Label(area.kind.title, systemImage: area.kind.symbol)
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          HeliosLongevityGradeChip(grade: area.grade, large: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heliosGroupSurface()
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// A grade as symbol + word, never color alone.
struct HeliosLongevityGradeChip: View {
  let grade: LongevityGrade?
  var large = false

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: Self.symbol(grade))
        .font(.system(size: large ? 12 : 9, weight: .semibold))
        .foregroundStyle(Self.color(grade))
        .accessibilityHidden(true)
      Text(grade?.title ?? "Not graded yet")
        .foregroundStyle(grade == .attention ? Self.color(grade) : (grade == nil ? .secondary : .primary))
        .lineLimit(1).minimumScaleFactor(0.8)
    }
    .font(large ? .body.weight(.semibold) : .subheadline)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Grade: \(grade?.title ?? "not enough data yet")")
  }

  static func symbol(_ grade: LongevityGrade?) -> String {
    switch grade {
    case .excellent: "checkmark.seal.fill"
    case .good: "checkmark.circle.fill"
    case .attention: "exclamationmark.triangle.fill"
    case nil: "hourglass"
    }
  }

  static func color(_ grade: LongevityGrade?) -> Color {
    switch grade {
    case .excellent: .green
    case .good: .blue
    case .attention: .orange
    case nil: .secondary
    }
  }
}

/// Small bar chart without a charting framework: a few dozen bars at most.
struct HeliosLongevityBars: View {
  let title: String
  let values: [(label: String, value: Double)]
  let format: (Double) -> String
  /// Bars start at the lowest value instead of zero (temperatures).
  var relative = false

  var body: some View {
    let high = values.map(\.value).max() ?? 1
    let low = relative ? max(0, (values.map(\.value).min() ?? 0) - 3) : 0
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.subheadline).foregroundStyle(.secondary)
        Spacer()
        if let last = values.last { Text(format(last.value)).font(.subheadline).monospacedDigit() }
      }
      GeometryReader { geometry in
        HStack(alignment: .bottom, spacing: 2) {
          ForEach(Array(values.enumerated()), id: \.offset) { _, item in
            RoundedRectangle(cornerRadius: 2)
              .fill(Color.accentColor.opacity(0.7))
              .frame(height: max(2, geometry.size.height * (item.value - low) / max(0.001, high - low)))
              .help("\(item.label): \(format(item.value))")
          }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
      }
      .frame(height: 60)
      HStack {
        Text(values.first?.label ?? "")
        Spacer()
        Text(values.last?.label ?? "")
      }
      .font(.caption).foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(values.last.map { "Latest \(format($0.value))" } ?? "No data")
  }

  /// Daily writes from the SSD's lifetime counter, last 30 days.
  static func dailyWrites(_ days: [LongevityDayRecord]) -> [(label: String, value: Double)] {
    let points = days.suffix(31).compactMap { day in day.ssdLifetimeWrittenBytes.map { (day.day, $0) } }
    return zip(points, points.dropFirst()).compactMap { previous, next in
      let span = next.0.timeIntervalSince(previous.0) / 86_400
      guard span > 0, next.1 >= previous.1 else { return nil }
      return (next.0.formatted(.dateTime.month(.abbreviated).day()), (next.1 - previous.1) / span)
    }
  }

  /// Mean temperature under load per calendar week, weeks with at least 20 busy minutes.
  static func weeklyBusyTemperature(_ days: [LongevityDayRecord], calendar: Calendar = .current)
    -> [(label: String, value: Double)]
  {
    var weeks: [Date: (seconds: Double, celsius: Double)] = [:]
    for day in days where day.busySeconds > 0 {
      guard let week = calendar.dateInterval(of: .weekOfYear, for: day.day)?.start else { continue }
      let current = weeks[week] ?? (0, 0)
      weeks[week] = (current.seconds + day.busySeconds, current.celsius + day.busyCelsiusSeconds)
    }
    return weeks.filter { $0.value.seconds >= 1_200 }.sorted { $0.key < $1.key }.suffix(12).map {
      ($0.key.formatted(.dateTime.month(.abbreviated).day()), $0.value.celsius / $0.value.seconds)
    }
  }
}

/// Overview row: the overall longevity grade, one click from the page.
struct HeliosLongevitySummaryRow: View {
  @ObservedObject var model: OverviewViewModel
  @ObservedObject private var center = HeliosLongevityCenter.shared
  let open: () -> Void

  var body: some View {
    let report = center.report(snapshot: model.snapshot, battery: model.batteryHealth)
    Button(action: open) {
      HStack(spacing: 10) {
        Image(systemName: "heart.text.square").foregroundStyle(.secondary).accessibilityHidden(true)
        Text("Longevity")
        Spacer()
        HeliosLongevityGradeChip(grade: report.overall)
        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .heliosGroupSurface()
    .help(report.overallSummary)
    .accessibilityLabel("Longevity: \(report.overall?.title ?? "not graded yet"). \(report.overallSummary)")
    .accessibilityHint("Shows Longevity")
  }
}
