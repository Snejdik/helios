import Combine
import Foundation

enum DiagnosticsTransportResult: Sendable, Equatable {
  case accepted
  case retryable(retryAfter: TimeInterval?)
  case rejected
  case cancelled
}

@MainActor
protocol DiagnosticsTransporting: AnyObject {
  func send(_ payload: FrozenDiagnosticsPayload) async -> DiagnosticsTransportResult
  func cancel()
}

final class DiagnosticsRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

@MainActor
final class DiagnosticsURLSessionTransport: DiagnosticsTransporting {
  nonisolated static let endpoint = URL(string: "https://www.snejda.cz/api/helios/diagnostics")!
  nonisolated static let timeout: TimeInterval = 8
  private let session: URLSession
  private var activeTask: Task<(Data, URLResponse), Error>?

  init(configuration: URLSessionConfiguration? = nil) {
    let configuration = configuration ?? .ephemeral
    configuration.timeoutIntervalForRequest = Self.timeout
    configuration.timeoutIntervalForResource = Self.timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = nil
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration, delegate: DiagnosticsRedirectDelegate(),
      delegateQueue: nil)
  }

  nonisolated static func makeRequest(_ payload: FrozenDiagnosticsPayload) throws -> URLRequest {
    guard payload.data.count <= FrozenDiagnosticsPayload.maximumBytes else {
      throw DiagnosticsPayloadError.tooLarge
    }
    var request = URLRequest(
      url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.httpBody = payload.data
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpShouldHandleCookies = false
    return request
  }

  func send(_ payload: FrozenDiagnosticsPayload) async -> DiagnosticsTransportResult {
    guard !Task.isCancelled, activeTask == nil, let request = try? Self.makeRequest(payload) else { return .rejected }
    let operation = Task { try await session.data(for: request) }
    activeTask = operation
    defer { activeTask = nil }
    do {
      let (data, response) = try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
      guard !Task.isCancelled else { return .cancelled }
      guard let response = response as? HTTPURLResponse,
        response.url == Self.endpoint,
        data.count <= 1_024
      else { return .rejected }
      if (200...299).contains(response.statusCode) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["status"] as? String == "accepted"
        else { return .rejected }
        return .accepted
      }
      if response.statusCode == 408 || response.statusCode == 429 || response.statusCode >= 500 {
        return .retryable(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
      }
      return .rejected
    } catch is CancellationError {
      return .cancelled
    } catch let error as URLError {
      return error.code == .cancelled ? .cancelled : .retryable(retryAfter: nil)
    } catch {
      return .retryable(retryAfter: nil)
    }
  }

  func cancel() { activeTask?.cancel() }

  nonisolated static func retryAfter(_ value: String?) -> TimeInterval? {
    guard let value, let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 else {
      return nil
    }
    return min(6 * 60 * 60, seconds)
  }
}

struct DiagnosticsScheduleInput: Sendable {
  let now: Date
  let launchStartedAt: Date
  let lastSuccessfulSend: Date?
  let lastChainStartedAt: Date?
  let persistedNextEligible: Date?
  let lastVersion: String?
  let lastBuild: String?
  let lastMacOSBuild: String?
  let currentVersion: String
  let currentBuild: String
  let currentMacOSBuild: String
}

struct DiagnosticsScheduleDecision: Sendable, Equatable {
  let eligibleAt: Date
  let reason: DiagnosticsReportReason
}

enum DiagnosticsSchedulePolicy {
  static let firstEligibility: TimeInterval = 5 * 60
  static let updateFloor: TimeInterval = 60 * 60
  static let baseCooldown: TimeInterval = 24 * 60 * 60
  static let retryDelays: [TimeInterval] = [15 * 60, 2 * 60 * 60]
  static let jitterRange = 0.8...1.2

  static func decision(_ input: DiagnosticsScheduleInput) -> DiagnosticsScheduleDecision {
    let reason: DiagnosticsReportReason
    let base: Date
    if let success = input.lastSuccessfulSend {
      if input.lastVersion != input.currentVersion || input.lastBuild != input.currentBuild {
        reason = .heliosVersionChanged
        base = success.addingTimeInterval(updateFloor)
      } else if input.currentMacOSBuild != "unknown", input.lastMacOSBuild != "unknown",
        input.lastMacOSBuild != input.currentMacOSBuild {
        reason = .macOSBuildChanged
        base = success.addingTimeInterval(updateFloor)
      } else {
        reason = .daily
        base = success.addingTimeInterval(baseCooldown)
      }
    } else {
      reason = .initialOptIn
      base = input.launchStartedAt.addingTimeInterval(firstEligibility)
    }

    var eligible = base
    if let chain = input.lastChainStartedAt,
      input.lastSuccessfulSend == nil || chain > input.lastSuccessfulSend!
    {
      eligible = max(eligible, chain.addingTimeInterval(baseCooldown))
    }
    // A daily deadline saved after success must not erase the one-hour update window.
    // Persisted retries/failed chains retain their stricter cooldown above.
    let successfulUpdate = input.lastSuccessfulSend != nil
      && (reason == .heliosVersionChanged || reason == .macOSBuildChanged)
      && (input.lastChainStartedAt == nil || input.lastChainStartedAt! <= input.lastSuccessfulSend!)
    if let persisted = input.persistedNextEligible, !successfulUpdate {
      eligible = max(eligible, persisted)
    }
    return DiagnosticsScheduleDecision(eligibleAt: eligible, reason: reason)
  }

  static func retryDelay(index: Int, jitter: Double, retryAfter: TimeInterval?) -> TimeInterval? {
    guard retryDelays.indices.contains(index) else { return nil }
    let boundedJitter = min(jitterRange.upperBound, max(jitterRange.lowerBound, jitter))
    return max(retryDelays[index] * boundedJitter, min(6 * 60 * 60, max(0, retryAfter ?? 0)))
  }
}

@MainActor
final class DiagnosticsController: ObservableObject {
  let preferences: DiagnosticsPreferences
  let session: DiagnosticsSessionTracker
  @Published private(set) var sending = false

  private let transportFactory: @MainActor () -> any DiagnosticsTransporting
  private let compatibilityProbeFactory: @Sendable () -> DiagnosticsCompatibilityProbe
  private var transport: (any DiagnosticsTransporting)?
  private var compatibilityProbe: DiagnosticsCompatibilityProbe?
  private var automaticTask: Task<Void, Never>?
  private var started = false
  private var stopped = false
  private var automaticRequestInFlight = false
  private let now: () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let lifecycle: DiagnosticsLifecycleStore
  private var generation: UInt64 = 0

  init(
    preferences: DiagnosticsPreferences,
    session: DiagnosticsSessionTracker = DiagnosticsSessionTracker(),
    now: @escaping () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds(max(0, $0)), tolerance: .seconds(5))
    },
    transportFactory: @escaping @MainActor () -> any DiagnosticsTransporting = {
      DiagnosticsURLSessionTransport()
    },
    compatibilityProbeFactory: @escaping @Sendable () -> DiagnosticsCompatibilityProbe = {
      DiagnosticsCompatibilityProbe()
    }
  ) {
    self.preferences = preferences
    self.session = session
    self.now = now
    self.sleep = sleep
    lifecycle = preferences.makeLifecycleStore()
    self.transportFactory = transportFactory
    self.compatibilityProbeFactory = compatibilityProbeFactory
    preferences.automaticWorkCancellation = { [weak self] in self?.cancelAutomaticWork() }
  }

  func start() {
    guard !started, !stopped else { return }
    started = true
    // DiagnosticsPreferences has already read persisted state for this launch.
    // Missing/corrupt values are not enabled and create no scheduler or session.
    if preferences.automaticEnabled {
      beginLifecycle()
      scheduleNextAutomatic()
    } else {
      lifecycle.clear()
      session.stability = lifecycle.summary
    }
  }

  func shutdown() {
    stopped = true
    updateLifecycle()
    lifecycle.end()
    automaticTask?.cancel()
    automaticTask = nil
    transport?.cancel()
  }

  func accept(_ snapshot: TelemetrySnapshot, helper: DiagnosticsHelperObservation) {
    let oldBuild = session.observedMacOSBuild
    session.accept(snapshot)
    session.updateHelper(helper)
    updateLifecycle()
    let newBuild = session.observedMacOSBuild
    if started, preferences.automaticEnabled, !sending, oldBuild != newBuild, newBuild != "unknown" {
      scheduleNextAutomatic()
    }
  }

  func setAutomaticEnabled(_ enabled: Bool) {
    guard !stopped else { return }
    let decision: DiagnosticsConsentState = enabled ? .enabled : .disabled
    guard preferences.consent != decision else { return }
    preferences.setConsent(decision)
    // The preferences callback already cancels work synchronously on opt-out.
    guard preferences.automaticEnabled else { return }
    beginLifecycle()
    scheduleNextAutomatic()
  }

  private func beginLifecycle() {
    let common = session.commonFields(generatedAt: now())
    lifecycle.begin(helios: common.helios, macOSBuild: common.system.macOSBuild)
    updateLifecycle()
  }

  private func updateLifecycle() {
    guard preferences.automaticEnabled else { return }
    lifecycle.update(
      duration: DiagnosticsFieldRules.duration(now().timeIntervalSince(session.launchStartedAt)),
      macOSBuild: session.observedMacOSBuild)
    session.stability = lifecycle.summary
  }

  func makeHealthPayload(
    type: DiagnosticsReportType,
    reason: DiagnosticsReportReason,
    now: Date = Date()
  ) throws -> FrozenDiagnosticsPayload {
    generation &+= 1
    let report = try session.buildHealth(type: type, reason: reason, generatedAt: now)
    return try DiagnosticsPayloadEncoder.freeze(
      report, reportType: type, now: now, generation: generation)
  }

  func makeCompatibilityPayload(now: Date = Date()) async throws -> FrozenDiagnosticsPayload {
    let evidence = await resolvedCompatibilityProbe().gather()
    let report = DiagnosticsCompatibilityAssembler.report(
      common: session.commonFields(generatedAt: now), evidence: evidence, generatedAt: now)
    generation &+= 1
    return try DiagnosticsPayloadEncoder.freeze(
      report, reportType: .manualCompatibility, now: now, generation: generation)
  }

  func sendManual(_ payload: FrozenDiagnosticsPayload) async -> DiagnosticsTransportResult {
    guard !stopped, !Task.isCancelled,
      payload.reportType == .manualHealth || payload.reportType == .manualCompatibility,
      !payload.isExpired(at: now())
    else { return .rejected }
    guard !sending else { return .retryable(retryAfter: nil) }
    sending = true
    defer { sending = false }
    let result = await resolvedTransport().send(payload)
    guard !stopped, !Task.isCancelled else { return .cancelled }
    switch result {
    case .accepted: preferences.recordLocalStatus(.success, category: .none)
    case .rejected:
      session.recordDiagnosticsError(.serverRejected)
      preferences.recordLocalStatus(.failed, category: .serverRejected, at: now())
    case .retryable:
      session.recordDiagnosticsError(.transport)
      preferences.recordLocalStatus(.failed, category: .transport, at: now())
    case .cancelled: break
    }
    return result
  }

  private func scheduleNextAutomatic() {
    let now = now()
    automaticTask?.cancel()
    automaticTask = nil
    guard !stopped, preferences.automaticEnabled else { return }
    let common = session.commonFields(generatedAt: now)
    let decision = DiagnosticsSchedulePolicy.decision(
      DiagnosticsScheduleInput(
        now: now, launchStartedAt: session.launchStartedAt,
        lastSuccessfulSend: preferences.lastSuccessfulAutomaticSend,
        lastChainStartedAt: preferences.lastAutomaticChainStartedAt,
        persistedNextEligible: preferences.nextEligibleTime,
        lastVersion: preferences.lastReportedHeliosVersion,
        lastBuild: preferences.lastReportedHeliosBuild,
        lastMacOSBuild: preferences.lastReportedMacOSBuild,
        currentVersion: common.helios.version, currentBuild: common.helios.build,
        currentMacOSBuild: common.system.macOSBuild))
    preferences.recordScheduledCheck(at: decision.eligibleAt)
    let revision = preferences.consentRevision
    let delay = max(0, decision.eligibleAt.timeIntervalSince(now))
    let sleep = self.sleep
    automaticTask = Task(priority: .utility) { [weak self] in
      if delay > 0 {
        do { try await sleep(delay) } catch { return }
      }
      guard let self, !self.stopped, !Task.isCancelled, self.preferences.automaticEnabled,
        self.preferences.consentRevision == revision
      else { return }
      await self.runAutomaticChain(reason: decision.reason)
    }
  }

  private func runAutomaticChain(reason: DiagnosticsReportReason) async {
    let baseAttempt = now()
    preferences.recordAutomaticChainStart(
      at: baseAttempt, nextEligible: baseAttempt.addingTimeInterval(DiagnosticsSchedulePolicy.baseCooldown))
    let revision = preferences.consentRevision
    for attempt in 0...2 {
      // Manual and automatic work share one request slot. A manual send must not
      // cause a spurious server-rejection/cooldown in the automatic chain.
      while sending && !Task.isCancelled {
        do { try await sleep(1) } catch { return }
      }
      guard !stopped, preferences.automaticEnabled, preferences.consentRevision == revision,
        !Task.isCancelled
      else { return }

      let payload: FrozenDiagnosticsPayload
      do {
        payload = try makeHealthPayload(type: .automaticHealth, reason: reason, now: now())
      } catch {
        session.recordDiagnosticsError(.build)
        preferences.recordLocalStatus(.failed, category: .build)
        preferences.finishFailedAutomaticChain(baseAttempt: baseAttempt)
        scheduleNextAutomatic()
        return
      }
      sending = true
      automaticRequestInFlight = true
      let result = await resolvedTransport().send(payload)
      automaticRequestInFlight = false
      sending = false
      guard !stopped, !Task.isCancelled, preferences.automaticEnabled,
        preferences.consentRevision == revision else { return }
      switch result {
      case .accepted:
        // Record exactly the accepted report's build tuple, not a newer snapshot.
        guard let accepted = try? JSONDecoder().decode(DiagnosticsHealthReport.self, from: payload.data)
        else { return }
        preferences.recordAutomaticSuccess(
          at: now(), heliosVersion: accepted.helios.version, heliosBuild: accepted.helios.build,
          macOSBuild: accepted.system.macOSBuild)
        scheduleNextAutomatic()
        return
      case .retryable(let retryAfter):
        session.recordDiagnosticsError(.transport)
        if attempt < 2, let delay = DiagnosticsSchedulePolicy.retryDelay(
          index: attempt, jitter: Double.random(in: DiagnosticsSchedulePolicy.jitterRange),
          retryAfter: retryAfter)
        {
          preferences.recordRetry(attempt + 1, nextEligible: now().addingTimeInterval(delay))
          do { try await sleep(delay) } catch { return }
        } else {
          preferences.recordLocalStatus(.failed, category: .transport)
          preferences.finishFailedAutomaticChain(baseAttempt: baseAttempt)
          scheduleNextAutomatic()
          return
        }
      case .rejected:
        session.recordDiagnosticsError(.serverRejected)
        preferences.recordLocalStatus(.failed, category: .serverRejected)
        preferences.finishFailedAutomaticChain(baseAttempt: baseAttempt)
        scheduleNextAutomatic()
        return
      case .cancelled: return
      }
    }
    preferences.finishFailedAutomaticChain(baseAttempt: baseAttempt)
    scheduleNextAutomatic()
  }

  private func cancelAutomaticWork() {
    automaticTask?.cancel()
    automaticTask = nil
    if automaticRequestInFlight { transport?.cancel() }
    if !preferences.automaticEnabled {
      lifecycle.clear()
      session.stability = lifecycle.summary
    }
  }

  private func resolvedTransport() -> any DiagnosticsTransporting {
    if let transport { return transport }
    let created = transportFactory()
    transport = created
    return created
  }

  private func resolvedCompatibilityProbe() -> DiagnosticsCompatibilityProbe {
    if let compatibilityProbe { return compatibilityProbe }
    let created = compatibilityProbeFactory()
    compatibilityProbe = created
    return created
  }
}
