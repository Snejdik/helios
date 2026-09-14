import Foundation

private func require(_ condition: Bool, _ message: String) {
  guard condition else { fatalError(message) }
}

@main
struct UpdateChecks {
  @MainActor
  static func main() async throws {
    let one = HeliosReleaseVersion(tag: "v0.1.0-prebeta.1")!
    let two = HeliosReleaseVersion(tag: "v0.1.0-prebeta.2")!
    require(
      HeliosReleaseVersion.aboutText(tag: one.tag, version: "0.1.0", build: "47")
        == "Helios 0.1.0 Pre-beta 1 · Build 47", "About must preserve bundle build")
    require(
      HeliosReleaseVersion.aboutText(tag: "bad", version: "0.1.0", build: "9")
        == "Version 0.1.0 · Build 9", "Malformed-tag fallback")
    require(
      HeliosReleaseVersion.aboutText(tag: one.tag, version: "0.2.0", build: nil)
        == "Version 0.2.0", "Mismatched metadata fallback")
    require(
      HeliosReleaseVersion.aboutText(tag: nil, version: nil, build: "7") == "Build 7",
      "Build-only fallback")
    require(
      HeliosReleaseVersion.aboutText(tag: nil, version: "", build: "") == "Development build",
      "Empty fallback")
    require(two > one, "Pre-beta 2 must be newer")
    require(one == HeliosReleaseVersion(tag: one.tag), "Identical release")
    require(!(one > two), "Older release")
    require(HeliosReleaseVersion(tag: "v0.1.0-prebeta.10")! > two, "Numeric ordinal")
    require(HeliosReleaseVersion(tag: "v0.2.0-prebeta.1")! > two, "Numeric base version")
    for tag in [
      "", "0.1.0-prebeta.2", "v0.1.0", "v0.1.0-beta.2", "v0.1.0-prebeta.0",
      "v0.1.0-prebeta.02", "v0.1.0-prebeta.-1", "v0.1.0-prebeta.2.extra",
      "v0.1.0-prebeta.999999999999999999999999", "v0.1-prebeta.2", "v0.1.0-prebeta.2\n",
    ] {
      require(HeliosReleaseVersion(tag: tag) == nil, "Malformed tag accepted: \(tag)")
    }
    let fixture = Data(
      """
      [
        {"tag_name":"v0.1.0-prebeta.99","draft":true},
        {"tag_name":"v0.1.0-prebeta.2","draft":false,"prerelease":true,"name":"Wrong title"},
        {"tag_name":"v0.1.0-prebeta.1","draft":false,"prerelease":false},
        {"tag_name":"invalid","draft":false},
        {"tag_name":42,"draft":false}, null, {},
        {"tag_name":"v0.1.0-prebeta.77","draft":0},
        {"tag_name":"v0.1.0-prebeta.88"}
      ]
      """.utf8)
    let versions = try HeliosReleaseFeed.versions(in: fixture).versions
    require(versions == [two, one], "Draft/malformed filtering and prerelease acceptance")
    require(versions.max() == two, "Highest version independent of order/title")
    require(try HeliosReleaseFeed.versions(in: Data("[]".utf8)).versions.isEmpty, "Empty feed")
    do {
      _ = try HeliosReleaseFeed.versions(in: Data("{}".utf8))
      fatalError("Invalid response accepted")
    } catch {}
    require(
      two.releaseURL.absoluteString
        == "https://github.com/Snejdik/helios/releases/tag/v0.1.0-prebeta.2", "Specific release URL"
    )

    let date = Date(timeIntervalSince1970: 1_800_000_000)
    require(HeliosUpdateChecker.automaticCheckIsDue(lastAttempt: nil, now: date), "First check")
    require(
      !HeliosUpdateChecker.automaticCheckIsDue(
        lastAttempt: date, now: date.addingTimeInterval(86399)), "24h throttle")
    require(
      HeliosUpdateChecker.automaticCheckIsDue(
        lastAttempt: date, now: date.addingTimeInterval(86400)), "24h boundary")
    require(
      HeliosUpdateChecker.automaticCheckIsDue(lastAttempt: date.addingTimeInterval(1), now: date),
      "Clock rollback recovery")
    let suite = "Helios.UpdateChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let checker = HeliosUpdateChecker(
      current: one, defaults: defaults, now: { date }, fetch: { two })
    require(await checker.check(manual: false) == .available(two), "Automatic newer release")
    checker.didPresent(two)
    require(
      defaults.object(forKey: HeliosUpdateChecker.lastSuccessKey) as? Date == date,
      "Successful timestamp persisted")
    require(await checker.check(manual: false) == nil, "Repeat automatic throttled")
    require(await checker.check(manual: true) == .available(two), "Manual bypass")
    let relaunched = HeliosUpdateChecker(
      current: one, defaults: defaults, now: { date.addingTimeInterval(86400) }, fetch: { two })
    require(await relaunched.check(manual: false) == nil, "Reminder persisted across launches")
    let weekLater = HeliosUpdateChecker(
      current: one, defaults: defaults, now: { date.addingTimeInterval(7 * 86400) }, fetch: { two })
    require(
      await weekLater.check(manual: false) == .available(two),
      "Reminder becomes eligible after a week")
    for remote in [one, HeliosReleaseVersion(tag: "v0.0.9-prebeta.1")!] {
      let latest = HeliosUpdateChecker(current: one, defaults: defaults, fetch: { remote })
      require(await latest.check(manual: true) == .upToDate, "Equal/older manual feedback")
    }
    let empty = HeliosUpdateChecker(current: one, defaults: defaults, fetch: { nil })
    require(await empty.check(manual: true) == .unavailable, "Empty feed must not claim latest")
    defaults.removePersistentDomain(forName: suite)
    let failing = HeliosUpdateChecker(
      current: one, defaults: defaults, now: { date },
      fetch: { throw URLError(.notConnectedToInternet) })
    require(await failing.check(manual: false) == nil, "Silent automatic failure")
    require(
      defaults.object(forKey: HeliosUpdateChecker.lastSuccessKey) == nil, "Failure not successful")
    require(
      defaults.object(forKey: HeliosUpdateChecker.lastAttemptKey) as? Date == date,
      "Failed attempt throttled")
    require(await failing.check(manual: true) == .failed, "Manual failure feedback")
    let unknown = HeliosUpdateChecker(current: nil, defaults: defaults, fetch: { two })
    require(await unknown.check(manual: true) == .unavailable, "Missing metadata not guessed")
    print(
      "PASS update parsing, comparison, feed filtering, feedback, persisted throttle and reminders")
  }
}
