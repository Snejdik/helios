import AppKit
import SwiftUI

@MainActor
final class HeliosEnergyInspectorState: ObservableObject {
  struct Aggregation {
    let visibleBuckets: [AppEnergyBucket]
    let summary: AppEnergySummary
    let batteryBuckets: [AppEnergyBucket]
  }

  @Published var range: HeliosGraphRange = .sixHours
  @Published var selectedAppKey: String?

  private var cachedRange: HeliosGraphRange?
  private var cachedBucketCount = -1
  private var cachedFirstCapture: Date?
  private var cachedLastCapture: Date?
  private var cachedAggregation: Aggregation?

  func clearDerivedCache() {
    cachedRange = nil
    cachedBucketCount = -1
    cachedFirstCapture = nil
    cachedLastCapture = nil
    cachedAggregation = nil
  }

  func aggregation(for source: AppEnergySummary) -> Aggregation {
    let first = source.buckets.first?.capturedAt
    let last = source.buckets.last?.capturedAt
    if cachedRange == range, cachedBucketCount == source.buckets.count,
      cachedFirstCapture == first, cachedLastCapture == last, let cachedAggregation
    {
      return cachedAggregation
    }

    let visible: [AppEnergyBucket]
    if let anchor = last {
      let cutoff = anchor.addingTimeInterval(-range.seconds)
      visible = source.buckets.filter { $0.capturedAt >= cutoff && $0.capturedAt <= anchor }
    } else {
      visible = []
    }
    let summary = AppEnergyHistoryEngine.summary(visible)
    let result = Aggregation(
      visibleBuckets: visible,
      summary: summary,
      batteryBuckets: visible.filter { $0.onBattery == true })
    cachedRange = range
    cachedBucketCount = source.buckets.count
    cachedFirstCapture = first
    cachedLastCapture = last
    cachedAggregation = result
    return result
  }
}

@MainActor
struct HeliosEnergyInspectorView: View {
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var state: HeliosEnergyInspectorState = HeliosEnergyInspectorState()

  private var range: HeliosGraphRange { state.range }
  private var selectedAppKey: String? { state.selectedAppKey }

  private static let supportedRanges: [HeliosGraphRange] = [.oneHour, .sixHours, .twentyFourHours]
  private var p: OverviewPresentation { model.presentation }

  private var aggregation: HeliosEnergyInspectorState.Aggregation {
    state.aggregation(for: model.appEnergy)
  }

  private var visibleBuckets: [AppEnergyBucket] { aggregation.visibleBuckets }
  private var summary: AppEnergySummary { aggregation.summary }
  private var batteryBuckets: [AppEnergyBucket] { aggregation.batteryBuckets }

  private var trackedEnergyWattHours: Double {
    summary.topOnBattery.reduce(0) { $0 + $1.energyWattHours }
  }

  private var effectiveSelectedAppKey: String? {
    if let selectedAppKey,
      summary.topOnBattery.contains(where: { $0.appKey == selectedAppKey })
    {
      return selectedAppKey
    }
    return summary.topOnBattery.first?.appKey
  }

  private var selectedEntry: AppEnergyEntry? {
    guard let key = effectiveSelectedAppKey else { return nil }
    return summary.topOnBattery.first { $0.appKey == key }
  }

  private var batteryChangePercent: Double? {
    let values = batteryBuckets.compactMap { bucket -> Double? in
      guard let percent = bucket.batteryPercent, percent.isFinite, (0...100).contains(percent)
      else { return nil }
      return percent
    }
    guard let first = values.first, let last = values.last, values.count >= 2 else { return nil }
    return last - first
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          summaryCards
          risingApps
          batteryHistory
          HStack(alignment: .top, spacing: 14) {
            rankingPanel
              .frame(minWidth: 270, idealWidth: 300, maxWidth: 320, alignment: .topLeading)
            selectedAppPanel
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          caveat
        }
        .padding(18)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 680, minHeight: 470)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "battery.75percent")
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(preferences.color(for: .energy))
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text("Energy Inspector")
          .font(.system(size: 16, weight: .semibold))
        Text("Which apps used battery energy, and when")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      Spacer()
      rangeControls
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
  }

  private var rangeControls: some View {
    HStack(spacing: 10) {
      Button("Export CSV…", action: exportCSV)
        .controlSize(.small)
        .disabled(summary.topOnBattery.isEmpty)
        .help("Save the app ranking for the selected range as a CSV file")
      Picker("History range", selection: $state.range) {
        ForEach(Self.supportedRanges) { item in
          Text(item.label).tag(item)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      .frame(width: 190)
      .accessibilityLabel("Energy history range")
    }
  }

  private var summaryCards: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10
    ) {
      inspectorCard(
        "Battery now", currentBatteryText, detail: currentPowerSourceText,
        symbol: "battery.75percent", tint: preferences.color(for: .battery))
      inspectorCard(
        "Live flow", currentBatteryFlowText, detail: currentBatteryFlowDetail,
        symbol: "bolt.fill", tint: preferences.color(for: .power))
      inspectorCard(
        "Battery change", batteryChangeText,
        detail: "during observed on-battery samples", symbol: "chart.line.downtrend.xyaxis",
        tint: batteryChangeTint)
      inspectorCard(
        "Observed", TelemetryFormatting.duration(summary.onBatteryCoverageSeconds),
        detail: "on battery in selected range", symbol: "clock",
        tint: preferences.color(for: .energy))
    }
  }

  private var batteryHistory: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text("Battery level")
            .font(.system(size: 11, weight: .semibold))
          Spacer()
          Text(range.menuLabel)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if batteryLevelSamples.contains(where: { $0.value != nil }) {
          HeliosTimeSeriesChart(
            samples: batteryLevelSamples,
            range: range,
            fixedRange: 0...100,
            tint: preferences.color(for: .battery),
            lineStyle: preferences.graphLineStyle,
            animateUpdates: false,
            inspectorEnabled: true,
            valueStyle: .percent,
            seriesLabel: "Battery"
          )
          .frame(height: 92)
        } else {
          inspectorEmpty(
            "No battery-level history in this range",
            detail:
              "Use the Mac on battery while Helios is running; the local history updates automatically."
          )
        }
      }
      .padding(4)
    }
  }

  private var rankingPanel: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Battery energy by app")
            .font(.system(size: 11, weight: .semibold))
          Spacer()
          Text("Share")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }

        if summary.topOnBattery.isEmpty {
          inspectorEmpty(
            "No on-battery app history",
            detail:
              "Helios will rank apps after it has observed at least one completed energy-history bucket while on battery."
          )
        } else {
          ForEach(Array(summary.topOnBattery.prefix(12).enumerated()), id: \.element.id) {
            index, entry in
            Button {
              state.selectedAppKey = entry.appKey
            } label: {
              energyLeaderRow(rank: index + 1, entry: entry)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .padding(4)
    }
  }

  @ViewBuilder
  private var selectedAppPanel: some View {
    GroupBox {
      if let entry = selectedEntry {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 9) {
            HeliosAppIdentityIcon(appKey: entry.appKey, size: 30)
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
              Text(selectedShareText(entry))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(energyText(entry.energyWattHours))
              .font(.system(size: 11, weight: .semibold).monospacedDigit())
          }

          HeliosTimeSeriesChart(
            samples: selectedAppSamples(appKey: entry.appKey),
            range: range,
            fixedRange: nil,
            tint: preferences.color(for: .energy),
            lineStyle: preferences.graphLineStyle,
            animateUpdates: false,
            inspectorEnabled: true,
            valueStyle: .milliwattHours,
            seriesLabel: entry.displayName
          )
          .frame(height: 100)

          Divider().opacity(0.45)
          inspectorDetailRow("CPU time", TelemetryFormatting.duration(entry.cpuCoreSeconds))
          inspectorDetailRow("Wakeups", String(format: "%.0f", entry.wakeups))
          inspectorDetailRow(
            "Peak memory", TelemetryFormatting.storageBytes(entry.peakMemoryBytes))
          appActions(entry)
        }
        .padding(4)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("App timeline")
            .font(.system(size: 11, weight: .semibold))
          inspectorEmpty(
            "Select an app",
            detail:
              "Once on-battery history exists, choose an app on the left to inspect its minute-by-minute tracked energy."
          )
        }
        .padding(4)
      }
    }
  }

  // MARK: - Compared with the previous hour

  /// Apps that used clearly more energy in the last hour than in the hour before.
  /// Independent of the selected range: it always compares two neighbouring hours.
  @ViewBuilder
  private var risingApps: some View {
    let trends = model.appEnergy.recentHourTrends
    if !trends.isEmpty {
      let rising = trends
        .filter { $0.changeWattHours > 0.01 && ($0.changePercent ?? 100) >= 25 }
        .sorted { $0.changeWattHours > $1.changeWattHours }
        .prefix(4)
      GroupBox {
        VStack(alignment: .leading, spacing: 6) {
          Text("Using more than the hour before")
            .font(.system(size: 11, weight: .semibold))
          if rising.isEmpty {
            Text("No app stands out compared with the previous hour.")
              .font(.system(size: 11)).foregroundStyle(.secondary)
          } else {
            ForEach(Array(rising)) { trend in
              Button {
                state.selectedAppKey = trend.appKey
              } label: {
                HStack(spacing: 8) {
                  HeliosAppIdentityIcon(appKey: trend.appKey, size: 20)
                  Text(trend.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                  Spacer(minLength: 6)
                  Text(risingText(trend))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.orange)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .padding(4)
      }
    }
  }

  private func risingText(_ trend: AppEnergyTrend) -> String {
    let extra = energyText(trend.changeWattHours)
    guard let percent = trend.changePercent else { return "+\(extra) · new in the last hour" }
    return String(format: "+%@ · +%.0f%%", extra, percent)
  }

  // MARK: - Actions

  @ViewBuilder
  private func appActions(_ entry: AppEnergyEntry) -> some View {
    if HeliosAppActions.bundlePath(forKey: entry.appKey) != nil {
      let running = HeliosAppActions.runningApplication(forKey: entry.appKey) != nil
      Divider().opacity(0.45)
      HStack(spacing: 8) {
        Button("Quit") { HeliosAppActions.quit(entry.appKey) }
          .disabled(!running)
        Button("Force Quit…") {
          HeliosAppActions.forceQuit(entry.appKey, displayName: entry.displayName)
        }
        .disabled(!running)
        Button("Show in Finder") { HeliosAppActions.revealInFinder(entry.appKey) }
        Spacer(minLength: 0)
        if !running {
          Text("Not running").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
      }
      .controlSize(.small)
    }
  }

  private func exportCSV() {
    HeliosFileExport.save(
      suggestedName: "helios-app-energy-\(range.label).csv", type: .commaSeparatedText
    ) { HeliosEnergyCSV.make(entries: summary.topOnBattery).data(using: .utf8) }
  }

  private var caveat: some View {
    Label(
      "Relative local attribution only. Inaccessible/system processes can be absent, and process-accounted energy does not equal whole-system battery drain 1:1.",
      systemImage: "info.circle"
    )
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var batteryLevelSamples: [HeliosChartSample] {
    visibleBuckets.map { bucket in
      let value = bucket.onBattery == true ? bucket.batteryPercent : nil
      return HeliosChartSample(capturedAt: bucket.capturedAt, value: value)
    }
  }

  private func selectedAppSamples(appKey: String) -> [HeliosChartSample] {
    visibleBuckets.map { bucket in
      guard bucket.onBattery == true else {
        return HeliosChartSample(capturedAt: bucket.capturedAt, value: nil)
      }
      let energy = bucket.entries.first(where: { $0.appKey == appKey })?.energyWattHours
      let milliwattHours = energy.map { $0 * 1_000 }
      return HeliosChartSample(capturedAt: bucket.capturedAt, value: milliwattHours)
    }
  }

  private func energyLeaderRow(rank: Int, entry: AppEnergyEntry) -> some View {
    let selected = effectiveSelectedAppKey == entry.appKey
    let share = trackedEnergyWattHours > 0 ? entry.energyWattHours / trackedEnergyWattHours : 0
    return HStack(spacing: 8) {
      Text("\(rank)")
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.tertiary)
        .frame(width: 14, alignment: .trailing)
      HeliosAppIdentityIcon(appKey: entry.appKey, size: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.displayName)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
        GeometryReader { proxy in
          ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.10))
            Capsule().fill(Color.orange.opacity(0.78))
              .frame(width: proxy.size.width * CGFloat(min(1, max(0, share))))
          }
        }
        .frame(height: 3)
      }
      Spacer(minLength: 5)
      VStack(alignment: .trailing, spacing: 1) {
        Text(TelemetryFormatting.percent(share * 100))
          .font(.system(size: 11, weight: .semibold).monospacedDigit())
        Text(energyText(entry.energyWattHours))
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
    .background(
      selected ? Color.accentColor.opacity(0.12) : Color.clear,
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .contentShape(Rectangle())
  }

  private func inspectorCard(
    _ title: String, _ value: String, detail: String, symbol: String, tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        Image(systemName: symbol)
          .foregroundStyle(tint)
        Text(title)
          .foregroundStyle(.secondary)
      }
      .font(.system(size: 11, weight: .medium))
      Text(value)
        .font(.system(size: 18, weight: .semibold).monospacedDigit())
        .lineLimit(1)
      Text(detail)
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    .padding(10)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.52),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func inspectorEmpty(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
      Text(detail)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .padding(.vertical, 6)
  }

  private func inspectorDetailRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }
    .font(.system(size: 11))
  }

  private func selectedShareText(_ entry: AppEnergyEntry) -> String {
    guard trackedEnergyWattHours > 0 else { return "Tracked battery share unavailable" }
    let share = entry.energyWattHours / trackedEnergyWattHours
    return String(format: "%.1f%% of tracked app energy · %@", share * 100, range.menuLabel)
  }

  private func energyText(_ wattHours: Double) -> String {
    guard wattHours.isFinite, wattHours >= 0 else { return "—" }
    if wattHours < 1 {
      return String(format: "%.2f mWh", wattHours * 1_000)
    }
    return String(format: "%.2f Wh", wattHours)
  }

  private var currentBatteryText: String {
    guard case .success(let battery) = p.battery,
      case .success(let percent) = battery.stateOfChargePercent
    else { return "—" }
    return TelemetryFormatting.percent(percent)
  }

  private var currentPowerSourceText: String {
    guard case .success(let battery) = p.battery,
      case .success(let source) = battery.powerSource
    else { return "Current power source unavailable" }
    return source.rawValue
  }

  private var currentBatteryFlowText: String {
    guard case .success(let battery) = p.battery,
      case .success(let power) = battery.power
    else { return "—" }
    return TelemetryFormatting.watts(power.signedWatts, signed: true)
  }

  private var currentBatteryFlowDetail: String {
    guard case .success(let battery) = p.battery,
      case .success(let source) = battery.powerSource
    else { return "Current battery flow unavailable" }
    switch source {
    case .battery: return "negative = discharging"
    case .powerAdapter: return "connected to power adapter"
    }
  }

  private var batteryChangeText: String {
    guard let batteryChangePercent else { return "—" }
    return String(format: "%+.1f%%", batteryChangePercent)
  }

  private var batteryChangeTint: Color {
    guard let batteryChangePercent else { return .secondary }
    if batteryChangePercent < -15 { return .orange }
    if batteryChangePercent > 0.5 { return .green }
    return .blue
  }
}
