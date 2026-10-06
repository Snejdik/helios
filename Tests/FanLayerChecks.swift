import Foundation

// Simulated checks for the cool-only fan layer (docs/FAN_LAYER_DESIGN.md §11).
// No privileged service, no launchd registration, no physical SMC writes.

private enum Failure: Error { case check(String), simulated(String) }
private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure.check(message) }
}
private func rejects(_ message: String, _ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure.check("Expected rejection: \(message)")
}
private func ticks(_ seconds: Double) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return UInt64(seconds * 1_000_000_000 * Double(info.denom) / Double(info.numer))
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_000_000_000_000
    var now: UInt64 { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value &+= ticks(seconds) } }
}

/// Two-fan simulated SMC with an explicit macOS model: restoring a fan hands it
/// back to "macOS" (mode 3, target from the system level).
private final class SimLayerHardware: FanLayerControlHardware, @unchecked Sendable {
    let lock = NSLock()
    var ftst: UInt8 = 0
    var modes: [Int: UInt8] = [0: 3, 1: 3]
    var targets: [Int: Double] = [0: 0, 1: 0]
    var actuals: [Int: Double] = [0: 0, 1: 0]
    var systemLevel: [Int: Double] = [0: 0, 1: 0]
    var limits: [Int: (Double, Double)] = [0: (2_317, 6_550), 1: (1_200, 6_000)]
    var failOn: String?
    var stuckFtst = false
    var surfaceDrift = false
    var log: [String] = []

    var writes: [String] { lock.withLock { log.filter { $0.hasPrefix("write") } } }

    func reclaimByMacOS() {
        lock.withLock {
            ftst = 0
            for id in modes.keys { modes[id] = 3; targets[id] = systemLevel[id] ?? 0 }
        }
    }

    private func check(_ op: String) throws {
        if failOn == op { throw Failure.simulated(op) }
    }

    func validateGlobalAcquisitionBaseline() throws {
        try lock.withLock {
            log.append("baseline")
            guard !surfaceDrift else { throw Failure.simulated("surface drift") }
            guard ftst == 0, modes.values.allSatisfy({ $0 == 0 || $0 == 3 }) else {
                throw Failure.simulated("baseline not clean")
            }
        }
    }
    func requestGlobalAcquisition() throws {
        try lock.withLock { log.append("write Ftst=1"); try check("Ftst=1"); ftst = 1 }
    }
    func readGlobalOwnership() throws -> UInt8 { lock.withLock { ftst } }
    func readFanMode(_ id: Int) throws -> UInt8 {
        try lock.withLock { guard let mode = modes[id] else { throw Failure.simulated("no fan") }; return mode }
    }
    func requestFanManual(_ id: Int) throws {
        try lock.withLock {
            log.append("write F\(id)Md=1")
            try check("F\(id)Md=1")
            guard ftst == 1 else { throw Failure.simulated("manual without Ftst") }
            modes[id] = 1
        }
    }
    func setFanTarget(_ id: Int, rpm: Double) throws {
        try lock.withLock {
            log.append("write F\(id)Tg=\(Int(rpm))")
            try check("F\(id)Tg")
            guard ftst == 1, modes[id] == 1, let (low, high) = limits[id],
                  rpm == rpm.rounded(), rpm >= ceil(low), rpm <= floor(high) else {
                throw Failure.simulated("invalid target write")
            }
            targets[id] = rpm
            actuals[id] = rpm
        }
    }
    func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool {
        lock.withLock { ftst == 1 && modes[id] == 1 && abs((targets[id] ?? -1) - targetRPM) <= 1 }
    }
    func restoreFanToSystem(_ id: Int) throws {
        try lock.withLock {
            if modes[id] == 1 {
                log.append("write F\(id)Md=0")
                try check("F\(id)Md=0")
                modes[id] = 3
                targets[id] = systemLevel[id] ?? 0
            }
        }
    }
    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        lock.withLock { ftst == 0 && (modes[id] == 0 || modes[id] == 3) }
    }
    func requestGlobalRelease() throws {
        try lock.withLock {
            log.append("write Ftst=0")
            try check("Ftst=0")
            if !stuckFtst { ftst = 0 }
        }
    }
    func systemReading(_ id: Int) throws -> (targetRPM: Double, actualRPM: Double) {
        try lock.withLock {
            guard let target = targets[id], let actual = actuals[id] else { throw Failure.simulated("no fan") }
            return (target, actual)
        }
    }
}

private final class SimThermals: FanLayerThermalSource, @unchecked Sendable {
    let lock = NSLock()
    var celsius: Double? = 60
    func maximumSoCCelsius() throws -> Double {
        try lock.withLock {
            guard let celsius else { throw TelemetryError.unavailable("stale trusted thermals") }
            return celsius
        }
    }
}

private final class MemoryLayerJournal: FanLayerJournal, @unchecked Sendable {
    var record = FanOwnershipRecoveryRecord.clean
    var origin: FanLayerMachineIdentity?
    let identity: FanLayerMachineIdentity
    var failSaves = false
    var quarantined = false
    init(identity: FanLayerMachineIdentity) { self.identity = identity }
    func load() throws -> FanOwnershipRecoveryRecord { record }
    func save(_ next: FanOwnershipRecoveryRecord) throws {
        if failSaves { throw Failure.simulated("journal save") }
        // Exercise the real codec on every save.
        let decoded = try FanLayerJournalCodec.decode(try FanLayerJournalCodec.encode(next, identity: identity))
        record = decoded.record
        origin = decoded.identity
    }
    func quarantine() throws { quarantined = true; record = .clean; origin = nil }
}

private final class MemoryConsent: FanLayerConsentStore {
    var stored: FanLayerMachineIdentity?
    func consentedIdentity() throws -> FanLayerMachineIdentity? { stored }
    func grant(_ identity: FanLayerMachineIdentity) throws { stored = identity }
    func revoke() throws { stored = nil }
}

private func identity(_ model: String = "Mac16,1", _ build: String = "26A434") -> FanLayerMachineIdentity {
    try! FanLayerMachineIdentity(modelIdentifier: model, osBuild: build)
}

private func evidence(model: String = "Mac16,1", build: String = "26A434", ftst: UInt8 = 0,
                      fans: [FanOwnershipPreflightFan]? = nil, fanCount: Int? = nil) -> FanOwnershipPreflightEvidence {
    let list = fans ?? [FanOwnershipPreflightFan(id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 0,
                                                 minimumRPM: 2_317, maximumRPM: 6_550, targetType: "flt ")]
    return FanOwnershipPreflightEvidence(modelIdentifier: model, osBuild: build, fanCount: fanCount ?? list.count,
                                         globalKeyType: "ui8 ", globalKeySize: 1, globalValue: ftst, fans: list)
}

private let fullAccess = FanLayerKeyAccess(attributes: ["Ftst": 0xd0, "F0Md": 0xd0, "F0Tg": 0xd4, "F1Md": 0xd0, "F1Tg": 0xd4])

private func twoFanProfile() throws -> FanLayerProfile {
    let fans = [
        FanOwnershipPreflightFan(id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 0,
                                 minimumRPM: 2_317, maximumRPM: 6_550, targetType: "flt "),
        FanOwnershipPreflightFan(id: 1, modeKey: "F1Md", mode: 3, actualRPM: 0, targetRPM: 0,
                                 minimumRPM: 1_200, maximumRPM: 6_000, targetType: "flt "),
    ]
    let profile = try FanLayerProbe.evaluate(evidence: evidence(model: "Mac16,6", fans: fans), cpuBrand: "Apple M4 Max",
                                             access: fullAccess, trustedThermalsAvailable: true)
    try require(profile.tier == .experimental, "two-fan M4 Max profile is experimental: \(profile.reasons)")
    return profile
}

private final class FlagBox: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

private struct Rig {
    let clock = TestClock()
    /// The user's unlock of the full factory maximum (default: 90 % limit).
    let fullMaximum: FlagBox
    let hardware = SimLayerHardware()
    let thermals = SimThermals()
    let observer = FanLayerSystemObserver()
    let journal: MemoryLayerJournal
    let machine: FanOwnershipRecoveryStateMachine
    let engine: FanLayerEngine

    init(fullMaximum: Bool = false) throws {
        journal = MemoryLayerJournal(identity: identity("Mac16,6"))
        machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let clock = clock
        let flag = FlagBox(fullMaximum)
        self.fullMaximum = flag
        engine = try FanLayerEngine(profile: try twoFanProfile(), stateMachine: machine, hardware: hardware,
                                    thermals: thermals, observer: observer, now: { clock.now },
                                    pause: { clock.advance(0.1) }, fullMaximum: { flag.value })
    }

    func apply(_ mode: HeliosFanMode, _ rpm: Double, app: Double = .nan, response: FanLayerResponse = .balanced,
               permit: () throws -> Void = {}) throws {
        try engine.apply(mode: mode, rpm: rpm, context: FanControlContext(appCelsius: app, response: response),
                         permit: permit)
    }
}

@main
private enum FanLayerChecks {
    static func main() async {
        do {
            try require(geteuid() != 0, "Run checks as an ordinary user")
            try policyChecks()
            try smootherAndEnvelopeChecks()
            try timingBudgetChecks()
            try reclaimGuardChecks()
            try probeChecks()
            try journalChecks()
            try bootstrapChecks()
            try engineChecks()
            try engineFailureMatrix()
            try await coordinatorChecks()
            print("PASS fan layer: cool-only policy, safety floor, smoothing, envelope, reclaim limit, tiers/probe, v3 journal, cross-build recovery, engine failure matrix, coordinator lockout/boost cap")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    // MARK: Policy

    static func policyChecks() throws {
        let fan = FanLayerFanLimits(id: 0, minimumRPM: 2_317, maximumRPM: 6_550)
        func demand(_ request: Double, _ celsius: Double, baseline: Double = 0, envelope: Double = 0,
                    informed: Bool = true, boost: Bool = false) -> FanLayerDemand {
            FanLayerDemand(boost: boost, requestRPM: request, celsius: celsius, baselineRPM: baseline,
                           envelopeRPM: envelope, envelopeInformed: informed)
        }
        // Safety curve shape.
        try require(FanLayerSafetyCurve.fraction(at: 50) == 0, "no floor at 50 °C")
        try require(FanLayerSafetyCurve.fraction(at: 65) == 0, "floor starts above 65 °C")
        try require(abs(FanLayerSafetyCurve.fraction(at: 80) - 0.5) < 1e-9, "half range at 80 °C")
        try require(FanLayerSafetyCurve.fraction(at: 88) == 1, "maximum from 88 °C")
        try require(FanLayerSafetyCurve.fraction(at: .nan) == 1, "unknown temperature errs to cooling")
        var previous = 0.0
        for tenth in 300...1_000 {
            let value = FanLayerSafetyCurve.fraction(at: Double(tenth) / 10)
            try require(value >= previous, "safety curve is monotone")
            previous = value
        }

        // Never below any source, integral, inside the factory range.
        for request in stride(from: 0.0, through: 8_000, by: 250) {
            for celsius in stride(from: 30.0, through: 94, by: 2) {
                for baseline in [0.0, 2_500, 4_000] {
                    for envelope in [0.0, 2_600, 5_000] {
                        for informed in [true, false] {
                            let target = try FanLayerPolicy.target(for: fan, demand: demand(request, celsius, baseline: baseline,
                                                                                            envelope: envelope, informed: informed))
                            let shifted = informed ? celsius : celsius + FanLayerSafetyCurve.uncertaintyShiftCelsius
                            let safety = fan.rpm(fraction: FanLayerSafetyCurve.fraction(at: shifted))
                            try require(target.rpm >= min(6_550, max(request, baseline, envelope, safety)) - 0.0001,
                                        "never below a source at \(request)/\(celsius)/\(baseline)/\(envelope)")
                            try require(target.rpm >= 2_317 && target.rpm <= 6_550, "inside factory range")
                            try require(target.rpm == target.rpm.rounded(), "integral target")
                            try require(target.floorRPM <= target.rpm, "floor never exceeds target")
                        }
                    }
                }
            }
        }
        try require(try FanLayerPolicy.target(for: fan, demand: demand(0, 96)).rpm == 6_550, "emergency forces max")
        try require(try FanLayerPolicy.target(for: fan, demand: demand(0, 96)).source == .emergency, "emergency source")
        try require(try FanLayerPolicy.target(for: fan, demand: demand(0, 40, boost: true)).rpm == 6_550, "Boost is max")
        try require(try FanLayerPolicy.target(for: fan, demand: demand(2_700.2, 40)).rpm == 2_701, "rounds up")
        try require(try FanLayerPolicy.target(for: fan, demand: demand(0, 40)).source == .factoryMinimum, "minimum source")
        try require(try FanLayerPolicy.target(for: fan, demand: demand(2_400, 80)).source == .safetyFloor, "safety wins hot")
        try require(try FanLayerPolicy.target(for: fan, demand: demand(2_400, 62, informed: false)).rpm
                    > (try FanLayerPolicy.target(for: fan, demand: demand(2_400, 62, informed: true)).rpm),
                    "uninformed envelope is more aggressive")
        try rejects("NaN temperature") { _ = try FanLayerPolicy.target(for: fan, demand: demand(2_400, .nan)) }
        try rejects("negative request") { _ = try FanLayerPolicy.target(for: fan, demand: demand(-1, 50)) }
        try rejects("bad limits") {
            _ = try FanLayerPolicy.target(for: FanLayerFanLimits(id: 0, minimumRPM: 3_000, maximumRPM: 2_000), demand: demand(1, 50))
        }

        // Engagement only when Helios adds cooling.
        try require(!FanLayerPolicy.needsOwnership(requestRPM: 2_500, boost: false, systemTargetRPM: 2_500, systemActualRPM: 2_480),
                    "no takeover when macOS already does it")
        try require(!FanLayerPolicy.needsOwnership(requestRPM: 2_540, boost: false, systemTargetRPM: 2_500, systemActualRPM: 0),
                    "margin avoids pointless takeover")
        // While macOS spins the fan, only a clearly higher request takes over.
        try require(!FanLayerPolicy.needsOwnership(requestRPM: 2_900, boost: false, systemTargetRPM: 2_500, systemActualRPM: 2_480),
                    "small gain over a spinning macOS fan is not worth the takeover dip")
        try require(FanLayerPolicy.needsOwnership(requestRPM: 3_100, boost: false, systemTargetRPM: 2_500, systemActualRPM: 2_480),
                    "clearly higher request takes over")
        try require(FanLayerPolicy.needsOwnership(requestRPM: 2_400, boost: false, systemTargetRPM: 0, systemActualRPM: 0),
                    "idle fan keeps the small margin")
        try require(FanLayerPolicy.needsOwnership(requestRPM: 2_317, boost: false, systemTargetRPM: 0, systemActualRPM: 0),
                    "takeover when fan is off and a minimum is requested")
        try require(FanLayerPolicy.needsOwnership(requestRPM: 0, boost: true, systemTargetRPM: 6_000, systemActualRPM: 6_000),
                    "Boost always takes over")
        try require(FanLayerResponse(smoothness: 1.01) == nil && FanLayerResponse(smoothness: -0.01) == nil
                    && FanLayerResponse(smoothness: .nan) == nil && FanLayerResponse(smoothness: .infinity) == nil,
                    "response is bounded")
        var gentler: FanLayerSmoothing?
        for step in 0...20 {
            guard let response = FanLayerResponse(smoothness: Double(step) / 20) else { throw Failure.check("valid response") }
            let smoothing = response.smoothing
            try require(smoothing.riseRPMPerSecond > smoothing.fallRPMPerSecond, "rises faster than falls (\(step))")
            if let gentler {
                try require(smoothing.fallRPMPerSecond < gentler.fallRPMPerSecond
                            && smoothing.minimumDwellSeconds >= gentler.minimumDwellSeconds
                            && smoothing.riseRPMPerSecond < gentler.riseRPMPerSecond,
                            "gentler is slower everywhere (\(step))")
            }
            gentler = smoothing
        }
        try require(FanLayerResponse.quickly.smoothing.fallRPMPerSecond == 1_000
                    && abs(FanLayerResponse.gently.smoothing.fallRPMPerSecond - 40) < 0.001
                    && FanLayerResponse.gently.smoothing.minimumDwellSeconds == 10, "slider ends")
        try require(FanLayerResponse(legacyIndex: 0).smoothness < FanLayerResponse(legacyIndex: 1).smoothness
                    && FanLayerResponse(legacyIndex: 1) == .balanced
                    && FanLayerResponse(legacyIndex: 9).smoothness == FanLayerResponse(legacyIndex: 2).smoothness,
                    "0.2 picker migrates")
        let fall = FanLayerResponse.balanced.secondsToFall(from: 5_895, to: 2_317)
        try require(abs(fall - (5 + 3_578.0 / 200)) < 0.01, "caption time (\(fall))")

        // The speed limit is 90 % of the factory maximum by default.
        try require(FanLayerCeiling.rpm(for: fan, fullMaximum: false) == 5_895, "90 % of 6,550 is 5,895")
        try require(FanLayerCeiling.rpm(for: fan, fullMaximum: true) == 6_550, "unlocked is the factory maximum")
        try require(FanLayerCeiling.rpm(for: FanLayerFanLimits(id: 0, minimumRPM: 2_000, maximumRPM: 2_100),
                                        fullMaximum: false) == 2_000, "never below the factory minimum")
        func limited(_ request: Double, _ celsius: Double, boost: Bool = false, baseline: Double = 0,
                     envelope: Double = 0) throws -> FanLayerTarget {
            var value = demand(request, celsius, baseline: baseline, envelope: envelope, boost: boost)
            value.ceilingRPM = 5_895
            return try FanLayerPolicy.target(for: fan, demand: value)
        }
        let limitedBoost = try limited(0, 40, boost: true)
        try require(limitedBoost.rpm == 5_895 && limitedBoost.floorRPM == 5_895 && limitedBoost.source == .boost,
                    "Boost is the limit")
        try require(try limited(6_400, 40).rpm == 5_895, "Manual above the limit is clamped")
        try require(try limited(30_000, 40).rpm == 5_895, "the app cannot exceed the limit with a huge request")
        try require(try limited(3_000, 50).rpm == 3_000 && !(try limited(3_000, 50).handback), "below the limit unchanged")
        try require(try limited(0, 96).handback, "emergency under a limit hands back to macOS")
        try require(try limited(0, 88).handback, "safety floor above the limit hands back")
        try require(try limited(0, 60, baseline: 6_100).handback, "macOS cooling above the limit hands back")
        try require(try limited(0, 60, envelope: 6_000).handback, "learned macOS level above the limit hands back")
        try require(!(try limited(0, 84).handback), "a floor under the limit is still held")
        for request in stride(from: 0.0, through: 8_000, by: 500) {
            for celsius in stride(from: 30.0, through: 99, by: 3) {
                let target = try limited(request, celsius)
                try require(target.handback || target.rpm <= 5_895, "never above the limit (\(request)/\(celsius))")
            }
        }
    }

    /// Regression from a live run: the app gave
    /// up after 13 s while the helper was still restoring System after a
    /// refused takeover. Every client wait must cover the helper's worst case.
    static func timingBudgetChecks() throws {
        try require(ControlLease.acquisitionTimeoutSeconds == FanLayerTimings.acquisitionLeaseSeconds,
                    "acquisition lease matches the shared budget")
        try require(ControlLease.steadyTimeoutSeconds == FanLayerTimings.steadyLeaseSeconds,
                    "steady lease matches the shared budget")
        try require(FanLayerEngine.manualTimeoutSeconds == FanLayerTimings.manualTimeoutSeconds
                    && FanLayerEngine.manualTimeoutSeconds < FanLayerTimings.acquisitionLeaseSeconds,
                    "F0Md arbitration ends inside the acquisition lease")
        for fans in 1...FanLayerTimings.budgetFanCount {
            let release = FanLayerTimings.releaseBudgetSeconds(fanCount: fans)
            try require(release >= FanLayerTimings.transitionTimeoutSeconds * Double(1 + fans),
                        "release budget covers Ftst plus \(fans) fan readbacks")
            try require(FanLayerTimings.clientAcquisitionTimeoutSeconds > FanLayerTimings.acquisitionLeaseSeconds + release,
                        "client acquisition wait > lease + release (\(fans) fans)")
            try require(FanLayerTimings.clientSteadyTimeoutSeconds > FanLayerTimings.transitionTimeoutSeconds + release,
                        "client steady wait > update + release (\(fans) fans)")
            try require(FanLayerTimings.clientReleaseTimeoutSeconds > release, "client release wait > release (\(fans) fans)")
        }
        try require(FanLayerTimings.clientAcquisitionTimeoutSeconds >= 23, "acquisition wait is at least 23 s")
        try require(FanLayerTimings.milliseconds(FanLayerTimings.clientAcquisitionTimeoutSeconds)
                    >= Int(FanLayerTimings.clientAcquisitionTimeoutSeconds * 1_000), "milliseconds round up")
    }

    /// Regression from a live run: falls must follow the
    /// configured rate over a whole descent, not one calculation step per dwell.
    static func fallRampChecks(fan: FanLayerFanLimits, start: UInt64) throws {
        func target(_ rpm: Double, floor: Double = 2_317) -> FanLayerTarget {
            FanLayerTarget(rpm: rpm, floorRPM: floor, source: .request)
        }
        for response in FanLayerResponse.presets {
            let smoothing = response.smoothing
            var smoother = FanLayerSmoother()
            _ = smoother.next(fanID: 0, target: target(6_550), limits: fan, smoothing: smoothing, ticks: start)
            // The daemon calculates about every 0.53 s, with jitter.
            var time = 0.0, step = 0
            var samples: [(time: Double, rpm: Double)] = []
            while time < 30 {
                step += 1
                time += [0.53, 0.48, 0.61, 0.5][step % 4]
                let rpm = smoother.next(fanID: 0, target: target(2_317), limits: fan, smoothing: smoothing,
                                        ticks: start + ticks(time))
                samples.append((time, rpm))
            }
            // The hold starts when the lower target is first seen.
            let hold = samples[0].time + smoothing.minimumDwellSeconds
            // Exactly one hold: unchanged until the dwell has passed, then strictly
            // falling until the target is reached.
            for sample in samples where sample.time <= hold {
                try require(sample.rpm == 6_550, "hold keeps the level (\(response) t=\(sample.time))")
            }
            let after = samples.filter { $0.time > hold }
            for (earlier, later) in zip(after, after.dropFirst()) where earlier.rpm > 2_317 {
                try require(later.rpm < earlier.rpm, "no second hold during a fall (\(response) t=\(later.time))")
            }
            // Average rate after the hold within ±10 % of the configured rate.
            let expected = smoothing.fallRPMPerSecond
            if let moving = after.last(where: { $0.rpm > 2_317 }) {
                let rate = (6_550 - moving.rpm) / (moving.time - hold)
                try require(abs(rate - expected) <= expected * 0.10,
                            "fall rate \(Int(rate)) RPM/s matches \(Int(expected)) (\(response))")
            }
            let last = samples[samples.count - 1]
            let ideal = max(2_317, 6_550 - expected * (last.time - hold))
            try require(abs(last.rpm - ideal) <= 1.5, "level after 30 s follows the ramp (\(response): \(last.rpm) vs \(ideal))")
        }

        // A floor that holds the level does not re-arm the hold and does not cause a jump.
        let smoothing = FanLayerResponse.balanced.smoothing
        let hold = smoothing.minimumDwellSeconds
        var floored = FanLayerSmoother()
        _ = floored.next(fanID: 0, target: target(6_000), limits: fan, smoothing: smoothing, ticks: start)
        _ = floored.next(fanID: 0, target: target(2_317), limits: fan, smoothing: smoothing, ticks: start + ticks(0.5))
        let pinned = floored.next(fanID: 0, target: target(5_500, floor: 5_500), limits: fan, smoothing: smoothing,
                                  ticks: start + ticks(hold + 10))
        try require(pinned == 5_500, "floor pins the fall (\(pinned))")
        let released = floored.next(fanID: 0, target: target(2_317), limits: fan, smoothing: smoothing,
                                    ticks: start + ticks(hold + 11))
        try require(abs(released - (5_500 - smoothing.fallRPMPerSecond)) <= 1,
                    "after a floor the fall continues at the rate without a jump or new hold (\(released))")

        // Settling at a lower target and then lowering it again continues the ramp.
        var settled = FanLayerSmoother()
        _ = settled.next(fanID: 0, target: target(4_000), limits: fan, smoothing: smoothing, ticks: start)
        _ = settled.next(fanID: 0, target: target(3_800), limits: fan, smoothing: smoothing, ticks: start + ticks(0.5))
        let reachedAt = 0.5 + hold + 200 / smoothing.fallRPMPerSecond + 0.5
        let reached = settled.next(fanID: 0, target: target(3_800), limits: fan, smoothing: smoothing,
                                   ticks: start + ticks(reachedAt))
        try require(reached == 3_800, "reaches the first lower target (\(reached))")
        let lowered = settled.next(fanID: 0, target: target(3_000), limits: fan, smoothing: smoothing,
                                   ticks: start + ticks(reachedAt + 1))
        try require(abs(lowered - (3_800 - smoothing.fallRPMPerSecond)) <= 1, "a further fall step is not held again (\(lowered))")
        // A rise ends the fall; the next fall holds again.
        _ = settled.next(fanID: 0, target: target(4_500, floor: 4_500), limits: fan, smoothing: smoothing,
                         ticks: start + ticks(reachedAt + 2))
        _ = settled.next(fanID: 0, target: target(3_000), limits: fan, smoothing: smoothing,
                         ticks: start + ticks(reachedAt + 2.5))
        let heldAgain = settled.next(fanID: 0, target: target(3_000), limits: fan, smoothing: smoothing,
                                     ticks: start + ticks(reachedAt + 2.5 + hold - 0.5))
        try require(heldAgain == 4_500, "a new fall after a rise is held once (\(heldAgain))")
    }

    static func smootherAndEnvelopeChecks() throws {
        let fan = FanLayerFanLimits(id: 0, minimumRPM: 2_317, maximumRPM: 6_550)
        let smoothing = FanLayerResponse.balanced.smoothing
        var smoother = FanLayerSmoother()
        let start: UInt64 = 1_000_000_000
        func target(_ rpm: Double, floor: Double = 2_317, source: FanLayerTargetSource = .request) -> FanLayerTarget {
            FanLayerTarget(rpm: rpm, floorRPM: floor, source: source)
        }
        try require(smoother.next(fanID: 0, target: target(5_000), limits: fan, smoothing: smoothing, ticks: start) == 5_000,
                    "first target is applied directly")
        // Dwell: an immediate fall is held (the hold starts when the fall begins, t = 1 s).
        try require(smoother.next(fanID: 0, target: target(3_000), limits: fan, smoothing: smoothing,
                                  ticks: start + ticks(1)) == 5_000, "dwell holds a fall")
        // After the dwell, fall by the fall rate for the time after the hold.
        let afterHold = 1 + smoothing.minimumDwellSeconds
        let fallen = smoother.next(fanID: 0, target: target(3_000), limits: fan, smoothing: smoothing,
                                   ticks: start + ticks(afterHold + 1))
        try require(abs(fallen - (5_000 - smoothing.fallRPMPerSecond * 1)) <= 1, "slow fall (\(fallen))")
        // A floor rise is immediate.
        let floorRise = smoother.next(fanID: 0, target: target(6_000, floor: 6_000, source: .safetyFloor), limits: fan,
                                      smoothing: smoothing, ticks: start + ticks(afterHold + 1.5))
        try require(floorRise == 6_000, "safety rise is immediate")
        // Never below the floor even while falling slowly.
        var second = FanLayerSmoother()
        _ = second.next(fanID: 0, target: target(6_000), limits: fan, smoothing: smoothing, ticks: start)
        let held = second.next(fanID: 0, target: target(4_000, floor: 5_900), limits: fan, smoothing: smoothing,
                               ticks: start + ticks(10))
        try require(held >= 5_900, "smoother respects the floor")
        // A request rise is rate limited but fast.
        var third = FanLayerSmoother()
        _ = third.next(fanID: 0, target: target(2_317), limits: fan, smoothing: smoothing, ticks: start)
        let risen = third.next(fanID: 0, target: target(6_500), limits: fan, smoothing: smoothing, ticks: start + ticks(0.5))
        try require(risen > 2_317 && risen <= 2_317 + smoothing.riseRPMPerSecond * 0.5 + 1, "request rise is bounded")
        // Clock regression: take the policy target.
        let regressed = third.next(fanID: 0, target: target(3_000), limits: fan, smoothing: smoothing, ticks: start)
        try require(regressed == 3_000, "clock regression applies the target directly")
        try fallRampChecks(fan: fan, start: start)

        var envelope = FanSystemEnvelope()
        try require(envelope.floor(fanID: 0, celsius: 60) == (0, false), "empty envelope is uninformed")
        envelope.observe(fanID: 0, celsius: 55.4, systemRPM: 2_500)
        envelope.observe(fanID: 0, celsius: 62.0, systemRPM: 2_520)
        envelope.observe(fanID: 0, celsius: 70.0, systemRPM: 0)
        envelope.observe(fanID: 0, celsius: .nan, systemRPM: 9_000)
        envelope.observe(fanID: 0, celsius: 60, systemRPM: 99_000)
        try require(envelope.floor(fanID: 0, celsius: 50).rpm == 0, "nothing below observations")
        try require(envelope.floor(fanID: 0, celsius: 56).rpm == 2_500, "observed level")
        try require(envelope.floor(fanID: 0, celsius: 75).rpm == 2_520, "monotone: hotter keeps the cooler maximum")
        try require(envelope.floor(fanID: 0, celsius: 71).informed, "informed near the hottest observation")
        try require(!envelope.floor(fanID: 0, celsius: 80).informed, "uninformed far above observations")
        try require(envelope.floor(fanID: 1, celsius: 60) == (0, false), "per fan")
    }

    static func reclaimGuardChecks() throws {
        var guardState = FanLayerReclaimGuard()
        let start: UInt64 = 5_000_000_000
        guardState.recordLoss(at: start)
        guardState.recordLoss(at: start + ticks(60))
        try require(!guardState.isLockedOut(at: start + ticks(61)), "two losses do not lock out")
        guardState.recordLoss(at: start + ticks(120))
        try require(guardState.isLockedOut(at: start + ticks(121)), "third loss in ten minutes locks out")
        try require(guardState.isLockedOut(at: start + ticks(700)), "lockout lasts")
        try require(!guardState.isLockedOut(at: start + ticks(120 + 601)), "lockout ends")
        var spread = FanLayerReclaimGuard()
        spread.recordLoss(at: start)
        spread.recordLoss(at: start + ticks(400))
        spread.recordLoss(at: start + ticks(800))
        try require(!spread.isLockedOut(at: start + ticks(801)), "old losses expire from the window")
        try require(spread.isLockedOut(at: start - 1) == false, "no lockout without three recent losses")
    }

    // MARK: Probe / tiers

    static func probeChecks() throws {
        let m4 = "Apple M4"
        let oneAccess = FanLayerKeyAccess(attributes: ["Ftst": 0xd0, "F0Md": 0xd0, "F0Tg": 0xd4])
        let experimental = try FanLayerProbe.evaluate(evidence: evidence(), cpuBrand: m4, access: oneAccess,
                                                      trustedThermalsAvailable: true)
        try require(experimental.tier == .experimental && experimental.fans.count == 1, "this Mac (26A434) is experimental")
        let validated = try FanLayerProbe.evaluate(evidence: evidence(build: "25G83"), cpuBrand: m4, access: oneAccess,
                                                   trustedThermalsAvailable: true)
        try require(validated.tier == .validated, "Mac16,1 / 25G83 is validated")

        func unsupported(_ name: String, evidence: FanOwnershipPreflightEvidence = evidence(), cpu: String = m4,
                         access: FanLayerKeyAccess? = oneAccess, thermals: Bool = true) throws {
            let profile = try FanLayerProbe.evaluate(evidence: evidence, cpuBrand: cpu, access: access,
                                                     trustedThermalsAvailable: thermals)
            try require(profile.tier == .unsupported && !profile.reasons.isEmpty && profile.fans.isEmpty,
                        "unsupported: \(name)")
        }
        func fan(id: Int = 0, key: String = "F0Md", mode: UInt8 = 3, type: String = "flt ",
                 min: Double = 2_317, max: Double = 6_550, actual: Double = 0) -> FanOwnershipPreflightFan {
            FanOwnershipPreflightFan(id: id, modeKey: key, mode: mode, actualRPM: actual, targetRPM: 0,
                                     minimumRPM: min, maximumRPM: max, targetType: type)
        }
        try unsupported("Intel", cpu: "Intel(R) Core(TM) i9")
        try unsupported("fanless", evidence: evidence(fans: []))
        try unsupported("Ftst already set", evidence: evidence(ftst: 1))
        try unsupported("fan in manual", evidence: evidence(fans: [fan(mode: 1)]))
        try unsupported("lowercase mode key", evidence: evidence(fans: [fan(key: "F0md")]))
        try unsupported("fpe2 target", evidence: evidence(fans: [fan(type: "fpe2")]))
        try unsupported("implausible limits", evidence: evidence(fans: [fan(min: 0, max: 6_550)]))
        try unsupported("tiny range", evidence: evidence(fans: [fan(min: 2_000, max: 2_200)]))
        try unsupported("absurd max", evidence: evidence(fans: [fan(max: 40_000)]))
        try unsupported("incomplete inventory", evidence: evidence(fanCount: 2))
        try unsupported("no key attributes", access: nil)
        try unsupported("read-only Ftst", access: FanLayerKeyAccess(attributes: ["Ftst": 0x80, "F0Md": 0xd0, "F0Tg": 0xd4]))
        try unsupported("read-only target", access: FanLayerKeyAccess(attributes: ["Ftst": 0xd0, "F0Md": 0xd0, "F0Tg": 0x84]))
        try unsupported("no thermal map (M3)", cpu: "Apple M3 Pro")
        try unsupported("thermals unreadable", thermals: false)
        try rejects("invalid identity") {
            _ = try FanLayerProbe.evaluate(evidence: evidence(model: ""), cpuBrand: m4, access: oneAccess,
                                           trustedThermalsAvailable: true)
        }
        try require(FanLayerProbe.accessKeys(fanCount: 2) == ["Ftst", "F0Md", "F0Tg", "F1Md", "F1Tg"], "access keys")

        // Surface drift.
        let drifted = try FanLayerProbe.evaluate(evidence: evidence(fans: [fan(max: 6_400)]), cpuBrand: m4,
                                                 access: oneAccess, trustedThermalsAvailable: true)
        try require(!FanLayerProbe.sameSurface(drifted, as: experimental), "limit drift detected")
        let otherBuild = try FanLayerProbe.evaluate(evidence: evidence(build: "26A999"), cpuBrand: m4,
                                                    access: oneAccess, trustedThermalsAvailable: true)
        try require(!FanLayerProbe.sameSurface(otherBuild, as: experimental), "build change detected")
        try require(FanLayerProbe.sameSurface(experimental, as: experimental), "same surface")
        let two = try twoFanProfile()
        try require(!FanLayerProbe.sameSurface(experimental, as: two), "fan count change detected")

        // The daemon trusts exactly the sensors the app trusts.
        let classifier = ThermalClassifier(cpuBrand: m4, machineModel: "Mac16,1", osBuild: "26A434")
        for key in FanLayerTrustedThermals.m4PerformanceCPU {
            try require(classifier.group(for: key) == .performanceCPU, "P key \(key) matches the app")
        }
        for key in FanLayerTrustedThermals.m4EfficiencyCPU {
            try require(classifier.group(for: key) == .efficiencyCPU, "E key \(key) matches the app")
        }
        for key in FanLayerTrustedThermals.m4GPU {
            try require(classifier.group(for: key) == .gpu, "GPU key \(key) matches the app")
        }
        try require(FanLayerTrustedThermals.groups(for: "Apple M5") == nil, "unknown chips have no map")
    }

    // MARK: Journal

    static func journalChecks() throws {
        let here = identity()
        let owned = FanOwnershipRecoveryRecord(generation: 7, phase: .owned, globalOwnershipMayBeActive: true, fanIDs: [0, 1])
        let data = try FanLayerJournalCodec.encode(owned, identity: here)
        try require(data.count == FanLayerJournalCodec.encodedSize, "fixed size")
        let decoded = try FanLayerJournalCodec.decode(data)
        try require(decoded.record == owned && decoded.identity == here, "round trip")
        var bytes = [UInt8](data)
        bytes[9] ^= 0xff
        try rejects("checksum") { _ = try FanLayerJournalCodec.decode(Data(bytes)) }
        bytes = [UInt8](data); bytes[0] = 0
        try rejects("magic") { _ = try FanLayerJournalCodec.decode(Data(bytes)) }
        bytes = [UInt8](data); bytes[60] = 1
        try rejects("tail") { _ = try FanLayerJournalCodec.decode(Data(bytes)) }
        try rejects("truncated") { _ = try FanLayerJournalCodec.decode(data.prefix(40)) }
        try rejects("v2 bytes") {
            _ = try FanLayerJournalCodec.decode(try FanOwnershipRecoveryCodec.encode(owned))
        }
        let inconsistent = FanOwnershipRecoveryRecord(generation: 1, phase: .owned, globalOwnershipMayBeActive: false, fanIDs: [0])
        try rejects("owned without global risk") {
            _ = try FanLayerJournalCodec.decode(try FanLayerJournalCodec.encode(inconsistent, identity: here))
        }
        try rejects("identity too long") { _ = try FanLayerMachineIdentity(modelIdentifier: "Mac16,1-way-too-long", osBuild: "1") }
        try rejects("identity with space") { _ = try FanLayerMachineIdentity(modelIdentifier: "Mac 16", osBuild: "1") }

        // Disposition after an update / on another Mac.
        try require(FanLayerRecoveryDisposition.evaluate(record: .clean, origin: here, current: here) == .clean, "clean")
        try require(FanLayerRecoveryDisposition.evaluate(record: owned, origin: here, current: here) == .recover(crossBuild: false),
                    "same build recovers")
        try require(FanLayerRecoveryDisposition.evaluate(record: owned, origin: identity("Mac16,1", "25G83"), current: here)
                    == .recover(crossBuild: true), "macOS update still recovers")
        try require(FanLayerRecoveryDisposition.evaluate(record: owned, origin: nil, current: here) == .recover(crossBuild: true),
                    "legacy v2 record recovers")
        try require(FanLayerRecoveryDisposition.evaluate(record: owned, origin: identity("Mac15,3"), current: here) == .foreignModel,
                    "another model never authorizes writes")
    }

    static func bootstrapChecks() throws {
        let clock = TestClock()
        let here = identity()
        // Clean: hardware never constructed.
        let clean = MemoryLayerJournal(identity: here)
        var built = 0
        let result = try FanLayerRecoveryBootstrap.recover(journal: clean, current: here, makeHardware: {
            built += 1; return SimLayerHardware()
        }, now: { clock.now }, pause: { clock.advance(0.1) })
        try require(result == .clean && built == 0, "clean journal opens no writer")

        // Dirty after a crash on an older build: recovered with Ftst=0 / Md=0 only.
        let crashed = MemoryLayerJournal(identity: identity("Mac16,1", "25G83"))
        try crashed.save(FanOwnershipRecoveryRecord(generation: 3, phase: .owned, globalOwnershipMayBeActive: true, fanIDs: [0]))
        let hardware = SimLayerHardware()
        hardware.ftst = 1
        hardware.modes = [0: 1]
        hardware.targets = [0: 3_000]
        let recovered = try FanLayerRecoveryBootstrap.recover(journal: crashed, current: here, makeHardware: { hardware },
                                                              now: { clock.now }, pause: { clock.advance(0.1) })
        try require(recovered == .recover(crossBuild: true), "cross-build recovery ran")
        try require(crashed.record.isClean && hardware.ftst == 0 && hardware.modes[0] == 3, "recovered to System")
        try require(hardware.writes.allSatisfy { $0 == "write F0Md=0" || $0 == "write Ftst=0" },
                    "recovery wrote only F0Md=0 / Ftst=0: \(hardware.writes)")

        // Another model: quarantined, never touches hardware.
        let foreign = MemoryLayerJournal(identity: identity("Mac15,3", "25G83"))
        try foreign.save(FanOwnershipRecoveryRecord(generation: 3, phase: .owned, globalOwnershipMayBeActive: true, fanIDs: [0]))
        built = 0
        let foreignResult = try FanLayerRecoveryBootstrap.recover(journal: foreign, current: here, makeHardware: {
            built += 1; return SimLayerHardware()
        }, now: { clock.now }, pause: { clock.advance(0.1) })
        try require(foreignResult == .foreignModel && foreign.quarantined && built == 0, "foreign journal set aside, no writes")

        // Ftst stuck at 1: recovery fails and keeps the risk.
        let stuck = MemoryLayerJournal(identity: here)
        try stuck.save(FanOwnershipRecoveryRecord(generation: 1, phase: .owned, globalOwnershipMayBeActive: true, fanIDs: [0]))
        let stuckHardware = SimLayerHardware()
        stuckHardware.ftst = 1
        stuckHardware.modes = [0: 1]
        stuckHardware.stuckFtst = true
        try rejects("stuck Ftst") {
            _ = try FanLayerRecoveryBootstrap.recover(journal: stuck, current: here, makeHardware: { stuckHardware },
                                                      now: { clock.now }, pause: { clock.advance(0.1) })
        }
        try require(stuck.record.needsRecovery && stuck.record.globalOwnershipMayBeActive, "unconfirmed release keeps evidence")
    }

    // MARK: Engine

    static func engineChecks() throws {
        // macOS already cools more: no takeover, no writes.
        do {
            let rig = try Rig()
            rig.hardware.targets = [0: 3_000, 1: 3_000]
            rig.hardware.actuals = [0: 3_000, 1: 3_000]
            try rig.apply(.override, 2_500)
            try require(rig.engine.state == .system && rig.hardware.writes.isEmpty && rig.journal.record.isClean,
                        "no takeover below macOS")
            try require(rig.engine.statusDetail?.contains("already cooling") == true, "explains why")
        }
        // Takeover from a stopped fan: targets ≥ request and ≥ minimum, journal owned.
        // (Full maximum unlocked: this sequence checks the floors themselves.)
        let rig = try Rig(fullMaximum: true)
        try rig.apply(.override, 3_000)
        try require(rig.engine.state == .override && rig.journal.record.phase == .owned, "owned after takeover")
        try require(rig.hardware.ftst == 1 && rig.hardware.modes[0] == 1 && rig.hardware.modes[1] == 1, "both fans manual")
        try require(rig.hardware.targets[0] == 3_000 && rig.hardware.targets[1] == 3_000, "request applied")
        try require(rig.hardware.writes.first == "write Ftst=1", "Ftst first (after durable intent)")
        // Same target: verify only.
        let before = rig.hardware.writes.count
        rig.clock.advance(0.5)
        try rig.apply(.override, 3_000)
        try require(rig.hardware.writes.count == before, "steady state is write-free")
        // Heat: the safety floor raises immediately above the request.
        rig.thermals.celsius = 84
        rig.clock.advance(0.5)
        try rig.apply(.override, 3_000)
        let hot = rig.hardware.targets[0] ?? 0
        try require(hot >= FanLayerFanLimits(id: 0, minimumRPM: 2_317, maximumRPM: 6_550)
                        .rpm(fraction: FanLayerSafetyCurve.fraction(at: 84)) - 1, "safety floor applied (\(hot))")
        // The app can only raise the temperature, never lower it.
        rig.clock.advance(0.5)
        try rig.apply(.override, 3_000, app: 20)
        try require((rig.hardware.targets[0] ?? 0) >= hot - 1, "app temperature cannot lower the floor")
        // Cooling down: falls are slow (one hold, then the Response fall rate).
        let smoothing = FanLayerResponse.balanced.smoothing
        rig.thermals.celsius = 55
        rig.clock.advance(0.5)
        try rig.apply(.override, 3_000)
        try require(rig.hardware.targets[0] == hot, "dwell holds the level after heat")
        rig.clock.advance(smoothing.minimumDwellSeconds + 1)
        try rig.apply(.override, 3_000)
        let falling = rig.hardware.targets[0] ?? 0
        try require(abs(falling - (hot - smoothing.fallRPMPerSecond)) <= 2, "slow fall (\(hot) → \(falling))")
        // With the full maximum unlocked, emergency forces the factory maximum.
        rig.thermals.celsius = 96
        rig.clock.advance(0.5)
        try rig.apply(.override, 2_400)
        try require(rig.hardware.targets[0] == 6_550 && rig.hardware.targets[1] == 6_000, "unlocked emergency maximum")
        try rig.engine.restore()
        try require(rig.engine.state == .system && rig.journal.record.isClean && rig.hardware.ftst == 0, "verified release")
        try require(rig.hardware.modes.values.allSatisfy { $0 == 3 }, "fans back to macOS")

        // Under the 90 % limit an emergency hands the fans back to macOS.
        let locked = try Rig()
        try locked.apply(.override, 3_000)
        try require(locked.engine.state == .override, "locked rig holds at a normal temperature")
        locked.thermals.celsius = 96
        locked.clock.advance(0.5)
        try locked.apply(.override, 2_400)
        try require(locked.engine.state == .system && locked.journal.record.isClean && locked.hardware.ftst == 0
                    && locked.hardware.modes.values.allSatisfy { $0 == 3 }, "emergency under the limit returns to macOS")
        try require(locked.engine.statusDetail?.hasPrefix(FanLayerCeiling.handbackPrefix) == true, "handback explained")
        // ... and it does not take the fans again while that hot.
        locked.clock.advance(0.5)
        let writesBefore = locked.hardware.writes.count
        try locked.apply(.override, 2_400)
        try require(locked.engine.state == .system && locked.hardware.writes.count == writesBefore, "no takeover while hot")

        // Emergency takeover even when the request is below macOS (unlocked only).
        let hotRig = try Rig(fullMaximum: true)
        hotRig.thermals.celsius = 97
        hotRig.hardware.targets = [0: 5_000, 1: 5_000]
        try hotRig.apply(.override, 0)
        try require(hotRig.engine.state == .override && hotRig.hardware.targets[0] == 6_550, "emergency takes over")
        try hotRig.engine.restore()
        let lockedHot = try Rig()
        lockedHot.thermals.celsius = 97
        try lockedHot.apply(.override, 0)
        try require(lockedHot.engine.state == .system && lockedHot.hardware.writes.isEmpty, "locked emergency stays on macOS")
        // Close to the boundary Helios does not take the fans (3 °C headroom).
        let edge = try Rig()
        edge.thermals.celsius = 85
        try edge.apply(.override, 3_000)
        try require(edge.engine.state == .system && edge.hardware.writes.isEmpty, "no takeover just below a handback")

        // Boost is the user's limit; unlocked it is the factory maximum.
        let boost = try Rig()
        try boost.apply(.boost, 0)
        try require(boost.engine.state == .boost && boost.hardware.targets[0] == 5_895
                    && boost.hardware.targets[1] == 5_400, "Boost is 90 % (\(boost.hardware.targets))")
        try boost.engine.restore()
        let fullBoost = try Rig(fullMaximum: true)
        try fullBoost.apply(.boost, 0)
        try require(fullBoost.hardware.targets[0] == 6_550, "unlocked Boost is the maximum")
        // Locking again while holding: the next calculation stays within the limit.
        fullBoost.fullMaximum.value = false
        fullBoost.clock.advance(0.5)
        try fullBoost.apply(.boost, 0)
        try require((fullBoost.hardware.targets[0] ?? .infinity) <= 5_895, "a new limit applies while holding")
        try fullBoost.engine.restore()
        // Manual above the limit is clamped; the app cannot exceed it.
        let manual = try Rig()
        try manual.apply(.override, 9_000)
        try require(manual.hardware.targets[0] == 5_895 && manual.hardware.targets[1] == 5_400, "Manual clamped to the limit")
        try manual.engine.restore()

        // Envelope: learned macOS level is a floor.
        let learned = try Rig()
        learned.observer.observe(fanID: 0, celsius: 58, systemRPM: 3_400)
        learned.thermals.celsius = 60
        try learned.apply(.override, 2_400)
        try require((learned.hardware.targets[0] ?? 0) >= 3_400, "learned macOS level respected")
        try learned.engine.restore()
    }

    static func engineFailureMatrix() throws {
        // macOS reclaims the fans while Helios holds them.
        do {
            let rig = try Rig()
            try rig.apply(.override, 3_000)
            rig.hardware.reclaimByMacOS()
            rig.clock.advance(0.5)
            do { try rig.apply(.override, 3_000); throw Failure.check("reclaim not detected") }
            catch let error as FanLayerEngineError { try require(error == .ownershipLost, "ownership loss reported") }
            try require(rig.journal.record.needsRecovery, "loss keeps recovery evidence")
            try rig.engine.restore()
            try require(rig.journal.record.isClean && rig.hardware.ftst == 0, "restored after reclaim")
        }
        // Stale/missing trusted thermals: refuse to act, then release cleanly.
        do {
            let rig = try Rig()
            try rig.apply(.override, 3_000)
            rig.thermals.celsius = nil
            try rejects("stale thermals") { try rig.apply(.override, 3_000) }
            try rig.engine.restore()
            try require(rig.journal.record.isClean && rig.engine.state == .system, "stale thermals end on System")
        }
        // Stale thermals before takeover: no writes at all.
        do {
            let rig = try Rig()
            rig.thermals.celsius = nil
            try rejects("no takeover without thermals") { try rig.apply(.override, 3_000) }
            try require(rig.hardware.writes.isEmpty && rig.journal.record.isClean, "no writes without thermals")
        }
        // Partial write failure on the second fan during takeover.
        do {
            let rig = try Rig()
            rig.hardware.failOn = "F1Tg"
            try rejects("partial takeover") { try rig.apply(.override, 3_000) }
            try require(rig.journal.record.needsRecovery && rig.journal.record.fanIDs.contains(1), "partial risk journaled")
            rig.hardware.failOn = nil
            try rig.engine.restore()
            try require(rig.journal.record.isClean && rig.hardware.ftst == 0
                        && rig.hardware.modes.values.allSatisfy { $0 == 3 }, "partial takeover rolled back")
        }
        // Cancellation right after Ftst=1 (lease revoked mid-acquisition).
        do {
            let rig = try Rig()
            var permits = 0
            try rejects("cancelled acquisition") {
                try rig.apply(.override, 3_000, permit: {
                    permits += 1
                    if rig.hardware.ftst == 1 { throw Failure.simulated("lease revoked") }
                })
            }
            try require(rig.journal.record.needsRecovery && rig.journal.record.globalOwnershipMayBeActive, "Ftst risk kept")
            try rig.engine.restore()
            try require(rig.journal.record.isClean && rig.hardware.ftst == 0, "cancelled takeover released")
        }
        // Crash after takeover: a fresh process recovers from the journal alone.
        do {
            let rig = try Rig()
            try rig.apply(.override, 3_000)
            let fresh = try FanLayerRecoveryBootstrap.recover(
                journal: rig.journal, current: identity("Mac16,6"), makeHardware: { rig.hardware },
                now: { rig.clock.now }, pause: { rig.clock.advance(0.1) })
            try require(fresh == .recover(crossBuild: false), "fresh process recovers")
            try require(rig.journal.record.isClean && rig.hardware.ftst == 0
                        && rig.hardware.modes.values.allSatisfy { $0 == 3 }, "crash recovery restores System")
        }
        // Another controller holds Ftst at start: refuse without journaling risk.
        do {
            let rig = try Rig()
            rig.hardware.ftst = 1
            try rejects("foreign Ftst") { try rig.apply(.override, 3_000) }
            try require(rig.journal.record.isClean && rig.hardware.writes.isEmpty && rig.hardware.ftst == 1,
                        "never clears a flag Helios did not set")
        }
        // Surface changed (fan count / limits) since the helper started.
        do {
            let rig = try Rig()
            rig.hardware.surfaceDrift = true
            try rejects("surface drift") { try rig.apply(.override, 3_000) }
            try require(rig.journal.record.isClean && rig.hardware.writes.isEmpty, "drift refuses before any write")
        }
        // Release cannot be confirmed (Ftst stuck): recoveryRequired, evidence kept.
        do {
            let rig = try Rig()
            try rig.apply(.override, 3_000)
            rig.hardware.stuckFtst = true
            try rejects("stuck release") { try rig.engine.restore() }
            try require(rig.engine.state == .recoveryRequired && rig.journal.record.globalOwnershipMayBeActive,
                        "unconfirmed release keeps evidence")
            try rejects("no new takeover while recovery is pending") { try rig.apply(.override, 3_000) }
            rig.hardware.stuckFtst = false
            try rig.engine.restore()
            try require(rig.journal.record.isClean, "retry completes the release")
        }
        // Journal cannot be written: no hardware write happens.
        do {
            let rig = try Rig()
            rig.journal.failSaves = true
            try rejects("journal failure") { try rig.apply(.override, 3_000) }
            try require(rig.hardware.writes.isEmpty, "no write without durable intent")
        }
        // Firmware refuses manual mode until the deadline: rolled back.
        do {
            let rig = try Rig()
            rig.hardware.failOn = "F0Md=1"
            try rejects("manual refused") { try rig.apply(.override, 3_000) }
            rig.hardware.failOn = nil
            try rig.engine.restore()
            try require(rig.journal.record.isClean && rig.hardware.ftst == 0, "refused manual rolled back")
        }
    }

    // MARK: Coordinator

    private final class LossEngine: FanControlDriving, @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var responses: [FanLayerResponse] = []
        var state: HeliosFanState { .system }
        func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
            throw Failure.check("context path expected")
        }
        func apply(mode: HeliosFanMode, rpm: Double, context: FanControlContext, permit: () throws -> Void) throws {
            lock.withLock { calls += 1; responses.append(context.response) }
            throw FanLayerEngineError.ownershipLost
        }
        func restore() throws {}
    }

    static func coordinatorChecks() async throws {
        let engine = LossEngine()
        let controller = FanControlCoordinator(validationMessage: nil, makeEngine: { engine }, wakeSafetyCheck: {},
                                               emergencyMaximumCelsius: 95)
        let owner = UUID()
        controller.bind(owner)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            let ready = await withCheckedContinuation { continuation in
                controller.status { ready, _, _ in continuation.resume(returning: ready) }
            }
            if ready { break }
            guard ContinuousClock.now < deadline else { throw Failure.check("coordinator not ready") }
            try await Task.sleep(for: .milliseconds(10))
        }
        func calculate(_ sequence: UInt64) async -> (HeliosReplyCode, String) {
            await withCheckedContinuation { continuation in
                controller.calculate(owner: owner, sequence: sequence, sample: HostClock.now, mode: .override, rpm: 3_000,
                                     temperature: 60, response: .gently) { code, _, detail in
                    continuation.resume(returning: (code, detail))
                }
            }
        }
        for sequence in 1...3 {
            let (code, _) = await calculate(UInt64(sequence))
            try require(code == .hardwareFailure, "loss \(sequence) reported as a recovered failure")
            try await Task.sleep(for: .milliseconds(20))
        }
        let (locked, detail) = await calculate(4)
        try require(locked == .controlUnavailable && detail.contains("took back"), "lockout after three reclaims: \(detail)")
        try require(engine.lock.withLock { engine.calls } == 3, "locked out without touching hardware")
        try require(engine.lock.withLock { engine.responses.allSatisfy { $0 == .gently } }, "Response reaches the engine")

        // Boost hard cap: after the cap the helper returns to System by itself.
        final class BoostEngine: FanControlDriving, @unchecked Sendable {
            let lock = NSLock()
            var current = HeliosFanState.system
            var restores = 0
            var state: HeliosFanState { lock.withLock { current } }
            func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
                try permit()
                lock.withLock { current = mode == .boost ? .boost : .override }
            }
            func restore() throws { lock.withLock { current = .system; restores += 1 } }
        }
        let boostEngine = BoostEngine()
        let capped = FanControlCoordinator(validationMessage: nil, makeEngine: { boostEngine }, wakeSafetyCheck: {},
                                           emergencyMaximumCelsius: 95, boostCapSeconds: 0.3)
        capped.bind(owner)
        try await Task.sleep(for: .milliseconds(200))
        func boost(_ sequence: UInt64) async -> (HeliosReplyCode, HeliosFanState) {
            await withCheckedContinuation { continuation in
                capped.calculate(owner: owner, sequence: sequence, sample: HostClock.now, mode: .boost, rpm: 0,
                                 temperature: 60) { code, state, _ in continuation.resume(returning: (code, state)) }
            }
        }
        let first = await boost(1)
        try require(first == (.ok, .boost), "Boost starts")
        try await Task.sleep(for: .milliseconds(150))
        try require(await boost(2) == (.ok, .boost), "Boost holds before the cap")
        try await Task.sleep(for: .milliseconds(250))
        let ended = await boost(3)
        try require(ended.0 == .controlUnavailable && ended.1 == .system, "Boost ends at the hard cap")
        try require(boostEngine.lock.withLock { boostEngine.restores } >= 1, "cap restored System")

        try await reacquireCooldownChecks(owner: owner)
    }

    /// After a verified release the helper waits before it
    /// takes the fans again, with a calm reply, no write and no lease; emergency
    /// cooling never waits.
    static func reacquireCooldownChecks(owner: UUID) async throws {
        var pure = FanLayerReacquireCooldown(seconds: 15)
        let start: UInt64 = 5_000_000_000
        try require(pure.remaining(at: start) == nil, "no wait before any release")
        pure.recordRelease(at: start)
        try require(abs((pure.remaining(at: start + ticks(5)) ?? 0) - 10) < 0.01, "waits the rest of the cooldown")
        try require(pure.remaining(at: start + ticks(15.1)) == nil, "cooldown ends")
        try require(pure.remaining(at: start - 1) == 15, "clock regression waits the full time")
        var off = FanLayerReacquireCooldown(seconds: 0)
        off.recordRelease(at: start)
        try require(off.remaining(at: start) == nil, "0 disables the cooldown")
        try require(FanLayerReacquireCooldown(seconds: .nan).seconds == FanLayerReacquireCooldown.defaultSeconds
                    && FanLayerReacquireCooldown(seconds: 1_000).seconds == 60, "cooldown is bounded")
        try require(FanLayerReacquireCooldown.reply(remaining: 9.2).hasPrefix(FanLayerReacquireCooldown.replyPrefix),
                    "reply carries the calm prefix")
        // Repeated refusals back off (15, 30, 60 … ≤ 300 s); a held takeover resets.
        var backoff = FanLayerReacquireCooldown(seconds: 15)
        for expected in [30.0, 60, 120, 240, 300, 300] {
            backoff.recordRelease(at: start, refused: true)
            try require(backoff.currentSeconds == expected, "refusal backoff \(expected) (\(backoff.currentSeconds))")
        }
        backoff.recordHeld()
        backoff.recordRelease(at: start)
        try require(backoff.currentSeconds == 15 && abs((backoff.remaining(at: start + ticks(5)) ?? 0) - 10) < 0.01,
                    "a held takeover resets the backoff")

        final class CountingEngine: FanControlDriving, @unchecked Sendable {
            let lock = NSLock()
            var current = HeliosFanState.system
            var applies = 0
            var state: HeliosFanState { lock.withLock { current } }
            func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
                try permit()
                lock.withLock { applies += 1; current = mode == .boost ? .boost : .override }
            }
            func restore() throws { lock.withLock { current = .system } }
        }
        let engine = CountingEngine()
        let controller = FanControlCoordinator(validationMessage: nil, makeEngine: { engine }, wakeSafetyCheck: {},
                                               emergencyMaximumCelsius: 95, reacquireCooldownSeconds: 0.6)
        controller.bind(owner)
        try await Task.sleep(for: .milliseconds(200))
        var sequence: UInt64 = 0
        func manual(_ celsius: Double = 60) async -> (HeliosReplyCode, HeliosFanState, String) {
            sequence += 1
            let next = sequence
            return await withCheckedContinuation { continuation in
                controller.calculate(owner: owner, sequence: next, sample: HostClock.now, mode: .override, rpm: 3_000,
                                     temperature: celsius) { code, state, detail in
                    continuation.resume(returning: (code, state, detail))
                }
            }
        }
        func release() async {
            await withCheckedContinuation { continuation in
                controller.release(owner: owner, graceful: false) { _, _ in continuation.resume() }
            }
        }
        let first = await manual()
        try require(first.0 == .ok && first.1 == .override, "first takeover")
        // Same-ownership updates never wait.
        try require(await manual().1 == .override, "updates while owned do not wait")
        await release()
        let waiting = await manual()
        try require(waiting.0 == .ok && waiting.1 == .system && waiting.2.hasPrefix(FanLayerReacquireCooldown.replyPrefix),
                    "takeover right after a release waits calmly: \(waiting)")
        try require(engine.lock.withLock { engine.applies } == 2, "waiting does not touch the hardware")
        let emergency = await manual(96)
        try require(emergency.0 == .ok && emergency.1 != .system, "emergency cooling never waits")
        await release()
        try await Task.sleep(for: .milliseconds(700))
        let after = await manual()
        try require(after.0 == .ok && after.1 == .override, "takeover after the cooldown proceeds")
        await release()

        // Without a cooldown (tests, legacy path) a takeover proceeds at once.
        let inert = FanControlCoordinator(validationMessage: nil, makeEngine: { engine }, wakeSafetyCheck: {})
        inert.bind(owner)
        try await Task.sleep(for: .milliseconds(200))
        for step in 1...2 {
            let reply = await withCheckedContinuation { continuation in
                inert.calculate(owner: owner, sequence: UInt64(step), sample: HostClock.now, mode: .override, rpm: 3_000,
                                temperature: 60) { code, state, _ in continuation.resume(returning: (code, state)) }
            }
            try require(reply == (.ok, .override), "inert coordinator takes over immediately (\(step))")
            await withCheckedContinuation { continuation in
                inert.release(owner: owner, graceful: false) { _, _ in continuation.resume() }
            }
        }
    }
}
