import SwiftUI

/// One telemetry sampler in Settings › Modules › Data Collection: name, what it
/// reads, its cost and state on the left, the switch in a right-aligned column.
struct HeliosSamplerRow: View {
  let title: String
  let detail: String
  let cost: String
  let status: String
  let isCollecting: Bool
  @Binding var isOn: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 4) {
          Text(status)
            .foregroundStyle(isCollecting ? Color.green : Color.secondary)
          Text("· \(cost) cost").foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .medium))
      }
      Spacer(minLength: 8)
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(title)
    }
    .padding(.vertical, 7)
    .accessibilityElement(children: .combine)
  }
}

/// Segmented interface preset. The label is hidden so the four segments get the
/// whole row; with a label beside it the control overflowed and clipped "Simple".
struct HeliosPresetPicker: View {
  @Binding var selection: HeliosDashboardMode

  var body: some View {
    Picker("Preset", selection: $selection) {
      ForEach(HeliosDashboardMode.allCases) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(maxWidth: .infinity)
    .accessibilityLabel("Interface preset")
  }
}

/// One look for every Settings group: a quiet title above, content in a rounded
/// grouped surface (the Helios design system's group), no heavy native box.
struct HeliosSettingsGroupBoxStyle: GroupBoxStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      configuration.label
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
      configuration.content
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .heliosGroupSurface()
    }
  }
}

/// Multi-select goal cards, shared by the welcome flow and Settings › General.
/// "Just tell me if my Mac is OK" is exclusive: it means nothing extra.
struct HeliosGoalPicker: View {
  @Binding var selection: Set<HeliosGoal>
  /// Goals this Mac can serve; the welcome hides cooling on a fanless Mac and
  /// battery on a desktop.
  var available: [HeliosGoal] = HeliosGoal.allCases

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
      spacing: 10
    ) {
      ForEach(available.filter { $0 != .simple }) { card($0) }
      card(.simple).gridCellColumns(2)
    }
  }

  private func toggle(_ goal: HeliosGoal) {
    if selection.contains(goal) {
      selection.remove(goal)
    } else if goal == .simple {
      selection = [.simple]
    } else {
      selection.remove(.simple)
      selection.insert(goal)
    }
  }

  private func card(_ goal: HeliosGoal) -> some View {
    let selected = selection.contains(goal)
    return Button { toggle(goal) } label: {
      HStack(spacing: 12) {
        Image(systemName: goal.symbol)
          .font(.system(size: 18, weight: .medium))
          .frame(width: 26)
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(goal.title).font(.system(size: 13, weight: .semibold))
          Text(goal.detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.6))
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.18),
            lineWidth: selected ? 1.25 : 0.7))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(goal.title)
    .accessibilityValue(selected ? "Selected" : "Not selected")
    .accessibilityHint(goal.detail)
  }
}

/// The helper action inside the welcome flow: one clear button for the current
/// registration state. All registration work stays in DaemonService.
struct HeliosHelperSetupRow: View {
  @ObservedObject var service: DaemonService

  var body: some View {
    VStack(spacing: 8) {
      switch service.state {
      case .installed:
        Label("Helper installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
      case .requiresApproval:
        Button("Open System Settings") { service.openApprovalSettings() }
          .buttonStyle(.borderedProminent)
        Text("Turn on Helios in Login Items & Extensions.")
          .font(.subheadline).foregroundStyle(.secondary)
      case .missing:
        Button("Install Helper") { service.install() }
          .buttonStyle(.borderedProminent)
          .disabled(service.busy)
      case .unavailable:
        Text("The helper is not available on this Mac.")
          .font(.subheadline).foregroundStyle(.secondary)
      }
      if let message = service.message {
        Text(message).font(.subheadline).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
  }
}

/// "Support Helios" at the foot of the main window's sidebar (never in a popover).
struct HeliosSupportRow: View {
  var body: some View {
    VStack(spacing: 0) {
      Divider()
      Button {
        guard let url = URL(string: "https://buymeacoffee.com/snejda") else { return }
        NSWorkspace.shared.open(url)
      } label: {
        Label("Support Helios", systemImage: "cup.and.saucer")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Helios is free. A coffee helps pay for test hardware.")
      .accessibilityLabel("Support Helios with a coffee")
    }
  }
}

/// One calm, dismissible reminder a week after first use for people who have not
/// shared anonymous diagnostics. It never blocks anything.
struct HeliosDiagnosticsReminder: View {
  @ObservedObject var diagnosticsPreferences: DiagnosticsPreferences
  @ObservedObject var interface: HeliosInterfacePreferences
  let review: () -> Void

  var body: some View {
    if interface.shouldShowDiagnosticsReminder(sharingDiagnostics: diagnosticsPreferences.automaticEnabled) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "stethoscope").foregroundStyle(.secondary).padding(.top, 2)
        VStack(alignment: .leading, spacing: 8) {
          Text("Help Helios work on more Macs").font(.headline)
          Text("Anonymous diagnostics let me fix problems on Macs I do not own. Nothing is sent unless you turn it on, and you can see exactly what would be sent first.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Review…", action: review)
            Button("Not now") { interface.dismissDiagnosticsReminder() }
          }
        }
        Spacer(minLength: 0)
      }
      .padding(14)
      .heliosGroupSurface()
    }
  }
}

/// Settings › Cooling: re-arm Auto (with the saved curve) after launch and wake.
struct HeliosRestoreAutoToggle: View {
  @ObservedObject var model: FanControlModel
  let isEnabled: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle("Restore Auto when Helios starts", isOn: $model.restoresAutoOnStart)
        .disabled(!isEnabled)
      Text("If Auto was your last choice, Helios arms it again after launch and after the helper reconnects, for example following sleep. Your curve and Response setting are kept either way. Manual and Boost are never restored.")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
