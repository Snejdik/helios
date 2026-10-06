import Foundation

/// Thread-safe holder of the learned macOS envelope. The runtime's read-only
/// sampler writes it while macOS controls the fans; the engine reads it.
final class FanLayerSystemObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var envelope = FanSystemEnvelope()
    private var samples = 0

    func observe(fanID: Int, celsius: Double, systemRPM: Double) {
        lock.lock(); defer { lock.unlock() }
        envelope.observe(fanID: fanID, celsius: celsius, systemRPM: systemRPM)
        samples += 1
    }

    func floor(fanID: Int, celsius: Double) -> (rpm: Double, informed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return envelope.floor(fanID: fanID, celsius: celsius)
    }

    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples
    }
}

enum FanLayerEngineError: LocalizedError, Equatable {
    /// macOS (or something else) took the fans back while Helios held them.
    case ownershipLost
    case modeNotSupported

    var errorDescription: String? {
        switch self {
        case .ownershipLost: "macOS took back fan control"
        case .modeNotSupported: "Only Boost and Manual/Auto targets use the fan layer"
        }
    }
}

/// The cool-only layer (docs/FAN_LAYER_DESIGN.md §5–§7) on top of the same
/// durable journal state machine and acquisition/update/recovery executors the
/// validated production path uses. Per call:
/// - trusted temperature is read by the daemon itself (stale ⇒ throw ⇒ System),
/// - Helios takes the fans only when the request adds cooling over macOS,
/// - the commanded target is max(request, safety floor, macOS level) clamped to
///   the factory range, with slow falls and immediate safety rises.
final class FanLayerEngine: FanControlDriving {
    static let manualRetryIntervalSeconds = 1.0
    // Measured on Mac16,1 / 26A434: F0Md accepted ~6 s after Ftst=1 (five 0x82 retries).
    // Still bounded by the 12-second acquisition lease; the app waits for the
    // whole budget in `FanLayerTimings`.
    static let manualTimeoutSeconds = FanLayerTimings.manualTimeoutSeconds

    private let profile: FanLayerProfile
    private let stateMachine: FanOwnershipRecoveryStateMachine
    private let hardware: any FanLayerControlHardware
    private let thermals: any FanLayerThermalSource
    private let observer: FanLayerSystemObserver
    private let now: () -> UInt64
    private let pause: () throws -> Void
    private let acquisitionPolicy: FanOwnershipTransitionPolicy
    private let releasePolicy: FanOwnershipTransitionPolicy
    /// The user's unlock of the full factory maximum, read on every calculation
    /// (`FanLayerCeiling`). The helper enforces the limit, not the app.
    private let fullMaximum: () -> Bool

    private(set) var state = HeliosFanState.system
    private(set) var statusDetail: String?
    private var baselines: [Int: Double] = [:]
    private var commanded: [Int: Double] = [:]
    private var smoother = FanLayerSmoother()

    init(profile: FanLayerProfile, stateMachine: FanOwnershipRecoveryStateMachine,
         hardware: any FanLayerControlHardware, thermals: any FanLayerThermalSource,
         observer: FanLayerSystemObserver, now: @escaping () -> UInt64 = { HostClock.now },
         pause: @escaping () throws -> Void = { Thread.sleep(forTimeInterval: 0.10) },
         fullMaximum: @escaping () -> Bool = { false }) throws {
        guard profile.tier != .unsupported, !profile.fans.isEmpty else {
            throw TelemetryError.unavailable("This Mac has no supported fan layer profile")
        }
        guard stateMachine.record.isClean else {
            throw TelemetryError.unavailable("Fan layer requires start-up recovery to finish first")
        }
        self.profile = profile
        self.stateMachine = stateMachine
        self.hardware = hardware
        self.thermals = thermals
        self.observer = observer
        self.now = now
        self.pause = pause
        self.fullMaximum = fullMaximum
        acquisitionPolicy = try FanOwnershipTransitionPolicy(
            timeoutSeconds: FanLayerTimings.transitionTimeoutSeconds, requiredStableReads: 2)
        releasePolicy = try FanOwnershipTransitionPolicy(
            timeoutSeconds: FanLayerTimings.transitionTimeoutSeconds, requiredStableReads: 10)
    }

    /// Commanded per-fan targets while owned (diagnostics and tests).
    var commandedTargets: [Int: Double] { commanded }

    func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
        try apply(mode: mode, rpm: rpm,
                  context: FanControlContext(appCelsius: .nan, response: .standard), permit: permit)
    }

    func apply(mode: HeliosFanMode, rpm: Double, context: FanControlContext,
               permit: () throws -> Void) throws {
        guard mode == .boost || mode == .override else { throw FanLayerEngineError.modeNotSupported }
        guard rpm.isFinite, rpm >= 0 else { throw TelemetryError.invalidData("Fan layer request must be finite") }
        guard stateMachine.record.phase == .owned || stateMachine.record.isClean else {
            state = .recoveryRequired
            throw TelemetryError.unavailable("Fan ownership journal requires recovery before another takeover")
        }
        let boost = mode == .boost
        do {
            try permit()
            // The daemon's own trusted reading; the app's value may only raise it.
            var celsius = try thermals.maximumSoCCelsius()
            if context.appCelsius.isFinite, context.appCelsius > 0, context.appCelsius <= 150 {
                celsius = max(celsius, context.appCelsius)
            }
            let ticks = now()
            if stateMachine.record.isClean {
                try engage(boost: boost, rpm: rpm, celsius: celsius, ticks: ticks,
                           smoothing: context.response.smoothing, permit: permit)
            } else {
                try hold(boost: boost, rpm: rpm, celsius: celsius, ticks: ticks,
                         smoothing: context.response.smoothing, permit: permit)
            }
        } catch {
            if stateMachine.record.needsRecovery { state = .recoveryRequired }
            throw error
        }
    }

    private func ceiling(for fan: FanLayerFanSurface, fullMaximum: Bool) -> Double {
        FanLayerCeiling.rpm(for: fan.limits, fullMaximum: fullMaximum)
    }

    /// Boost asks for the user's limit; any other request is clamped to it.
    private func request(for fan: FanLayerFanSurface, rpm: Double, boost: Bool, fullMaximum: Bool) -> Double {
        let limit = ceiling(for: fan, fullMaximum: fullMaximum)
        return boost ? limit : min(limit, rpm)
    }

    private func targets(boost: Bool, rpm: Double, celsius: Double, fullMaximum: Bool) throws -> [Int: FanLayerTarget] {
        var result: [Int: FanLayerTarget] = [:]
        for fan in profile.fans {
            let envelope = observer.floor(fanID: fan.id, celsius: celsius)
            let demand = FanLayerDemand(boost: boost,
                                        requestRPM: request(for: fan, rpm: rpm, boost: boost, fullMaximum: fullMaximum),
                                        celsius: celsius, baselineRPM: baselines[fan.id] ?? 0,
                                        envelopeRPM: envelope.rpm, envelopeInformed: envelope.informed,
                                        ceilingRPM: ceiling(for: fan, fullMaximum: fullMaximum))
            result[fan.id] = try FanLayerPolicy.target(for: fan.limits, demand: demand)
        }
        return result
    }

    private func engage(boost: Bool, rpm: Double, celsius: Double, ticks: UInt64,
                        smoothing: FanLayerSmoothing, permit: () throws -> Void) throws {
        try permit()
        var readings: [Int: (targetRPM: Double, actualRPM: Double)] = [:]
        for fan in profile.fans { readings[fan.id] = try hardware.systemReading(fan.id) }
        let full = fullMaximum()
        // Under the user's limit, never take the fans when a handback would
        // follow (with headroom, so Helios does not cycle at the boundary).
        baselines = readings.mapValues { max($0.targetRPM, $0.actualRPM) }
        let headroom = try targets(boost: boost, rpm: rpm,
                                   celsius: min(150, celsius + FanLayerCeiling.engageMarginCelsius), fullMaximum: full)
        if headroom.values.contains(where: \.handback) {
            resetRuntime()
            state = .system
            statusDetail = FanLayerCeiling.handbackDetail
            return
        }
        let emergency = celsius >= FanLayerSafetyCurve.emergencyCelsius
        let needed = emergency || profile.fans.contains { fan in
            guard let reading = readings[fan.id] else { return true }
            // Boost under a limit is just "the limit": it adds nothing when
            // macOS already cools at least that much.
            let boosting = boost && full
            return FanLayerPolicy.needsOwnership(requestRPM: request(for: fan, rpm: rpm, boost: boost, fullMaximum: full),
                                                 boost: boosting,
                                                 systemTargetRPM: reading.targetRPM, systemActualRPM: reading.actualRPM)
        }
        guard needed else {
            // macOS already cools at least this much: stay on System, no writes.
            state = .system
            smoother.reset()
            commanded = [:]
            baselines = [:]
            let level = readings.values.map { max($0.targetRPM, $0.actualRPM) }.max() ?? 0
            statusDetail = "macOS is already cooling at \(Int(level.rounded())) RPM or more, so Helios stays on System."
            return
        }
        smoother.reset()
        let wanted = try targets(boost: boost, rpm: rpm, celsius: celsius, fullMaximum: full)
        var first: [Int: Double] = [:]
        for fan in profile.fans {
            guard let target = wanted[fan.id] else { continue }
            first[fan.id] = smoother.next(fanID: fan.id, target: target, limits: fan.limits,
                                          smoothing: smoothing, ticks: ticks)
        }
        try withoutActuallyEscaping(permit) { escapingPermit in
            let acquire = FanOwnershipAcquisitionExecutor(
                stateMachine: stateMachine, hardware: hardware, transitionPolicy: acquisitionPolicy,
                now: now, pause: pause, permit: escapingPermit,
                manualRetryIntervalSeconds: Self.manualRetryIntervalSeconds,
                manualTimeoutSeconds: Self.manualTimeoutSeconds)
            try acquire.acquire(targets: first)
        }
        commanded = first
        state = boost ? .boost : .override
        statusDetail = describe(wanted, celsius: celsius)
    }

    private func hold(boost: Bool, rpm: Double, celsius: Double, ticks: UInt64,
                      smoothing: FanLayerSmoothing, permit: () throws -> Void) throws {
        let wanted = try targets(boost: boost, rpm: rpm, celsius: celsius, fullMaximum: fullMaximum())
        if wanted.values.contains(where: \.handback) {
            // More cooling than the user's limit is needed: macOS takes over.
            try restore()
            statusDetail = FanLayerCeiling.handbackDetail
            return
        }
        var next: [Int: Double] = [:]
        for fan in profile.fans {
            guard let target = wanted[fan.id] else { continue }
            next[fan.id] = smoother.next(fanID: fan.id, target: target, limits: fan.limits,
                                         smoothing: smoothing, ticks: ticks)
        }
        let unchanged = next.allSatisfy { id, value in abs((commanded[id] ?? -1) - value) <= 0.5 }
        if unchanged {
            // Same targets: no writes, but verify that Helios still holds the
            // fans so a takeover by macOS fails closed and is reported.
            for (id, value) in next.sorted(by: { $0.key < $1.key }) {
                try permit()
                guard try hardware.verifyFanOwned(id, targetRPM: value) else {
                    try stateMachine.requireRecovery()
                    state = .recoveryRequired
                    throw FanLayerEngineError.ownershipLost
                }
            }
        } else {
            do {
                try withoutActuallyEscaping(permit) { escapingPermit in
                    let update = FanOwnershipTargetUpdateExecutor(
                        stateMachine: stateMachine, hardware: hardware, permit: escapingPermit,
                        transitionPolicy: acquisitionPolicy, now: now, pause: pause)
                    try update.update(targets: next)
                }
            } catch FanOwnershipTargetUpdateExecutorError.fanVerificationFailed {
                state = .recoveryRequired
                throw FanLayerEngineError.ownershipLost
            }
            commanded = next
        }
        state = boost ? .boost : .override
        statusDetail = describe(wanted, celsius: celsius)
    }

    private func describe(_ wanted: [Int: FanLayerTarget], celsius: Double) -> String {
        let values = profile.fans.compactMap { fan in commanded[fan.id].map { (fan.id, $0) } }
        let rpm = values.map { "\(Int($0.1.rounded()))" }.joined(separator: " / ")
        let sources = Set(wanted.values.map(\.source)).map(\.rawValue).sorted().joined(separator: ", ")
        return "\(profile.tier.label) fan layer · \(rpm) RPM · \(sources) · \(Int(celsius.rounded())) °C"
    }

    func restore() throws {
        guard stateMachine.record.needsRecovery else {
            resetRuntime()
            state = .system
            return
        }
        state = .restoring
        let recovery = FanOwnershipRecoveryExecutor(
            stateMachine: stateMachine, hardware: hardware, transitionPolicy: releasePolicy,
            now: now, pause: pause,
            // Recovery is independent of the revoked control lease.
            permit: {})
        do {
            try recovery.recover()
            guard stateMachine.record.isClean else {
                throw TelemetryError.unavailable("Fan layer recovery did not reach a clean journal")
            }
            guard try hardware.readGlobalOwnership() == 0 else {
                throw TelemetryError.unavailable("Ftst did not return to 0 after release")
            }
            for fan in profile.fans where !(try hardware.verifyFanIsSystem(fan.id)) {
                throw TelemetryError.unavailable("Fan \(fan.id + 1) did not return to macOS control")
            }
            resetRuntime()
            state = .system
        } catch {
            state = .recoveryRequired
            throw error
        }
    }

    private func resetRuntime() {
        baselines = [:]
        commanded = [:]
        smoother.reset()
        statusDetail = nil
    }
}
