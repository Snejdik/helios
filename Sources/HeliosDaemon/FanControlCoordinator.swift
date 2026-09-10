import Foundation
import OSLog

private final class FanSoftReleasePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func check() throws {
        lock.lock(); let isCancelled = cancelled; lock.unlock()
        guard !isCancelled else {
            throw TelemetryError.unavailable("Soft fan release was pre-empted by a safety restoration")
        }
    }
}

/// Coordination state lives on queue; engine lives exclusively on io.
/// The watchdog never runs on the queue that can block inside AppleSMC.
final class FanControlCoordinator: @unchecked Sendable {
    static let validationRequired = "Fan takeover is unavailable because this Mac/OS safety profile has not been validated."
    private let queue = DispatchQueue(label: "com.snejda.Helios.fan-safety", qos: .userInitiated)
    private let io = DispatchQueue(label: "com.snejda.Helios.fan-writer", qos: .userInitiated)
    private let lease = ControlLease()
    private let makeEngine: @Sendable () throws -> any FanControlDriving
    private let wakeSafetyCheck: @Sendable () throws -> Void
    private let validationMessage: String?
    private let allowedModes: [HeliosFanMode]
    private let readyDetail: String
    private let softReleaseStepDelaySeconds: Double
    private let emergencyMaximumCelsius: Double?
    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanControl")
    private var engine: (any FanControlDriving)? // io only; constructed lazily on first control request
    private var owner: UUID?
    private var pendingOperations = 0
    private var busy: Bool { pendingOperations > 0 }
    private var ready = false
    private var shuttingDown = false
    private var paused = false
    private var state = HeliosFanState.system
    private var detail = ""
    private var timer: DispatchSourceTimer?
    private var softReleasePermit: FanSoftReleasePermit?

    /// The default remains inert for tests/callers that do not explicitly opt
    /// into a validated production profile. HeliosDaemon passes nil only after
    /// the read-only production gate succeeds. The writer factory is lazy, so a
    /// connected helper that never receives a control request never opens it.
    init(validationMessage: String? = FanControlCoordinator.validationRequired,
         allowedModes: [HeliosFanMode] = [.boost, .override],
         readyDetail: String = "",
         makeEngine: @escaping @Sendable () throws -> any FanControlDriving = {
        throw TelemetryError.unavailable("No fan-control engine was explicitly configured")
    },
         wakeSafetyCheck: @escaping @Sendable () throws -> Void = {
        _ = try ProductionFanWakeSafety.run()
    },
         softReleaseStepDelaySeconds: Double = 0.60,
         emergencyMaximumCelsius: Double? = nil) {
        self.validationMessage = validationMessage
        self.allowedModes = allowedModes
        self.readyDetail = readyDetail
        self.makeEngine = makeEngine
        self.wakeSafetyCheck = wakeSafetyCheck
        self.softReleaseStepDelaySeconds = softReleaseStepDelaySeconds.isFinite && softReleaseStepDelaySeconds >= 0
            ? softReleaseStepDelaySeconds
            : 0.60
        self.emergencyMaximumCelsius = emergencyMaximumCelsius.flatMap { $0.isFinite && $0 > 0 && $0 <= 150 ? $0 : nil }
        queue.async { [self] in
            guard validationMessage == nil, !allowedModes.isEmpty else {
                detail = validationMessage ?? "No fan control modes are enabled by this safety profile."
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, self.lease.expire() else { return }
                self.restore(reset: false) { _, _ in }
            }
            self.timer = timer
            timer.activate()
            ready = true
            detail = readyDetail
        }
    }

    func bind(_ id: UUID) { queue.async { [self] in if owner == nil { owner = id } } }

    func status(reply: @escaping @Sendable (Bool, HeliosFanState, String) -> Void) {
        queue.async { [self] in
            reply(ready && !shuttingDown && !paused && !busy && state != .restoring && state != .recoveryRequired,
                  state, detail)
        }
    }

    func calculate(owner id: UUID, sequence: UInt64, sample: UInt64, mode: HeliosFanMode, rpm: Double, temperature: Double,
                   reply: @escaping @Sendable (HeliosReplyCode, HeliosFanState, String) -> Void) {
        queue.async { [self] in
            guard owner == id, !shuttingDown, !paused else { reply(.invalidSession, state, "Control session closed"); return }
            guard ready else { reply(.controlUnavailable, state, detail); return }
            guard !busy else { reply(.busy, state, "Fan state is updating"); return }
            guard allowedModes.contains(mode) else {
                restore(reset: false) { state, _ in
                    reply(.controlUnavailable, state, "That fan mode is not enabled by the current safety profile.")
                }
                return
            }
            guard rpm.isFinite, temperature.isFinite, temperature > 0, temperature <= 150 else {
                restore(reset: false) { state, detail in reply(.invalidCalculation, state, detail) }
                return
            }
            let token: UInt64
            do { token = try lease.accept(owner: id, sequence: sequence, sample: sample, now: HostClock.now) }
            catch {
                restore(reset: false) { state, _ in reply(.invalidCalculation, state, "Fresh telemetry and a new System selection are required") }
                return
            }
            // Privileged thermal safety floor: even if the authenticated app's
            // Manual/Auto policy requests a low target, a fresh trusted Max SoC
            // sample at or above the validated emergency threshold is forced to
            // factory max in the daemon. This does not grant the helper access to
            // sensors; it only constrains the already-authenticated calculation.
            let effectiveMode: HeliosFanMode
            let effectiveRPM: Double
            if let threshold = emergencyMaximumCelsius, temperature >= threshold {
                effectiveMode = .boost
                effectiveRPM = rpm
            } else {
                effectiveMode = mode
                effectiveRPM = rpm
            }
            let acquisitionRequest = state == .system && effectiveMode != .system
            pendingOperations += 1
            io.async { [self] in
                let result = captureMetric {
                    // The first user-requested takeover starts from a fresh
                    // telemetry calculation, but the physically validated M4
                    // Ftst/F0Md arbitration may legitimately take >5 seconds.
                    // Arm a separate bounded acquisition lease before opening
                    // the lazy writer. Revocation still cancels every subsequent
                    // permit check immediately.
                    if acquisitionRequest { try lease.beginAcquisition(token) }
                    if engine == nil { engine = try makeEngine() }
                    guard let engine else { throw TelemetryError.unavailable("Fan engine unavailable") }
                    if acquisitionRequest {
                        try engine.apply(mode: effectiveMode, rpm: effectiveRPM) { try lease.checkAcquisition(token) }
                        try lease.completeAcquisition(token)
                    } else {
                        try engine.apply(mode: effectiveMode, rpm: effectiveRPM) { try lease.check(token) }
                    }
                    return engine.state
                }
                let actual = engine?.state ?? .system
                queue.async { [self] in
                    pendingOperations -= 1
                    if case .success(let value) = result, (try? lease.check(token)) != nil {
                        state = value
                        detail = readyDetail
                        reply(.ok, value, readyDetail)
                    } else {
                        state = actual
                        let failure: String
                        if case .failure(let error) = result {
                            failure = error.localizedDescription
                            logger.error("Fan request failed: \(failure, privacy: .public)")
                        } else {
                            failure = "The control lease expired before the fan request completed."
                        }

                        // A genuine hardware/acquisition failure may happen while
                        // this authenticated calculation is still fresh. Convert that
                        // exact token into a recovery-only generation *before* touching
                        // hardware. After verified System restoration we may re-arm the
                        // lease gate without clearing sample/sequence history. If sleep,
                        // disconnect, expiry, or any other safety revocation races the
                        // recovery, generation changes and completion refuses to re-arm.
                        let recoveryLeaseGeneration = lease.beginRecoverableFailureReset(
                            token,
                            acquisition: acquisitionRequest,
                            now: HostClock.now
                        )
                        restore(
                            reset: false,
                            clearHistory: false,
                            leaseAlreadyRevoked: recoveryLeaseGeneration != nil,
                            recoverableResetGeneration: recoveryLeaseGeneration
                        ) { restoredState, restoreDetail in
                            let message = restoredState == .system
                                ? "Fan request failed; System control was restored. \(failure)"
                                : (restoreDetail.isEmpty ? failure : restoreDetail)
                            reply(.hardwareFailure, restoredState, message)
                        }
                    }
                }
            }
        }
    }

    func release(owner id: UUID, disconnect: Bool = false, graceful: Bool = true,
                 reply: @escaping @Sendable (HeliosFanState, String) -> Void) {
        lease.revoke(owner: id)
        queue.async { [self] in
            guard owner == id else { reply(state, detail); return }
            if graceful && !disconnect && (state == .boost || state == .override) {
                beginSoftRelease(reset: true, clearHistory: false, reply: reply)
                return
            }
            restore(reset: true, clearHistory: disconnect) { [self] value, message in
                if disconnect { owner = nil }
                reply(value, message)
            }
        }
    }

    func shutdown(reply: @escaping @Sendable (Bool) -> Void) {
        lease.revoke()
        queue.async { [self] in
            shuttingDown = true
            timer?.cancel(); timer = nil
            restore(reset: false) { state, _ in reply(state == .system) }
        }
    }

    func pause(reply: @escaping @Sendable (Bool) -> Void) {
        lease.revoke()
        queue.async { [self] in
            paused = true
            restore(reset: false) { state, _ in reply(state == .system) }
        }
    }

    /// Wake never merely flips the paused bit. Any pre-sleep writer is destroyed,
    /// journal-gated recovery runs, and a fresh read-only AppleSMC preflight must
    /// succeed. A new writer remains unopened until the next fresh Boost request.
    func wake(reply: @escaping @Sendable (Bool) -> Void = { _ in }) {
        lease.revoke()
        queue.async { [self] in
            guard !shuttingDown else { reply(false); return }
            paused = true
            ready = false
            state = .restoring
            detail = "Verifying fan safety after wake…"
            pendingOperations += 1
            io.async { [self] in
                let result = captureMetric {
                    engine = nil
                    try wakeSafetyCheck()
                    return true
                }
                queue.async { [self] in
                    pendingOperations -= 1
                    switch result {
                    case .success:
                        state = .system
                        paused = false
                        ready = validationMessage == nil && !allowedModes.isEmpty
                        detail = validationMessage ?? readyDetail
                        lease.reset(clearHistory: true)
                        logger.notice("Wake SMC reprobe completed; stale pre-sleep fan hardware discarded and writer remains lazy.")
                        reply(true)
                    case .failure(let error):
                        state = .recoveryRequired
                        paused = true
                        ready = false
                        detail = "Wake SMC reprobe or recovery could not be confirmed."
                        logger.fault("Wake fan safety check failed: \(error.localizedDescription, privacy: .public)")
                        reply(false)
                    }
                }
            }
        }
    }

    private func beginSoftRelease(reset: Bool, clearHistory: Bool,
                                  reply: @escaping @Sendable (HeliosFanState, String) -> Void) {
        cancelSoftRelease()
        let permit = FanSoftReleasePermit()
        softReleasePermit = permit
        state = .restoring
        detail = "Reducing fan speed before returning control to macOS…"
        pendingOperations += 1
        io.async { [self] in
            let result = captureMetric { engine?.softReleaseTargets() ?? [] }
            queue.async { [self] in
                pendingOperations -= 1
                guard softReleasePermit === permit else { return }
                switch result {
                case .success(let targets):
                    if targets.isEmpty {
                        softReleasePermit = nil
                        restore(reset: reset, clearHistory: clearHistory, reply: reply)
                    } else {
                        runSoftReleaseStep(targets, index: 0, permit: permit,
                                           reset: reset, clearHistory: clearHistory, reply: reply)
                    }
                case .failure(let error):
                    logger.error("Could not prepare soft fan release: \(error.localizedDescription, privacy: .public)")
                    softReleasePermit = nil
                    restore(reset: reset, clearHistory: clearHistory, reply: reply)
                }
            }
        }
    }

    private func runSoftReleaseStep(_ targets: [Double], index: Int, permit: FanSoftReleasePermit,
                                    reset: Bool, clearHistory: Bool,
                                    reply: @escaping @Sendable (HeliosFanState, String) -> Void) {
        guard softReleasePermit === permit else { return }
        guard index < targets.count else {
            softReleasePermit = nil
            restore(reset: reset, clearHistory: clearHistory, reply: reply)
            return
        }

        pendingOperations += 1
        let target = targets[index]
        io.async { [self] in
            let result = captureMetric {
                try permit.check()
                guard let engine else { throw TelemetryError.unavailable("Fan engine unavailable during soft release") }
                try engine.applySoftReleaseTarget(target) { try permit.check() }
                try permit.check()
            }
            queue.async { [self] in
                pendingOperations -= 1
                guard softReleasePermit === permit else { return }
                switch result {
                case .success:
                    detail = "Soft release · \(Int(target)) RPM"
                    let delayMilliseconds = max(0, Int((softReleaseStepDelaySeconds * 1_000).rounded()))
                    queue.asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) { [weak self, permit] in
                        guard let self, self.softReleasePermit === permit else { return }
                        self.runSoftReleaseStep(targets, index: index + 1, permit: permit,
                                                reset: reset, clearHistory: clearHistory, reply: reply)
                    }
                case .failure(let error):
                    logger.error("Soft fan release step failed; restoring System immediately: \(error.localizedDescription, privacy: .public)")
                    softReleasePermit = nil
                    restore(reset: reset, clearHistory: clearHistory, reply: reply)
                }
            }
        }
    }

    private func cancelSoftRelease() {
        softReleasePermit?.cancel()
        softReleasePermit = nil
    }

    private func restore(reset: Bool, clearHistory: Bool = false,
                         leaseAlreadyRevoked: Bool = false,
                         recoverableResetGeneration: UInt64? = nil,
                         reply: @escaping @Sendable (HeliosFanState, String) -> Void) {
        cancelSoftRelease()
        if !leaseAlreadyRevoked { lease.revoke() }
        state = validationMessage == nil ? .restoring : .system
        pendingOperations += 1
        io.async { [self] in
            let result = captureMetric {
                // If no control request ever constructed the writer, there is no
                // in-process ownership to release. Startup/wake bootstrap already
                // proved the durable v2 journal clean before `ready` was exposed.
                if validationMessage == nil, let engine { try engine.restore() }
            }
            queue.async { [self] in
                pendingOperations -= 1
                switch result {
                case .success:
                    state = .system
                    ready = validationMessage == nil && !allowedModes.isEmpty && !shuttingDown
                    detail = validationMessage ?? readyDetail
                    if let recoverableResetGeneration {
                        _ = lease.completeRecoverableFailureReset(recoverableResetGeneration, clearHistory: clearHistory)
                    } else if reset {
                        lease.reset(clearHistory: clearHistory)
                    }
                case .failure(let error):
                    state = .recoveryRequired
                    ready = false
                    detail = "Automatic fan restoration could not be confirmed."
                    logger.fault("Fan recovery failed: \(error.localizedDescription, privacy: .public)")
                }
                reply(state, detail)
            }
        }
    }
}
