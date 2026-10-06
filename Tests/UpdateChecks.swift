import Foundation

private func require(_ condition: Bool, _ message: String) {
  guard condition else { fatalError(message) }
}

@MainActor
private final class UpdateClock {
  var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Explicit barriers exercise cancellation even when a transport ignores it.
private actor UpdateFetchGate {
  private var continuation: CheckedContinuation<HeliosReleaseVersion?, Never>?
  private let started: AsyncStream<Void>.Continuation
  init(started: AsyncStream<Void>.Continuation) { self.started = started }
  func fetch() async -> HeliosReleaseVersion? {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started.yield(())
      started.finish()
    }
  }
  func finish(_ release: HeliosReleaseVersion?) {
    continuation?.resume(returning: release)
    continuation = nil
  }
}

@main
struct UpdateChecks {
  @MainActor
  static func main() async throws {
    let one = HeliosReleaseVersion(tag: "v0.1.0-prebeta.1")!
    let two = HeliosReleaseVersion(tag: "v0.1.0-prebeta.2")!
    let stable = HeliosReleaseVersion(tag: "v0.1.0")!
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
      HeliosReleaseVersion.aboutText(tag: "v0.2.0-beta.1", version: "0.2.0", build: "4")
        == "Helios 0.2.0 Beta 1 · Build 4", "Beta identity")
    require(HeliosReleaseVersion.aboutText(tag: nil, version: nil, build: "7") == "Build 7", "Build fallback")
    require(HeliosReleaseVersion.aboutText(tag: nil, version: "", build: "") == "Development build", "Empty fallback")
    require(HeliosReleaseVersion.aboutText(tag: stable.tag, version: "0.1.0", build: "3") == "Helios 0.1.0 · Build 3", "Stable identity")
    require(two > one && stable > two, "Stable follows prerelease; numeric ordinal")
    require(HeliosReleaseVersion(tag: "v0.1.0-prebeta.10")! > two, "Numeric ordinal")
    require(HeliosReleaseVersion(tag: "v0.2.0-alpha")! > stable, "Core version precedes channel")
    let order = ["alpha", "alpha.1", "alpha.beta", "beta", "beta.2", "beta.11", "rc.1"]
      .map { HeliosReleaseVersion(tag: "v1.0.0-" + $0)! }
    for (a, b) in zip(order, order.dropFirst()) { require(a < b, "SemVer identifier ordering") }
    require(order.last! < HeliosReleaseVersion(tag: "v1.0.0")!, "Release has higher precedence")
    require(HeliosReleaseVersion(tag: "v1.0.0-beta.999999999999999999999999")! > order[5], "Large prerelease numbers must not overflow")
    require(HeliosReleaseVersion(tag: "v1.0.0+001")! == HeliosReleaseVersion(tag: "v1.0.0+002")!, "Metadata cannot manufacture updates")
    require(!(HeliosReleaseVersion(tag: "v1.0.0+002")! > HeliosReleaseVersion(tag: "v1.0.0")!), "Metadata ignored in precedence")
    for tag in ["", "v", "0.1.0", "v01.0.0", "v1.00.0", "v1.0.01", "v1.0", "v1.0.0.1",
      "v1.0.0-", "v1.0.0-alpha..1", "v1.0.0-alpha.01", "v1.0.0+", "v1.0.0+a..b",
      "v1.0.0+a+b", "v1.0.0-β", "v1.0.0-beta_1", "v1.0.0\n", "v1.0.0-beta.1\n"] {
      require(HeliosReleaseVersion(tag: tag) == nil, "Malformed tag accepted: \(tag)")
    }
    require(HeliosReleaseVersion(tag: "v1.0.0-0") != nil, "Numeric zero is legal SemVer")
    let fixture = Data("""
      [
        {"tag_name":"v9.0.0","draft":true,"prerelease":false},
        {"tag_name":"v0.1.0-prebeta.2","draft":false,"prerelease":true,"name":"Wrong title"},
        {"tag_name":"v0.1.0","draft":false,"prerelease":false},
        {"tag_name":"v0.2.0-beta.1","draft":false,"prerelease":false},
        {"tag_name":"v0.3.0","draft":false,"prerelease":true},
        {"tag_name":"invalid","draft":false,"prerelease":false},
        {"tag_name":42,"draft":false,"prerelease":false}, null, {},
        {"tag_name":"v8.0.0","draft":0,"prerelease":false},
        {"tag_name":"v7.0.0","draft":false,"prerelease":0},
        {"tag_name":"v6.0.0","draft":false}
      ]
      """.utf8)
    let versions = try HeliosReleaseFeed.versions(in: fixture)
    require(versions.count == 12 && versions.versions.count == 4, "Malformed rows cannot mask valid versions")
    require(try HeliosReleaseFeed.versions(in: fixture, allowPrereleases: false).versions == [stable], "Stable excludes either tag or GitHub prerelease marker")
    require(versions.versions.max() == HeliosReleaseVersion(tag: "v0.3.0")!, "Choose highest version independent of title/order")
    require(try HeliosReleaseFeed.versions(in: Data("[]".utf8)).versions.isEmpty, "Empty feed")
    do { _ = try HeliosReleaseFeed.versions(in: Data("{}".utf8)); fatalError("Invalid response accepted") } catch {}
    require(two.releaseURL.absoluteString == "https://github.com/Snejdik/helios/releases/tag/v0.1.0-prebeta.2", "Specific release URL")

    let clock = UpdateClock(), date = clock.date
    for (frequency, seconds) in [(HeliosUpdateFrequency.daily, 86400.0), (.weekly, 7 * 86400.0), (.monthly, 30 * 86400.0)] {
      require(!HeliosUpdateChecker.automaticCheckIsDue(frequency: frequency, lastSuccess: date, lastAttempt: date, now: date.addingTimeInterval(seconds - 1)), "Selected interval floor")
      require(HeliosUpdateChecker.automaticCheckIsDue(frequency: frequency, lastSuccess: date, lastAttempt: date, now: date.addingTimeInterval(seconds)), "Selected interval boundary")
      require(!HeliosUpdateChecker.automaticCheckIsDue(frequency: frequency, lastSuccess: nil, lastAttempt: date, now: date.addingTimeInterval(86399)), "Failure floor applies to all frequencies")
    }
    require(!HeliosUpdateChecker.automaticCheckIsDue(frequency: .never, lastSuccess: nil, lastAttempt: nil, now: date), "Never is never due")
    require(HeliosUpdateChecker.automaticCheckIsDue(frequency: .weekly, lastSuccess: date.addingTimeInterval(1), lastAttempt: date.addingTimeInterval(1), now: date), "Clock rollback recovers once with a new baseline")
    let suite = "Helios.UpdateChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = HeliosUpdateChecker(current: one, defaults: defaults, now: { clock.date }, fetch: { two })
    require(fresh.frequency == .weekly && fresh.lastSuccessfulCheck == nil, "New users default weekly; no invented check")
    for enabled in [false, true] {
      defaults.removePersistentDomain(forName: suite)
      defaults.set(enabled, forKey: HeliosUpdateChecker.automaticEnabledKey)
      let migrated = HeliosUpdateChecker(current: one, defaults: defaults, fetch: { two })
      require(migrated.frequency == (enabled ? .weekly : .never), "Legacy disabled must remain Never")
      migrated.frequency = .monthly
      require(HeliosUpdateChecker(current: one, defaults: defaults).frequency == .monthly, "Canonical frequency survives legacy boolean/relaunch")
    }
    defaults.set("corrupt", forKey: HeliosUpdateChecker.frequencyKey)
    defaults.set(false, forKey: HeliosUpdateChecker.automaticEnabledKey)
    require(HeliosUpdateChecker(current: one, defaults: defaults).frequency == .never, "Corrupt frequency must preserve legacy opt-out")
    defaults.removePersistentDomain(forName: suite)
    let checker = HeliosUpdateChecker(current: one, defaults: defaults, now: { clock.date }, fetch: { two })
    require(await checker.check(manual: false) == .available(two), "First automatic check")
    require(checker.lastSuccessfulCheck == date, "Last success published")
    checker.frequency = .never
    require(await checker.check(manual: false) == nil, "Disabled automatic check")
    require(await checker.check(manual: true) == .available(two), "Never preserves manual check")
    let disabled = HeliosUpdateChecker(current: one, defaults: defaults, fetch: { fatalError("Never reached fetch") })
    require(disabled.frequency == .never, "Persisted opt-out frequency")
    require(await disabled.check(manual: false) == nil, "Persisted opt-out prevents fetch")
    checker.frequency = .weekly
    checker.didPresent(two)
    require(await checker.check(manual: false) == nil, "Repeat automatic throttled")
    clock.date = date.addingTimeInterval(86400)
    require(await checker.check(manual: false) == nil, "Weekly stays silent after one day")
    clock.date = date.addingTimeInterval(7 * 86400)
    require(await checker.check(manual: false) == .available(two), "Weekly boundary and reminder")
    require(HeliosUpdateChecker(current: one, defaults: defaults).lastSuccessfulCheck == clock.date, "Last success persists across launch")
    for remote in [one, HeliosReleaseVersion(tag: "v0.0.9")!] {
      let latest = HeliosUpdateChecker(current: one, defaults: defaults, fetch: { remote })
      require(await latest.check(manual: true) == .upToDate, "Equal/older manual feedback")
    }
    let stableChecker = HeliosUpdateChecker(current: stable, defaults: defaults, fetch: { HeliosReleaseVersion(tag: "v0.2.0-beta")! })
    require(await stableChecker.check(manual: true) == .unavailable, "Stable checker defense excludes injected prerelease")
    let graduating = HeliosUpdateChecker(current: two, defaults: defaults, fetch: { stable })
    require(await graduating.check(manual: true) == .available(stable), "Prerelease graduates to stable")
    let priorSuccess = defaults.object(forKey: HeliosUpdateChecker.lastSuccessKey) as? Date
    let empty = HeliosUpdateChecker(current: one, defaults: defaults, fetch: { nil })
    require(await empty.check(manual: true) == .unavailable, "Empty feed cannot claim latest")
    require(defaults.object(forKey: HeliosUpdateChecker.lastSuccessKey) as? Date == priorSuccess, "No comparable release does not advance success")
    defaults.removePersistentDomain(forName: suite)
    clock.date = date
    let failing = HeliosUpdateChecker(current: one, defaults: defaults, now: { clock.date }, fetch: { throw URLError(.notConnectedToInternet) })
    require(await failing.check(manual: false) == nil, "Silent automatic failure")
    require(failing.lastSuccessfulCheck == nil, "Failure not successful")
    require(defaults.object(forKey: HeliosUpdateChecker.lastAttemptKey) as? Date == date, "Failed attempt persisted")
    require(await failing.check(manual: false) == nil, "Repeated lifecycle failure suppressed")
    require(await failing.check(manual: true) == .failed, "Manual failure feedback")

    let url = URL(string: "https://api.github.com/repos/Snejdik/helios/releases")!
    let response = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
      headerFields: ["Retry-After": "7200", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(date.timeIntervalSince1970 + 3600)])!
    let until = HeliosReleaseFeed.retryDate(for: response, now: date)!
    require(until == date.addingTimeInterval(7200), "Use longer server pause")
    require(HeliosReleaseFeed.retryDate(for: HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "864000"])!, now: date) == date.addingTimeInterval(10 * 86400), "Long server pauses must not be shortened")
    require(HeliosReleaseFeed.retryDate(for: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!, now: date) == nil, "Success not rate limited")
    require(HeliosReleaseFeed.retryDate(for: HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Retry-After": "NaN"])!, now: date) == date.addingTimeInterval(60), "Malformed header safe fallback")
    let limited = HeliosUpdateChecker(current: one, defaults: defaults, now: { clock.date }, fetch: { throw HeliosReleaseFeedError.rateLimited(until: until) })
    require(await limited.check(manual: true) == .rateLimited(until), "Rate limit feedback")
    let cooling = HeliosUpdateChecker(current: one, defaults: defaults, now: { clock.date }, fetch: { two })
    cooling.frequency = .never
    require(await cooling.check(manual: true) == .rateLimited(until), "Rate-limit pause persists; manual honors it independent of Never")
    clock.date = until
    require(await cooling.check(manual: true) == .available(two), "Manual allowed at server deadline")

    defaults.removePersistentDomain(forName: suite)
    let deadline = Task { @MainActor in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      fatalError("Cancellation fixture failed to finish")
    }
    defer { deadline.cancel() }
    for manual in [false, true] {
      defaults.removePersistentDomain(forName: suite)
      let (started, signal) = AsyncStream<Void>.makeStream()
      let gate = UpdateFetchGate(started: signal)
      let suspended = HeliosUpdateChecker(current: one, defaults: defaults, now: { date }, fetch: { await gate.fetch() })
      let pending = Task { await suspended.check(manual: manual) }
      var iterator = started.makeAsyncIterator()
      require(await iterator.next() != nil && suspended.isChecking, "Explicit fetch-entry barrier")
      require(await suspended.check(manual: true) == nil, "Only one canonical active request")
      suspended.frequency = .never
      if !manual { suspended.frequency = .weekly } // Rapid off/on must not revive canceled work.
      await gate.finish(two)
      require(await pending.value == (manual ? .available(two) : nil), "Never cancels automatic only, including noncooperative transport")
      require(!suspended.isChecking, "Completed/canceled request clears state")
      require(suspended.lastSuccessfulCheck == (manual ? date : nil), "Canceled work cannot record success")
    }
    defaults.removePersistentDomain(forName: suite)
    let (started, signal) = AsyncStream<Void>.makeStream()
    let gate = UpdateFetchGate(started: signal)
    let stopped = HeliosUpdateChecker(current: one, defaults: defaults, fetch: { await gate.fetch() })
    let pending = Task { await stopped.check(manual: true) }
    var iterator = started.makeAsyncIterator()
    require(await iterator.next() != nil, "Shutdown barrier")
    stopped.shutdown()
    await gate.finish(two)
    require(await pending.value == nil && stopped.lastSuccessfulCheck == nil, "Shutdown rejects late result")
    require(await stopped.check(manual: true) == nil, "Stopped updater stays stopped")
    let unknown = HeliosUpdateChecker(current: nil, defaults: defaults, fetch: { fatalError("Missing identity reached fetch") })
    require(await unknown.check(manual: true) == .unavailable, "Missing identity not guessed from build")
    print("PASS SemVer/channel filtering, frequency migration, due-date/failure/rate-limit policy and updater cancellation")
  }
}
