import AppKit
import Foundation

/// Why Helios.app could not be moved to the Trash by the app itself.
enum HeliosTrashBlocker: Equatable, Sendable {
  case notAnAppBundle
  case developmentBuild
  case translocated
  case readOnlyVolume
  case failed(String)

  var explanation: String {
    switch self {
    case .notAnAppBundle: "Helios is not running from an app bundle."
    case .developmentBuild: "This is a development build, so it was left in place."
    case .translocated:
      "macOS is running Helios from a temporary copy (App Translocation), so the original could not be found."
    case .readOnlyVolume: "Helios is running from a read-only disk image or volume."
    case .failed(let reason): "The Trash refused the move: \(reason)"
    }
  }
}

enum HeliosUninstallOutcome: Equatable, Sendable {
  /// Nothing irreversible beyond the fan hand-back happened; the user can retry.
  case stoppedAtLaunchAtLogin
  case stoppedAtHelper
  case movedToTrash
  /// The helper is gone and Launch at Login is off, but the app is still on disk.
  case needsManualTrash(HeliosTrashBlocker)
}

/// One-click removal. The order is deliberate: everything that registers Helios with
/// macOS is undone first, and the bundle goes to the Trash last, so a failure part-way
/// can never leave a registered helper behind without the app that manages it.
@MainActor
struct HeliosUninstaller {
  var returnFansToMacOS: () -> Void
  var disableLaunchAtLogin: () async -> Bool
  var unregisterHelper: () async -> Bool
  var eraseLocalData: () -> Void
  var moveAppToTrash: () async -> HeliosTrashBlocker?

  func run(eraseData: Bool) async -> HeliosUninstallOutcome {
    returnFansToMacOS()
    guard await disableLaunchAtLogin() else { return .stoppedAtLaunchAtLogin }
    guard await unregisterHelper() else { return .stoppedAtHelper }
    if eraseData { eraseLocalData() }
    if let blocker = await moveAppToTrash() { return .needsManualTrash(blocker) }
    return .movedToTrash
  }

  /// Returns why a bundle at this location must not be trashed automatically, or nil.
  static func trashBlocker(for bundleURL: URL, onReadOnlyVolume: Bool) -> HeliosTrashBlocker? {
    guard bundleURL.pathExtension == "app" else { return .notAnAppBundle }
    let path = bundleURL.standardizedFileURL.path
    if path.contains("/AppTranslocation/") { return .translocated }
    if onReadOnlyVolume { return .readOnlyVolume }
    if path.contains("/DerivedData/") || path.contains("/.build/") { return .developmentBuild }
    return nil
  }

  /// Moves the running app bundle to the Trash through Finder, which asks for an
  /// administrator password itself when the folder requires one.
  static func trashRunningApp(_ bundleURL: URL = Bundle.main.bundleURL) async -> HeliosTrashBlocker? {
    let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    if let blocker = trashBlocker(for: bundleURL, onReadOnlyVolume: readOnly) { return blocker }
    do {
      _ = try await NSWorkspace.shared.recycle([bundleURL])
      return nil
    } catch {
      return .failed(error.localizedDescription)
    }
  }
}
