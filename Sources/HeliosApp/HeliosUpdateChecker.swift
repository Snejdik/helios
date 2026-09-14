import Combine
import CoreFoundation
import Foundation

/// Only Helios's pre-beta channel is recognized. Build numbers are not release ordinals.
struct HeliosReleaseVersion: Comparable, Sendable {
  let major: Int
  let minor: Int
  let patch: Int
  let prebeta: Int

  init?(tag: String) {
    let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].hasPrefix("v"), parts[1].hasPrefix("prebeta.") else {
      return nil
    }
    let numbers =
      parts[0].dropFirst().split(separator: ".", omittingEmptySubsequences: false)
      + [parts[1].dropFirst("prebeta.".count)]
    guard numbers.count == 4 else { return nil }
    let values = numbers.compactMap { part -> Int? in
      guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
        part.count == 1 || part.first != "0"
      else { return nil }
      return Int(part)
    }
    guard values.count == 4, values[3] > 0 else { return nil }
    major = values[0]
    minor = values[1]
    patch = values[2]
    prebeta = values[3]
  }

  var base: String { "\(major).\(minor).\(patch)" }
  var tag: String { "v\(base)-prebeta.\(prebeta)" }
  var displayName: String { "Helios \(base) Pre-beta \(prebeta)" }
  var releaseURL: URL { URL(string: "https://github.com/Snejdik/helios/releases/tag/\(tag)")! }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch, lhs.prebeta)
      < (rhs.major, rhs.minor, rhs.patch, rhs.prebeta)
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

enum HeliosReleaseFeed {
  /// Decode each entry independently so one malformed release cannot hide valid releases.
  static func versions(in data: Data) throws -> (versions: [HeliosReleaseVersion], count: Int) {
    guard let entries = try JSONSerialization.jsonObject(with: data) as? [Any] else {
      throw URLError(.cannotParseResponse)
    }
    let versions = entries.compactMap { entry -> HeliosReleaseVersion? in
      guard let release = entry as? [String: Any],
        let draft = release["draft"] as? NSNumber,
        CFGetTypeID(draft) == CFBooleanGetTypeID(), !draft.boolValue,
        let tag = release["tag_name"] as? String
      else { return nil }
      return HeliosReleaseVersion(tag: tag)
    }
    return (versions, entries.count)
  }

  static func fetchNewest() async throws -> HeliosReleaseVersion? {
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
    // Bounded pagination; never claim up-to-date from a truncated collection.
    for page in 1...3 {
      try Task.checkCancellation()
      let url = URL(
        string: "https://api.github.com/repos/Snejdik/helios/releases?per_page=100&page=\(page)")!
      var request = URLRequest(url: url)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
      request.setValue("Helios-Update-Checker", forHTTPHeaderField: "User-Agent")
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
        response.url == url, data.count <= 2 * 1_024 * 1_024
      else {
        throw URLError(.badServerResponse)
      }
      let result = try versions(in: data)
      newest = (result.versions + [newest].compactMap { $0 }).max()
      if result.count < 100 { return newest }
    }
    throw URLError(.dataLengthExceedsMaximum)
  }
}

@MainActor
final class HeliosUpdateChecker: ObservableObject {
  enum Outcome: Equatable {
    case available(HeliosReleaseVersion)
    case upToDate
    case unavailable
    case failed
  }

  static let lastAttemptKey = "updates.v1.lastAttempt"
  static let lastSuccessKey = "updates.v1.lastSuccess"
  static let lastPresentedKey = "updates.v1.lastPresentedTag"
  static let lastPresentedAtKey = "updates.v1.lastPresentedAt"
  @Published private(set) var isChecking = false
  let current: HeliosReleaseVersion?
  private let defaults: UserDefaults
  private let fetch: @Sendable () async throws -> HeliosReleaseVersion?
  private let now: () -> Date

  init(
    current: HeliosReleaseVersion? = .current(), defaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    fetch: @escaping @Sendable () async throws -> HeliosReleaseVersion? = HeliosReleaseFeed
      .fetchNewest
  ) {
    self.current = current
    self.defaults = defaults
    self.now = now
    self.fetch = fetch
  }

  static func automaticCheckIsDue(lastAttempt: Date?, now: Date) -> Bool {
    guard let lastAttempt, lastAttempt.timeIntervalSince1970.isFinite else { return true }
    let elapsed = now.timeIntervalSince(lastAttempt)
    return elapsed < 0 || elapsed >= 24 * 60 * 60
  }

  func check(manual: Bool) async -> Outcome? {
    guard !isChecking else { return nil }
    guard
      manual
        || Self.automaticCheckIsDue(
          lastAttempt: defaults.object(forKey: Self.lastAttemptKey) as? Date, now: now())
    else { return nil }
    guard let current else { return manual ? .unavailable : nil }
    isChecking = true
    defer { isChecking = false }
    // Throttle failures too, so repeated offline launches do not spam GitHub.
    defaults.set(now(), forKey: Self.lastAttemptKey)
    do {
      let newest = try await fetch()
      try Task.checkCancellation()
      defaults.set(now(), forKey: Self.lastSuccessKey)
      guard let newest else { return manual ? .unavailable : nil }
      guard newest > current else { return manual ? .upToDate : nil }
      if !manual, defaults.string(forKey: Self.lastPresentedKey) == newest.tag,
        let presented = defaults.object(forKey: Self.lastPresentedAtKey) as? Date,
        (0..<(7 * 24 * 60 * 60)).contains(now().timeIntervalSince(presented))
      {
        return nil
      }
      return .available(newest)
    } catch {
      return manual && !Task.isCancelled ? .failed : nil
    }
  }

  func didPresent(_ release: HeliosReleaseVersion) {
    defaults.set(release.tag, forKey: Self.lastPresentedKey)
    defaults.set(now(), forKey: Self.lastPresentedAtKey)
  }
}
