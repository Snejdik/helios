import Foundation

/// Best-effort local opt-in marker, not a crash detector or a cross-report identity.
/// No timestamps or usage history are retained; duration changes write at most six buckets.
@MainActor
final class DiagnosticsLifecycleStore {
  nonisolated static let key = DiagnosticsPreferences.namespace + "lifecycleMarker"
  private struct Marker: Codable {
    var endedCleanly: Bool
    var duration: DiagnosticsDurationBucket
    let helios: DiagnosticsHelios
    var macOSBuild: String
  }

  private let defaults: UserDefaults
  private var previous: Marker?
  private var current: Marker?

  init(defaults: UserDefaults) { self.defaults = defaults }

  func begin(helios: DiagnosticsHelios, macOSBuild: String) {
    guard current == nil else { return }
    previous = defaults.data(forKey: Self.key).flatMap {
      guard $0.count <= 1_024,
        let marker = try? PropertyListDecoder().decode(Marker.self, from: $0),
        DiagnosticsFieldRules.validVersion(marker.helios.version),
        DiagnosticsFieldRules.validBuild(marker.helios.build),
        DiagnosticsFieldRules.validOSBuild(marker.macOSBuild)
      else { return nil }
      return marker
    }
    current = Marker(
      endedCleanly: false, duration: .underFiveMinutes,
      helios: helios, macOSBuild: macOSBuild)
    persist()
  }

  func update(duration: DiagnosticsDurationBucket, macOSBuild: String) {
    guard var marker = current else { return }
    let build = macOSBuild == "unknown" ? marker.macOSBuild : macOSBuild
    guard marker.duration != duration || marker.macOSBuild != build else { return }
    marker.duration = duration
    marker.macOSBuild = build
    current = marker
    persist()
  }

  var summary: DiagnosticsStability {
    guard let current else {
      return DiagnosticsStability(
        previousSessionEndedUncleanly: false,
        previousSessionDuration: nil, lifecycleCategory: .unknown)
    }
    let category: DiagnosticsLifecycleCategory
    if let previous {
      if !previous.endedCleanly {
        category = .afterUncleanExit
      } else if previous.helios != current.helios {
        category = .afterUpdate
      } else if previous.macOSBuild != "unknown", current.macOSBuild != "unknown",
        previous.macOSBuild != current.macOSBuild
      {
        category = .afterMacOSUpdate
      } else {
        category = .normalLaunch
      }
    } else {
      category = .firstLaunch
    }
    return DiagnosticsStability(
      previousSessionEndedUncleanly: previous?.endedCleanly == false,
      previousSessionDuration: previous?.duration, lifecycleCategory: category)
  }

  func end() {
    guard current != nil else { return }
    current?.endedCleanly = true
    persist()
    current = nil
  }

  func clear() {
    current = nil
    previous = nil
    defaults.removeObject(forKey: Self.key)
  }

  private func persist() {
    guard let current, let data = try? PropertyListEncoder().encode(current) else { return }
    defaults.set(data, forKey: Self.key)
  }
}
