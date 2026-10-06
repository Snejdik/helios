import AppKit
import UniformTypeIdentifiers

/// Actions on an app listed in the Energy Inspector. An app key is "app:" plus the
/// path of its bundle; other keys (plain processes) have no actions.
@MainActor
enum HeliosAppActions {
  static func bundlePath(forKey appKey: String) -> String? {
    guard appKey.hasPrefix("app:") else { return nil }
    let path = String(appKey.dropFirst(4))
    return path.isEmpty ? nil : path
  }

  /// The running instance of the app, never Helios itself.
  static func runningApplication(forKey appKey: String) -> NSRunningApplication? {
    guard let path = bundlePath(forKey: appKey) else { return nil }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    return NSWorkspace.shared.runningApplications.first {
      $0.bundleURL?.path == path && $0.processIdentifier != ownPID
        && $0.activationPolicy != .prohibited
    }
  }

  /// Asks the app to quit, like choosing Quit from its menu; it may ask to save work.
  static func quit(_ appKey: String) {
    _ = runningApplication(forKey: appKey)?.terminate()
  }

  /// Ends the app immediately after the user confirms; unsaved work in it is lost.
  static func forceQuit(_ appKey: String, displayName: String) {
    guard let app = runningApplication(forKey: appKey) else { return }
    let alert = NSAlert()
    alert.messageText = "Force quit \(displayName)?"
    alert.informativeText = "Unsaved changes in \(displayName) will be lost."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Force Quit")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn { _ = app.forceTerminate() }
  }

  static func openActivityMonitor() {
    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }

  static func revealInFinder(_ appKey: String) {
    guard let path = bundlePath(forKey: appKey) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}

/// Asks where to save an export, then writes it; a failure is shown to the user.
@MainActor
enum HeliosFileExport {
  static func save(suggestedName: String, type: UTType, data: () -> Data?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      guard let data = data() else { throw CocoaError(.fileWriteUnknown) }
      try data.write(to: url, options: .atomic)
    } catch {
      let alert = NSAlert()
      alert.messageText = "The file could not be saved"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }
}

/// CSV of the energy ranking for the range on screen.
enum HeliosEnergyCSV {
  static let header = "app,energy_wh,cpu_core_seconds,wakeups,peak_memory_bytes"

  static func make(entries: [AppEnergyEntry]) -> String {
    var lines = [header]
    for entry in entries {
      lines.append([
        field(entry.displayName),
        String(format: "%.6f", entry.energyWattHours),
        String(format: "%.1f", entry.cpuCoreSeconds),
        String(format: "%.0f", entry.wakeups),
        String(entry.peakMemoryBytes),
      ].joined(separator: ","))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Quotes a text field and neutralises a leading formula character, so opening
  /// the file in a spreadsheet never evaluates an app name.
  static func field(_ text: String) -> String {
    var value = text.replacingOccurrences(of: "\"", with: "\"\"")
    if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
    return "\"\(value)\""
  }
}
