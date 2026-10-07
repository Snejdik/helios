import AppKit
import SwiftUI

/// A short "what changed" window shown once after Helios is updated. A fresh
/// installation sees the welcome flow instead and never gets this window.
enum HeliosWhatsNew {
  struct Highlight: Identifiable, Sendable {
    let symbol: String
    let title: String
    let detail: String
    var id: String { title }
  }

  static let lastSeenReleaseKey = "v2.ui.lastSeenRelease"

  /// Notes per release (major.minor.patch). A release without notes only records
  /// itself, so a forgotten entry can never show an older release's text.
  static let notes: [String: [Highlight]] = [
    "0.2.1": [
      Highlight(
        symbol: "thermometer.medium",
        title: "Temperatures on more Macs",
        detail:
          "CPU and GPU temperatures now appear on M1, M2, M3, M5 and M6 Macs too. Their sensor map comes from a public catalogue and is verified only on M4, so fan control is unchanged."),
      Highlight(
        symbol: "fan",
        title: "Auto cooling stays on",
        detail:
          "Automatic, Manual and Boost no longer drop back to System whenever the GPU goes to sleep."),
      Highlight(
        symbol: "envelope.badge.shield.half.filled",
        title: "Weekly compatibility report (optional)",
        detail:
          "If you tick it below, Helios sends which sensors and fans your Mac has once a week, so it can learn Macs I do not own. Anonymous and off by default."),
      Highlight(
        symbol: "trash",
        title: "One-click uninstall",
        detail:
          "Settings › Advanced › Uninstall Helios returns the fans to macOS, removes the helper and moves the app to the Trash."),
    ]
  ]

  enum Decision: Equatable, Sendable {
    case show
    case recordOnly
    case nothing
  }

  static func decide(lastSeen: String?, current: HeliosReleaseVersion?, onboardingCompleted: Bool)
    -> Decision
  {
    // Development builds without a matching release tag never show or record anything.
    guard let current else { return .nothing }
    // First launch (or the welcome flow was requested again): the welcome flow explains Helios.
    guard onboardingCompleted else { return lastSeen == current.tag ? .nothing : .recordOnly }
    guard let lastSeen else {
      // Builds before 0.2.1 never stored a release, so this is an update.
      return notes[current.base] == nil ? .recordOnly : .show
    }
    if lastSeen == current.tag { return .nothing }
    guard let previous = HeliosReleaseVersion(tag: lastSeen) else {
      return notes[current.base] == nil ? .recordOnly : .show
    }
    // Beta to final of the same release, or a downgrade: nothing new to tell.
    guard previous.base != current.base, previous < current, notes[current.base] != nil else {
      return .recordOnly
    }
    return .show
  }
}

/// Keeps the helper state visible after an update. A replaced app bundle changes the
/// helper's code signature, which may need the helper to be installed again.
private struct HeliosWhatsNewHelperRow: View {
  @ObservedObject var service: DaemonService
  @ObservedObject var client: DaemonClient

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Fan helper").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      switch service.state {
      case .installed:
        switch client.state {
        case .connected:
          Label("Connected and working", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        case .connecting, .disconnected:
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Connecting to the helper…").foregroundStyle(.secondary)
          }
        case .versionMismatch, .signingRequired, .failed:
          Text("The helper from the previous version does not answer this one. Reinstall it once; macOS may ask you to approve it again.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Reinstall Helper") { Task { await service.reinstall() } }
            .disabled(service.busy)
        }
      case .requiresApproval:
        Text("macOS is waiting for you to allow the helper in Login Items & Extensions.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Open System Settings") { service.openApprovalSettings() }
      case .missing, .unavailable:
        EmptyView()
      }
      if let message = service.message {
        Text(message).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 13))
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The two anonymous-report opt-ins, for people who updated and never see the welcome again.
private struct HeliosWhatsNewSharingRows: View {
  let diagnostics: DiagnosticsController
  @ObservedObject var preferences: DiagnosticsPreferences

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Help Helios work on more Macs").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      Toggle("Share anonymous diagnostics", isOn: Binding(
        get: { preferences.automaticEnabled }, set: { diagnostics.setAutomaticEnabled($0) }))
        .toggleStyle(.checkbox)
      Toggle("Send a weekly compatibility report", isOn: Binding(
        get: { preferences.weeklyCompatibilityEnabled },
        set: { diagnostics.setWeeklyCompatibilityEnabled($0) }))
        .toggleStyle(.checkbox)
      Text("No names, files or apps. Settings › Privacy & Diagnostics shows exactly what is sent.")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 13))
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct HeliosWhatsNewView: View {
  @ObservedObject var preferences: HeliosPreferences
  /// Nil in offline renders and tests.
  let service: DaemonService?
  let release: HeliosReleaseVersion
  /// Nil in offline renders and tests; then the sharing choices are not shown.
  var diagnostics: DiagnosticsController? = nil
  let onContinue: () -> Void

  private var highlights: [HeliosWhatsNew.Highlight] { HeliosWhatsNew.notes[release.base] ?? [] }
  private var showsHelper: Bool {
    guard let service else { return false }
    return service.state == .installed || service.state == .requiresApproval
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(spacing: 8) {
            HeliosApplicationIcon(size: 54)
            Text("What’s New in \(release.displayName)").font(.system(size: 22, weight: .semibold))
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 14) {
            ForEach(highlights) { highlight in
              HStack(alignment: .top, spacing: 12) {
                Image(systemName: highlight.symbol)
                  .font(.system(size: 18))
                  .foregroundStyle(.secondary)
                  .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                  Text(highlight.title).font(.system(size: 13, weight: .semibold))
                  Text(highlight.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .accessibilityElement(children: .combine)
            }
          }

          VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
              Text("Temperature unit").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
              Picker("Temperature unit", selection: $preferences.temperatureUnit) {
                ForEach(TemperatureUnit.allCases) { unit in Text(unit.suffix).tag(unit) }
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .fixedSize()
            }
            if let diagnostics {
              Divider()
              HeliosWhatsNewSharingRows(diagnostics: diagnostics, preferences: diagnostics.preferences)
            }
            if showsHelper, let service {
              Divider()
              HeliosWhatsNewHelperRow(service: service, client: service.client)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
      }

      Divider()
      HStack {
        Text("You can change these later in Settings.").font(.subheadline).foregroundStyle(.secondary)
        Spacer()
        Button("Continue", action: onContinue).keyboardShortcut(.defaultAction)
      }
      .padding(18)
    }
    .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 760)
    .background(.regularMaterial)
  }
}
