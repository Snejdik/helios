import OSLog
import SwiftUI

struct HeliosThermalsPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @State private var showSensors = false

  var body: some View {
    let presentation = model.presentation
    let assessment = HeliosMacAssessment.thermals(
      model.snapshot, now: Date(), configuration: context.preferences.healthAlerts)
    let range = context.preferences.graphRange(for: .thermals)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      HeliosAreaHeader(
        assessment: assessment, meaning: HeliosCopy.meaning(.thermals), valueCaption: "Max SoC",
        showsValue: false)
      HeliosThermalBlock(
        context: context, model: model, presentation: presentation,
        markers: context.feed.markers(for: .temperature, range: range))

      HeliosSection("What is keeping your Mac busy") {
        VStack(alignment: .leading, spacing: 8) {
          HeliosRightNowList(context: context, presentation: presentation, limit: 5, grouped: true)
          Text("Apps using the most CPU right now. Heat follows work, but one busy app is not proof it is the cause.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      HeliosSection("Sensor groups") {
        HeliosGroup { sensorGroups(presentation) }
          .help(HeliosCopy.maxSoC)
      }

      HeliosSection("Cooling") {
        HeliosCoolingSection(context: context, presentation: presentation)
      }

      DisclosureGroup("All sensors", isExpanded: $showSensors) {
        HeliosSensorInventory(presentation: presentation)
          .padding(.top, 8)
      }
    }
  }

  @ViewBuilder
  private func sensorGroups(_ p: OverviewPresentation) -> some View {
    let groups: [ThermalGroup] = [.performanceCPU, .efficiencyCPU, .gpu, .validatedHotspot]
    let available = groups.compactMap { group -> (ThermalGroup, ThermalGroupSummary)? in
      guard case .success(let summary) = p.temperatures(group) else { return nil }
      return (group, summary)
    }
    if available.isEmpty {
      HeliosFactRow(label: "Sensors", value: thermalsGap(p), showsDivider: false)
    } else {
      ForEach(Array(available.enumerated()), id: \.element.0) { index, item in
        HeliosFactRow(
          label: item.0.rawValue,
          value: "\(TelemetryFormatting.temperature(item.1.maximum)) max · \(TelemetryFormatting.temperature(item.1.average)) avg",
          showsDivider: index < available.count - 1)
      }
    }
    if case .success(let system) = p.system {
      Divider()
      HeliosFactRow(label: "macOS thermal pressure", value: system.thermalState.rawValue,
        showsDivider: false)
    }
  }

  private func thermalsGap(_ p: OverviewPresentation) -> String {
    switch p.thermals {
    case .success: "No identified sensors on this Mac"
    case .failure(let error): HeliosText.failure(error)
    }
  }
}

/// Temperature and fan as one block: the two readings side by side, then the
/// temperature chart and, when the fan actually ran, its chart in the same surface.
struct HeliosThermalBlock: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  let presentation: OverviewPresentation
  let markers: [HeliosChartMarker]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 24) {
        reading(
          title: "Temperature", symbol: "thermometer.medium",
          value: HeliosText.value(presentation.thermals.flatMap(\.maximumSoCCelsius)) {
            TelemetryFormatting.temperature($0)
          },
          caption: "Hottest chip sensor")
        Divider().frame(height: 44)
        reading(
          title: "CPU average", symbol: "cpu",
          value: HeliosText.value(presentation.thermals.flatMap(\.averageCPUCelsius)) {
            TelemetryFormatting.temperature($0)
          },
          caption: "P- and E-core mean")
        Divider().frame(height: 44)
        reading(
          title: "Fan", symbol: "fan", value: fanValue, caption: fanCaption)
        Spacer(minLength: 0)
      }
      HeliosChartPanel(
        metric: .temperature, model: model, preferences: context.preferences, scope: .thermals,
        markers: markers, showsTitle: false, bare: true)
      if HeliosCooling.hasFans(presentation) {
        HeliosChartPanel(
          metric: .fan, model: model, preferences: context.preferences, scope: .thermals,
          height: 80, showsRange: false, hidesWhenIdle: true, bare: true)
      }
    }
    .padding(14)
    .heliosGroupSurface()
    .accessibilityElement(children: .contain)
  }

  private func reading(title: String, symbol: String, value: String, caption: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
      Text(value).font(.title2.weight(.semibold)).monospacedDigit()
      Text(caption).font(.subheadline).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private var fanValue: String {
    if HeliosCooling.isFanless(presentation) { return "None" }
    guard case .success(let inventory) = presentation.fans else {
      return HeliosText.value(presentation.fans) { _ in "" }
    }
    return TelemetryFormatting.fanSummary(inventory)
  }

  private var fanCaption: String {
    if HeliosCooling.isFanless(presentation) { return "Passively cooled" }
    guard case .success(let inventory) = presentation.fans, let fan = inventory.fans.first,
      let range = HeliosCooling.rangeText(fan)
    else { return "macOS manages it" }
    return range
  }
}

/// Cooling status and control. Every change goes through FanControlModel and
/// its existing gates; this view never decides fan safety.
struct HeliosCoolingSection: View {
  let context: HeliosContext
  let presentation: OverviewPresentation

  var body: some View {
    if HeliosCooling.isFanless(presentation) {
      HeliosGroup {
        HeliosFactRow(label: "Fans", value: "None · passively cooled", showsDivider: false)
      }
    } else if case .success(let inventory) = presentation.fans {
      if let service = context.service, context.preferences.coolingFeaturesEnabled {
        HeliosCoolingControl(
          model: service.fanControl, client: service.client, preferences: context.preferences,
          inventory: inventory, preflight: presentation.fanOwnershipPreflight,
          host: Self.hostSummary(presentation),
          setUp: { context.actions.openSettingsRoute(.fans) })
      } else {
        VStack(alignment: .leading, spacing: 8) {
          HeliosGroup { HeliosFanRows(inventory: inventory) }
          if context.service != nil {
            Text("Fan control is turned off in Settings. macOS manages the fans.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }
    } else if !context.preferences.isTelemetryCollectionRequired(.fans) {
      HeliosCollectionOffNotice(
        title: "Fan monitoring is off.", module: .fans, preferences: context.preferences)
    } else {
      HeliosGroup {
        HeliosFactRow(label: "Fans", value: HeliosText.value(presentation.fans) { _ in "" },
          showsDivider: false)
      }
    }
  }
}

extension HeliosCoolingSection {
  /// "Mac16,1 · macOS build 26A434" for the unsupported-profile explanation.
  static func hostSummary(_ presentation: OverviewPresentation) -> String? {
    guard case .success(let system) = presentation.system,
      case .success(let model) = system.modelIdentifier,
      case .success(let build) = system.osBuild
    else { return nil }
    return "\(model) · macOS build \(build)"
  }
}

/// Says why the fan modes are greyed out. The helper being installed is not the
/// problem when it is connected: then this Mac/macOS is not a validated profile.
struct HeliosFanUnavailableNotice: View {
  @ObservedObject var client: DaemonClient
  let host: String?
  let setUp: () -> Void

  var body: some View {
    if client.state != .connected {
      VStack(alignment: .leading, spacing: 8) {
        Text("Fan control needs the Helios helper. Until it is set up, macOS manages the fans.")
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Set Up Fan Control…", action: setUp)
      }
    } else if !client.fanControlAvailable, client.fanState != .system {
      Text(client.fanDetail).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if !client.fanControlAvailable, let layer = client.fanLayer, layer.available, !layer.consented {
      VStack(alignment: .leading, spacing: 8) {
        Text("Experimental fan control is available for this Mac.").font(.subheadline.weight(.medium))
        Text("\(layer.machine.isEmpty ? "This Mac" : layer.machine) has not been tested by Helios yet. You can turn on experimental fan control in Settings › Cooling. Until then macOS manages the fans.")
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Open Cooling Settings…", action: setUp)
      }
    } else if !client.fanControlAvailable {
      VStack(alignment: .leading, spacing: 4) {
        Text("Fan control is not available on this Mac yet.").font(.subheadline.weight(.medium))
        Text("The helper is installed and connected, but Helios only writes to fans on a Mac and macOS build it has verified on real hardware. \(host.map { "This Mac is \($0)." } ?? "") macOS keeps managing your fans safely, and temperatures and fan speed are still shown.")
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      Text("Waiting for fresh thermal and fan readings.")
        .font(.subheadline).foregroundStyle(.secondary)
    }
  }
}

extension View {
  /// First-use safety guide before the first non-System fan mode. Choosing the mode
  /// still goes through `FanControlModel.setMode` and its gates.
  func heliosFanSafetyAlert(
    pendingMode: Binding<FanControlSelection?>, model: FanControlModel,
    preferences: HeliosPreferences
  ) -> some View {
    alert("Before changing fan control", isPresented: Binding(
      get: { pendingMode.wrappedValue != nil }, set: { if !$0 { pendingMode.wrappedValue = nil } })
    ) {
      Button("Stay on System", role: .cancel) { pendingMode.wrappedValue = nil }
      Button("I Understand") {
        preferences.completeFanSafetyGuide()
        if let mode = pendingMode.wrappedValue { model.setMode(mode) }
        pendingMode.wrappedValue = nil
      }
    } message: {
      Text("System control is recommended. Boost, Manual and Automatic only add cooling on top of macOS: Helios never runs a fan slower than macOS would, stays within your speed limit, and hands the fans back to macOS when more cooling is needed and on any error. Custom choices remain your responsibility.")
    }
  }
}

/// Compact fan mode switch for the menu-bar temperature popover. Same gates as the
/// Thermals page: a mode is selectable only when `FanControlModel.canSelectMode`.
/// The first-use safety guide is inline here: an alert is a separate window,
/// so a transient popover closed itself and dropped the choice.
struct HeliosFanModeBar: View {
  @ObservedObject var model: FanControlModel
  @ObservedObject var client: DaemonClient
  @ObservedObject var preferences: HeliosPreferences
  let host: String?
  let setUp: () -> Void
  @State private var pendingMode: FanControlSelection?
  private static let logger = Logger(subsystem: "com.snejda.Helios", category: "FanControl")

  private static let modes: [(mode: FanControlSelection, title: String)] = [
    (.system, "System"), (.boost, "Boost"), (.override, "Manual"), (.auto, "Auto"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        ForEach(Self.modes, id: \.mode) { option in
          let selected = model.selection == option.mode
          let enabled = option.mode == .system || model.canSelectMode(option.mode)
          Button(option.title) { select(option.mode) }
            .buttonStyle(.bordered)
            .tint(selected ? Color.accentColor : nil)
            .controlSize(.small)
            .disabled(!enabled)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityLabel("\(option.title) cooling")
        }
      }
      if let mode = pendingMode {
        VStack(alignment: .leading, spacing: 6) {
          Text("Before changing fan control").font(.subheadline.weight(.semibold))
          Text("System is recommended. Helios only adds cooling on top of macOS, stays within your speed limit and hands the fans back to macOS when more cooling is needed or on any error. Custom choices remain your responsibility.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Stay on System") { pendingMode = nil }
            Button("I Understand") {
              preferences.completeFanSafetyGuide()
              pendingMode = nil
              apply(mode)
            }
            .buttonStyle(.borderedProminent)
          }
          .controlSize(.small)
        }
      } else if !model.canSelectControl {
        HeliosFanUnavailableNotice(client: client, host: host, setUp: setUp)
      } else if let notice = HeliosFanHandoverNotice.text(model) {
        HeliosFanHandoverNotice(text: notice, working: model.handingOver)
      } else if model.selection == .override, let bounds = model.limitBounds {
        HeliosManualSpeedControl(model: model, bounds: bounds, compact: true)
      } else if model.selection != .system, !client.fanDetail.isEmpty {
        Text(client.fanDetail).font(.subheadline).foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
  }

  private func select(_ mode: FanControlSelection) {
    Self.logger.notice("Popover fan mode click: \(mode.rawValue, privacy: .public) (selected \(model.selection.rawValue, privacy: .public), selectable \(model.canSelectMode(mode), privacy: .public))")
    guard mode != model.selection else { return }
    if mode != .system, !preferences.fanSafetyGuideCompleted {
      pendingMode = mode
    } else {
      pendingMode = nil
      apply(mode)
    }
  }

  private func apply(_ mode: FanControlSelection) {
    model.setMode(mode)
    if model.selection != mode {
      Self.logger.notice("Popover fan mode \(mode.rawValue, privacy: .public) was not applied; selection stays \(model.selection.rawValue, privacy: .public)")
    }
  }
}

/// Calm takeover feedback: macOS needs several seconds to hand the fans over,
/// and a refused handover is a safe outcome, not an error. Deliberately static
/// (no spinner, no time estimate): a spinning "up to 12 s" is stressful for
/// something that simply happens in the background.
struct HeliosFanHandoverNotice: View {
  let text: String
  let working: Bool

  @MainActor static func text(_ model: FanControlModel) -> String? {
    if model.handingOver { return FanControlModel.handingOverText }
    if model.selection != .system, model.cooldownEndsAt != nil {
      // The helper's reply carries the remaining time (longer after refusals).
      let detail = model.client.fanDetail
      return detail.hasPrefix(FanLayerReacquireCooldown.replyPrefix) ? detail : FanControlModel.cooldownText
    }
    return model.controlNotice
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: working ? "arrow.left.arrow.right" : "info.circle")
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Manual speed: the slider moves freely, the helper is asked after the
/// slider rests for a few seconds and then ramps smoothly.
struct HeliosManualSpeedControl: View {
  @ObservedObject var model: FanControlModel
  let bounds: ClosedRange<Double>
  var compact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Text("At least")
        Slider(value: $model.targetRPM, in: bounds, step: 50)
          .accessibilityLabel("Manual minimum fan speed")
        Text(model.targetRPM.isFinite ? TelemetryFormatting.rpm(model.targetRPM) : "—")
          .monospacedDigit()
          .frame(minWidth: compact ? 64 : 84, alignment: .trailing)
      }
      if model.manualChangeAppliesAt != nil {
        Text("Applies in a few seconds, then the fans change smoothly.")
          .font(.subheadline).foregroundStyle(.secondary)
      } else if !compact, !model.fullMaximumAllowed {
        Text("Up to \(TelemetryFormatting.rpm(bounds.upperBound)), your speed limit (Settings › Cooling).")
          .font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }
}

/// One slider for how quickly the fans follow changes (Response, 0…1).
struct HeliosResponseControl: View {
  @ObservedObject var model: FanControlModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Text("Response")
        Text("Quickly").font(.subheadline).foregroundStyle(.secondary)
        Slider(
          value: Binding(get: { model.response.smoothness },
            set: { model.setResponse(FanLayerResponse(smoothness: ($0 * 20).rounded() / 20) ?? .standard) }),
          in: 0...1
        ) {
          Text("Response")
        }
        .labelsHidden()
        .accessibilityValue(model.response.label)
        .frame(maxWidth: 260)
        Text("Gently").font(.subheadline).foregroundStyle(.secondary)
      }
      Text(caption).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var caption: String {
    guard let bounds = model.limitBounds else {
      return "How quickly the fans follow changes. Extra cooling for heat is always immediate."
    }
    let seconds = Int(model.response.secondsToFall(from: bounds.upperBound, to: bounds.lowerBound).rounded())
    return "From your limit down to the minimum in about \(seconds) s. Extra cooling for heat is always immediate."
  }
}

struct HeliosFanRows: View {
  let inventory: FanInventory

  var body: some View {
    ForEach(Array(inventory.fans.enumerated()), id: \.element.id) { index, fan in
      HeliosFactRow(
        label: inventory.fans.count > 1 ? "Fan \(fan.id + 1)" : "Fan",
        value: HeliosText.value(fan.actualRPM) { TelemetryFormatting.fanRPM($0) },
        detail: HeliosCooling.rangeText(fan),
        showsDivider: index < inventory.fans.count - 1)
    }
  }
}

private struct HeliosCoolingControl: View {
  @ObservedObject var model: FanControlModel
  @ObservedObject var client: DaemonClient
  @ObservedObject var preferences: HeliosPreferences
  let inventory: FanInventory
  let preflight: MetricResult<FanOwnershipPreflightSnapshot>
  /// This Mac's model and macOS build, when known.
  let host: String?
  /// Opens Settings › Cooling, where the helper is installed.
  let setUp: () -> Void
  @State private var pendingMode: FanControlSelection?
  @State private var showSafety = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HeliosGroup {
        HeliosFanRows(inventory: inventory)
        Divider()
        ForEach(Array(Self.modes.enumerated()), id: \.element.mode) { index, option in
          modeRow(option)
          if index < Self.modes.count - 1 { Divider() }
        }
      }

      if model.selection == .override, let bounds = model.limitBounds {
        HeliosManualSpeedControl(model: model, bounds: bounds)
      } else if model.selection == .auto, !model.autoDetail.isEmpty {
        Text(model.autoDetail).font(.subheadline).foregroundStyle(.secondary)
      }

      if model.selection == .auto, model.canSelectControl {
        HeliosGroup {
          HeliosFanCurveEditor(model: model)
        }
      }

      if model.selection == .boost, let end = model.boostEndsAt {
        Text("Boost returns to macOS by itself \(Self.remaining(until: end)).")
          .font(.subheadline).foregroundStyle(.secondary)
      }
      if model.canSelectControl {
        HeliosResponseControl(model: model)
      }

      if !model.canSelectControl {
        HeliosFanUnavailableNotice(client: client, host: host, setUp: setUp)
      } else if let notice = HeliosFanHandoverNotice.text(model) {
        HeliosFanHandoverNotice(text: notice, working: model.handingOver)
      } else if !client.fanDetail.isEmpty, model.selection != .system {
        Text(client.fanDetail).font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      DisclosureGroup("Safety", isExpanded: $showSafety) {
        VStack(alignment: .leading, spacing: 8) {
          Text("System is recommended. Boost, Manual and Automatic only add cooling on top of macOS, within your speed limit (90 % of the factory maximum unless unlocked in Settings › Cooling). The helper reads trusted temperatures itself, never goes below what macOS would do, and returns control to macOS when more cooling is needed, if telemetry stops, on sleep, on quit and on any error. Taking the fans from macOS takes several seconds, during which the fans may briefly run at their minimum; while macOS is already spinning them, Helios therefore only takes over for a clearly higher speed.")
            .fixedSize(horizontal: false, vertical: true)
          HeliosGroup {
            HeliosFactRow(label: "Helper connection", value: client.state.rawValue)
            HeliosFactRow(label: "Fan control", value: client.fanControlAvailable ? "Available" : "Unavailable")
            HeliosFactRow(label: "Fan layer",
              value: client.fanLayer.map { $0.consented ? "\($0.tier.label) · on" : ($0.available ? "\($0.tier.label) · off" : "Not supported") } ?? "—")
            HeliosFactRow(label: "Speed limit",
              value: model.fullMaximumAllowed ? "Factory maximum" : "90 % of the factory maximum", showsDivider: false)
          }
        }
        .font(.subheadline)
        .padding(.top, 6)
      }
    }
    .heliosFanSafetyAlert(pendingMode: $pendingMode, model: model, preferences: preferences)
  }

  private struct ModeOption {
    let mode: FanControlSelection
    let title: String
    let detail: String
  }

  private static let modes = [
    ModeOption(mode: .system, title: "System", detail: "macOS manages the fans. Recommended."),
    ModeOption(mode: .boost, title: "Boost", detail: "Strongest cooling your speed limit allows for 15 minutes, then macOS again."),
    ModeOption(mode: .override, title: "Manual", detail: "At least the speed you choose; more when it gets hot."),
    ModeOption(mode: .auto, title: "Automatic", detail: "Your fan curve or rules, separately for adapter and battery."),
  ]

  private func modeRow(_ option: ModeOption) -> some View {
    let selected = model.selection == option.mode
    let enabled = option.mode == .system || model.canSelectMode(option.mode)
    return Button {
      select(option.mode)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(option.title)
          Text(option.detail).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.vertical, 6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.5)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
    .accessibilityLabel("\(option.title) cooling")
  }

  private func select(_ mode: FanControlSelection) {
    guard mode != model.selection else { return }
    if mode != .system, !preferences.fanSafetyGuideCompleted {
      pendingMode = mode
    } else {
      model.setMode(mode)
    }
  }

  static func remaining(until end: ContinuousClock.Instant) -> String {
    let seconds = max(0, Int(ContinuousClock.now.duration(to: end).components.seconds))
    return seconds >= 60 ? "in about \(seconds / 60) min" : "in under a minute"
  }
}

/// Settings › Cooling: per model + macOS build opt-in for the experimental
/// cool-only fan layer. The helper stores the choice and restarts itself.
struct HeliosFanLayerConsentBox: View {
  @ObservedObject var client: DaemonClient
  @State private var confirming = false
  @State private var working = false
  @State private var message: String?

  var body: some View {
    GroupBox("Experimental fan control") {
      VStack(alignment: .leading, spacing: 10) {
        if client.state != .connected {
          Text("Install and connect the helper above to check this Mac.")
            .font(.subheadline).foregroundStyle(.secondary)
        } else if let layer = client.fanLayer {
          if !layer.machine.isEmpty {
            HStack {
              Text("This Mac")
              Spacer()
              Text(layer.machine).foregroundStyle(.secondary)
            }
          }
          if layer.available {
            Toggle(
              "Use experimental fan control on this Mac",
              isOn: Binding(get: { layer.consented }, set: { $0 ? (confirming = true) : set(false) }))
              .disabled(working)
            Text("Helios never cools less than macOS. It only adds cooling when you choose Boost, Manual or Auto, and hands the fans back to macOS on any error, before sleep and when it quits. This applies only to this Mac and macOS version; after a macOS update Helios asks again.")
              .font(.subheadline).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if layer.consented {
              Divider()
              Toggle(
                "Allow the full factory maximum",
                isOn: Binding(get: { layer.fullMaximumAllowed }, set: { setFullMaximum($0) }))
                .disabled(working)
              Text(layer.fullMaximumAllowed
                ? "Helios may run the fans up to the factory maximum. The fans are louder and wear faster at full speed."
                : "Helios keeps the fans at or below 90 % of the factory maximum. When more cooling is needed, it hands the fans back to macOS, which may use full speed.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          } else {
            Text(layer.detail.isEmpty ? "Fan control is not supported on this Mac." : layer.detail)
              .font(.subheadline).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let message {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
          }
        } else {
          Text("Checking this Mac…").font(.subheadline).foregroundStyle(.secondary)
        }
      }
    }
    .alert("Turn on experimental fan control?", isPresented: $confirming) {
      Button("Cancel", role: .cancel) {}
      Button("Turn On") { set(true) }
    } message: {
      Text("Helios has not been tested on this Mac and macOS version. It only adds cooling on top of macOS and returns control to macOS on any error, but fan control by third-party software is not documented by Apple. This feature is experimental and you use it at your own risk: there is no warranty and no liability for any damage to your Mac.")
    }
  }

  private func setFullMaximum(_ allowed: Bool) {
    working = true
    message = nil
    let sent = client.setFanLayerFullMaximum(allowed) { ok, detail in
      working = false
      message = ok ? nil : detail
    }
    if !sent {
      working = false
      message = "The helper is not connected."
    }
  }

  private func set(_ on: Bool) {
    working = true
    message = nil
    let sent = client.setFanLayerConsent(on) { ok, detail in
      working = false
      message = ok
        ? (on ? "Turned on. The helper restarts and reconnects in a few seconds." : "Turned off. macOS manages the fans.")
        : detail
    }
    if !sent {
      working = false
      message = "The helper is not connected."
      return
    }
    // The helper restarts right after replying; never leave the switch busy.
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(8))
      if working {
        working = false
        message = "The helper restarted. The status above updates when it reconnects."
      }
    }
  }
}

/// Complete thermal inventory: trusted groups, display-only labels and raw keys.
private struct HeliosSensorInventory: View {
  let presentation: OverviewPresentation

  var body: some View {
    switch presentation.thermals {
    case .success(let metrics):
      let inventory = ThermalInventoryPresentation(metrics)
      VStack(alignment: .leading, spacing: 14) {
        if !inventory.identified.isEmpty {
          HeliosSection("Identified sensors") {
            if inventory.identified.contains(where: { $0.group == .unclassified }) {
              Text(HeliosCopy.catalogueSensors).font(.subheadline).foregroundStyle(.secondary)
            }
            HeliosFactList(rows: inventory.identified.map {
              HeliosEvidence(label: $0.key, value: TelemetryFormatting.temperature($0.celsius, decimals: 1),
                source: $0.displayGroup.rawValue)
            })
          }
        }
        if !inventory.auxiliary.isEmpty {
          HeliosSection("Other known sensors") {
            HeliosFactList(rows: inventory.auxiliary.map {
              HeliosEvidence(label: "\($0.info.title) (\($0.reading.key))",
                value: TelemetryFormatting.temperature($0.reading.celsius, decimals: 1),
                source: "Display only")
            })
          }
        }
        if !inventory.unknown.isEmpty {
          HeliosSection("Unclassified sensors") {
            Text(HeliosCopy.unclassifiedSensor).font(.subheadline).foregroundStyle(.secondary)
            HeliosFactList(rows: inventory.unknown.map {
              HeliosEvidence(label: $0.reading.key,
                value: TelemetryFormatting.temperature($0.reading.celsius, decimals: 1))
            })
          }
        }
        if !inventory.advisoryFailures.isEmpty || !inventory.trustedFailures.isEmpty {
          HeliosSection("Read failures") {
            HeliosFactList(rows: (inventory.trustedFailures.map { ($0.key, $0.value, "Trusted") }
              + inventory.advisoryFailures.map { ($0.key, $0.value, "Optional") })
              .sorted { $0.0 < $1.0 }
              .map { HeliosEvidence(label: $0.0, value: $0.1.localizedDescription, source: $0.2) })
          }
        }
        if !inventory.inactive.isEmpty {
          HeliosSection("Not measuring right now") {
            Text(HeliosCopy.inactiveSensors).font(.subheadline).foregroundStyle(.secondary)
            Text(inventory.inactive.joined(separator: ", ")).font(.subheadline.monospaced())
              .foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        if !inventory.unsupported.isEmpty {
          HeliosSection("Not readable by Helios") {
            Text(HeliosCopy.unsupportedSensors).font(.subheadline).foregroundStyle(.secondary)
            Text(inventory.unsupported.joined(separator: ", ")).font(.subheadline.monospaced())
              .foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        if let captured = metrics.advisoryReadingsCapturedAt {
          Text("Optional sensors updated \(TelemetryFormatting.ageSeconds(since: captured)) ago; they refresh less often than identified sensors.")
            .font(.subheadline).foregroundStyle(.secondary)
        }
      }
    case .failure(let error):
      Text("Sensor inventory: \(HeliosText.failure(error))").foregroundStyle(.secondary)
    }
  }
}
