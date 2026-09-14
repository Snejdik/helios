import AppKit
import SwiftUI

/// App-only presentation boundary; a future Sparkle integration can replace this without
/// touching telemetry or privileged control. Automatic notices never activate the app.
@MainActor
final class HeliosUpdatePresenter {
  static let shared = HeliosUpdatePresenter()
  let checker = HeliosUpdateChecker()
  private var panel: NSPanel?
  private var task: Task<Void, Never>?

  func check(manual: Bool) {
    guard task == nil else { return }
    task = Task { [weak self] in
      guard let self else { return }
      defer { task = nil }
      guard let outcome = await checker.check(manual: manual), !Task.isCancelled else { return }
      present(outcome, manual: manual)
    }
  }

  func shutdown() {
    task?.cancel()
    panel?.close()
    panel = nil
  }

  private func present(_ outcome: HeliosUpdateChecker.Outcome, manual: Bool) {
    panel?.close()
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
      styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "Helios Updates"
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.contentViewController = NSHostingController(
      rootView: HeliosUpdateNoticeView(
        outcome: outcome, current: checker.current, dismiss: { [weak self] in self?.panel?.close() }
      ))
    panel.center()
    self.panel = panel
    if manual {
      NSApp.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
    } else {
      panel.orderFront(nil)
    }
    if case .available(let release) = outcome { checker.didPresent(release) }
  }
}

private struct HeliosUpdateNoticeView: View {
  let outcome: HeliosUpdateChecker.Outcome
  let current: HeliosReleaseVersion?
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(title).font(.headline)
      Text(detail).font(.callout).foregroundStyle(.secondary)
      HStack {
        Spacer()
        if case .available(let release) = outcome {
          Button("Remind Me Later", action: dismiss)
          Button("View / Download Update") {
            NSWorkspace.shared.open(release.releaseURL)
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
        } else {
          Button("OK", action: dismiss).keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(24)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var title: String {
    switch outcome {
    case .available(let release): "\(release.displayName) is available."
    case .upToDate: "Helios is up to date."
    case .unavailable: "Update information is unavailable."
    case .failed: "Couldn’t check for updates."
    }
  }

  private var detail: String {
    switch outcome {
    case .available:
      "You’re running \(current?.displayName ?? "a development build"). The update opens on GitHub."
    case .upToDate: "You’re running the latest available Helios pre-beta version."
    case .unavailable: "No comparable pre-beta release was found, or this build has no release tag."
    case .failed: "GitHub couldn’t be reached or returned an error. Please try again later."
    }
  }
}
