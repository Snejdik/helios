import SwiftUI

/// Events only: health issues, power changes and daily peaks. Charts live on History.
struct HeliosActivityPage: View {
  @ObservedObject var feed: HeliosActivityFeed
  @State private var filter: HeliosActivityFilter = .all
  @State private var problemsOnly = false

  var body: some View {
    let events = feed.events.filter { filter.includes($0, problemsOnly: problemsOnly) }
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Picker("Area", selection: $filter) {
          ForEach(HeliosActivityFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Show events for")
        Toggle("Problems only", isOn: $problemsOnly)
          .toggleStyle(.checkbox)
        Spacer(minLength: 0)
      }
      if events.isEmpty {
        HeliosEmptyState(
          symbol: "list.bullet.rectangle", title: "No events",
          message: filter == .all && !problemsOnly
            ? "Health events, power changes and daily peaks appear here."
            : "Nothing for this filter in the last days.")
      } else {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(HeliosActivityDay.group(events)) { day in
            VStack(alignment: .leading, spacing: 6) {
              Text(HeliosCopy.dayTitle(day.date))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
              HeliosGroup {
                ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                  HeliosTimelineRow(event: event)
                  if index < day.events.count - 1 { Divider() }
                }
              }
            }
          }
        }
      }
      Text("Activity is built from what Helios already keeps on this Mac: health events (7 days) and 30-second history (24 hours). Events are recorded only while Helios is running.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Charts for one metric at a time over the retained history, with the events from
/// Activity marked on them.
struct HeliosHistoryPage: View {
  let context: HeliosContext
  /// Not observed here: the chart panel observes the 1 Hz model itself.
  let model: OverviewViewModel
  @ObservedObject var feed: HeliosActivityFeed
  @State private var metric: HeliosChartMetric = .temperature
  @State private var range: HeliosGraphRange = .twentyFourHours

  private static let chartMetrics: [HeliosChartMetric] = [.temperature, .cpu, .memory, .power, .battery]

  var body: some View {
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      Picker("Metric", selection: $metric) {
        ForEach(Self.chartMetrics) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      HeliosChartPanel(
        metric: metric, model: model, preferences: context.preferences, scope: .history,
        height: 240, markers: feed.markers(for: metric, range: range), localRange: $range)
      Text("Dashed lines mark health events and power changes from Activity. History covers the last 24 hours at 30-second resolution and is recorded only while Helios is running.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct HeliosActivityDay: Identifiable {
  let date: Date
  let events: [HeliosActivityEvent]
  var id: Date { date }

  /// Events arrive newest first; days keep that order.
  static func group(_ events: [HeliosActivityEvent], calendar: Calendar = .current) -> [Self] {
    var days: [Self] = []
    var currentDay: Date?
    var bucket: [HeliosActivityEvent] = []
    for event in events {
      let day = calendar.startOfDay(for: event.date)
      if day != currentDay {
        if let currentDay { days.append(Self(date: currentDay, events: bucket)) }
        currentDay = day
        bucket = []
      }
      bucket.append(event)
    }
    if let currentDay { days.append(Self(date: currentDay, events: bucket)) }
    return days
  }
}

private struct HeliosTimelineRow: View {
  let event: HeliosActivityEvent

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(event.date.formatted(.dateTime.hour().minute()))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .leading)
      Image(systemName: HeliosCopy.symbol(event))
        .foregroundStyle(HeliosDesign.toneColor(event.tone))
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(event.title)
        if let detail = event.detail {
          Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if let duration = event.duration {
        Text(HeliosCopy.duration(duration))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 7)
    .accessibilityElement(children: .combine)
  }
}
