import Combine
import CoreFoundation
import Foundation

/// GitHub release tags use v-prefixed SemVer. Bundle build numbers are not release ordinals.
struct HeliosReleaseVersion: Comparable, Sendable {
  let major: Int
  let minor: Int
  let patch: Int
  let prerelease: [String]
  let metadata: [String]

  init?(tag: String) {
    guard tag.hasPrefix("v"), tag.utf8.count > 1, tag.utf8.count <= 256 else { return nil }
    let decorated = tag.dropFirst().split(separator: "+", omittingEmptySubsequences: false)
    guard decorated.count <= 2 else { return nil }
    let version = decorated[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = version[0].split(separator: ".", omittingEmptySubsequences: false)
    guard core.count == 3 else { return nil }
    let numbers = core.compactMap { part -> Int? in
      guard Self.isNumeric(String(part)), part.count == 1 || part.first != "0" else { return nil }
      return Int(part)
    }
    guard numbers.count == 3 else { return nil }
    let pre = version.count == 2 ? version[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
    let meta = decorated.count == 2 ? decorated[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
    guard (pre + meta).allSatisfy(Self.isIdentifier),
      pre.allSatisfy({ !Self.isNumeric($0) || $0.count == 1 || $0.first != "0" })
    else { return nil }
    major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    prerelease = pre; metadata = meta
  }

  private static func isNumeric(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
  }

  private static func isIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
    }
  }

  var isPrerelease: Bool { !prerelease.isEmpty }
  var base: String { "\(major).\(minor).\(patch)" }
  var tag: String {
    "v\(base)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
      + (metadata.isEmpty ? "" : "+" + metadata.joined(separator: "."))
  }
  var displayName: String {
    if prerelease.count == 2, Self.isNumeric(prerelease[1]) {
      switch prerelease[0] {
      case "prebeta": return "Helios \(base) Pre-beta \(prerelease[1])"
      case "beta": return "Helios \(base) Beta \(prerelease[1])"
      default: break
      }
    }
    return "Helios " + String(tag.dropFirst())
  }
  var releaseURL: URL { URL(string: "https://github.com/Snejdik/helios/releases/tag/\(tag)")! }

  // Metadata identifies the tag but must never manufacture an update of equal precedence.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
      && lhs.prerelease == rhs.prerelease
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    let left = (lhs.major, lhs.minor, lhs.patch), right = (rhs.major, rhs.minor, rhs.patch)
    if left != right { return left < right }
    if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
      return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
    }
    for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
      let aNumeric = isNumeric(a), bNumeric = isNumeric(b)
      if aNumeric != bNumeric { return aNumeric }
      if aNumeric, a.count != b.count { return a.count < b.count }
      return a < b // ASCII identifiers; equal-length numeric identifiers compare without overflow.
    }
    return lhs.prerelease.count < rhs.prerelease.count
  }

  static func aboutText(tag: String?, version: String?, build: String?) -> String {
    let version = version.flatMap { $0.isEmpty ? nil : $0 }
    let build = build.flatMap { $0.isEmpty ? nil : $0 }
    let identity: String
    if let tag, let release = Self(tag: tag), release.base == version {
      identity = release.displayName
    } else if let version {
      identity = "Version \(version)"
    } else {
      return build.map { "Build \($0)" } ?? "Development build"
    }
    return build.map { "\(identity) · Build \($0)" } ?? identity
  }

  static func current(in bundle: Bundle = .main) -> Self? {
    guard let tag = bundle.object(forInfoDictionaryKey: "HeliosReleaseTag") as? String,
      let version = Self(tag: tag),
      version.base == bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else { return nil }
    return version
  }
}

private final class HeliosUpdateRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

enum HeliosReleaseFeedError: Error {
  case rateLimited(until: Date)
}

enum HeliosReleaseFeed {
  /// Decode each entry independently so one malformed release cannot hide valid releases.
  static func versions(in data: Data, allowPrereleases: Bool = true) throws
    -> (versions: [HeliosReleaseVersion], count: Int)
  {
    guard let entries = try JSONSerialization.jsonObject(with: data) as? [Any] else {
      throw URLError(.cannotParseResponse)
    }
    let versions = entries.compactMap { entry -> HeliosReleaseVersion? in
      guard let release = entry as? [String: Any],
        let draft = release["draft"] as? NSNumber,
        CFGetTypeID(draft) == CFBooleanGetTypeID(), !draft.boolValue,
        let prerelease = release["prerelease"] as? NSNumber,
        CFGetTypeID(prerelease) == CFBooleanGetTypeID(),
        let tag = release["tag_name"] as? String,
        let version = HeliosReleaseVersion(tag: tag),
        allowPrereleases || (!prerelease.boolValue && !version.isPrerelease)
      else { return nil }
      return version
    }
    return (versions, entries.count)
  }

  /// Pure header policy also used by offline fixtures. No retry task or timer is created.
  static func retryDate(for response: HTTPURLResponse, now: Date) -> Date? {
    guard response.statusCode == 403 || response.statusCode == 429 else { return nil }
    // Keep persisted/UI dates representable, without shortening practical server pauses.
    let maximumEpoch: TimeInterval = 253_402_300_799 // End of Gregorian year 9999.
    var deadline = now.addingTimeInterval(60)
    if let value = response.value(forHTTPHeaderField: "Retry-After"),
      let seconds = Double(value), seconds.isFinite, seconds >= 0,
      seconds <= maximumEpoch - now.timeIntervalSince1970
    { deadline = max(deadline, now.addingTimeInterval(seconds)) }
    if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
      let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
      let seconds = Double(value), seconds.isFinite,
      seconds > now.timeIntervalSince1970, seconds <= maximumEpoch
    { deadline = max(deadline, Date(timeIntervalSince1970: seconds)) }
    return deadline
  }

  static func fetchNewest(allowPrereleases: Bool) async throws -> HeliosReleaseVersion? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = nil
    configuration.waitsForConnectivity = false
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(
      configuration: configuration, delegate: HeliosUpdateRedirectDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var newest: HeliosReleaseVersion?
    // The list endpoint includes prereleases. /latest excludes them. Bounded pagination;
    // never claim up-to-date from a truncated collection, even for stable-only builds.
    for page in 1...3 {
      try Task.checkCancellation()
      let url = URL(
        string: "https://api.github.com/repos/Snejdik/helios/releases?per_page=100&page=\(page)")!
      var request = URLRequest(url: url)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
      request.setValue("Helios-Update-Checker", forHTTPHeaderField: "User-Agent")
      let (data, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard let response = response as? HTTPURLResponse, response.url == url else {
        throw URLError(.badServerResponse)
      }
      if let until = retryDate(for: response, now: Date()) {
        throw HeliosReleaseFeedError.rateLimited(until: until)
      }
      guard response.statusCode == 200, data.count <= 2 * 1_024 * 1_024 else {
        throw URLError(.badServerResponse)
      }
      let result = try versions(in: data, allowPrereleases: allowPrereleases)
      newest = (result.versions + [newest].compactMap { $0 }).max()
      if result.count < 100 { return newest }
    }
    throw URLError(.dataLengthExceedsMaximum)
  }
}

enum HeliosUpdateFrequency: String, CaseIterable, Identifiable, Sendable {
  case never, daily, weekly, monthly
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var interval: TimeInterval? {
    switch self {
    case .never: nil
    case .daily: 86400
    case .weekly: 7 * 86400
    case .monthly: 30 * 86400
    }
  }
}

@MainActor
final class HeliosUpdateChecker: ObservableObject {
  enum Outcome: Equatable {
    case available(HeliosReleaseVersion)
    case upToDate
    case unavailable
    case failed
    case rateLimited(Date)
  }

  static let frequencyKey = "updates.v2.frequency"
  static let automaticEnabledKey = "updates.v1.automaticEnabled" // Migration only.
  static let lastAttemptKey = "updates.v1.lastAttempt"
  static let lastSuccessKey = "updates.v1.lastSuccess"
  static let retryAfterKey = "updates.v2.retryAfter"
  static let lastPresentedKey = "updates.v1.lastPresentedTag"
  static let lastPresentedAtKey = "updates.v1.lastPresentedAt"
  @Published var frequency: HeliosUpdateFrequency {
    didSet {
      defaults.set(frequency.rawValue, forKey: Self.frequencyKey)
      if frequency == .never, !activeCheckIsManual { activeFetch?.cancel() }
    }
  }
  var automaticallyChecksForUpdates: Bool { frequency != .never }
  @Published private(set) var lastSuccessfulCheck: Date?
  @Published private(set) var isChecking = false
  let current: HeliosReleaseVersion?
  private let defaults: UserDefaults
  private var activeFetch: Task<HeliosReleaseVersion?, Error>?
  private var activeCheckIsManual = false
  private var stopped = false
  private let fetch: @Sendable () async throws -> HeliosReleaseVersion?
  private let now: () -> Date

  init(
    current: HeliosReleaseVersion? = .current(), defaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    fetch: (@Sendable () async throws -> HeliosReleaseVersion?)? = nil
  ) {
    let selectedFrequency: HeliosUpdateFrequency
    if let stored = defaults.string(forKey: Self.frequencyKey),
      let frequency = HeliosUpdateFrequency(rawValue: stored)
    { selectedFrequency = frequency }
    else if let legacy = defaults.object(forKey: Self.automaticEnabledKey) as? NSNumber,
      CFGetTypeID(legacy) == CFBooleanGetTypeID(), !legacy.boolValue
    { selectedFrequency = .never }
    else { selectedFrequency = .weekly }
    frequency = selectedFrequency
    // Metadata-less standalone presentation fixtures must not migrate the user's
    // real defaults merely by constructing the shared Settings view.
    if current != nil { defaults.set(selectedFrequency.rawValue, forKey: Self.frequencyKey) }
    lastSuccessfulCheck = Self.validDate(defaults.object(forKey: Self.lastSuccessKey))
    self.current = current
    self.defaults = defaults
    self.now = now
    if let fetch { self.fetch = fetch }
    else { self.fetch = { try await HeliosReleaseFeed.fetchNewest(allowPrereleases: current?.isPrerelease == true) } }
  }

  private static func validDate(_ value: Any?) -> Date? {
    guard let date = value as? Date, date.timeIntervalSince1970.isFinite else { return nil }
    return date
  }

  static func automaticCheckIsDue(
    frequency: HeliosUpdateFrequency, lastSuccess: Date?, lastAttempt: Date?, now: Date
  ) -> Bool {
    guard let interval = frequency.interval, now.timeIntervalSince1970.isFinite else { return false }
    // A successful check sets the selected cadence. Failures/cancellations still
    // have a one-day floor so activation/wake/relaunch cannot produce a retry loop.
    if let lastAttempt, lastAttempt.timeIntervalSince1970.isFinite {
      let elapsed = now.timeIntervalSince(lastAttempt)
      if elapsed >= 0 && elapsed < 86400 { return false }
    }
    guard let lastSuccess, lastSuccess.timeIntervalSince1970.isFinite else { return true }
    let elapsed = now.timeIntervalSince(lastSuccess)
    return elapsed < 0 || elapsed >= interval
  }

  func shutdown() {
    stopped = true
    activeFetch?.cancel()
  }

  func check(manual: Bool) async -> Outcome? {
    guard !stopped, !Task.isCancelled, !isChecking, manual || automaticallyChecksForUpdates else { return nil }
    let attemptedAt = now()
    if let retryAfter = Self.validDate(defaults.object(forKey: Self.retryAfterKey)),
      retryAfter > attemptedAt
    { return manual ? .rateLimited(retryAfter) : nil }
    guard manual || Self.automaticCheckIsDue(
      frequency: frequency, lastSuccess: lastSuccessfulCheck,
      lastAttempt: Self.validDate(defaults.object(forKey: Self.lastAttemptKey)), now: attemptedAt)
    else { return nil }
    guard let current else { return manual ? .unavailable : nil }
    isChecking = true
    activeCheckIsManual = manual
    let fetch = self.fetch
    let requestTask = Task {
      try Task.checkCancellation()
      return try await fetch()
    }
    activeFetch = requestTask
    defer { isChecking = false; activeFetch = nil; activeCheckIsManual = false }
    defaults.set(attemptedAt, forKey: Self.lastAttemptKey)
    do {
      let newest = try await withTaskCancellationHandler {
        try await requestTask.value
      } onCancel: { requestTask.cancel() }
      try Task.checkCancellation()
      guard !requestTask.isCancelled, !stopped, manual || automaticallyChecksForUpdates else { return nil }
      guard let newest, current.isPrerelease || !newest.isPrerelease else {
        return manual ? .unavailable : nil
      }
      let checkedAt = now()
      lastSuccessfulCheck = checkedAt
      defaults.set(checkedAt, forKey: Self.lastSuccessKey)
      defaults.removeObject(forKey: Self.retryAfterKey)
      guard newest > current else { return manual ? .upToDate : nil }
      if !manual, defaults.string(forKey: Self.lastPresentedKey) == newest.tag,
        let presented = Self.validDate(defaults.object(forKey: Self.lastPresentedAtKey)),
        (0..<(7 * 86400)).contains(checkedAt.timeIntervalSince(presented))
      { return nil }
      return .available(newest)
    } catch {
      guard !Task.isCancelled, !requestTask.isCancelled, !stopped else { return nil }
      if case HeliosReleaseFeedError.rateLimited(let until) = error {
        defaults.set(until, forKey: Self.retryAfterKey)
        return manual ? .rateLimited(until) : nil
      }
      return manual ? .failed : nil
    }
  }

  func didPresent(_ release: HeliosReleaseVersion) {
    defaults.set(release.tag, forKey: Self.lastPresentedKey)
    defaults.set(now(), forKey: Self.lastPresentedAtKey)
  }
}
