import SwiftUI

/// Auto: one editor with a switch
/// between a fan curve (temperature → speed, draggable points) and TG Pro-style
/// step rules ("when the sensor is above X, run the fans at Y %"). Per power
/// source, with presets and "copy to the other source". Speeds are a share of
/// factory minimum … the user's speed limit. The helper's safety floor, the
/// limit and the zone where macOS takes over are drawn and explained.
struct HeliosFanCurveEditor: View {
  @ObservedObject var model: FanControlModel
  @State private var profile: CoolingPowerProfile?
  @State private var draft: CoolingCurve?
  @State private var dragging: Int?
  @State private var confirmCopy = false

  private var shownProfile: CoolingPowerProfile { profile ?? model.activePowerProfile ?? .powerAdapter }
  private var otherProfile: CoolingPowerProfile { shownProfile == .powerAdapter ? .battery : .powerAdapter }
  private var curve: CoolingCurve { draft ?? model.curves.curve(shownProfile) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text("Automatic cooling").font(.headline)
        Spacer()
        Picker("Auto follows", selection: Binding(get: { model.curves.usesCurve }, set: { model.setAutoUsesCurve($0) })) {
          Text("Curve").tag(true)
          Text("Rules").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 160)
        .help("Curve: speed follows the temperature smoothly. Rules: fixed speeds from temperature thresholds, like TG Pro.")
      }
      HStack(spacing: 10) {
        Picker("Power source", selection: Binding(get: { shownProfile }, set: { profile = $0; draft = nil })) {
          ForEach(CoolingPowerProfile.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 240)
        if shownProfile == model.activePowerProfile {
          Text("in use now").font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Menu("Presets") {
          ForEach(CoolingPreset.allCases) { preset in
            Button {
              draft = nil
              model.applyPreset(preset, for: shownProfile)
            } label: {
              Text(preset.label)
              Text(preset.detail)
            }
          }
        }
        .fixedSize()
        .help("Replace the \(shownProfile.label) \(model.curves.usesCurve ? "curve" : "rules") with a preset.")
        Button("Copy to \(otherProfile.label)…") { confirmCopy = true }
      }
      .controlSize(.small)

      if model.curves.usesCurve {
        curveSection
      } else {
        HeliosCoolingRulesList(model: model, profile: shownProfile)
      }
    }
    .alert("Replace the \(otherProfile.label) settings?", isPresented: $confirmCopy) {
      Button("Cancel", role: .cancel) {}
      Button("Copy") {
        if model.curves.usesCurve {
          model.copyCurve(from: shownProfile, to: otherProfile)
        } else {
          model.copyRules(from: shownProfile, to: otherProfile)
        }
      }
    } message: {
      Text("The \(otherProfile.label) \(model.curves.usesCurve ? "curve" : "rules") will be replaced with the \(shownProfile.label) ones.")
    }
  }

  @ViewBuilder
  private var curveSection: some View {
    HStack(spacing: 10) {
      Picker("Sensor", selection: Binding(get: { curve.sensor }, set: { sensor in
        var edited = curve
        edited.sensor = sensor
        model.updateCurve(edited, for: shownProfile)
      })) {
        ForEach(CoolingCurveSensor.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .frame(maxWidth: 200)
      Spacer()
      Button("Add Point") {
        var edited = curve
        if edited.addPoint() { model.updateCurve(edited, for: shownProfile) }
      }
      .disabled(curve.points.count >= CoolingCurve.maximumPoints)
    }
    .controlSize(.small)

    HeliosFanCurveChart(
      curve: curve, limits: limits, fullMaximum: model.fullMaximumAllowed,
      now: shownProfile == model.activePowerProfile ? model.curveInputCelsius.map { ($0 * 2).rounded() / 2 } : nil,
      dragging: dragging,
      onDrag: { index, celsius, percent in
        var edited = draft ?? model.curves.curve(shownProfile)
        edited.move(index, celsius: celsius, percent: percent)
        draft = edited
        dragging = index
      },
      onEnd: {
        if let draft { model.updateCurve(draft, for: shownProfile) }
        draft = nil
        dragging = nil
      })
      .equatable()
      .frame(height: 210)

    HeliosFanCurveLegend(fullMaximum: model.fullMaximumAllowed, limits: limits)

    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
        pointRow(index, point)
      }
    }
    .font(.subheadline)
  }

  private var limits: (minimum: Double, limit: Double, maximum: Double)? {
    guard let bounds = model.sliderBounds, let limit = model.limitBounds?.upperBound else { return nil }
    return (bounds.lowerBound, limit, bounds.upperBound)
  }

  private func pointRow(_ index: Int, _ point: CoolingCurvePoint) -> some View {
    HStack(spacing: 12) {
      Text("Point \(index + 1)").foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
      Stepper(value: Binding(get: { point.celsius }, set: { value in edit(index) { $0.move(index, celsius: value, percent: point.percent) } }),
              in: CoolingCurve.celsiusRange, step: 1) {
        Text(TelemetryFormatting.temperature(point.celsius)).monospacedDigit().frame(width: 56, alignment: .trailing)
      }
      .accessibilityLabel("Point \(index + 1) temperature")
      Stepper(value: Binding(get: { point.percent }, set: { value in edit(index) { $0.move(index, celsius: point.celsius, percent: value) } }),
              in: 0...100, step: 5) {
        Text("\(Int(point.percent.rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
      }
      .accessibilityLabel("Point \(index + 1) speed")
      if let limits {
        Text(TelemetryFormatting.rpm(limits.minimum + (limits.limit - limits.minimum) * point.percent / 100))
          .monospacedDigit().foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        edit(index) { $0.removePoint(index) }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .disabled(curve.points.count <= CoolingCurve.minimumPoints)
      .help("Remove this point")
      .accessibilityLabel("Remove point \(index + 1)")
    }
  }

  private func edit(_ index: Int, _ change: (inout CoolingCurve) -> Void) {
    var edited = model.curves.curve(shownProfile)
    change(&edited)
    model.updateCurve(edited, for: shownProfile)
  }
}

/// What the lines and zones in the curve chart mean; hover any item for more.
private struct HeliosFanCurveLegend: View {
  let fullMaximum: Bool
  let limits: (minimum: Double, limit: Double, maximum: Double)?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 16) {
        item(swatch: AnyView(Capsule().fill(Color.accentColor).frame(width: 18, height: 3)),
             title: "Your curve",
             help: "The speed you want at each temperature. Below the first point macOS manages the fans as usual.")
        item(swatch: AnyView(dashed), title: "Safety floor",
             help: "While Helios holds the fans, macOS cannot react, so Helios never runs them slower than this line, even if your curve is lower. It rises as the Mac gets hot.")
        if !fullMaximum {
          item(swatch: AnyView(RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.25)).frame(width: 14, height: 10)),
               title: "macOS takes over",
               help: "From here the safety floor needs more than your speed limit, so Helios hands the fans back to macOS, which may use full speed.")
        }
        item(swatch: AnyView(Capsule().fill(Color.secondary.opacity(0.6)).frame(width: 18, height: 1)),
             title: fullMaximum ? "Factory maximum" : "Your limit",
             help: fullMaximum
               ? "100 % is the factory maximum (unlocked in Settings › Cooling)."
               : "100 % is your speed limit, 90 % of the factory maximum (Settings › Cooling).")
      }
      .font(.subheadline)
      Text(caption).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var caption: String {
    guard let limits else { return "0 % is the factory minimum, 100 % your speed limit. Point at the chart for exact values." }
    return "0 % is the factory minimum (\(TelemetryFormatting.rpm(limits.minimum))), 100 % \(fullMaximum ? "the factory maximum" : "your speed limit") (\(TelemetryFormatting.rpm(limits.limit))). Point at the chart for exact values."
  }

  private var dashed: some View {
    Path { path in
      path.move(to: CGPoint(x: 0, y: 1))
      path.addLine(to: CGPoint(x: 18, y: 1))
    }
    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    .frame(width: 18, height: 3)
  }

  private func item(swatch: AnyView, title: String, help: String) -> some View {
    HStack(spacing: 6) {
      swatch
      Text(title).foregroundStyle(.secondary)
      Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.tertiary)
    }
    .help(help)
    .accessibilityElement(children: .combine)
    .accessibilityHint(help)
  }
}

/// TG Pro-style step rules: "When <sensor> is above <°C>, run <fans> at <%>".
/// The highest matching rule wins; below every threshold macOS keeps the fans.
private struct HeliosCoolingRulesList: View {
  @ObservedObject var model: FanControlModel
  let profile: CoolingPowerProfile

  var body: some View {
    let rules = model.rules(for: profile)
    VStack(alignment: .leading, spacing: 8) {
      if rules.isEmpty {
        Text("No rules: macOS manages the fans on \(profile.label.lowercased()). Add a rule or pick a preset.")
          .font(.subheadline).foregroundStyle(.secondary)
      } else {
        HeliosGroup {
          ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
            row(rule, index: index, count: rules.count)
              .padding(.vertical, 4)
            if index < rules.count - 1 { Divider() }
          }
        }
      }
      HStack {
        Button("Add Rule") { model.addRule(profile: profile) }
        Button("Add Always Rule") { model.addAlwaysRule(profile: profile) }
          .help("A speed that applies whenever Auto is on, regardless of temperature.")
        Spacer()
      }
      .controlSize(.small)
      .disabled(rules.count >= CoolingRulesConfiguration.maximumRuleCount)
      Text("When several rules match, the fastest one wins. Below every threshold macOS manages the fans. 0 % is the factory minimum, 100 % your speed limit.")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func row(_ rule: CoolingRule, index: Int, count: Int) -> some View {
    let active = model.activePowerProfile == profile && model.activeRuleIDs.contains(rule.id)
    return HStack(spacing: 8) {
      Toggle("", isOn: binding(rule) { $0.enabled } set: { $0.enabled = $1 })
        .labelsHidden()
        .toggleStyle(.checkbox)
        .help(rule.enabled ? "Rule is on" : "Rule is off")
      Circle()
        .fill(active ? Color.green : Color.clear)
        .overlay(Circle().stroke(Color.secondary.opacity(active ? 0 : 0.4), lineWidth: 1))
        .frame(width: 7, height: 7)
        .help(active ? "This rule is active right now" : "Not active right now")
      Text(rule.sensor.kind == .always ? "Always" : "When")
      if rule.sensor.kind != .always {
        Picker("Sensor", selection: binding(rule) { $0.sensor } set: { $0.sensor = $1 }) {
          ForEach(model.availableRuleSensors.filter { $0.source.kind != .always }, id: \.source) { option in
            Text(option.label).tag(option.source)
          }
          if !model.availableRuleSensors.contains(where: { $0.source == rule.sensor }) {
            Text(model.label(for: rule.sensor)).tag(rule.sensor)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 150)
        Text("is above")
        Stepper(value: binding(rule) { $0.thresholdCelsius } set: { $0.thresholdCelsius = $1 }, in: 20...120, step: 1) {
          Text(TelemetryFormatting.temperature(rule.thresholdCelsius)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
      }
      Text("run")
      if model.fanTargets.count > 2 {
        Picker("Fans", selection: binding(rule) { $0.target } set: { $0.target = $1 }) {
          ForEach(model.fanTargets, id: \.self) { Text(model.targetLabel($0)).tag($0) }
        }
        .labelsHidden()
        .frame(maxWidth: 100)
      } else {
        Text("fans")
      }
      Text("at")
      Stepper(value: binding(rule) { Double($0.speedPercent) } set: { $0.speedPercent = Int($1) }, in: 0...100, step: 5) {
        Text("\(rule.speedPercent) %").monospacedDigit().frame(width: 40, alignment: .trailing)
      }
      Spacer(minLength: 4)
      Button { model.moveRule(profile: profile, id: rule.id, offset: -1) } label: { Image(systemName: "chevron.up") }
        .disabled(index == 0).help("Move up")
      Button { model.moveRule(profile: profile, id: rule.id, offset: 1) } label: { Image(systemName: "chevron.down") }
        .disabled(index == count - 1).help("Move down")
      Button { model.removeRule(profile: profile, id: rule.id) } label: { Image(systemName: "minus.circle") }
        .help("Remove rule")
    }
    .buttonStyle(.borderless)
    .font(.subheadline)
    .opacity(rule.enabled ? 1 : 0.55)
  }

  private func binding<Value>(_ rule: CoolingRule, get: @escaping (CoolingRule) -> Value,
                              set: @escaping (inout CoolingRule, Value) -> Void) -> Binding<Value> {
    Binding(
      get: { model.rule(profile: profile, id: rule.id).map(get) ?? get(rule) },
      set: { value in model.updateRule(profile: profile, id: rule.id) { set(&$0, value) } })
  }
}

/// The plot: axes 30–100 °C × 0–100 %, the curve with its points, and the
/// read-only overlays (helper safety floor, the user's limit, macOS zone).
/// Equatable without the closures: Auto refreshes the model twice a second,
/// the plot redraws only when what it shows changed.
private struct HeliosFanCurveChart: View, Equatable {
  nonisolated static func == (a: Self, b: Self) -> Bool {
    a.curve == b.curve && a.fullMaximum == b.fullMaximum && a.now == b.now && a.dragging == b.dragging
      && a.unit == b.unit
      && a.limits?.minimum == b.limits?.minimum && a.limits?.limit == b.limits?.limit
      && a.limits?.maximum == b.limits?.maximum
  }

  let curve: CoolingCurve
  let limits: (minimum: Double, limit: Double, maximum: Double)?
  let fullMaximum: Bool
  let now: Double?
  let dragging: Int?
  let onDrag: (Int, Double, Double) -> Void
  let onEnd: () -> Void
  /// Labels follow the °C/°F setting; the curve itself is always stored in °C.
  let unit = TemperatureUnit.current

  @State private var hoverCelsius: Double?

  private let left: CGFloat = 36
  private let bottom: CGFloat = 20
  private let top: CGFloat = 14
  private let right: CGFloat = 8
  private let range = CoolingCurve.celsiusRange

  var body: some View {
    GeometryReader { geometry in
      let plot = CGRect(x: left, y: top, width: max(1, geometry.size.width - left - right),
                        height: max(1, geometry.size.height - top - bottom))
      ZStack(alignment: .topLeading) {
        grid(plot)
        if let handback = handbackCelsius {
          Rectangle()
            .fill(Color.orange.opacity(0.08))
            .frame(width: max(0, plot.maxX - x(handback, plot)), height: plot.height)
            .offset(x: x(handback, plot), y: plot.minY)
          Text("macOS")
            .font(.caption2).foregroundStyle(.orange)
            .offset(x: x(handback, plot) + 4, y: plot.minY + 2)
        }
        safetyLine(plot)
          .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        Path { path in
          path.move(to: CGPoint(x: plot.minX, y: plot.minY))
          path.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        }
        .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
        Text(fullMaximum ? "Factory maximum" : "Your limit")
          .font(.caption2).foregroundStyle(.secondary)
          .offset(x: plot.minX + 4, y: plot.minY - 13)
        curveArea(plot).fill(Color.accentColor.opacity(0.12))
        curveLine(plot).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        if let now, range.contains(now) {
          Path { path in
            path.move(to: CGPoint(x: x(now, plot), y: plot.minY))
            path.addLine(to: CGPoint(x: x(now, plot), y: plot.maxY))
          }
          .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
          Text("now \(TelemetryFormatting.temperature(now))")
            .font(.caption2).foregroundStyle(.secondary)
            .offset(x: min(plot.maxX - 56, x(now, plot) + 3), y: plot.maxY - 14)
        }
        if let hover = hoverCelsius, dragging == nil {
          Path { path in
            path.move(to: CGPoint(x: x(hover, plot), y: plot.minY))
            path.addLine(to: CGPoint(x: x(hover, plot), y: plot.maxY))
          }
          .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
          readout(hover)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.25)))
            .fixedSize()
            .offset(x: x(hover, plot) > plot.midX ? plot.minX + 4 : plot.midX, y: plot.minY + 4)
            .allowsHitTesting(false)
        }
        ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
          Circle()
            .fill(dragging == index ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 12, height: 12)
            .contentShape(Circle().inset(by: -6))
            .position(x: x(point.celsius, plot), y: y(point.percent, plot))
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .named("fanCurve"))
                .onChanged { value in
                  onDrag(index, celsius(value.location.x, plot), percent(value.location.y, plot))
                }
                .onEnded { _ in onEnd() })
            .accessibilityElement()
            .accessibilityLabel("Point \(index + 1): \(TelemetryFormatting.temperature(point.celsius)), \(Int(point.percent.rounded())) %")
        }
      }
      .contentShape(Rectangle())
      .onContinuousHover(coordinateSpace: .named("fanCurve")) { phase in
        switch phase {
        case .active(let location) where plot.insetBy(dx: -2, dy: -2).contains(location):
          hoverCelsius = min(range.upperBound, max(range.lowerBound, (celsius(location.x, plot) * 2).rounded() / 2))
        default:
          hoverCelsius = nil
        }
      }
      .coordinateSpace(name: "fanCurve")
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Fan curve")
  }

  /// "72°C · curve 44 % (3,890 RPM) · safety floor 12 %" for the pointer.
  private func readout(_ celsius: Double) -> some View {
    let curveValue = curve.percent(at: celsius)
    let safety = safetyPercent(celsius)
    let handback = handbackCelsius.map { celsius >= $0 } ?? false
    var parts = [TelemetryFormatting.temperature(celsius)]
    if handback {
      parts.append("macOS takes over")
    } else if let curveValue {
      var text = "curve \(Int(curveValue.rounded())) %"
      if let limits {
        text += " (\(TelemetryFormatting.rpm(limits.minimum + (limits.limit - limits.minimum) * curveValue / 100)))"
      }
      parts.append(text)
      if let safety, safety > curveValue + 0.5 {
        parts.append("safety floor \(Int(min(100, safety).rounded())) %")
      }
    } else {
      parts.append("macOS manages the fans")
    }
    return Text(parts.joined(separator: " · ")).font(.caption).monospacedDigit()
  }

  // MARK: Mapping

  private func x(_ celsius: Double, _ plot: CGRect) -> CGFloat {
    plot.minX + plot.width * CGFloat((celsius - range.lowerBound) / (range.upperBound - range.lowerBound))
  }

  private func y(_ percent: Double, _ plot: CGRect) -> CGFloat {
    plot.maxY - plot.height * CGFloat(min(100, max(0, percent)) / 100)
  }

  private func celsius(_ x: CGFloat, _ plot: CGRect) -> Double {
    range.lowerBound + Double((x - plot.minX) / plot.width) * (range.upperBound - range.lowerBound)
  }

  private func percent(_ y: CGFloat, _ plot: CGRect) -> Double {
    Double((plot.maxY - y) / plot.height) * 100
  }

  /// The helper's safety floor as a share of minimum … limit (may exceed 100 %).
  private func safetyPercent(_ celsius: Double) -> Double? {
    guard let limits, limits.limit > limits.minimum else { return nil }
    let rpm = limits.minimum + (limits.maximum - limits.minimum) * FanLayerSafetyCurve.fraction(at: celsius)
    return (rpm - limits.minimum) / (limits.limit - limits.minimum) * 100
  }

  /// From here the safety floor needs more than the limit: macOS takes over.
  private var handbackCelsius: Double? {
    guard !fullMaximum else { return nil }
    var celsius = range.lowerBound
    while celsius <= range.upperBound {
      if let value = safetyPercent(celsius), value > 100 { return celsius }
      celsius += 0.5
    }
    return nil
  }

  // MARK: Shapes

  private func grid(_ plot: CGRect) -> some View {
    ZStack(alignment: .topLeading) {
      Path { path in
        for celsius in stride(from: range.lowerBound, through: range.upperBound, by: 10) {
          path.move(to: CGPoint(x: x(celsius, plot), y: plot.minY))
          path.addLine(to: CGPoint(x: x(celsius, plot), y: plot.maxY))
        }
        for percent in stride(from: 0.0, through: 100, by: 25) {
          path.move(to: CGPoint(x: plot.minX, y: y(percent, plot)))
          path.addLine(to: CGPoint(x: plot.maxX, y: y(percent, plot)))
        }
      }
      .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
      ForEach(Array(stride(from: range.lowerBound, through: range.upperBound, by: 10)), id: \.self) { celsius in
        Text("\(Int(TemperatureUnit.current.convert(celsius).rounded()))°")
          .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
          .position(x: x(celsius, plot), y: plot.maxY + 10)
      }
      ForEach(Array(stride(from: 0.0, through: 100, by: 50)), id: \.self) { percent in
        Text("\(Int(percent)) %")
          .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
          .position(x: plot.minX - 18, y: y(percent, plot))
      }
    }
  }

  private func safetyLine(_ plot: CGRect) -> Path {
    Path { path in
      var started = false
      var celsius = range.lowerBound
      while celsius <= range.upperBound {
        if let value = safetyPercent(celsius) {
          let point = CGPoint(x: x(celsius, plot), y: y(min(100, value), plot))
          if started { path.addLine(to: point) } else { path.move(to: point); started = true }
          if value > 100 { break }
        }
        celsius += 0.5
      }
    }
  }

  private func curvePoints(_ plot: CGRect) -> [CGPoint] {
    guard let last = curve.points.last else { return [] }
    return curve.points.map { CGPoint(x: x($0.celsius, plot), y: y($0.percent, plot)) }
      + [CGPoint(x: plot.maxX, y: y(last.percent, plot))]
  }

  private func curveLine(_ plot: CGRect) -> Path {
    Path { path in path.addLines(curvePoints(plot)) }
  }

  private func curveArea(_ plot: CGRect) -> Path {
    Path { path in
      let points = curvePoints(plot)
      guard let first = points.first, let last = points.last else { return }
      path.move(to: CGPoint(x: first.x, y: plot.maxY))
      path.addLines(points)
      path.addLine(to: CGPoint(x: last.x, y: plot.maxY))
      path.closeSubpath()
    }
  }
}
