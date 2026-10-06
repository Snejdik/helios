import AppKit
import SwiftUI

/// Helios menu-bar popover: a fixed mini-Overview followed by the
/// sections the user enabled. Shares the one telemetry model with every surface.
struct HeliosStatusPopoverView: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var interface: HeliosInterfacePreferences
  @ObservedObject var feed: HeliosActivityFeed

  static let width: CGFloat = 340

  init(context: HeliosContext) {
    self.context = context
    model = context.model
    interface = context.preferences.interface
    feed = context.feed
  }

  var body: some View {
    let assessment = HeliosMacAssessment.evaluate(
      model.snapshot, configuration: context.preferences.healthAlerts)
    let presentation = model.presentation
    VStack(alignment: .leading, spacing: 14) {
      HeliosOverviewHero(assessment: assessment, compact: true)
      HeliosGroup {
        ForEach(Array(assessment.areas.enumerated()), id: \.element.id) { index, area in
          Button { context.actions.openPage(HeliosPage(focus: area)) } label: {
            HStack(spacing: 8) {
              Image(systemName: area.area.symbol).foregroundStyle(.secondary).frame(width: 18)
                .accessibilityHidden(true)
              Text(area.area.title)
              Spacer(minLength: 6)
              Text(area.value ?? (area.status == .notPresent ? "No battery" : "—"))
                .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
              HeliosStatusLabel(status: area.status, compact: true)
                .frame(width: 84, alignment: .leading)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(area.area.title): \(area.status.label)\(area.value.map { ", \($0)" } ?? "")")
          .accessibilityHint("Opens \(area.area.title) in Helios")
          if index < assessment.areas.count - 1 { Divider() }
        }
      }

      ForEach(interface.popoverSections) { section in
        sectionView(section, assessment: assessment, presentation: presentation)
      }

      Divider()
      HStack(spacing: 10) {
        Button("Open Helios") { context.actions.openPage(.overview) }
          .keyboardShortcut(.defaultAction)
        Spacer()
        Button("Settings…", action: context.actions.openSettings)
        Button("Quit") { NSApp.terminate(nil) }
      }
      .controlSize(.small)
    }
    .padding(16)
    .frame(width: Self.width)
  }

  @ViewBuilder
  private func sectionView(
    _ section: HeliosPopoverSection, assessment: HeliosMacAssessment, presentation: OverviewPresentation
  ) -> some View {
    switch section {
    case .chart:
      let automatic = assessment.focus.flatMap { assessment.area($0)?.chartMetric } ?? .cpu
      HeliosChartPanel(
        metric: interface.overviewChartMetric ?? automatic, model: model,
        preferences: context.preferences, scope: .overview, height: 56, showsRange: false)
    case .processes:
      HeliosRightNowSection(context: context, presentation: presentation, limit: 3)
    case .cooling:
      // Only on Macs where Helios actually detects a fan.
      if HeliosCooling.hasFans(presentation) {
        HeliosPopoverCooling(context: context, presentation: presentation)
      }
    case .activity:
      HeliosRecentSection(events: Array(feed.recent(3))) { context.actions.openPage(.activity) }
    case .network:
      HeliosPopoverNetwork(context: context, presentation: presentation)
    }
  }
}

private struct HeliosPopoverNetwork: View {
  let context: HeliosContext
  let presentation: OverviewPresentation

  var body: some View {
    HeliosSection("Network") {
      if !context.preferences.isTelemetryCollectionRequired(.network) {
        HeliosCollectionOffNotice(
          title: "Network monitoring is off.", module: .network, preferences: context.preferences)
      } else {
        switch presentation.network.flatMap(\.throughput) {
        case .success(let rate):
          HStack {
            Label(TelemetryFormatting.bytesPerSecond(rate.downloadBytesPerSecond), systemImage: "arrow.down")
            Spacer()
            Label(TelemetryFormatting.bytesPerSecond(rate.uploadBytesPerSecond), systemImage: "arrow.up")
          }
          .monospacedDigit()
          .accessibilityElement(children: .combine)
        case .failure(let error):
          Text(HeliosText.failure(error)).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Cooling line with a quick mode menu. Same FanControlModel gates and
/// first-use safety guide as the Thermals page.
private struct HeliosPopoverCooling: View {
  let context: HeliosContext
  let presentation: OverviewPresentation

  var body: some View {
    if let service = context.service, context.preferences.coolingFeaturesEnabled {
      HeliosPopoverCoolingControl(
        model: service.fanControl, preferences: context.preferences,
        fans: fanSummary)
    } else {
      HStack {
        Label("Cooling", systemImage: "fan")
        Spacer()
        Text("System · \(fanSummary)").monospacedDigit().foregroundStyle(.secondary)
      }
    }
  }

  private var fanSummary: String {
    if case .success(let inventory) = presentation.fans { return TelemetryFormatting.fanSummary(inventory) }
    return "—"
  }
}

private struct HeliosPopoverCoolingControl: View {
  @ObservedObject var model: FanControlModel
  @ObservedObject var preferences: HeliosPreferences
  let fans: String
  @State private var pendingMode: FanControlSelection?

  var body: some View {
    HStack(spacing: 8) {
      Label("Cooling", systemImage: "fan")
      Spacer()
      Text(fans).monospacedDigit().foregroundStyle(.secondary)
      Menu(HeliosCooling.modeTitle(model.selection)) {
        ForEach([FanControlSelection.system, .boost, .override, .auto], id: \.self) { mode in
          Button {
            select(mode)
          } label: {
            if mode == model.selection {
              Label(HeliosCooling.modeTitle(mode), systemImage: "checkmark")
            } else {
              Text(HeliosCooling.modeTitle(mode))
            }
          }
          .disabled(mode != .system && !model.canSelectMode(mode))
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Cooling mode: \(HeliosCooling.modeTitle(model.selection))")
    }
    .alert("Before changing fan control", isPresented: Binding(
      get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } })
    ) {
      Button("Stay on System", role: .cancel) { pendingMode = nil }
      Button("I Understand") {
        preferences.completeFanSafetyGuide()
        if let mode = pendingMode { model.setMode(mode) }
        pendingMode = nil
      }
    } message: {
      Text("System control is recommended. Boost, Manual and Automatic Rules override macOS fan targets. Helios keeps targets inside the validated factory range and the helper enforces a 95 °C maximum-cooling guard. Custom choices remain your responsibility.")
    }
  }

  private func select(_ mode: FanControlSelection) {
    guard mode != model.selection else { return }
    if mode != .system, !preferences.fanSafetyGuideCompleted {
      pendingMode = mode
    } else {
      model.setMode(mode)
    }
  }
}
