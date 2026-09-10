import Darwin
import Foundation

private enum CheckFailure: Error { case failed(String), simulated }

private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw CheckFailure.failed(message) }
}

private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw CheckFailure.failed("Expected operation to fail")
}

private func ticks(_ seconds: Double) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return UInt64(seconds * 1_000_000_000 * Double(info.denom) / Double(info.numer))
}

private final class MemoryJournal: FanOwnershipRecoveryJournal {
    var record: FanOwnershipRecoveryRecord
    var saves: [FanOwnershipRecoveryRecord] = []

    init(_ record: FanOwnershipRecoveryRecord = .clean) { self.record = record }

    func load() throws -> FanOwnershipRecoveryRecord { record }

    func save(_ next: FanOwnershipRecoveryRecord) throws {
        record = next
        saves.append(next)
    }
}

private final class ClockBox {
    var now = HostClock.now
    func advance(_ seconds: Double) { now &+= ticks(seconds) }
}

private final class PreflightFixtureTransport: SMCReadTransport {
    struct Value {
        let type: String
        let bytes: [UInt8]
    }

    let values: [String: Value]
    init(values: [String: Value]) { self.values = values }

    func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
        guard let value = values[request.key] else { throw TelemetryError.smc(request.key, 0x84) }
        var reply = [UInt8](repeating: 0, count: SMCCodec.frameSize)
        func put(_ value: UInt32, at offset: Int) {
            for n in 0..<4 { reply[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
        }
        switch request.command {
        case .keyInfo:
            put(UInt32(value.bytes.count), at: 28)
            put(try SMCCodec.fourCC(value.type), at: 32)
        case .bytes:
            guard request.dataSize == value.bytes.count else { throw CheckFailure.simulated }
            reply.replaceSubrange(48..<(48 + value.bytes.count), with: value.bytes)
        case .keyAtIndex:
            throw CheckFailure.simulated
        }
        return reply
    }
}

private func floatBytes(_ value: Float) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
}

private final class LifecycleHardware: FanOwnershipAcquisitionHardware, FanOwnershipRecoveryHardware {
    var globalReads: [UInt8]
    var globalReadIndex = 0
    var events: [String] = []
    var targets: [Int: Double] = [:]
    var manual: Set<Int> = []
    var baselineFailure = false
    var manualRejectAttemptsRemaining = 0
    var manualAttempts = 0
    var ownedVerificationResults: [Bool] = []
    private var ownedVerificationIndex = 0

    init(globalReads: [UInt8]) { self.globalReads = globalReads }

    func validateGlobalAcquisitionBaseline() throws {
        events.append("baseline")
        if baselineFailure { throw CheckFailure.simulated }
    }
    func requestGlobalAcquisition() throws { events.append("global acquire") }
    func requestGlobalRelease() throws { events.append("global release") }

    func readGlobalOwnership() throws -> UInt8 {
        guard !globalReads.isEmpty else { throw CheckFailure.simulated }
        let index = min(globalReadIndex, globalReads.count - 1)
        globalReadIndex += 1
        events.append("global read \(globalReads[index])")
        return globalReads[index]
    }

    func readFanMode(_ id: Int) throws -> UInt8 { manual.contains(id) ? 1 : 3 }

    func requestFanManual(_ id: Int) throws {
        events.append("manual \(id)")
        manualAttempts += 1
        if manualRejectAttemptsRemaining > 0 {
            manualRejectAttemptsRemaining -= 1
            return
        }
        manual.insert(id)
    }

    func setFanTarget(_ id: Int, rpm: Double) throws {
        events.append("target \(id) \(Int(rpm))")
        targets[id] = rpm
    }

    func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool {
        events.append("verify owned \(id) \(Int(targetRPM))")
        if !ownedVerificationResults.isEmpty {
            let index = min(ownedVerificationIndex, ownedVerificationResults.count - 1)
            ownedVerificationIndex += 1
            return ownedVerificationResults[index]
        }
        return manual.contains(id) && targets[id] == targetRPM
    }

    func restoreFanToSystem(_ id: Int) throws {
        events.append("restore \(id)")
        manual.remove(id)
        targets[id] = 0
    }

    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        events.append("verify system \(id)")
        return !manual.contains(id) && targets[id] == 0
    }
}

@main
private enum OwnershipChecks {
    static func main() {
        do {
            try delayedTransitionCheck()
            try delayedFanTargetVerificationCheck()
            try manualArbitrationRetryCheck()
            try acquisitionLeaseCheck()
            try externalBaselineRejectionCheck()
            try lifecycleCheck()
            try restartRecoveryCheck()
            try daemonBootstrapCheck()
            try wakeSafetyVerifierCheck()
            try failClosedUpdateCheck()
            try preflightCheck()
            try preflightReaderCheck()
            try productionFanControlProfileCheck()
            print("PASS Phase 4.4 lifecycle, restart/bootstrap/wake recovery, paced manual arbitration, acquisition lease, and Phase 4.6 production Boost/Override gate")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func delayedTransitionCheck() throws {
        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 1.5, requiredStableReads: 2)
        var tracker = try FanOwnershipTransitionTracker(expected: 1, startedAt: ticks(100), policy: policy)
        try require(!(try tracker.observe(0, at: ticks(100.1))), "Old Ftst state incorrectly completed acquisition")
        try require(!(try tracker.observe(1, at: ticks(100.2))), "One matching read incorrectly completed acquisition")
        try require(try tracker.observe(1, at: ticks(100.3)), "Stable delayed readback did not complete acquisition")
    }

    private static func delayedFanTargetVerificationCheck() throws {
        let journal = MemoryJournal()
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let hardware = LifecycleHardware(globalReads: [0, 1, 1])
        hardware.ownedVerificationResults = [false, false, true, true]
        let clock = ClockBox()
        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 2, requiredStableReads: 2)
        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: machine,
            hardware: hardware,
            transitionPolicy: policy,
            now: { clock.now },
            pause: { clock.advance(0.2) },
            permit: {}
        )
        try acquire.acquire(targets: [0: 3_000])
        let verificationEvents = hardware.events.filter { $0.hasPrefix("verify owned") }
        try require(verificationEvents.count == 4, "Delayed F0Tg visibility did not require stable consecutive ownership readback")
        try require(machine.record.phase == .owned, "Delayed target readback did not eventually reach durable owned state")
    }

    private static func manualArbitrationRetryCheck() throws {
        let journal = MemoryJournal()
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let hardware = LifecycleHardware(globalReads: [1, 1])
        hardware.manualRejectAttemptsRemaining = 5
        let clock = ClockBox()
        var permits = 0
        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 8.0, requiredStableReads: 2)
        let started = clock.now
        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: machine,
            hardware: hardware,
            transitionPolicy: policy,
            now: { clock.now },
            pause: { clock.advance(0.1) },
            permit: { permits += 1 },
            manualRetryIntervalSeconds: 1.0,
            manualTimeoutSeconds: 8.0
        )
        try acquire.acquire(targets: [0: 3_000])
        try require(hardware.manualAttempts == 6, "Manual arbitration did not retry the five simulated protected-mode rejections")
        try require(HostClock.seconds(from: started, to: clock.now) >= 5.0,
                    "Manual arbitration retried faster than the validated one-second cadence")
        try require(permits > hardware.manualAttempts, "Manual retry loop did not re-check the control permit around write attempts")
        try require(machine.record.phase == .owned, "Bounded manual arbitration did not reach durable owned state")
    }

    private static func acquisitionLeaseCheck() throws {
        let lease = ControlLease()
        let owner = UUID()
        let sample = ticks(100.0)
        let token = try lease.accept(owner: owner, sequence: 1, sample: sample, now: ticks(101.0))
        try lease.beginAcquisition(token, now: ticks(101.1))

        // The ordinary 5-second freshness window may elapse while firmware
        // arbitration is still in progress, but the separately bounded
        // acquisition permit must remain valid until its 12-second deadline.
        try lease.checkAcquisition(token, now: ticks(111.0))
        try require(!lease.expire(now: ticks(111.0)), "Watchdog expired a valid bounded acquisition too early")
        try rejects { try lease.checkAcquisition(token, now: ticks(113.2)) }

        let lease2 = ControlLease()
        let token2 = try lease2.accept(owner: owner, sequence: 2, sample: ticks(200.0), now: ticks(200.5))
        try lease2.beginAcquisition(token2, now: ticks(200.6))
        try lease2.completeAcquisition(token2, now: ticks(207.0))
        try lease2.check(token2, now: ticks(211.9))
        try rejects { try lease2.check(token2, now: ticks(212.1)) }

        // Completing acquisition must not erase replay history.
        try rejects {
            _ = try lease2.accept(owner: owner, sequence: 2, sample: ticks(200.0), now: ticks(207.1))
        }
    }

    private static func externalBaselineRejectionCheck() throws {
        let journal = MemoryJournal()
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let hardware = LifecycleHardware(globalReads: [1])
        hardware.baselineFailure = true
        let clock = ClockBox()
        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: machine,
            hardware: hardware,
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 1, requiredStableReads: 2),
            now: { clock.now },
            pause: { clock.advance(0.1) },
            permit: {}
        )
        try rejects { try acquire.acquire(targets: [0: 3_000]) }
        try require(machine.record.isClean, "Read-only external-controller rejection created Helios recovery risk")
        try require(hardware.events == ["baseline"], "Baseline rejection touched acquisition hardware or journaled ownership")
    }

    private static func lifecycleCheck() throws {
        let journal = MemoryJournal()
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let hardware = LifecycleHardware(globalReads: [0, 1, 1])
        let clock = ClockBox()
        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 2, requiredStableReads: 2)

        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: machine,
            hardware: hardware,
            transitionPolicy: policy,
            now: { clock.now },
            pause: { clock.advance(0.2) },
            permit: {}
        )
        try acquire.acquire(targets: [0: 3_000])
        try require(machine.record.phase == .owned && machine.record.fanIDs == [0], "Acquisition did not reach durable owned state")

        let updates = FanOwnershipTargetUpdateExecutor(stateMachine: machine, hardware: hardware, permit: {})
        let journalSaveCountBeforeUpdate = journal.saves.count
        try updates.update(targets: [0: 3_400])
        try require(hardware.targets[0] == 3_400, "Owned target update was not applied")
        try require(machine.record.phase == .owned, "Successful target update changed ownership phase")
        try require(journal.saves.count == journalSaveCountBeforeUpdate, "Target-only update rewrote ownership intent")

        hardware.globalReads = [1, 0, 0]
        hardware.globalReadIndex = 0
        let release = FanOwnershipRecoveryExecutor(
            stateMachine: machine,
            hardware: hardware,
            transitionPolicy: policy,
            now: { clock.now },
            pause: { clock.advance(0.2) },
            permit: {}
        )
        try release.recover()
        try require(machine.record.isClean, "Release did not return to a clean System record")
        try require(!hardware.manual.contains(0) && hardware.targets[0] == 0, "Release did not restore the fan")
    }

    private static func restartRecoveryCheck() throws {
        let journal = MemoryJournal()
        let firstMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let acquisitionHardware = LifecycleHardware(globalReads: [0, 1, 1])
        let clock = ClockBox()
        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 2, requiredStableReads: 2)
        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: firstMachine,
            hardware: acquisitionHardware,
            transitionPolicy: policy,
            now: { clock.now },
            pause: { clock.advance(0.2) },
            permit: {}
        )
        try acquire.acquire(targets: [0: 3_000])
        try require(journal.record.phase == .owned && journal.record.fanIDs == [0],
                    "Crash fixture did not persist owned state before simulated death")

        // Simulate a fresh process: reconstruct both the state machine and the
        // hardware facade from only persisted journal + externally visible state.
        let restartedMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let restartedHardware = LifecycleHardware(globalReads: [1, 0, 0])
        restartedHardware.manual = [0]
        restartedHardware.targets[0] = 3_000
        let recover = FanOwnershipRecoveryExecutor(
            stateMachine: restartedMachine,
            hardware: restartedHardware,
            transitionPolicy: policy,
            now: { clock.now },
            pause: { clock.advance(0.2) },
            permit: {}
        )
        try recover.recover()
        try require(journal.record.isClean, "Fresh-process recovery did not clear durable ownership after verification")
        try require(!restartedHardware.manual.contains(0), "Fresh-process recovery left simulated manual ownership active")
    }

    private static func daemonBootstrapCheck() throws {
        let cleanJournal = MemoryJournal()
        var cleanHardwareFactoryCalls = 0
        let cleanBootstrap = FanRecoveryBootstrap(
            journal: cleanJournal,
            makeHardware: {
                cleanHardwareFactoryCalls += 1
                return LifecycleHardware(globalReads: [0])
            },
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 2, requiredStableReads: 2),
            now: { HostClock.now },
            pause: {}
        )
        try require(try cleanBootstrap.run() == .clean, "Clean daemon bootstrap did not stay clean")
        try require(cleanHardwareFactoryCalls == 0, "Clean daemon bootstrap opened recovery hardware")

        let dirty = FanOwnershipRecoveryRecord(
            generation: 11,
            phase: .owned,
            globalOwnershipMayBeActive: true,
            fanIDs: [0]
        )
        let dirtyJournal = MemoryJournal(dirty)
        let hardware = LifecycleHardware(globalReads: [1, 0, 0])
        hardware.manual = [0]
        hardware.targets[0] = 3_000
        let clock = ClockBox()
        var dirtyHardwareFactoryCalls = 0
        let dirtyBootstrap = FanRecoveryBootstrap(
            journal: dirtyJournal,
            makeHardware: {
                dirtyHardwareFactoryCalls += 1
                return hardware
            },
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 2, requiredStableReads: 2),
            now: { clock.now },
            pause: { clock.advance(0.2) }
        )
        try require(try dirtyBootstrap.run() == .recovered, "Dirty daemon bootstrap did not report recovery")
        try require(dirtyHardwareFactoryCalls == 1, "Dirty daemon bootstrap did not open exactly one recovery backend")
        try require(dirtyJournal.record.isClean, "Dirty daemon bootstrap did not clear the journal after verified recovery")
        try require(!hardware.manual.contains(0), "Dirty daemon bootstrap left the fan in simulated manual mode")
    }

    private static func wakeSafetyVerifierCheck() throws {
        let fan = FanOwnershipPreflightFan(
            id: 0, modeKey: "F0Md", mode: 0, actualRPM: 2317, targetRPM: 2317,
            minimumRPM: 2317, maximumRPM: 6550, targetType: "flt "
        )
        let readyEvidence = FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [fan]
        )
        let ready = FanOwnershipPreflightEvaluator.evaluate(readyEvidence)
        var events: [String] = []
        let wakeClock = ClockBox()
        let verifier = FanWakeSafetyVerifier(
            recover: { events.append("recover"); return .clean },
            readPreflight: { events.append("fresh preflight"); return ready },
            timeoutSeconds: 2.0,
            now: { wakeClock.now },
            pause: { wakeClock.advance(0.1) }
        )
        try require(try verifier.run() == .clean, "Clean wake verifier did not stay clean")
        try require(events == ["recover", "fresh preflight"], "Wake verifier did not recover before opening a fresh preflight")

        let delayedClock = ClockBox()
        var delayedAttempts = 0
        let delayedVerifier = FanWakeSafetyVerifier(
            recover: { .clean },
            readPreflight: {
                delayedAttempts += 1
                if delayedAttempts < 3 { throw CheckFailure.simulated }
                return ready
            },
            timeoutSeconds: 2.0,
            now: { delayedClock.now },
            pause: { delayedClock.advance(0.1) }
        )
        try require(try delayedVerifier.run() == .clean, "Transient post-wake SMC unavailability did not recover")
        try require(delayedAttempts == 3, "Wake verifier did not reopen/retry the fresh preflight")

        let blockedEvidence = FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 1, fans: [fan]
        )
        let blocked = FanOwnershipPreflightEvaluator.evaluate(blockedEvidence)
        let blockedClock = ClockBox()
        let blockedVerifier = FanWakeSafetyVerifier(
            recover: { .clean },
            readPreflight: { blocked },
            timeoutSeconds: 0.4,
            now: { blockedClock.now },
            pause: { blockedClock.advance(0.1) }
        )
        try rejects { _ = try blockedVerifier.run() }

        let recoveredClock = ClockBox()
        let recoveredVerifier = FanWakeSafetyVerifier(
            recover: { .recovered },
            readPreflight: { ready },
            timeoutSeconds: 2.0,
            now: { recoveredClock.now },
            pause: { recoveredClock.advance(0.1) }
        )
        try require(try recoveredVerifier.run() == .recovered, "Recovered wake verifier lost recovery result")
    }

    private static func preflightCheck() throws {
        let fan = FanOwnershipPreflightFan(
            id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 3200,
            minimumRPM: 2317, maximumRPM: 6550, targetType: "flt "
        )
        let readyEvidence = FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [fan]
        )
        let ready = FanOwnershipPreflightEvaluator.evaluate(readyEvidence)
        try require(ready.state == .readyForValidation, "Approved read-only M4 baseline was rejected")
        try require(ready.reasons.isEmpty, "Ready preflight unexpectedly contains blockers")

        let activeGlobal = FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 1, fans: [fan]
        )
        try require(FanOwnershipPreflightEvaluator.evaluate(activeGlobal).state == .blocked,
                    "Active Ftst must block validation")

        let manualFan = FanOwnershipPreflightFan(
            id: 0, modeKey: "F0Md", mode: 1, actualRPM: 3000, targetRPM: 3000,
            minimumRPM: 2317, maximumRPM: 6550, targetType: "flt "
        )
        let manualEvidence = FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [manualFan]
        )
        try require(FanOwnershipPreflightEvaluator.evaluate(manualEvidence).state == .blocked,
                    "Existing manual fan ownership must block validation")

        let otherModel = FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac99,9", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [fan]
        )
        try require(FanOwnershipPreflightEvaluator.evaluate(otherModel).state == .unsupported,
                    "Unknown Mac profile must not inherit Mac16,1 approval")
    }

    private static func preflightReaderCheck() throws {
        let transport = PreflightFixtureTransport(values: [
            "Ftst": .init(type: "ui8 ", bytes: [0]),
            "FNum": .init(type: "ui8 ", bytes: [1]),
            "F0Md": .init(type: "ui8 ", bytes: [3]),
            "F0Ac": .init(type: "flt ", bytes: floatBytes(0)),
            "F0Tg": .init(type: "flt ", bytes: floatBytes(0)),
            "F0Mn": .init(type: "flt ", bytes: floatBytes(2317)),
            "F0Mx": .init(type: "flt ", bytes: floatBytes(6550))
        ])
        let reader = SMCFanOwnershipPreflightReader(client: SMCClient(transport: transport))
        let snapshot = try reader.read(modelIdentifier: "Mac16,1", osBuild: "25G83")
        try require(snapshot.state == .readyForValidation, "Read-only SMC preflight fixture did not match Mac16,1 profile")
        try require(snapshot.evidence.fans.first?.modeKey == "F0Md", "Preflight did not preserve exact mode-key casing")
        try require(snapshot.evidence.globalValue == 0, "Preflight did not preserve Ftst readback")
    }

    private static func productionFanControlProfileCheck() throws {
        let fan = FanOwnershipPreflightFan(
            id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 0,
            minimumRPM: 2317, maximumRPM: 6550, targetType: "flt "
        )
        let evidence = FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [fan]
        )
        let ready = FanOwnershipPreflightEvaluator.evaluate(evidence)
        try ProductionM4FanControlProfile.validate(ready)
        try require(try ProductionM4FanControlProfile.target(for: .boost, requestedRPM: 3000) == 6550,
                    "Production Boost no longer resolves to the pinned factory maximum")
        try require(try ProductionM4FanControlProfile.target(for: .override, requestedRPM: 4200.4) == 4200,
                    "Production Override did not quantize to integral RPM")
        try require(try ProductionM4FanControlProfile.target(for: .override, requestedRPM: 1000) == 2317,
                    "Production Override did not clamp below the validated factory minimum")
        try require(try ProductionM4FanControlProfile.target(for: .override, requestedRPM: 9000) == 6550,
                    "Production Override did not clamp above the validated factory maximum")
        try rejects { _ = try ProductionM4FanControlProfile.target(for: .override, requestedRPM: .nan) }
        try require(ProductionM4FanControlProfile.softReleaseTargets(from: 6550) == [5200, 4300, 3400, 2800],
                    "Factory-max soft release path changed")
        try require(ProductionM4FanControlProfile.softReleaseTargets(from: 4500) == [4300, 3400, 2800],
                    "Mid-range soft release path changed")
        try require(ProductionM4FanControlProfile.softReleaseTargets(from: 2600).isEmpty,
                    "Low manual target should release directly to System")

        let driftedFan = FanOwnershipPreflightFan(
            id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 0,
            minimumRPM: 2317, maximumRPM: 6500, targetType: "flt "
        )
        let drifted = FanOwnershipPreflightEvaluator.evaluate(FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [driftedFan]
        ))
        try rejects { try ProductionM4FanControlProfile.validate(drifted) }

        let encodingDriftFan = FanOwnershipPreflightFan(
            id: 0, modeKey: "F0Md", mode: 3, actualRPM: 0, targetRPM: 0,
            minimumRPM: 2317, maximumRPM: 6550, targetType: "fpe2"
        )
        let encodingDrift = FanOwnershipPreflightEvaluator.evaluate(FanOwnershipPreflightEvidence(
            modelIdentifier: "Mac16,1", osBuild: "25G83", fanCount: 1,
            globalKeyType: "ui8 ", globalKeySize: 1, globalValue: 0, fans: [encodingDriftFan]
        ))
        try rejects { try ProductionM4FanControlProfile.validate(encodingDrift) }
    }

    private static func failClosedUpdateCheck() throws {
        final class FailingHardware: FanOwnershipTargetHardware {
            var writes = 0
            func setFanTarget(_ id: Int, rpm: Double) throws { writes += 1 }
            func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool { false }
        }

        let owned = FanOwnershipRecoveryRecord(
            generation: 7,
            phase: .owned,
            globalOwnershipMayBeActive: true,
            fanIDs: [0]
        )
        let journal = MemoryJournal(owned)
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let hardware = FailingHardware()
        let updates = FanOwnershipTargetUpdateExecutor(stateMachine: machine, hardware: hardware, permit: {})
        try rejects { try updates.update(targets: [0: 3_200]) }
        try require(hardware.writes == 1, "Failure test did not reach the target write")
        try require(machine.record.phase == .recoveryRequired && machine.record.fanIDs == [0],
                    "Failed target verification did not preserve conservative recovery state")
    }
}
