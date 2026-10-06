import SwiftUI

extension HeliosChartMetric {
  var colorRole: HeliosColorRole {
    switch self {
    case .cpu: .cpu
    case .gpu: .gpu
    case .memory: .memory
    case .temperature: .temperature
    case .power: .power
    case .fan: .fan
    case .battery: .battery
    case .network: .networkDownload
    case .networkUpload: .networkUpload
    case .disk: .storageWrite
    }
  }

  var valueStyle: HeliosChartValueStyle {
    switch self {
    case .cpu, .gpu, .memory, .battery: .percent
    case .temperature: .celsius
    case .power: .watts
    case .fan: .rpm
    case .network, .networkUpload, .disk: .bytesPerSecond
    }
  }

  var fixedRange: ClosedRange<Double>? {
    switch self {
    case .cpu, .gpu, .memory, .battery: 0...100
    case .temperature: 20...100
    default: nil
    }
  }

  /// Live (1 Hz) and persistent (30 s) history accessors for the same quantity.
  func liveValue(_ point: TelemetryHistoryPoint) -> Double? {
    switch self {
    case .cpu: point.cpuPercent
    case .gpu: point.gpuPercent
    case .memory: point.memoryPercent
    case .temperature: point.maxSoCCelsius
    case .power: point.systemPowerWatts
    case .fan: point.fanRPM
    case .battery: point.batteryPercent
    case .network: point.networkDownloadBytesPerSecond
    case .networkUpload: point.networkUploadBytesPerSecond
    case .disk: Self.sum(point.storageReadBytesPerSecond, point.storageWriteBytesPerSecond)
    }
  }

  func persistentValue(_ point: PersistedTelemetryPoint) -> Double? {
    switch self {
    case .cpu: point.cpuPercent
    case .gpu: point.gpuPercent
    case .memory: point.memoryPercent
    case .temperature: point.maxSoCCelsius
    case .power: point.systemPowerWatts
    case .fan: point.fanRPM
    case .battery: point.batteryPercent
    case .network: point.networkDownloadBytesPerSecond
    case .networkUpload: point.networkUploadBytesPerSecond
    case .disk: Self.sum(point.storageReadBytesPerSecond, point.storageWriteBytesPerSecond)
    }
  }

  private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
    guard let lhs, let rhs else { return nil }
    return lhs + rhs
  }

  /// Telemetry module that must be collected for the chart to have data.
  var module: HeliosTelemetryModule? {
    switch self {
    case .cpu: .cpu
    case .gpu: .gpu
    case .memory: .memory
    case .temperature: nil
    case .power: .power
    case .fan: .fans
    case .battery: .battery
    case .network, .networkUpload: .network
    case .disk: .storage
    }
  }
}

extension HeliosPage {
  /// Range scope shared with the Graphs & Colors settings.
  var graphScope: HeliosGraphScope {
    switch self {
    case .overview: .overview
    case .cpu: .cpu
    case .gpu: .gpu
    case .memory: .memory
    case .thermals: .thermals
    case .battery: .battery
    case .energy: .energy
    case .storage: .storage
    case .network: .network
    case .activity, .history, .diagnostics, .hardware: .history
    }
  }
}

/// A titled live chart with a native range menu. The series is derived from the
/// shared in-memory and persistent histories; nothing new is sampled.
struct HeliosChartPanel: View {
  let metric: HeliosChartMetric
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var preferences: HeliosPreferences
  let scope: HeliosGraphScope
  var height: CGFloat = 150
  var markers: [HeliosChartMarker] = []
  /// Overview offers a metric menu (Automatic or a fixed metric) instead of a title.
  var metricChoice: MetricChoice? = nil
  var showsRange = true
  /// Hides the panel when the series has data but never leaves idle (a fan that
  /// stayed off for the whole range): an empty flat chart answers nothing.
  var hidesWhenIdle = false
  /// A page-local range instead of the persisted per-scope range (Activity: 24 h).
  var localRange: Binding<HeliosGraphRange>? = nil
  /// The title and current value; an embedded panel is titled by its block.
  var showsTitle = true
  /// Draws without its own surface, to sit inside a larger grouped block.
  var bare = false

  struct MetricChoice {
    /// nil = Automatic.
    let selected: Binding<HeliosChartMetric?>
    let automatic: HeliosChartMetric
    let available: [HeliosChartMetric]
  }

  private var rangeBinding: Binding<HeliosGraphRange> {
    localRange ?? Binding(
      get: { preferences.graphRange(for: scope) },
      set: { preferences.setGraphRange($0, for: scope) })
  }

  var body: some View {
    let range = rangeBinding.wrappedValue
    let samples = HeliosChartSeries.merged(
      range: range, live: model.history.points, persistent: model.persistentHistory.points,
      liveValue: metric.liveValue, persistentValue: metric.persistentValue)
    let current = samples.last(where: { $0.value != nil })?.value
    if hidesWhenIdle, HeliosMacAssessment.fanWasIdle(samples.compactMap(\.value)) {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          if !showsTitle {
            EmptyView()
          } else if let metricChoice {
            Menu {
              Button {
                metricChoice.selected.wrappedValue = nil
              } label: {
                menuLabel("Automatic", checked: metricChoice.selected.wrappedValue == nil)
              }
              Divider()
              ForEach(metricChoice.available) { option in
                Button {
                  metricChoice.selected.wrappedValue = option
                } label: {
                  menuLabel(option.title, checked: metricChoice.selected.wrappedValue == option)
                }
              }
            } label: {
              Text(metric.title).font(.subheadline.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(metricChoice.selected.wrappedValue == nil
              ? "Automatic: follows the area that needs attention, otherwise CPU." : "Chart metric")
            .accessibilityLabel("Chart metric: \(metric.title)")
          } else {
            Text(metric.title).font(.subheadline.weight(.semibold))
          }
          if showsTitle {
            Text(current.map(metric.valueStyle.format) ?? "—")
              .font(.subheadline)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          if showsRange {
            Picker("Range", selection: rangeBinding) {
              ForEach(HeliosGraphRange.allCases) { Text($0.menuLabel).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Chart time range")
          }
        }
        HeliosTimeSeriesChart(
          samples: samples, range: range, fixedRange: metric.fixedRange,
          tint: preferences.color(for: metric.colorRole),
          lineStyle: preferences.graphLineStyle,
          animateUpdates: preferences.animateGraphUpdates,
          valueStyle: metric.valueStyle, seriesLabel: metric.title, markers: markers)
          .frame(height: height)
      }
      .modifier(HeliosChartSurface(enabled: !bare))
      .accessibilityElement(children: .contain)
    }
  }

  @ViewBuilder
  private func menuLabel(_ title: String, checked: Bool) -> some View {
    if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
  }
}

/// The grouped surface behind a chart panel; omitted when the panel is embedded.
private struct HeliosChartSurface: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content
        .padding(12)
        .heliosGroupSurface()
    } else {
      content
    }
  }
}
