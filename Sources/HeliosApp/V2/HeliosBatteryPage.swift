import SwiftUI

struct HeliosBatteryPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel

  /// Apple's published service life for MacBook batteries.
  private static let ratedCycles = 1_000

  var body: some View {
    let presentation = model.presentation
    let assessment = HeliosMacAssessment.battery(
      model.snapshot, now: Date(), configuration: context.preferences.healthAlerts)
    let range = context.preferences.graphRange(for: .battery)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      HeliosAreaHeader(
        assessment: assessment, meaning: HeliosCopy.meaning(.battery), valueCaption: "Charge")
      if assessment.status == .notPresent {
        HeliosChartPanel(
          metric: .power, model: model, preferences: context.preferences, scope: .battery)
      } else {
        if !context.preferences.isTelemetryCollectionRequired(.battery) {
          HeliosCollectionOffNotice(
            title: "Battery monitoring is off.", module: .battery, preferences: context.preferences)
        }
        if case .success(let battery) = presentation.battery {
          statStrip(battery)
        }
        HeliosChartPanel(
          metric: .battery, model: model, preferences: context.preferences, scope: .battery,
          markers: context.feed.markers(for: .battery, range: range))
        if case .success(let battery) = presentation.battery {
          HStack(alignment: .top, spacing: 20) {
            HeliosSection("Capacity") { capacityBlock(battery) }
            HeliosSection("Power") { HeliosGroup { powerRows(battery) } }
          }
          HeliosSection("Condition") { HeliosGroup { conditionRows(battery) } }
        }
      }

      if assessment.status != .notPresent {
        HeliosSection("Health over time") {
          HeliosBatteryTrend(summary: model.batteryHealth)
        }
      }

      HeliosSection("Energy by app") {
        HeliosGroup {
          HStack(spacing: 12) {
            Image(systemName: "bolt.fill").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
              Text("Which apps used your battery, and when")
              Text("Compare periods, see time the Mac was asleep, quit an app or export the ranking.")
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Open Energy") { context.actions.openPage(.energy) }
          }
          .padding(.vertical, 8)
        }
      }
    }
  }

  // MARK: - Headline tiles

  private func statStrip(_ battery: BatteryMetrics) -> some View {
    HStack(alignment: .top, spacing: 12) {
      HeliosStatTile(
        title: "Health",
        value: HeliosText.value(battery.healthPercent) { TelemetryFormatting.percent($0, decimals: 0) },
        caption: "Capacity vs. new")
      HeliosStatTile(
        title: "Cycles",
        value: HeliosText.value(battery.cycleCount) { "\($0)" },
        caption: "of \(Self.ratedCycles.formatted()) rated")
      HeliosStatTile(
        title: "Temperature",
        value: HeliosText.value(battery.temperatureCelsius) { TelemetryFormatting.temperature($0, decimals: 1) },
        caption: "Battery")
      HeliosStatTile(
        title: powerTitle(battery),
        value: HeliosText.value(battery.power) { TelemetryFormatting.watts(abs($0.signedWatts)) },
        caption: status(battery))
    }
  }

  private func powerTitle(_ battery: BatteryMetrics) -> String {
    guard case .success(let power) = battery.power else { return "Power" }
    return power.signedWatts > 0 ? "Charging" : power.signedWatts < 0 ? "Discharging" : "Idle"
  }

  // MARK: - Sections

  /// A bar of the full-charge capacity against the design capacity, then the figures.
  private func capacityBlock(_ battery: BatteryMetrics) -> some View {
    HeliosGroup {
      if case .success(let full) = battery.maximumCapacityMAh,
        case .success(let design) = battery.designCapacityMAh, design > 0
      {
        VStack(alignment: .leading, spacing: 6) {
          HeliosBatteryCapacityBar(fraction: Double(full) / Double(design))
          Text("\(full.formatted()) of \(design.formatted()) mAh when new")
            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 8)
        Divider()
      }
      HeliosFactRow(label: "Health",
        value: HeliosText.value(battery.healthPercent) { TelemetryFormatting.percent($0, decimals: 1) },
        detail: "Full-charge capacity compared with design")
      HeliosFactRow(label: "Design capacity",
        value: HeliosText.value(battery.designCapacityMAh) { "\($0.formatted()) mAh" })
      HeliosFactRow(label: "Full-charge capacity",
        value: HeliosText.value(battery.maximumCapacityMAh) { "\($0.formatted()) mAh" })
      HeliosFactRow(label: "Current charge",
        value: HeliosText.value(battery.currentCapacityMAh) { "\($0.formatted()) mAh" },
        detail: "Raw gauge value; macOS reports the percentage separately", showsDivider: false)
    }
  }

  @ViewBuilder
  private func powerRows(_ battery: BatteryMetrics) -> some View {
    HeliosFactRow(label: "Status", value: status(battery))
    HeliosFactRow(label: "Time remaining",
      value: HeliosText.value(battery.timeRemaining) { TelemetryFormatting.batteryTimeRemaining($0) })
    HeliosFactRow(label: "Power flow",
      value: HeliosText.value(battery.power) { TelemetryFormatting.watts($0.signedWatts, signed: true) },
      detail: "+ charging · − discharging")
    HeliosFactRow(label: "Power adapter", value: adapterText(battery))
    HeliosFactRow(label: "Charger output", value: chargerText(battery),
      detail: "Voltage × current delivered to the battery", showsDivider: false)
  }

  @ViewBuilder
  private func conditionRows(_ battery: BatteryMetrics) -> some View {
    HeliosFactRow(label: "Age", value: ageText(battery),
      detail: "Since the battery was manufactured")
    HeliosFactRow(label: "Manufactured", value: HeliosText.value(battery.manufactureDate) {
      $0.formatted(date: .abbreviated, time: .omitted)
    })
    HeliosFactRow(label: "Optimized charging",
      value: HeliosText.value(battery.optimizedChargingEngaged) { $0 ? "Engaged" : "Not engaged" })
    HeliosFactRow(label: "Voltage",
      value: HeliosText.value(battery.voltageVolts) { String(format: "%.2f V", $0) })
    HeliosFactRow(label: "Current",
      value: HeliosText.value(battery.currentAmps) { String(format: "%+.2f A", $0) })
    HeliosFactRow(label: "Cell balance",
      value: HeliosText.value(battery.cellBalanceMillivolts) { String(format: "%.0f mV", $0) },
      detail: "Difference between the highest and lowest cell", showsDivider: false)
  }

  // MARK: - Text

  private func status(_ battery: BatteryMetrics) -> String {
    if case .success(true) = battery.isCharging { return "Charging" }
    if case .success(true) = battery.isCharged { return "Charged" }
    switch battery.powerSource {
    case .success(.battery): return "On battery"
    case .success(.powerAdapter): return "On power adapter, not charging"
    case .failure(let error): return HeliosText.failure(error)
    }
  }

  private func adapterText(_ battery: BatteryMetrics) -> String {
    if case .success(.battery) = battery.powerSource { return "Not connected" }
    guard case .success(let watts) = battery.adapterWatts else {
      return HeliosText.value(battery.adapterWatts) { "\($0) W" }
    }
    if case .success(let volts) = battery.adapterVoltageVolts, volts > 0 {
      return String(format: "%d W · %.1f V", watts, volts)
    }
    return "\(watts) W"
  }

  private func chargerText(_ battery: BatteryMetrics) -> String {
    guard case .success(let volts) = battery.chargingVoltageVolts,
      case .success(let amps) = battery.chargingCurrentAmps, amps > 0
    else { return "Not charging" }
    return String(format: "%.1f W · %.2f V × %.2f A", volts * amps, volts, amps)
  }

  private func ageText(_ battery: BatteryMetrics) -> String {
    guard case .success(let date) = battery.manufactureDate else {
      return HeliosText.value(battery.manufactureDate) { _ in "" }
    }
    guard date < Date() else { return "—" }
    let parts = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
    let years = parts.year ?? 0
    let months = parts.month ?? 0
    switch (years, months) {
    case (0, 0): return "Less than a month"
    case (0, _): return months == 1 ? "1 month" : "\(months) months"
    case (_, 0): return years == 1 ? "1 year" : "\(years) years"
    default:
      return "\(years) y \(months) mo"
    }
  }
}

/// One headline figure: a small title, the value, a one-line caption.
struct HeliosStatTile: View {
  let title: String
  let value: String
  let caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.subheadline).foregroundStyle(.secondary)
      Text(value)
        .font(.title2.weight(.semibold)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
      Text(caption)
        .font(.subheadline).foregroundStyle(.tertiary).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: HeliosDesign.groupCornerRadius))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title): \(value). \(caption)")
  }
}

/// Full-charge capacity as a share of the design capacity. A bar can pass 100 %.
struct HeliosBatteryCapacityBar: View {
  let fraction: Double

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.secondary.opacity(0.15))
        Capsule().fill(color)
          .frame(width: geometry.size.width * min(1, max(0, fraction)))
      }
    }
    .frame(height: 8)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Battery capacity compared with new")
    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
  }

  private var color: Color {
    fraction >= 0.8 ? .green : fraction >= 0.7 ? .orange : .red
  }
}

/// Battery health and cycle count across weeks and months, one point a day.
struct HeliosBatteryTrend: View {
  let summary: BatteryHealthSummary

  private var points: [(date: Date, value: Double)] {
    summary.days.compactMap { record in record.healthPercent.map { (record.day, $0) } }
  }

  var body: some View {
    if points.count < 2 {
      Text("Helios records your battery's health once a day. A trend appears after a couple of days.")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
          if let latest = points.last?.value {
            Text(TelemetryFormatting.percent(latest)).font(.title3.weight(.semibold)).monospacedDigit()
          }
          if let change = summary.healthChangePoints {
            Text(changeText(change)).foregroundStyle(.secondary)
          }
          if let cycles = summary.latest?.cycleCount {
            Text("\(cycles) cycles" + (summary.cyclesAdded.map { $0 > 0 ? " (+\($0))" : "" } ?? ""))
              .foregroundStyle(.secondary).monospacedDigit()
          }
          Spacer(minLength: 0)
        }
        HeliosHealthTrendChart(points: points)
          .frame(height: 110)
        HStack {
          Text(points.first.map { $0.date.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "")
          Spacer()
          Text(points.last.map { $0.date.formatted(.dateTime.month(.abbreviated).day().year()) } ?? "")
        }
        .font(.subheadline).foregroundStyle(.tertiary)
      }
    }
  }

  private func changeText(_ change: Double) -> String {
    let span = summary.days.count
    let rounded = (change * 10).rounded() / 10
    let sign = rounded > 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", rounded)) points over \(span) day\(span == 1 ? "" : "s")"
  }
}

/// A plain line chart: no framework load, a few hundred points at most.
struct HeliosHealthTrendChart: View {
  let points: [(date: Date, value: Double)]

  private var low: Double { max(0, (points.map(\.value).min() ?? 0) - 2) }
  private var high: Double { min(150, (points.map(\.value).max() ?? 100) + 2) }

  private func linePath(in size: CGSize) -> Path {
    let low = self.low
    let span = max(1, high - low)
    let first = points.first?.date.timeIntervalSince1970 ?? 0
    let total = max(1, (points.last?.date.timeIntervalSince1970 ?? 1) - first)
    var path = Path()
    for (index, point) in points.enumerated() {
      let location = CGPoint(
        x: size.width * (point.date.timeIntervalSince1970 - first) / total,
        y: size.height * (1 - (point.value - low) / span))
      if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
    }
    return path
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        linePath(in: geometry.size)
          .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        Text("\(Int(high.rounded()))%").font(.caption2).foregroundStyle(.tertiary)
        Text("\(Int(low.rounded()))%").font(.caption2).foregroundStyle(.tertiary)
          .frame(maxHeight: .infinity, alignment: .bottom)
      }
    }
    .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Battery health over time")
    .accessibilityValue(points.last.map { "\(Int($0.value.rounded())) percent now" } ?? "No data")
  }
}
