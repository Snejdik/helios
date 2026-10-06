import SwiftUI

struct HeliosOverviewPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var interface: HeliosInterfacePreferences
  @ObservedObject var feed: HeliosActivityFeed
  let navigation: HeliosNavigation

  var body: some View {
    let assessment = HeliosMacAssessment.evaluate(
      model.snapshot, configuration: context.preferences.healthAlerts)
    let automatic = assessment.focus.flatMap { assessment.area($0)?.chartMetric } ?? .cpu
    let metric = interface.overviewChartMetric ?? automatic
    let range = context.preferences.graphRange(for: .overview)
    VStack(alignment: .leading, spacing: 20) {
      if let diagnosticsPreferences = context.diagnosticsPreferences {
        HeliosDiagnosticsReminder(
          diagnosticsPreferences: diagnosticsPreferences, interface: interface,
          review: { context.actions.openSettingsRoute(.privacy) })
      }
      HeliosOverviewHero(assessment: assessment)
      HeliosAreaStrip(assessment: assessment) { navigation.selection = HeliosPage(focus: $0) }
      HeliosChartPanel(
        metric: metric, model: model, preferences: context.preferences, scope: .overview,
        height: 140, markers: feed.markers(for: metric, range: range),
        metricChoice: HeliosChartPanel.MetricChoice(
          selected: $interface.overviewChartMetric, automatic: automatic,
          available: HeliosChartMetric.available(in: model.presentation)))
      HStack(alignment: .top, spacing: 28) {
        HeliosRightNowSection(context: context, presentation: model.presentation, limit: 3)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        HeliosRecentSection(events: Array(feed.recent(3))) {
          navigation.selection = .activity
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      if HeliosCooling.hasFans(model.presentation) {
        HeliosCoolingSummaryRow(context: context, presentation: model.presentation) {
          navigation.selection = .thermals
        }
      }
    }
  }
}

/// Sun + one answer + one sentence. A problem takes over the answer, never the layout.
struct HeliosOverviewHero: View {
  let assessment: HeliosMacAssessment
  var compact = false

  var body: some View {
    HStack(alignment: .top, spacing: compact ? 10 : 14) {
      HeliosSunGlyph(status: assessment.overall, size: compact ? 26 : 38)
      VStack(alignment: .leading, spacing: 3) {
        Text(assessment.title)
          .font(compact ? .title3.weight(.semibold) : .title.weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        Text(assessment.subtitle)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !compact, let focus = assessment.focus, let area = assessment.area(focus) {
          HeliosWhyDisclosure(assessment: area, meaning: HeliosCopy.meaning(focus))
            .padding(.top, 4)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(assessment.title). \(assessment.subtitle)")
  }
}

/// The four Health areas on one surface (not four cards).
struct HeliosAreaStrip: View {
  let assessment: HeliosMacAssessment
  let onSelect: (HeliosAreaAssessment) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(assessment.areas.enumerated()), id: \.element.id) { index, area in
        if index > 0 { Divider().padding(.vertical, 8) }
        Button { onSelect(area) } label: {
          VStack(alignment: .leading, spacing: 4) {
            Label(area.area.title, systemImage: area.area.symbol)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            HeliosStatusLabel(status: area.status)
            Text(area.value ?? (area.status == .notPresent ? "No battery" : "—"))
              .font(.title3)
              .monospacedDigit()
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(area.explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(area.area.title): \(area.status.label)\(area.value.map { ", \($0)" } ?? "")")
        .accessibilityHint("Shows \(area.area.title)")
        .accessibilityAddTraits(.isButton)
      }
    }
    .heliosGroupSurface()
  }
}

/// Top processes by share of total CPU. Correlation only; never "the cause".
struct HeliosRightNowSection: View {
  let context: HeliosContext
  let presentation: OverviewPresentation
  let limit: Int
  var title = "Right now"

  var body: some View {
    HeliosSection(title) {
      HeliosRightNowList(context: context, presentation: presentation, limit: limit, grouped: false)
    }
  }
}

/// App-centric row: processes grouped by their outermost application bundle, so
/// "Claude Helper (Renderer)" counts toward "Claude". Built from the bounded
/// leader list only, so it is the share of the listed processes, not every one.
struct HeliosProcessRow: Identifiable, Equatable {
  let id: String
  let name: String
  let appKey: String
  let cpuShare: Double?
  let memoryBytes: UInt64
  let processNames: [String]
  let process: ProcessActivity

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.cpuShare == rhs.cpuShare && lhs.memoryBytes == rhs.memoryBytes
      && lhs.processNames == rhs.processNames
  }

  static func rows(_ processes: [ProcessActivity], system: MetricResult<SystemMetrics>, limit: Int)
    -> [HeliosProcessRow]
  {
    let logical = (try? system.get().logicalProcessorCount).map { max(1, $0) }
      ?? max(1, ProcessInfo.processInfo.processorCount)
    var order: [String] = []
    var groups: [String: HeliosProcessRow] = [:]
    for process in processes {
      let identity = HeliosAppIdentity.of(process)
      let share = TelemetryFormatting.processCPUSharePercent(
        process.cpuPercent, logicalProcessorCount: logical)
      if let existing = groups[identity.key] {
        let combined: Double? = switch (existing.cpuShare, share) {
        case (nil, nil): nil
        case (let a?, nil): a
        case (nil, let b?): b
        case (let a?, let b?): min(100, a + b)
        }
        let memory = existing.memoryBytes.addingReportingOverflow(process.physicalFootprintBytes)
        groups[identity.key] = HeliosProcessRow(
          id: existing.id, name: existing.name, appKey: existing.appKey, cpuShare: combined,
          memoryBytes: memory.overflow ? .max : memory.partialValue,
          processNames: existing.processNames + [process.name], process: existing.process)
      } else {
        order.append(identity.key)
        groups[identity.key] = HeliosProcessRow(
          id: identity.key, name: identity.name, appKey: identity.key, cpuShare: share,
          memoryBytes: process.physicalFootprintBytes, processNames: [process.name],
          process: process)
      }
    }
    return order.compactMap { groups[$0] }
      .sorted { ($0.cpuShare ?? -1) > ($1.cpuShare ?? -1) }
      .prefix(limit).map { $0 }
  }
}

struct HeliosProcessRowView: View {
  let row: HeliosProcessRow

  var body: some View {
    HStack(spacing: 8) {
      HeliosAppIdentityIcon(appKey: row.appKey, size: 18)
      Text(row.name).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 8)
      Text(row.cpuShare.map { TelemetryFormatting.percent($0, decimals: 1) } ?? "—")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .help(row.processNames.count > 1
      ? row.processNames.joined(separator: ", ") : row.processNames.first ?? row.name)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(row.name), \(row.cpuShare.map { TelemetryFormatting.percent($0, decimals: 1) } ?? "unknown") of CPU")
    .heliosProcessCopyActions(row.process)
  }
}

struct HeliosRecentSection: View {
  let events: [HeliosActivityEvent]
  var title = "Recent"
  let showAll: () -> Void

  var body: some View {
    HeliosSection(title, accessory: {
      Button("Show All", action: showAll).buttonStyle(.link).font(.subheadline)
    }) {
      if events.isEmpty {
        Text("Nothing notable recently.").foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(events) { event in HeliosEventLine(event: event) }
        }
      }
    }
  }
}

/// Compact one-line event: time · symbol · title.
struct HeliosEventLine: View {
  let event: HeliosActivityEvent

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(HeliosCopy.shortTime(event.date))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minWidth: 44, alignment: .leading)
      Image(systemName: HeliosCopy.symbol(event))
        .font(.system(size: 11))
        .foregroundStyle(HeliosDesign.toneColor(event.tone))
        .accessibilityHidden(true)
      Text(event.title).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

enum HeliosCooling {
  static func hasFans(_ presentation: OverviewPresentation) -> Bool {
    if case .success(let inventory) = presentation.fans { return !inventory.fans.isEmpty }
    return false
  }

  /// "Range 2317–6550 RPM", when the fan reports both factory limits.
  static func rangeText(_ fan: FanReading) -> String? {
    guard case .success(let minimum) = fan.minimumRPM, case .success(let maximum) = fan.maximumRPM
    else { return nil }
    return "Range \(Int(minimum))–\(Int(maximum)) RPM"
  }

  static func isFanless(_ presentation: OverviewPresentation) -> Bool {
    if case .success(let inventory) = presentation.fans { return inventory.fans.isEmpty }
    return false
  }

  static func modeTitle(_ selection: FanControlSelection) -> String {
    switch selection {
    case .system: "System"
    case .boost: "Boost"
    case .override: "Manual"
    case .auto: "Automatic Rules"
    }
  }
}

/// Read-only cooling status on Overview; changes happen on Thermals.
struct HeliosCoolingSummaryRow: View {
  let context: HeliosContext
  let presentation: OverviewPresentation
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Image(systemName: "fan").foregroundStyle(.secondary).accessibilityHidden(true)
        Text("Cooling")
        Spacer()
        Text(summary).monospacedDigit().foregroundStyle(.secondary)
        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .heliosGroupSurface()
    .accessibilityLabel("Cooling: \(summary)")
    .accessibilityHint("Shows Thermals")
  }

  private var summary: String {
    let mode = context.service.map { HeliosCooling.modeTitle($0.fanControl.selection) } ?? "System"
    let fans: String
    if case .success(let inventory) = presentation.fans {
      fans = TelemetryFormatting.fanSummary(inventory)
    } else {
      fans = "—"
    }
    return "\(mode) · \(fans)"
  }
}

extension HeliosChartMetric {
  /// Metrics worth offering on this Mac (no fan chart on a fanless Mac, etc.).
  static func available(in presentation: OverviewPresentation) -> [HeliosChartMetric] {
    allCases.filter { metric in
      switch metric {
      case .fan: HeliosCooling.hasFans(presentation)
      case .battery:
        if case .failure(let error) = presentation.battery {
          error != HeliosMacAssessment.batteryAbsentError
        } else {
          true
        }
      default: true
      }
    }
  }
}
