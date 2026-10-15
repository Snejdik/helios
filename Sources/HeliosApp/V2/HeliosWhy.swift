import AppKit
import SwiftUI

/// App-wide inputs of the "Why?" engine that are not in the telemetry snapshot: macOS's
/// diagnostic reports (read at most every five minutes, off the main thread), the last
/// on-demand network check, whether Helios's previous run ended cleanly, and what Helios
/// itself is doing (fans, Keep Awake). Local only; nothing here is ever sent anywhere.
@MainActor
final class HeliosDiagnosisCenter: ObservableObject {
  static let shared = HeliosDiagnosisCenter()
  static let sessionKey = "HeliosSession.endedCleanly.v1"

  @Published private(set) var reports: [DiagnosticReportSummary] = []
  @Published private(set) var networkCheck: HeliosNetworkCheck?
  @Published private(set) var networkChecking = false
  /// A question asked from outside the window (palette, link); the Overview opens it.
  @Published var requestedLens: HeliosLens?
  private(set) var previousSessionEndedUncleanly: Bool?
  private var reportsReadAt: Date?
  private var reportsTask: Task<Void, Never>?
  /// Set by the app once the fan service exists: the RPM Helios holds, or nil on System.
  var heliosFanRPM: () -> Double? = { nil }
  private var wifiDrops = HeliosWiFiDropTracker()

  /// Cheap per-snapshot bookkeeping (Wi-Fi drops only).
  func observe(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    wifiDrops.observe(try? snapshot.wifi.result.get(), now: now)
  }

  /// Records that a session is running; the previous value says whether the last one ended.
  func beginSession(defaults: UserDefaults = .standard) {
    if let stored = defaults.object(forKey: Self.sessionKey) as? Bool { previousSessionEndedUncleanly = !stored }
    defaults.set(false, forKey: Self.sessionKey)
  }

  func endSession(defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: Self.sessionKey)
  }

  func refreshReportsIfNeeded(now: Date = Date()) {
    guard reportsTask == nil, reportsReadAt.map({ now.timeIntervalSince($0) > 300 }) ?? true else { return }
    reportsTask = Task { [weak self] in
      let since = now.addingTimeInterval(-HeliosDiagnose.reportWindow)
      let read = await Task.detached(priority: .utility) { DiagnosticReportsReader.read(since: since) }.value
      self?.reports = read
      self?.reportsReadAt = now
      self?.reportsTask = nil
    }
  }

  func runNetworkCheck() {
    guard !networkChecking else { return }
    networkChecking = true
    Task { [weak self] in
      let check = await HeliosNetworkProbe.run()
      self?.networkCheck = check
      HeliosLatencyMonitor.shared.record(check)
      self?.networkChecking = false
    }
  }

  func input(snapshot: TelemetrySnapshot, now: Date = Date()) -> HeliosDiagnosisInput {
    HeliosDiagnosisInput(
      snapshot: snapshot, now: now, reports: reports,
      previousSessionEndedUncleanly: previousSessionEndedUncleanly,
      heliosFanRPM: heliosFanRPM(), keepAwakeActive: HeliosKeepAwake.shared.isActive,
      network: networkCheck, wifiDropsLastHour: wifiDrops.drops.count,
      latencyHistory: HeliosLatencyMonitor.shared.samples)
  }
}

/// The one list of things Helios can do on request. "Why?" causes, the command palette,
/// the `helios://` URL scheme and rules all go through here; fan modes are never in it
/// except through `FanControlModel` and its gates.
@MainActor
enum HeliosActionRegistry {
  static func perform(_ action: HeliosActionID, context: HeliosContext) {
    switch action {
    case .openActivityMonitor:
      HeliosAppActions.openActivityMonitor()
    case .openPage(let name):
      if let page = HeliosPage(rawValue: name) { context.actions.openPage(page) }
    case .openSystemSettings(let pane):
      openSystemSettings(pane)
    case .revealDiagnosticReports:
      NSWorkspace.shared.open(URL(fileURLWithPath: DiagnosticReportsReader.systemFolder, isDirectory: true))
    case .quitProcess(let pid, let name):
      quit(pid: pid, name: name)
    case .startKeepAwake:
      HeliosKeepAwake.shared.start(minutes: 60)
    case .stopKeepAwake:
      HeliosKeepAwake.shared.stop(reason: "Stopped.")
    case .runNetworkCheck:
      HeliosDiagnosisCenter.shared.runNetworkCheck()
    }
  }

  static func openSystemSettings(_ pane: String) {
    let identifiers = [
      "Battery": "com.apple.Battery-Settings.extension",
      "Network": "com.apple.Network-Settings.extension",
      "VPN": "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension",
      "Displays": "com.apple.Displays-Settings.extension",
      "Lock Screen": "com.apple.Lock-Screen-Settings.extension",
    ]
    let id = identifiers[pane] ?? "com.apple.systempreferences"
    if let url = URL(string: "x-apple.systempreferences:\(id)") { NSWorkspace.shared.open(url) }
  }

  /// Only regular apps are quit, gracefully and after a confirmation; anything else
  /// (daemons, helpers) opens Activity Monitor instead of being killed.
  static func quit(pid: Int32, name: String) {
    guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
      pid != ProcessInfo.processInfo.processIdentifier
    else {
      HeliosAppActions.openActivityMonitor()
      return
    }
    let alert = NSAlert()
    alert.messageText = "Quit \(name)?"
    alert.informativeText = "\(name) gets the chance to save first, as if you chose Quit in its menu."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { app.terminate() }
  }
}

/// "Why?" for one question: collapsed by default (nothing is computed until opened), then
/// each cause as "what I see → why I think so → what you can do", most likely first.
struct HeliosWhySection: View {
  let lens: HeliosLens
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @ObservedObject private var center = HeliosDiagnosisCenter.shared
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        expanded.toggle()
        if expanded { center.refreshReportsIfNeeded() }
      } label: {
        Label(lens.question, systemImage: expanded ? "chevron.down" : "questionmark.circle")
          .font(.headline)
      }
      .buttonStyle(.plain)
      .accessibilityHint(expanded ? "Hides the explanation" : "Shows what Helios sees")
      if expanded {
        HeliosDiagnosisView(
          diagnosis: HeliosDiagnose.run(lens, center.input(snapshot: model.snapshot)),
          context: context, networkChecking: center.networkChecking)
      }
    }
  }
}

struct HeliosDiagnosisView: View {
  let diagnosis: HeliosDiagnosis
  let context: HeliosContext
  var networkChecking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if diagnosis.causes.isEmpty {
        Text(diagnosis.summary).foregroundStyle(.secondary)
      }
      ForEach(diagnosis.causes) { cause in
        // The network question has its own Check Network button below.
        HeliosCauseRow(cause: cause, context: context,
                       showsAction: !(diagnosis.lens == .slowNetwork && cause.action == .runNetworkCheck))
      }
      if diagnosis.lens == .slowNetwork {
        Button(networkChecking ? "Checking… (about 6 s)" : "Check Network") {
          HeliosDiagnosisCenter.shared.runNetworkCheck()
        }
        .disabled(networkChecking)
      }
      ForEach(diagnosis.gaps, id: \.self) { gap in
        Label(gap, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(12)
    .heliosGroupSurface()
  }
}

private struct HeliosCauseRow: View {
  let cause: HeliosCause
  let context: HeliosContext
  var showsAction = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(cause.confidence.label)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(cause.confidence == .likely ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15),
                      in: Capsule())
        Text(cause.observation).font(.body.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(cause.reasoning).font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if showsAction, let action = cause.action {
        Button(action.title) { HeliosActionRegistry.perform(action, context: context) }
          .controlSize(.small)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Overview: every question in one place, one open at a time.
struct HeliosAskSection: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  /// Title above the question menu (the Overview's narrow second column).
  var stacked = false
  @ObservedObject private var center = HeliosDiagnosisCenter.shared
  @State private var lens: HeliosLens?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if stacked {
        Text("Ask Helios").font(.headline).accessibilityAddTraits(.isHeader)
        questionMenu
      } else {
        HStack {
          Text("Ask Helios").font(.headline).accessibilityAddTraits(.isHeader)
          Spacer()
          questionMenu.fixedSize()
        }
      }
      if let lens {
        HeliosDiagnosisView(
          diagnosis: HeliosDiagnose.run(lens, center.input(snapshot: model.snapshot)),
          context: context, networkChecking: center.networkChecking)
      }
    }
    .onReceive(center.$requestedLens) { requested in
      guard let requested else { return }
      lens = requested
      center.refreshReportsIfNeeded()
      center.requestedLens = nil
    }
  }

  private var questionMenu: some View {
    Menu(lens?.question ?? "Choose a question") {
      ForEach(HeliosLens.allCases) { item in
        Button(item.question) {
          lens = item
          center.refreshReportsIfNeeded()
        }
      }
    }
  }
}
