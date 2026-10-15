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
    "0.3.0": [
      Highlight(
        symbol: "stethoscope",
        title: "Ask Helios why",
        detail:
          "Why is my Mac slow, hot, draining the battery, not sleeping or restarting, why is the Wi-Fi slow: Helios answers with what it sees, why it thinks so and what you can do."),
      Highlight(
        symbol: "heart.text.square",
        title: "Longevity",
        detail:
          "A new page on how the battery, power adapter, SSD, cooling and memory hold up over months, in words, with estimates marked as estimates. Export a weekly report."),
      Highlight(
        symbol: "cup.and.saucer",
        title: "Keep Awake, command palette and rules",
        detail:
          "Keep your Mac awake for a while or until an app quits, open anything with ⌃⌥⌘Space, and let simple rules notify you or switch fans back to macOS."),
      Highlight(
        symbol: "fan",
        title: "Fan control on more Macs (experimental)",
        detail:
          "On Macs other than the tested M4, fan control can be turned on as an experiment after a 20-second fan test, with a 70 % limit. The fan helper must be reinstalled once for this version."),
    ],
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

  /// A short guided page after the highlights: what to do with a new feature. `fans`
  /// pages also show the helper state and a way to Settings › Cooling.
  struct Guide: Identifiable, Sendable {
    let symbol: String
    let title: String
    let intro: String
    let steps: [String]
    var footnote: String? = nil
    var fans = false
    var id: String { title }
  }

  static let guides: [String: [Guide]] = [
    "0.3.0": [
      Guide(
        symbol: "stethoscope", title: "Ask Helios why",
        intro: "When something feels off, ask. Helios answers from what it measures on this Mac: what it sees, why it thinks so, and what you can do. It says how sure it is (Likely or Possible) and what it could not check.",
        steps: [
          "Overview › Ask Helios: choose a question such as \u{201C}Why is my Mac slow?\u{201D}",
          "CPU, Thermals, Battery, Storage and Network each have their own Why? section.",
          "⌃⌥⌘Space opens the command palette from anywhere: type a question, a page or an action.",
          "Checkup (sidebar) shows what Helios found and what would let it see more.",
        ]),
      Guide(
        symbol: "heart.text.square", title: "Longevity",
        intro: "Helios now keeps one small record a day of the things that wear a Mac out over months, so a single reading is never mistaken for a trend. It stays on this Mac.",
        steps: [
          "Battery wear, cycles and charging habits; the power adapter and whether the cable limits it.",
          "SSD writes and the drive's own endurance estimate; memory pressure and swap.",
          "Cooling under similar load compared with the first four weeks: a hint of dust or a blocked vent.",
          "First grades appear within a day; trends need a few weeks. Export a report as PDF or HTML.",
        ],
        footnote: "Grades are words, never a bare score, and every estimate says it is one."),
      Guide(
        symbol: "cup.and.saucer", title: "Tools that save clicks",
        intro: "Everything here is off until you use it, and nothing runs in the background while it is off.",
        steps: [
          "Keep Awake in the popover and on the Overview: for a while, while on power, or until an app quits.",
          "Tell me when it's done: an app finishes, the Mac calms down, or a download ends.",
          "Rules in Settings › Automation: for example, notify me when the Mac gets hot.",
          "Network: optional latency history and data usage per app, kept on this Mac.",
        ]),
      Guide(
        symbol: "fan", title: "Fan control on your Mac (experimental)",
        intro: "macOS controls the fans, and Helios can only ever add cooling on top, never less. It is supported on the one Mac and macOS version Helios was tested on; on every other Mac you can turn it on as an experiment, in four steps:",
        steps: [
          "Reinstall the fan helper (below). Each update changes its signature, so macOS asks once.",
          "Settings › Cooling › Use experimental fan control on this Mac. It applies to this Mac model and macOS version only.",
          "Run Fan Test: for 20 seconds each fan runs at its lowest speed (you may hear it), Helios checks the Mac obeys and hands the fans back. If macOS does not hand them over right then, nothing is saved; try again in a few minutes.",
          "Then choose Manual or Auto on the Thermals page or in the cooling popover: up to 70 % of the factory maximum, without Boost. Auto starts once Helios has confirmed this Mac's CPU sensors.",
        ],
        footnote: "On any error, before sleep and when Helios quits, the fans go back to macOS. At 95 °C the helper acts on its own.",
        fans: true),
    ],
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

/// The last thing on the last page: a quiet way to support Helios, never a prompt.
private struct HeliosWhatsNewSupportRow: View {
  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "cup.and.saucer")
        .font(.system(size: 18)).foregroundStyle(.secondary)
        .frame(width: 26)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Support Helios").font(.system(size: 13, weight: .semibold))
        Text("Helios is free and made by one person. A coffee helps pay for test Macs.")
          .font(.system(size: 13)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Buy Me a Coffee") {
        guard let url = URL(string: "https://buymeacoffee.com/snejda") else { return }
        NSWorkspace.shared.open(url)
      }
      .help("Opens buymeacoffee.com/snejda in your browser.")
    }
    .padding(.horizontal, 16)
    .accessibilityElement(children: .contain)
  }
}

struct HeliosWhatsNewView: View {
  @ObservedObject var preferences: HeliosPreferences
  /// Nil in offline renders and tests.
  let service: DaemonService?
  let release: HeliosReleaseVersion
  /// Nil in offline renders and tests; then the sharing choices are not shown.
  var diagnostics: DiagnosticsController? = nil
  /// Opens Settings › Cooling (the fan guide's button); nil hides the button.
  var openCooling: (() -> Void)? = nil
  /// First page shown; offline renders use it to draw every page.
  var initialPage = 0
  let onContinue: () -> Void

  @State private var page: Int?

  private var highlights: [HeliosWhatsNew.Highlight] { HeliosWhatsNew.notes[release.base] ?? [] }
  private var guides: [HeliosWhatsNew.Guide] { HeliosWhatsNew.guides[release.base] ?? [] }
  /// Highlights, one page per guide, then the choices; a release without guides keeps one page.
  private var pageCount: Int { guides.isEmpty ? 1 : guides.count + 2 }
  private var current: Int { min(max(0, page ?? initialPage), pageCount - 1) }
  private var showsHelper: Bool {
    guard let service else { return false }
    return service.state == .installed || service.state == .requiresApproval
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if guides.isEmpty {
            header
            highlightList
            choices
            HeliosWhatsNewSupportRow()
          } else if current == 0 {
            header
            highlightList
            Text("The next pages show how to use each of these.")
              .font(.subheadline).foregroundStyle(.secondary)
          } else if current <= guides.count {
            guide(guides[current - 1])
          } else {
            VStack(alignment: .leading, spacing: 6) {
              Text("Your choices").font(.system(size: 20, weight: .semibold))
              Text("Two quick settings. Both can be changed later in Settings.")
                .foregroundStyle(.secondary)
            }
            choices
            HeliosWhatsNewSupportRow()
          }
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
      }
      .id(current)

      Divider()
      HStack(spacing: 10) {
        if pageCount > 1 {
          HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
              Circle().fill(index == current ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 6, height: 6)
            }
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Page \(current + 1) of \(pageCount)")
        } else {
          Text("You can change these later in Settings.").font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        if current > 0 {
          Button("Back") { page = current - 1 }
        }
        if current < pageCount - 1 {
          Button("Next") { page = current + 1 }.keyboardShortcut(.defaultAction)
        } else {
          Button("Continue", action: onContinue).keyboardShortcut(.defaultAction)
        }
      }
      .padding(18)
    }
    .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 760)
    .background(.regularMaterial)
  }

  private var header: some View {
    VStack(spacing: 8) {
      HeliosApplicationIcon(size: 54)
      Text("What’s New in \(release.displayName)").font(.system(size: 22, weight: .semibold))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
  }

  private var highlightList: some View {
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
  }

  private func guide(_ guide: HeliosWhatsNew.Guide) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: guide.symbol).font(.system(size: 26)).foregroundStyle(Color.accentColor)
          .frame(width: 34)
          .accessibilityHidden(true)
        Text(guide.title).font(.system(size: 20, weight: .semibold))
      }
      Text(guide.intro).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(guide.fans ? "\(index + 1)" : "•")
              .font(.system(size: 13, weight: .semibold)).monospacedDigit()
              .foregroundStyle(guide.fans ? Color.accentColor : .secondary)
              .frame(width: 16, alignment: .trailing)
            Text(step).font(.system(size: 13)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .combine)
        }
      }
      if let footnote = guide.footnote {
        Label(footnote, systemImage: guide.fans ? "checkmark.shield" : "info.circle")
          .font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if guide.fans {
        VStack(alignment: .leading, spacing: 14) {
          if showsHelper, let service {
            HeliosWhatsNewHelperRow(service: service, client: service.client)
          }
          if let openCooling {
            Button("Open Cooling Settings…", action: openCooling)
          }
          Text("Not interested? Leave it off: macOS keeps managing the fans and Helios keeps showing them.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
  }

  private var choices: some View {
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
      // Without a fan guide the helper state stays here, as before.
      if guides.isEmpty, showsHelper, let service {
        Divider()
        HeliosWhatsNewHelperRow(service: service, client: service.client)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
