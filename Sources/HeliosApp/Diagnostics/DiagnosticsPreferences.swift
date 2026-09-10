import Combine
import Foundation

enum DiagnosticsConsentState: String, Sendable, CaseIterable {
  case notDecided, disabled, enabled
}

enum DiagnosticsLocalReportStatus: String, Sendable, CaseIterable {
  case notSent = "not_sent"
  case success
  case failed

  var label: String {
    switch self {
    case .notSent: "Not sent"
    case .success: "Success"
    case .failed: "Failed"
    }
  }
}

/// Diagnostics preferences are intentionally separate from interface presets.
/// They contain consent and bounded scheduling state only, never client identity.
@MainActor
final class DiagnosticsPreferences: ObservableObject {
  nonisolated static let namespace = "betaDiagnostics.v1."

  @Published private(set) var consent: DiagnosticsConsentState
  @Published private(set) var consentRevision: Int
  @Published private(set) var lastSuccessfulReport: Date?
  @Published private(set) var lastSuccessfulAutomaticSend: Date?
  @Published private(set) var lastReportStatus: DiagnosticsLocalReportStatus
  @Published private(set) var lastStatusCategory: DiagnosticsErrorCategory
  @Published private(set) var lastReportedHeliosVersion: String?
  @Published private(set) var lastReportedHeliosBuild: String?
  @Published private(set) var lastReportedMacOSBuild: String?
  @Published private(set) var lastAutomaticChainStartedAt: Date?
  @Published private(set) var pendingRetryCount: Int
  @Published private(set) var nextEligibleTime: Date?

  var automaticWorkCancellation: (() -> Void)?
  var automaticEnabled: Bool { consent == .enabled }

  private let defaults: UserDefaults

  private enum Key {
    static let consent = DiagnosticsPreferences.namespace + "consent"
    static let consentRevision = DiagnosticsPreferences.namespace + "consentRevision"
    static let lastSuccessfulReport = DiagnosticsPreferences.namespace + "lastSuccessfulReport"
    static let lastSuccessfulSend = DiagnosticsPreferences.namespace + "lastSuccessfulAutomaticSend"
    static let lastStatus = DiagnosticsPreferences.namespace + "lastStatus"
    static let lastStatusCategory = DiagnosticsPreferences.namespace + "lastStatusCategory"
    static let lastVersion = DiagnosticsPreferences.namespace + "lastHeliosVersion"
    static let lastBuild = DiagnosticsPreferences.namespace + "lastHeliosBuild"
    static let lastMacOSBuild = DiagnosticsPreferences.namespace + "lastMacOSBuild"
    static let chainStartedAt = DiagnosticsPreferences.namespace + "lastAutomaticChainStartedAt"
    static let retryCount = DiagnosticsPreferences.namespace + "pendingRetryCount"
    static let nextEligible = DiagnosticsPreferences.namespace + "nextEligibleTime"

    static let all = [
      consent, consentRevision, lastSuccessfulReport, lastSuccessfulSend, lastStatus,
      lastStatusCategory, lastVersion,
      lastBuild, lastMacOSBuild, chainStartedAt, retryCount, nextEligible,
    ]
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let storedConsent = defaults.object(forKey: Key.consent) as? String
    consent = storedConsent.flatMap(DiagnosticsConsentState.init(rawValue:)) ?? .notDecided
    let revision = defaults.object(forKey: Key.consentRevision) as? NSNumber
    consentRevision = max(0, revision?.intValue ?? 0)
    lastSuccessfulReport = Self.safeDate(defaults.object(forKey: Key.lastSuccessfulReport))
    lastSuccessfulAutomaticSend = Self.safeDate(defaults.object(forKey: Key.lastSuccessfulSend))
    let storedStatus = defaults.object(forKey: Key.lastStatus) as? String
    lastReportStatus = storedStatus.flatMap(DiagnosticsLocalReportStatus.init(rawValue:)) ?? .notSent
    let storedCategory = defaults.object(forKey: Key.lastStatusCategory) as? String
    lastStatusCategory = storedCategory.flatMap(DiagnosticsErrorCategory.init(rawValue:)) ?? .none
    lastReportedHeliosVersion = Self.safeBoundedString(defaults.object(forKey: Key.lastVersion))
    lastReportedHeliosBuild = Self.safeBoundedString(defaults.object(forKey: Key.lastBuild))
    lastReportedMacOSBuild = Self.safeBoundedString(defaults.object(forKey: Key.lastMacOSBuild))
    lastAutomaticChainStartedAt = Self.safeDate(defaults.object(forKey: Key.chainStartedAt))
    let retry = (defaults.object(forKey: Key.retryCount) as? NSNumber)?.intValue ?? 0
    pendingRetryCount = (0...2).contains(retry) ? retry : 0
    nextEligibleTime = Self.safeDate(defaults.object(forKey: Key.nextEligible))
  }

  func setConsent(_ state: DiagnosticsConsentState) {
    guard state != .notDecided else {
      consent = .notDecided
      consentRevision &+= 1
      defaults.set(state.rawValue, forKey: Key.consent)
      defaults.set(consentRevision, forKey: Key.consentRevision)
      automaticWorkCancellation?()
      return
    }
    consent = state
    consentRevision &+= 1
    defaults.set(state.rawValue, forKey: Key.consent)
    defaults.set(consentRevision, forKey: Key.consentRevision)
    if state == .disabled {
      clearPendingAutomaticWork()
      automaticWorkCancellation?()
    }
  }

  func recordAutomaticChainStart(at date: Date, nextEligible: Date?) {
    lastAutomaticChainStartedAt = date
    pendingRetryCount = 0
    nextEligibleTime = nextEligible
    defaults.set(date, forKey: Key.chainStartedAt)
    defaults.set(0, forKey: Key.retryCount)
    setOptionalDate(nextEligible, key: Key.nextEligible)
  }

  func recordRetry(_ count: Int, nextEligible: Date?) {
    pendingRetryCount = min(2, max(0, count))
    nextEligibleTime = nextEligible
    defaults.set(pendingRetryCount, forKey: Key.retryCount)
    setOptionalDate(nextEligible, key: Key.nextEligible)
  }

  func recordAutomaticSuccess(
    at date: Date,
    heliosVersion: String,
    heliosBuild: String,
    macOSBuild: String
  ) {
    lastSuccessfulAutomaticSend = date
    lastSuccessfulReport = date
    lastReportStatus = .success
    lastStatusCategory = .none
    lastReportedHeliosVersion = String(heliosVersion.prefix(32))
    lastReportedHeliosBuild = String(heliosBuild.prefix(32))
    lastReportedMacOSBuild = String(macOSBuild.prefix(32))
    pendingRetryCount = 0
    nextEligibleTime = date.addingTimeInterval(24 * 60 * 60)
    defaults.set(date, forKey: Key.lastSuccessfulSend)
    defaults.set(date, forKey: Key.lastSuccessfulReport)
    defaults.set(lastReportStatus.rawValue, forKey: Key.lastStatus)
    defaults.set(lastStatusCategory.rawValue, forKey: Key.lastStatusCategory)
    defaults.set(lastReportedHeliosVersion, forKey: Key.lastVersion)
    defaults.set(lastReportedHeliosBuild, forKey: Key.lastBuild)
    defaults.set(lastReportedMacOSBuild, forKey: Key.lastMacOSBuild)
    defaults.set(0, forKey: Key.retryCount)
    defaults.set(nextEligibleTime, forKey: Key.nextEligible)
  }

  func recordLocalStatus(
    _ status: DiagnosticsLocalReportStatus, category: DiagnosticsErrorCategory, at date: Date = Date()
  ) {
    lastReportStatus = status
    lastStatusCategory = category
    if status == .success {
      lastSuccessfulReport = date
      defaults.set(date, forKey: Key.lastSuccessfulReport)
    }
    defaults.set(status.rawValue, forKey: Key.lastStatus)
    defaults.set(category.rawValue, forKey: Key.lastStatusCategory)
  }

  func finishFailedAutomaticChain(baseAttempt: Date) {
    pendingRetryCount = 0
    nextEligibleTime = baseAttempt.addingTimeInterval(24 * 60 * 60)
    defaults.set(0, forKey: Key.retryCount)
    defaults.set(nextEligibleTime, forKey: Key.nextEligible)
  }

  func clearPendingAutomaticWork() {
    pendingRetryCount = 0
    nextEligibleTime = nil
    defaults.set(0, forKey: Key.retryCount)
    defaults.removeObject(forKey: Key.nextEligible)
  }

  func eraseAllDiagnosticsPreferences() {
    automaticWorkCancellation?()
    for key in Key.all { defaults.removeObject(forKey: key) }
    consent = .notDecided
    consentRevision = 0
    lastSuccessfulReport = nil
    lastSuccessfulAutomaticSend = nil
    lastReportStatus = .notSent
    lastStatusCategory = .none
    lastReportedHeliosVersion = nil
    lastReportedHeliosBuild = nil
    lastReportedMacOSBuild = nil
    lastAutomaticChainStartedAt = nil
    pendingRetryCount = 0
    nextEligibleTime = nil
  }

  private func setOptionalDate(_ date: Date?, key: String) {
    if let date { defaults.set(date, forKey: key) } else { defaults.removeObject(forKey: key) }
  }

  private static func safeDate(_ value: Any?) -> Date? {
    guard let date = value as? Date, date.timeIntervalSince1970.isFinite else { return nil }
    return date
  }

  private static func safeBoundedString(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= 32 else { return nil }
    return value
  }
}
