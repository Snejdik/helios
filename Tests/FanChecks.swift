import Foundation

private enum Failure: Error { case check(String), simulated }
private func require(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure.check(message) }
}
private func rejects(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw Failure.check("Expected a rejected operation")
}
private func ticks(_ seconds: Double) -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return UInt64(seconds * 1_000_000_000 * Double(info.denom) / Double(info.numer))
}

/// Test-only synchronized counter for values captured by @Sendable factories.
/// The production coordinator may invoke its engine factory on the writer queue,
/// so Swift 6 correctly rejects an unsynchronized captured `var` even when the
/// test happens to observe it serially.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        storage += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private final class FanReadFixture: SMCReadTransport {
    var values: [String: (String, [UInt8])] = ["FNum": ("ui8 ", [0])]
    func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
        guard let (type, value) = values[request.key] else { throw TelemetryError.smc(request.key, 0x84) }
        var frame = [UInt8](repeating: 0, count: 80)
        if request.command == .keyInfo {
            frame[28] = UInt8(value.count)
            let raw = try SMCCodec.fourCC(type)
            for n in 0..<4 { frame[32 + n] = UInt8(truncatingIfNeeded: raw >> (8 * n)) }
        } else { frame.replaceSubrange(48..<(48 + value.count), with: value) }
        return frame
    }
}

@main
@MainActor
private enum FanChecks {
    static func main() async {
        do {
            try require(geteuid() != 0, "Run checks as an ordinary user")
            try codecsAndDiscovery()
            try engineFailures()
            try leaseAndPolicy()
            try coolingRulesChecks()
            try ownershipTransitionChecks()
            try ownershipRecoveryChecks()
            try ownershipRecoveryExecutorChecks()
            try ownershipAcquisitionExecutorChecks()
            try ownershipTargetUpdateChecks()
            try await coordinatorChecks()
            if CommandLine.arguments.contains("--live") {
                let reader = SMCFanReader(client: SMCClient(transport: try SMCIOKitTransport()))
                let inventory = try reader.read()
                print("LIVE: FNum = \(inventory.fans.count)")
                for fan in inventory.fans {
                    print("Fan \(fan.id): actual=\(fan.actualRPM), target=\(fan.targetRPM), min=\(fan.minimumRPM), max=\(fan.maximumRPM), automatic=\(fan.automatic)")
                }
            }
            print("PASS fan discovery/codecs, recovery/acquisition/update/release executors, independent leases, Manual bounds, TG-style Cooling Rules, 95C emergency floor, and pre-emptible soft release")
        } catch { print("FAIL: \(error)"); exit(1) }
    }

    static func codecsAndDiscovery() throws {
        let transport = FanReadFixture()
        let reader = SMCFanReader(client: SMCClient(transport: transport))
        try require(try reader.read().fans.isEmpty, "Zero fans must be a normal state")
        transport.values["FNum"] = ("ui8 ", [1])
        transport.values["F0Ac"] = ("fpe2", [0, 0])
        transport.values["F0Mn"] = ("fpe2", [0x0f, 0xa0])
        transport.values["F0Mx"] = ("flt ", [0, 0x40, 0x9c, 0x45]) // 5000
        transport.values["F0Md"] = ("ui8 ", [0])
        let value = try reader.read().fans[0]
        try require(try value.actualRPM.get() == 0, "Stopped fan must not become unavailable")
        try require(try value.minimumRPM.get() == 1000, "fpe2 decode")
        try require(try value.maximumRPM.get() == 5000, "float decode")
        try require((try? value.targetRPM.get()) == nil, "Missing target must be independent")
        transport.values["FNum"] = ("ui8 ", [255])
        try rejects { _ = try reader.read() }
        try rejects { _ = try FanCodec.rpm(type: "flt ", bytes: [0, 0, 0x80, 0x7f]) }
        for type in ["fpe2", "flt "] {
            let channel = FanChannel(id: 0, minimum: 1000.1, maximum: 5000.1)
            for request in [-20.0, 2500.1, 9000] {
                let encoded = try SMCFanHardware.encodedRPM(request, channel: channel, type: type)
                let decoded = try FanCodec.rpm(type: type, bytes: encoded)
                try require(decoded >= channel.minimum && decoded <= channel.maximum, "Encoding escaped factory bounds")
            }
            try rejects { _ = try SMCFanHardware.encodedRPM(.nan, channel: channel, type: type) }
        }
    }

    static func engineFailures() throws {
        let hardware = FakeFanHardware()
        let journal = FakeFanJournal()
        let engine = try FanControlEngine(hardware: hardware, journal: journal)
        try engine.apply(mode: .override, rpm: 0, permit: {})
        try require(hardware.target(0) == 1000 && hardware.target(1) == 1200, "Manual targets were not individually clamped")
        try engine.apply(mode: .boost, rpm: 0, permit: {})
        try require(hardware.target(0) == 5000 && hardware.target(1) == 6000, "Boost did not use each factory maximum")
        try engine.restore()
        try require(try journal.load().isEmpty && engine.state == .system, "Verified restore did not clear ownership")
        hardware.setFailure("manual 1")
        try rejects { try engine.apply(mode: .override, rpm: 3000, permit: {}) }
        try require(hardware.events.suffix(2) == ["restore 0", "restore 1"], "Partial transaction did not restore every touched fan")
        hardware.setFailure(nil)
        try engine.apply(mode: .boost, rpm: 0, permit: {})
        hardware.setFailure("restore 0")
        try rejects { try engine.restore() }
        try require(engine.state == .recoveryRequired && (try journal.load()) == [0, 1], "Failed restoration cleared the journal or claimed System")
        try require(hardware.events.last == "restore 1", "Failed fan reset prevented the other reset")
        hardware.setFailure(nil)
        let restarted = try FanControlEngine(hardware: hardware, journal: journal)
        try require(restarted.state == .system && (try journal.load()).isEmpty, "Startup did not recover journaled fans")
        journal.fail = true
        let before = hardware.events.count
        try rejects { try restarted.apply(mode: .boost, rpm: 0, permit: {}) }
        try require(hardware.events.count == before, "Hardware wrote before the journal was durable")
        let empty = FakeFanHardware()
        empty.channelValues = []
        let fanless = try FanControlEngine(hardware: empty, journal: FakeFanJournal())
        try rejects { try fanless.apply(mode: .boost, rpm: 0, permit: {}) }
        try require(empty.events.isEmpty, "Fanless takeover wrote hardware")
        let foreign = FakeFanHardware()
        try foreign.setManual(0)
        let foreignEngine = try FanControlEngine(hardware: foreign, journal: FakeFanJournal())
        try rejects { try foreignEngine.apply(mode: .boost, rpm: 0, permit: {}) }
        try require(foreign.events == ["manual 0"], "Takeover modified a foreign controller's fan")
        let malformed = FakeFanHardware()
        malformed.channelValues = [FanChannel(id: 0, minimum: 5000, maximum: 1000)]
        let malformedEngine = try FanControlEngine(hardware: malformed, journal: FakeFanJournal())
        try rejects { try malformedEngine.apply(mode: .override, rpm: 3000, permit: {}) }
        try require(malformed.events.isEmpty, "Invalid hardware limits reached a write")
    }

    static func leaseAndPolicy() throws {
        let owner = UUID()
        let lease = ControlLease()
        let start = ticks(100)
        let token = try lease.accept(owner: owner, sequence: 1, sample: start, now: start)
        try lease.check(token, now: start + ticks(4.999))
        try rejects { try lease.check(token, now: start + ticks(5)) }
        try require(lease.expire(now: start + ticks(5)), "Exact boundary did not revoke control")
        try rejects { _ = try lease.accept(owner: owner, sequence: 2, sample: start + ticks(6), now: start + ticks(6)) }
        lease.reset()
        try rejects { _ = try lease.accept(owner: owner, sequence: 1, sample: start, now: start) }
        try rejects { _ = try lease.accept(owner: owner, sequence: 2, sample: start + ticks(8), now: start + ticks(7)) }
        try rejects { _ = try lease.accept(owner: owner, sequence: 2, sample: start + ticks(6), now: start + ticks(10)) }
        let next = try lease.accept(owner: owner, sequence: 2, sample: start + ticks(10), now: start + ticks(10))
        lease.revoke(owner: owner)
        try rejects { try lease.check(next, now: start + ticks(10)) }

        // A still-fresh acquisition that fails in hardware may be retried only
        // after verified System restoration. Replay history survives the reset.
        let recoverable = ControlLease()
        let failedSample = start + ticks(20)
        let failedToken = try recoverable.accept(owner: owner, sequence: 1, sample: failedSample, now: failedSample)
        try recoverable.beginAcquisition(failedToken, now: failedSample + ticks(0.1))
        guard let recoveryGeneration = recoverable.beginRecoverableFailureReset(
            failedToken, acquisition: true, now: failedSample + ticks(0.2)
        ) else { throw Failure.check("Fresh failed acquisition was not eligible for recoverable reset") }
        try require(recoverable.completeRecoverableFailureReset(recoveryGeneration),
                    "Verified recoverable reset did not re-arm the lease gate")
        try rejects { _ = try recoverable.accept(owner: owner, sequence: 1, sample: failedSample, now: failedSample + ticks(0.3)) }
        _ = try recoverable.accept(owner: owner, sequence: 2, sample: failedSample + ticks(0.4), now: failedSample + ticks(0.4))

        // A safety revocation racing hardware recovery must win permanently; the
        // old recovery completion may not re-arm a newer generation.
        let raced = ControlLease()
        let racedSample = start + ticks(30)
        let racedToken = try raced.accept(owner: owner, sequence: 1, sample: racedSample, now: racedSample)
        try raced.beginAcquisition(racedToken, now: racedSample + ticks(0.1))
        guard let racedGeneration = raced.beginRecoverableFailureReset(
            racedToken, acquisition: true, now: racedSample + ticks(0.2)
        ) else { throw Failure.check("Race fixture could not enter recoverable reset") }
        raced.revoke(owner: owner)
        try require(!raced.completeRecoverableFailureReset(racedGeneration),
                    "Concurrent safety revocation was overwritten by recovery completion")
        try rejects { _ = try raced.accept(owner: owner, sequence: 2, sample: racedSample + ticks(0.4), now: racedSample + ticks(0.4)) }

        // Cooling automation is tested independently below. Lease tests stay
        // focused on the privilege boundary and replay/expiry semantics.

    }

    static func coolingRulesChecks() throws {
        let start = ticks(200)
        let hot = ThermalMetrics(readings: [
            ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 75),
            ThermalReading(key: "Tp05", group: .performanceCPU, celsius: 70),
            ThermalReading(key: "Te05", group: .efficiencyCPU, celsius: 60),
            ThermalReading(key: "Tg0G", group: .gpu, celsius: 65),
            ThermalReading(key: "Tzzz", group: .unclassified, celsius: 120)
        ], failures: [:])
        let rules = CoolingRuleProfile(rules: [
            CoolingRule(speedPercent: 20, sensor: .highestCPU, thresholdCelsius: 50),
            CoolingRule(speedPercent: 80, sensor: .highestCPU, thresholdCelsius: 70),
            CoolingRule(speedPercent: 60, sensor: .gpu, thresholdCelsius: 60)
        ])
        var engine = CoolingRulesEngine()
        var decision = engine.evaluate(profile: rules, inputs: CoolingRuleInputs(thermals: hot, batteryCelsius: 31, storageCelsius: nil), fanIDs: [0], ticks: start)
        try require(!decision.isActive, "Cooling rules skipped the engage debounce")
        decision = engine.evaluate(profile: rules, inputs: CoolingRuleInputs(thermals: hot, batteryCelsius: 31, storageCelsius: nil), fanIDs: [0], ticks: start + ticks(0.5))
        try require(decision.fanPercent[0] == 80, "Highest active Cooling Rule did not win")
        try require(decision.activeRuleIDs.count == 3, "Expected CPU/GPU rules did not activate")

        let cooling = ThermalMetrics(readings: [
            ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 66),
            ThermalReading(key: "Te05", group: .efficiencyCPU, celsius: 55),
            ThermalReading(key: "Tg0G", group: .gpu, celsius: 50)
        ], failures: [:])
        decision = engine.evaluate(profile: rules, inputs: CoolingRuleInputs(thermals: cooling, batteryCelsius: 31, storageCelsius: nil), fanIDs: [0], ticks: start + ticks(1.0))
        try require(decision.fanPercent[0] == 80, "Rule hysteresis released immediately")
        decision = engine.evaluate(profile: rules, inputs: CoolingRuleInputs(thermals: cooling, batteryCelsius: 31, storageCelsius: nil), fanIDs: [0], ticks: start + ticks(4.0))
        try require(decision.fanPercent[0] == 20, "Lower rule did not take over after release debounce")

        var perFan = CoolingRulesEngine()
        let fan0 = CoolingRule(speedPercent: 80, sensor: .always, thresholdCelsius: 120)
        let all = CoolingRule(speedPercent: 40, sensor: .always, thresholdCelsius: 120)
        decision = perFan.evaluate(profile: CoolingRuleProfile(rules: [all, CoolingRule(id: fan0.id, enabled: true, target: .fan(0), speedPercent: 80, sensor: .always)]),
                                 inputs: CoolingRuleInputs(thermals: hot, batteryCelsius: nil, storageCelsius: nil), fanIDs: [0, 1], ticks: start)
        try require(decision.fanPercent[0] == 80 && decision.fanPercent[1] == 40, "Per-fan and All Fans demands were not merged by maximum percent")
        try require(decision.activeRuleIDs.contains(all.id), "Always rule incorrectly depended on its ignored temperature threshold")

        let storageInputs = CoolingRuleInputs(thermals: hot, batteryCelsius: 31, storageCelsius: 47)
        try require(storageInputs.value(for: .storage) == 47, "SSD SMART temperature rule source")
        try require((storageInputs.value(for: .anySensor) ?? 0) >= 47, "Any Sensor omitted SSD SMART temperature")

        let individual = CoolingRuleInputs(thermals: hot, batteryCelsius: 31, storageCelsius: nil)
        try require(individual.value(for: .highestCPU) == 75, "Highest CPU source")
        try require(individual.value(for: .averageCPU).map { abs($0 - (205.0 / 3.0)) < 0.001 } == true, "Average CPU source")
        try require(individual.value(for: .anySensor) == 75, "Any Sensor trusted an unclassified 120C key")
        try require(individual.value(for: .individual("Tp05")) == 70, "Individual trusted sensor source")
        try require(individual.value(for: .battery) == 31, "Battery rule source")

        var emergency = CoolingRulesEngine()
        let critical = ThermalMetrics(readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 95)], failures: [:])
        decision = emergency.evaluate(profile: CoolingRuleProfile(rules: []), inputs: CoolingRuleInputs(thermals: critical, batteryCelsius: nil, storageCelsius: nil), fanIDs: [0, 1], ticks: start)
        try require(decision.emergency && decision.fanPercent == [0: 100, 1: 100], "95C emergency did not force all fans to 100% immediately")
        let safe = ThermalMetrics(readings: [ThermalReading(key: "Tp01", group: .performanceCPU, celsius: 87)], failures: [:])
        decision = emergency.evaluate(profile: CoolingRuleProfile(rules: []), inputs: CoolingRuleInputs(thermals: safe, batteryCelsius: nil, storageCelsius: nil), fanIDs: [0], ticks: start + ticks(1.0))
        try require(decision.emergency, "First safe emergency sample released immediately")
        decision = emergency.evaluate(profile: CoolingRuleProfile(rules: []), inputs: CoolingRuleInputs(thermals: safe, batteryCelsius: nil, storageCelsius: nil), fanIDs: [0], ticks: start + ticks(5.9))
        try require(decision.emergency, "Emergency released before five seconds")
        decision = emergency.evaluate(profile: CoolingRuleProfile(rules: []), inputs: CoolingRuleInputs(thermals: safe, batteryCelsius: nil, storageCelsius: nil), fanIDs: [0], ticks: start + ticks(6.0))
        try require(!decision.emergency, "Emergency did not release after sustained safe temperature")

        let bounds = 2317.0...6550.0
        try require(try CoolingRulePercentCodec.rpm(percent: 0, bounds: bounds) == 2317, "0% must map to factory minimum")
        try require(try CoolingRulePercentCodec.rpm(percent: 100, bounds: bounds) == 6550, "100% must map to factory maximum")
        try require(abs((try CoolingRulePercentCodec.rpm(percent: 20, bounds: bounds)) - 3163.6) < 0.001, "TG-style percent formula changed")

        var config = CoolingRulesConfiguration.safeDefault
        config.transitionSeconds = 99
        let encoded = try CoolingRulesPersistence.encode(config)
        let decoded = try CoolingRulesPersistence.decode(encoded)
        try require(decoded.transitionSeconds == CoolingRulesConfiguration.maximumTransitionSeconds, "Persisted transition was not normalized")
        try require(decoded.powerAdapter.rules.contains(where: { $0.speedPercent == 100 }), "Safe adapter preset lacks a 100% rule")
        try require(!decoded.powerAdapter.rules.contains(where: { $0.sensor.kind == .always }), "Safe default should preserve Apple zero-RPM control below first rule")
        var emptyProfile = CoolingRulesConfiguration.safeDefault
        emptyProfile.battery.rules = []
        let emptyDecoded = try CoolingRulesPersistence.decode(CoolingRulesPersistence.encode(emptyProfile))
        try require(emptyDecoded.battery.rules.isEmpty, "Empty Auto profile was not preserved as valid System-only configuration")
    }

    static func ownershipTransitionChecks() throws {
        final class ClockBox {
            var now: UInt64 = ticks(100)
            func advance(_ seconds: Double) { now += ticks(seconds) }
        }

        final class ReadSequence {
            var values: [UInt8]
            private(set) var reads = 0
            init(_ values: [UInt8]) { self.values = values }
            func read() -> UInt8 {
                let index = min(reads, values.count - 1)
                reads += 1
                return values[index]
            }
        }

        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 1.5, requiredStableReads: 2)

        do {
            let clock = ClockBox()
            let sequence = ReadSequence([0, 0, 1, 1])
            try FanOwnershipTransitionPoller(policy: policy).wait(
                expected: 1,
                now: { clock.now },
                read: { sequence.read() },
                pause: { clock.advance(0.2) },
                permit: {}
            )
            try require(sequence.reads == 4, "Delayed takeover was accepted before stable readback")
        }

        do {
            let clock = ClockBox()
            let sequence = ReadSequence([1, 0, 0])
            try FanOwnershipTransitionPoller(policy: policy).wait(
                expected: 0,
                now: { clock.now },
                read: { sequence.read() },
                pause: { clock.advance(0.2) },
                permit: {}
            )
            try require(sequence.reads == 3, "Delayed release was accepted before stable readback")
        }

        do {
            let clock = ClockBox()
            let sequence = ReadSequence([0, 1, 0, 1, 1])
            try FanOwnershipTransitionPoller(policy: policy).wait(
                expected: 1,
                now: { clock.now },
                read: { sequence.read() },
                pause: { clock.advance(0.1) },
                permit: {}
            )
            try require(sequence.reads == 5, "Non-consecutive ownership observations counted as stable")
        }

        do {
            let clock = ClockBox()
            let sequence = ReadSequence([0, 2])
            try rejects {
                try FanOwnershipTransitionPoller(policy: policy).wait(
                    expected: 1,
                    now: { clock.now },
                    read: { sequence.read() },
                    pause: { clock.advance(0.1) },
                    permit: {}
                )
            }
            try require(sequence.reads == 2, "Unexpected ownership value was not rejected immediately")
        }

        do {
            let clock = ClockBox()
            let sequence = ReadSequence([0])
            let short = try FanOwnershipTransitionPolicy(timeoutSeconds: 0.5, requiredStableReads: 2)
            try rejects {
                try FanOwnershipTransitionPoller(policy: short).wait(
                    expected: 1,
                    now: { clock.now },
                    read: { sequence.read() },
                    pause: { clock.advance(0.2) },
                    permit: {}
                )
            }
            try require(sequence.reads == 3, "Ownership timeout was not bounded by the policy deadline")
        }

        do {
            let clock = ClockBox()
            let sequence = ReadSequence([0])
            var permits = 0
            try rejects {
                try FanOwnershipTransitionPoller(policy: policy).wait(
                    expected: 1,
                    now: { clock.now },
                    read: { sequence.read() },
                    pause: { clock.advance(0.1) },
                    permit: {
                        permits += 1
                        if permits >= 4 { throw Failure.simulated }
                    }
                )
            }
            try require(sequence.reads < 4, "Cancellation did not stop ownership polling promptly")
        }
    }

    static func ownershipRecoveryChecks() throws {
        final class RecoveryJournal: FanOwnershipRecoveryJournal {
            var record = FanOwnershipRecoveryRecord.clean
            var failNextSave = false
            private(set) var saves: [FanOwnershipRecoveryRecord] = []

            func load() throws -> FanOwnershipRecoveryRecord { record }
            func save(_ record: FanOwnershipRecoveryRecord) throws {
                if failNextSave {
                    failNextSave = false
                    throw Failure.simulated
                }
                self.record = record
                saves.append(record)
            }
        }

        do {
            let journal = RecoveryJournal()
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            try require(machine.recoveryPlan.isEmpty, "Clean recovery journal produced work")

            // This durable intent must exist before a future Ftst=1 write. A crash
            // while firmware still reads the old value therefore still recovers global state.
            try machine.prepareGlobalAcquisition()
            try require(machine.record.phase == .acquiringGlobal && machine.record.globalOwnershipMayBeActive,
                        "Global acquisition intent was not durable before hardware")
            let crashBeforeReadback = FanOwnershipRecoveryPlan(record: journal.record)
            try require(crashBeforeReadback.fanIDs.isEmpty && crashBeforeReadback.clearGlobalOwnership,
                        "Crash during delayed Ftst acquisition lost global recovery intent")

            // Reload exactly what a restarted daemon would see while Ftst may flip later.
            let restarted = try FanOwnershipRecoveryStateMachine(journal: journal)
            try require(restarted.recoveryPlan.clearGlobalOwnership,
                        "Restart during delayed Ftst visibility did not require global cleanup")
            try restarted.requireRecovery()
            try require(restarted.record.phase == .recoveryRequired && restarted.record.globalOwnershipMayBeActive,
                        "Ambiguous restart discarded global ownership risk")
        }

        do {
            let journal = RecoveryJournal()
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            try machine.prepareGlobalAcquisition()
            try machine.confirmGlobalOwnership()
            try machine.prepareFanWrite(0)
            try require(machine.record.fanIDs == [0] && machine.record.phase == .acquiringFans,
                        "Fan was not journaled before its future write")
            try machine.prepareFanWrite(1)
            try machine.confirmOwned()
            try require(machine.recoveryPlan == FanOwnershipRecoveryPlan(record: machine.record),
                        "Recovery plan was not deterministic")
            try require(machine.recoveryPlan.fanIDs == [0, 1] && machine.recoveryPlan.clearGlobalOwnership,
                        "Owned recovery plan omitted a touched fan or global state")

            try machine.beginRelease()
            // Phase 4.5 showed per-fan verification may remain ambiguous until
            // global Ftst ownership is released. Preserve both fan bits while
            // entering the durable global-release phase.
            try machine.prepareGlobalRelease()
            try require(machine.record.phase == .releasingGlobal && machine.record.globalOwnershipMayBeActive && machine.record.fanIDs == [0, 1],
                        "Global release did not preserve pending fan risk")

            // A crash after a successful Ftst=0 transport return but before stable
            // readback must still retain both global and per-fan recovery intent.
            let crashDuringRelease = try FanOwnershipRecoveryStateMachine(journal: journal)
            try require(crashDuringRelease.recoveryPlan.fanIDs == [0, 1] && crashDuringRelease.recoveryPlan.clearGlobalOwnership,
                        "Crash during delayed Ftst release underestimated pending risk")

            try machine.confirmGlobalReleased()
            try require(machine.record.phase == .releasingFans && !machine.record.globalOwnershipMayBeActive && machine.record.fanIDs == [0, 1],
                        "Stable global release cleared pending fan verification")
            try machine.confirmFanReleased(0)
            try machine.confirmFanReleased(1)
            try machine.confirmSystemAfterFanOnlyRecovery()
            try require(machine.record.isClean && machine.recoveryPlan.isEmpty,
                        "Post-global fan verification did not produce a clean System record")
        }

        do {
            let journal = RecoveryJournal()
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            journal.failNextSave = true
            try rejects { try machine.prepareGlobalAcquisition() }
            try require(machine.record.isClean && journal.record.isClean,
                        "Persistence failure advanced acquisition state")
        }

        do {
            let record = FanOwnershipRecoveryRecord(
                generation: 42,
                phase: .releasingGlobal,
                globalOwnershipMayBeActive: true,
                fanIDs: []
            )
            let encoded = try FanOwnershipRecoveryCodec.encode(record)
            try require(encoded.count == FanOwnershipRecoveryCodec.encodedSize,
                        "Recovery v2 codec changed its fixed width")
            try require(try FanOwnershipRecoveryCodec.decode(encoded) == record,
                        "Recovery v2 codec did not round-trip")

            var corrupt = [UInt8](encoded)
            corrupt[7] ^= 0x01
            try rejects { _ = try FanOwnershipRecoveryCodec.decode(Data(corrupt)) }

            let structurallyInvalid = FanOwnershipRecoveryRecord(
                generation: 1,
                phase: .system,
                globalOwnershipMayBeActive: true,
                fanIDs: []
            )
            let invalidBytes = try FanOwnershipRecoveryCodec.encode(structurallyInvalid)
            try rejects { _ = try FanOwnershipRecoveryCodec.decode(invalidBytes) }
        }

        do {
            let journal = RecoveryJournal()
            journal.record = FanOwnershipRecoveryRecord(
                generation: 9,
                phase: .releasingGlobal,
                globalOwnershipMayBeActive: true,
                fanIDs: [0]
            )
            let resumed = try FanOwnershipRecoveryStateMachine(journal: journal)
            try require(resumed.recoveryPlan.fanIDs == [0] && resumed.recoveryPlan.clearGlobalOwnership,
                        "Releasing-global journal lost pending fan risk")
        }
    }


    static func ownershipRecoveryExecutorChecks() throws {
        final class ClockBox {
            var now: UInt64 = ticks(200)
            func advance(_ seconds: Double) { now += ticks(seconds) }
        }

        final class EventLog {
            var values: [String] = []
        }

        final class RecoveryJournal: FanOwnershipRecoveryJournal {
            var record: FanOwnershipRecoveryRecord
            let log: EventLog
            var failNextSave = false

            init(_ record: FanOwnershipRecoveryRecord, log: EventLog) {
                self.record = record
                self.log = log
            }

            func load() throws -> FanOwnershipRecoveryRecord { record }

            func save(_ record: FanOwnershipRecoveryRecord) throws {
                if failNextSave {
                    failNextSave = false
                    throw Failure.simulated
                }
                self.record = record
                log.values.append("journal \(record.phase)")
            }
        }

        final class RecoveryHardware: FanOwnershipRecoveryHardware {
            let log: EventLog
            var globalReads: [UInt8]
            private var globalReadIndex = 0
            var verifyFailureFan: Int?
            var restoreFailureFan: Int?
            var requestGlobalFailure = false
            var onVerifyFan: ((Int) -> Void)?
            var verifyResults: [Int: [Bool]] = [:]
            private var verifyIndices: [Int: Int] = [:]

            init(log: EventLog, globalReads: [UInt8]) {
                self.log = log
                self.globalReads = globalReads
            }

            func restoreFanToSystem(_ id: Int) throws {
                log.values.append("restore \(id)")
                if restoreFailureFan == id { throw Failure.simulated }
            }

            func verifyFanIsSystem(_ id: Int) throws -> Bool {
                log.values.append("verify \(id)")
                onVerifyFan?(id)
                if let values = verifyResults[id], !values.isEmpty {
                    let index = min(verifyIndices[id, default: 0], values.count - 1)
                    verifyIndices[id, default: 0] += 1
                    return values[index]
                }
                return verifyFailureFan != id
            }

            func requestGlobalRelease() throws {
                log.values.append("global release")
                if requestGlobalFailure { throw Failure.simulated }
            }

            func readGlobalOwnership() throws -> UInt8 {
                log.values.append("global read")
                guard !globalReads.isEmpty else { throw Failure.simulated }
                let index = min(globalReadIndex, globalReads.count - 1)
                globalReadIndex += 1
                return globalReads[index]
            }
        }

        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 1.5, requiredStableReads: 2)

        do {
            let log = EventLog()
            let initial = FanOwnershipRecoveryRecord(
                generation: 12,
                phase: .owned,
                globalOwnershipMayBeActive: true,
                fanIDs: [0]
            )
            let journal = RecoveryJournal(initial, log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = RecoveryHardware(log: log, globalReads: [1, 1, 0, 0])
            hardware.verifyResults[0] = [false, true, true]
            let clock = ClockBox()
            let executor = FanOwnershipRecoveryExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.2) },
                permit: {}
            )

            try executor.recover()
            try require(journal.record.isClean, "Delayed global release did not end in clean System")
            try require(log.values.filter { $0 == "global read" }.count == 4,
                        "Recovery accepted delayed global release before stable readback")
            try require(log.values.filter { $0 == "verify 0" }.count == 3,
                        "Recovery did not wait for stable post-global fan System readback")
            guard let journalRelease = log.values.firstIndex(of: "journal releasingGlobal"),
                  let hardwareRelease = log.values.firstIndex(of: "global release"),
                  let firstVerify = log.values.firstIndex(of: "verify 0") else {
                throw Failure.check("Recovery did not journal/request global release and verify the fan")
            }
            try require(journalRelease < hardwareRelease && hardwareRelease < firstVerify,
                        "Fan verification occurred before durable/stable global release")
            try require(log.values.last == "journal system",
                        "Recovery cleared durable risk before post-global fan verification")
        }

        do {
            let log = EventLog()
            let initial = FanOwnershipRecoveryRecord(
                generation: 20,
                phase: .owned,
                globalOwnershipMayBeActive: true,
                fanIDs: [0, 1]
            )
            let journal = RecoveryJournal(initial, log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            // This case is specifically a *post-global* partial fan verification
            // failure. Model a successfully observed Ftst release first; fan 1
            // then remains unresolved while fan 0 can be cleared. Using [1] here
            // would instead model a global-release timeout and could never reach
            // the post-global fan-risk state asserted below.
            let hardware = RecoveryHardware(log: log, globalReads: [0, 0])
            hardware.verifyFailureFan = 1
            let clock = ClockBox()
            let executor = FanOwnershipRecoveryExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.1) },
                permit: {}
            )

            try rejects { try executor.recover() }
            try require(journal.record.phase == .recoveryRequired,
                        "Partial fan recovery failure was not marked recovery-required")
            try require(journal.record.fanIDs == [1] && !journal.record.globalOwnershipMayBeActive,
                        "Partial post-global recovery lost unresolved fan risk")
            try require(log.values.contains("global release"),
                        "Recovery did not release global ownership before final fan verification")
        }

        do {
            // Regression for Next13: cancellation can happen after Ftst=1 was
            // accepted but before it becomes visible and before any fan bit is
            // journaled. Recovery must still issue global release, tolerate an
            // old 0 -> delayed 1 -> final 0 sequence, and finish clean without
            // requiring a non-existent fan-only transition.
            let log = EventLog()
            let initial = FanOwnershipRecoveryRecord(
                generation: 25,
                phase: .acquiringGlobal,
                globalOwnershipMayBeActive: true,
                fanIDs: []
            )
            let journal = RecoveryJournal(initial, log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = RecoveryHardware(log: log, globalReads: [0, 0, 1, 0, 0, 0, 0])
            let clock = ClockBox()
            let guarded = try FanOwnershipTransitionPolicy(timeoutSeconds: 2.0, requiredStableReads: 4)
            let executor = FanOwnershipRecoveryExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: guarded,
                now: { clock.now },
                pause: { clock.advance(0.2) },
                permit: {}
            )

            try executor.recover()
            try require(journal.record.isClean,
                        "Global-only delayed acquisition recovery did not finish clean")
            try require(log.values.filter { $0 == "global release" }.count == 1,
                        "Global-only recovery did not issue exactly one explicit release")
            try require(log.values.filter { $0 == "global read" }.count == 7,
                        "Delayed old-zero/global-one sequence was accepted too early")
            try require(!log.values.contains(where: { $0.hasPrefix("restore ") || $0.hasPrefix("verify ") }),
                        "Global-only recovery touched a fan that was never journaled")
            try require(log.values.last == "journal system",
                        "Global-only recovery did not end with a durable System record")
        }

        do {
            let log = EventLog()
            let initial = FanOwnershipRecoveryRecord(
                generation: 30,
                phase: .acquiringGlobal,
                globalOwnershipMayBeActive: true,
                fanIDs: []
            )
            let journal = RecoveryJournal(initial, log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = RecoveryHardware(log: log, globalReads: [1])
            let clock = ClockBox()
            let short = try FanOwnershipTransitionPolicy(timeoutSeconds: 0.5, requiredStableReads: 2)
            let executor = FanOwnershipRecoveryExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: short,
                now: { clock.now },
                pause: { clock.advance(0.2) },
                permit: {}
            )

            try rejects { try executor.recover() }
            try require(journal.record.phase == .recoveryRequired && journal.record.globalOwnershipMayBeActive,
                        "Global release timeout incorrectly cleared ownership risk")
            try require(!journal.record.isClean,
                        "Timed-out delayed global release produced a clean journal")
        }

        do {
            let log = EventLog()
            let initial = FanOwnershipRecoveryRecord(
                generation: 40,
                phase: .owned,
                globalOwnershipMayBeActive: true,
                fanIDs: [0]
            )
            let journal = RecoveryJournal(initial, log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = RecoveryHardware(log: log, globalReads: [0, 0])
            let clock = ClockBox()
            hardware.onVerifyFan = { id in
                if id == 0 { journal.failNextSave = true }
            }
            let executor = FanOwnershipRecoveryExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.1) },
                permit: {}
            )

            // The fan can already have verified System when the durable save
            // fails. Global ownership has already been released, but the fan risk
            // bit must remain conservative until its save succeeds.
            try rejects { try executor.recover() }
            try require(journal.record.fanIDs == [0] && !journal.record.globalOwnershipMayBeActive,
                        "Journal failure after post-global fan verification underestimated recovery risk")
            try require(log.values.contains("global release"),
                        "Recovery never reached the required global release")
        }

        do {
            let log = EventLog()
            let clean = RecoveryJournal(.clean, log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: clean)
            let hardware = RecoveryHardware(log: log, globalReads: [0])
            let clock = ClockBox()
            let executor = FanOwnershipRecoveryExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.1) },
                permit: {}
            )
            try executor.recover()
            try require(log.values.isEmpty, "Clean recovery journal performed hardware or journal work")
        }
    }

    static func ownershipAcquisitionExecutorChecks() throws {
        final class ClockBox {
            var now = HostClock.now
            func advance(_ seconds: Double) { now &+= ticks(seconds) }
        }
        final class EventLog { var values: [String] = [] }
        final class AcquisitionJournal: FanOwnershipRecoveryJournal {
            var record = FanOwnershipRecoveryRecord.clean
            var failNextSave = false
            let log: EventLog

            init(log: EventLog) { self.log = log }
            func load() throws -> FanOwnershipRecoveryRecord { record }
            func save(_ next: FanOwnershipRecoveryRecord) throws {
                if failNextSave { failNextSave = false; throw Failure.simulated }
                record = next
                log.values.append("journal \(next.phase)")
            }
        }
        final class AcquisitionHardware: FanOwnershipAcquisitionHardware {
            let log: EventLog
            var globalReads: [UInt8]
            var globalReadIndex = 0
            var baselineFailure = false
            var globalRequestFailure = false
            var manualFailureFan: Int?
            var targetFailureFan: Int?
            var verificationFailureFan: Int?
            var manualFans: Set<Int> = []

            init(log: EventLog, globalReads: [UInt8]) {
                self.log = log
                self.globalReads = globalReads
            }

            func validateGlobalAcquisitionBaseline() throws {
                log.values.append("baseline")
                if baselineFailure { throw Failure.simulated }
            }

            func requestGlobalAcquisition() throws {
                log.values.append("global acquire")
                if globalRequestFailure { throw Failure.simulated }
            }

            func readGlobalOwnership() throws -> UInt8 {
                log.values.append("global read")
                guard !globalReads.isEmpty else { throw Failure.simulated }
                let index = min(globalReadIndex, globalReads.count - 1)
                globalReadIndex += 1
                return globalReads[index]
            }

            func readFanMode(_ id: Int) throws -> UInt8 { manualFans.contains(id) ? 1 : 3 }

            func requestFanManual(_ id: Int) throws {
                log.values.append("manual \(id)")
                if manualFailureFan == id { throw Failure.simulated }
                manualFans.insert(id)
            }

            func setFanTarget(_ id: Int, rpm: Double) throws {
                log.values.append("target \(id) \(Int(rpm))")
                if targetFailureFan == id { throw Failure.simulated }
            }

            func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool {
                log.values.append("verify \(id) \(Int(targetRPM))")
                return verificationFailureFan != id
            }
        }

        let policy = try FanOwnershipTransitionPolicy(timeoutSeconds: 1.5, requiredStableReads: 2)

        do {
            let log = EventLog()
            let journal = AcquisitionJournal(log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = AcquisitionHardware(log: log, globalReads: [0, 1, 1])
            let clock = ClockBox()
            let executor = FanOwnershipAcquisitionExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.2) },
                permit: {}
            )

            try executor.acquire(targets: [1: 3_200, 0: 3_000])
            try require(journal.record.phase == .owned && journal.record.globalOwnershipMayBeActive && journal.record.fanIDs == [0, 1],
                        "Successful simulated acquisition did not retain complete owned journal state")
            try require(log.values.filter { $0 == "global read" }.count == 3,
                        "Acquisition accepted global ownership before stable delayed readback")
            // Ownership verification intentionally requires two consecutive
            // stable readbacks per fan (policy.requiredStableReads == 2).
            let expected = [
                "baseline", "journal acquiringGlobal", "global acquire",
                "global read", "global read", "global read", "journal globalOwned",
                "journal acquiringFans", "manual 0", "target 0 3000",
                "verify 0 3000", "verify 0 3000",
                "journal acquiringFans", "manual 1", "target 1 3200",
                "verify 1 3200", "verify 1 3200",
                "journal owned"
            ]
            try require(log.values == expected, "Acquisition journal/hardware ordering changed: \(log.values)")
        }

        do {
            let log = EventLog()
            let journal = AcquisitionJournal(log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = AcquisitionHardware(log: log, globalReads: [0])
            let clock = ClockBox()
            let short = try FanOwnershipTransitionPolicy(timeoutSeconds: 0.5, requiredStableReads: 2)
            let executor = FanOwnershipAcquisitionExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: short,
                now: { clock.now },
                pause: { clock.advance(0.2) },
                permit: {}
            )

            try rejects { try executor.acquire(targets: [0: 3_000]) }
            try require(journal.record.phase == .recoveryRequired && journal.record.globalOwnershipMayBeActive,
                        "Timed-out global acquisition discarded conservative ownership risk")
            try require(!log.values.contains("manual 0"), "Fan was touched before global ownership verified")
        }

        do {
            let log = EventLog()
            let journal = AcquisitionJournal(log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = AcquisitionHardware(log: log, globalReads: [1, 1])
            hardware.verificationFailureFan = 0
            let clock = ClockBox()
            let executor = FanOwnershipAcquisitionExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.1) },
                permit: {}
            )

            try rejects { try executor.acquire(targets: [0: 3_000, 1: 3_100]) }
            try require(journal.record.phase == .recoveryRequired && journal.record.globalOwnershipMayBeActive && journal.record.fanIDs == [0],
                        "Failed fan verification lost the touched-fan recovery bit")
            try require(!log.values.contains("manual 1"), "Acquisition continued to a later fan after verification failure")
        }

        do {
            let log = EventLog()
            let journal = AcquisitionJournal(log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = AcquisitionHardware(log: log, globalReads: [1, 1])
            hardware.baselineFailure = true
            let clock = ClockBox()
            let executor = FanOwnershipAcquisitionExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.1) },
                permit: {}
            )

            try rejects { try executor.acquire(targets: [0: 3_000]) }
            try require(journal.record.isClean, "Rejected read-only acquisition baseline created recovery authority")
            try require(log.values == ["baseline"], "Baseline rejection touched journal or hardware: \(log.values)")
        }

        do {
            let log = EventLog()
            let journal = AcquisitionJournal(log: log)
            journal.failNextSave = true
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = AcquisitionHardware(log: log, globalReads: [1, 1])
            let clock = ClockBox()
            let executor = FanOwnershipAcquisitionExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.1) },
                permit: {}
            )

            try rejects { try executor.acquire(targets: [0: 3_000]) }
            try require(journal.record.isClean, "Failed pre-write journal save mutated acquisition state")
            try require(!log.values.contains("global acquire"), "Global hardware was touched after durable intent failed")
        }

        do {
            let log = EventLog()
            let journal = AcquisitionJournal(log: log)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = AcquisitionHardware(log: log, globalReads: [1, 1])
            let clock = ClockBox()
            let executor = FanOwnershipAcquisitionExecutor(
                stateMachine: machine,
                hardware: hardware,
                transitionPolicy: policy,
                now: { clock.now },
                pause: { clock.advance(0.1) },
                permit: {}
            )
            try rejects { try executor.acquire(targets: [:]) }
            try rejects { try executor.acquire(targets: [0: .nan]) }
            try require(journal.record.isClean && log.values.isEmpty, "Invalid acquisition targets performed work")
        }
    }


    static func ownershipTargetUpdateChecks() throws {
        final class ClockBox {
            var now = HostClock.now
            func advance(_ seconds: Double) { now &+= ticks(seconds) }
        }
        final class UpdateJournal: FanOwnershipRecoveryJournal {
            var record: FanOwnershipRecoveryRecord
            var saves: [FanOwnershipRecoveryRecord] = []
            var failNextSave = false

            init(_ record: FanOwnershipRecoveryRecord) { self.record = record }

            func load() throws -> FanOwnershipRecoveryRecord { record }

            func save(_ next: FanOwnershipRecoveryRecord) throws {
                if failNextSave {
                    failNextSave = false
                    throw Failure.simulated
                }
                record = next
                saves.append(next)
            }
        }

        final class UpdateHardware: FanOwnershipTargetHardware {
            var events: [String] = []
            var targetFailureFan: Int?
            var verificationFailureFan: Int?
            var verificationResponses: [Bool] = []
            var verificationIndex = 0

            func setFanTarget(_ id: Int, rpm: Double) throws {
                events.append("target \(id) \(Int(rpm))")
                if targetFailureFan == id { throw Failure.simulated }
            }

            func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool {
                events.append("verify \(id) \(Int(targetRPM))")
                if verificationIndex < verificationResponses.count {
                    defer { verificationIndex += 1 }
                    return verificationResponses[verificationIndex]
                }
                return verificationFailureFan != id
            }
        }

        func ownedRecord(_ ids: Set<Int> = [0, 1]) -> FanOwnershipRecoveryRecord {
            FanOwnershipRecoveryRecord(
                generation: 12,
                phase: .owned,
                globalOwnershipMayBeActive: true,
                fanIDs: ids
            )
        }

        do {
            let journal = UpdateJournal(ownedRecord())
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = UpdateHardware()
            let executor = FanOwnershipTargetUpdateExecutor(
                stateMachine: machine,
                hardware: hardware,
                permit: {}
            )

            try executor.update(targets: [1: 3_400, 0: 3_000])
            try require(
                hardware.events == ["target 0 3000", "verify 0 3000", "target 1 3400", "verify 1 3400"],
                "Owned target update repeated acquisition steps or changed deterministic fan ordering: \(hardware.events)"
            )
            try require(machine.record == ownedRecord(), "Successful target update changed ownership journal state")
            try require(journal.saves.isEmpty, "Successful target-only update rewrote the ownership journal unnecessarily")
        }

        // Physical M4 validation showed F0Tg readback can lag a successful write.
        // Production Override therefore requires two stable owned/target reads
        // within a bounded window rather than treating an old target as failure.
        do {
            let journal = UpdateJournal(ownedRecord([0]))
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = UpdateHardware()
            hardware.verificationResponses = [false, false, true, true]
            let clock = ClockBox()
            let executor = FanOwnershipTargetUpdateExecutor(
                stateMachine: machine,
                hardware: hardware,
                permit: {},
                transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 2, requiredStableReads: 2),
                now: { clock.now },
                pause: { clock.advance(0.2) }
            )

            try executor.update(targets: [0: 3_600])
            try require(
                hardware.events == [
                    "target 0 3600",
                    "verify 0 3600", "verify 0 3600", "verify 0 3600", "verify 0 3600"
                ],
                "Delayed owned target verification did not require two stable readbacks: \(hardware.events)"
            )
            try require(machine.record == ownedRecord([0]), "Delayed successful target update changed ownership journal state")
            try require(journal.saves.isEmpty, "Delayed successful target update rewrote the ownership journal")
        }

        do {
            let journal = UpdateJournal(ownedRecord())
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = UpdateHardware()
            let executor = FanOwnershipTargetUpdateExecutor(
                stateMachine: machine,
                hardware: hardware,
                permit: {}
            )

            try rejects { try executor.update(targets: [0: 3_000]) }
            try require(hardware.events.isEmpty && journal.saves.isEmpty,
                        "Changing the owned fan set reached hardware or journal writes")
            try require(machine.record == ownedRecord(), "Rejected fan-set change mutated ownership state")
        }

        do {
            let journal = UpdateJournal(ownedRecord())
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = UpdateHardware()
            hardware.verificationFailureFan = 0
            let executor = FanOwnershipTargetUpdateExecutor(
                stateMachine: machine,
                hardware: hardware,
                permit: {}
            )

            try rejects { try executor.update(targets: [0: 3_050, 1: 3_450]) }
            try require(
                machine.record.phase == .recoveryRequired &&
                    machine.record.globalOwnershipMayBeActive &&
                    machine.record.fanIDs == [0, 1],
                "Failed owned target verification did not preserve conservative recovery state"
            )
            try require(!hardware.events.contains("target 1 3450"),
                        "Target updates continued to later fans after verification failure")
        }

        do {
            let journal = UpdateJournal(ownedRecord())
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = UpdateHardware()
            var permits = 0
            let executor = FanOwnershipTargetUpdateExecutor(
                stateMachine: machine,
                hardware: hardware,
                permit: {
                    permits += 1
                    if permits == 1 { throw Failure.simulated }
                }
            )

            try rejects { try executor.update(targets: [0: 3_000, 1: 3_400]) }
            try require(hardware.events.isEmpty, "Revoked update permit still reached hardware")
            try require(machine.record.phase == .recoveryRequired && machine.record.fanIDs == [0, 1],
                        "Permit revocation while owned failed to force deterministic recovery")
        }

        do {
            let journal = UpdateJournal(.clean)
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = UpdateHardware()
            let executor = FanOwnershipTargetUpdateExecutor(
                stateMachine: machine,
                hardware: hardware,
                permit: {}
            )

            try rejects { try executor.update(targets: [0: 3_000]) }
            try require(hardware.events.isEmpty && journal.saves.isEmpty,
                        "Target update outside an owned session performed work")
        }

        do {
            let journal = UpdateJournal(ownedRecord())
            let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = UpdateHardware()
            let executor = FanOwnershipTargetUpdateExecutor(
                stateMachine: machine,
                hardware: hardware,
                permit: {}
            )

            try rejects { try executor.update(targets: [:]) }
            try rejects { try executor.update(targets: [0: .nan, 1: 3_400]) }
            try require(hardware.events.isEmpty && journal.saves.isEmpty,
                        "Invalid target update performed work")
        }
    }

    static func status(_ controller: FanControlCoordinator) async -> (Bool, HeliosFanState, String) {
        await withCheckedContinuation { continuation in controller.status { continuation.resume(returning: ($0, $1, $2)) } }
    }
    static func waitReady(_ controller: FanControlCoordinator) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await status(controller)).0 {
            guard ContinuousClock.now < deadline else { throw Failure.check("Controller did not initialize") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func calculate(_ controller: FanControlCoordinator, owner: UUID, sequence: UInt64 = 1,
                          mode: HeliosFanMode = .boost, rpm: Double = 0, temperature: Double = 90) async -> HeliosReplyCode {
        await withCheckedContinuation { continuation in
            controller.calculate(owner: owner, sequence: sequence, sample: HostClock.now, mode: mode, rpm: rpm, temperature: temperature) { code, _, _ in
                continuation.resume(returning: code)
            }
        }
    }

    static func coordinatorChecks() async throws {
        final class SoftReleaseEngine: FanControlDriving, @unchecked Sendable {
            private let lock = NSLock()
            private var storedState = HeliosFanState.system
            private var storedEvents: [String] = []

            var state: HeliosFanState {
                lock.lock(); defer { lock.unlock() }
                return storedState
            }

            var events: [String] {
                lock.lock(); defer { lock.unlock() }
                return storedEvents
            }

            func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
                try permit()
                lock.lock(); defer { lock.unlock() }
                storedState = mode == .override ? .override : .boost
                storedEvents.append("apply \(mode.rawValue) \(Int(rpm))")
            }

            func softReleaseTargets() -> [Double] { [5_200, 4_300, 3_400] }

            func applySoftReleaseTarget(_ rpm: Double, permit: () throws -> Void) throws {
                try permit()
                lock.lock(); defer { lock.unlock() }
                storedEvents.append("soft \(Int(rpm))")
            }

            func restore() throws {
                lock.lock(); defer { lock.unlock() }
                storedEvents.append("restore")
                storedState = .system
            }
        }

        let blocked = FanControlCoordinator(makeEngine: { throw Failure.check("Production gate constructed a writer") })
        let owner = UUID()
        blocked.bind(owner)
        try require(await calculate(blocked, owner: owner) == .controlUnavailable, "Unvalidated hardware accepted takeover")
        let blockedState = await status(blocked)
        try require(blockedState.1 == .system && blockedState.2 == FanControlCoordinator.validationRequired, "Production gate attempted to initialize the injected writer")
        let hardware = FakeFanHardware()
        let journal = FakeFanJournal()
        let engineFactoryCalls = LockedCounter()
        let controller = FanControlCoordinator(validationMessage: nil, makeEngine: {
            engineFactoryCalls.increment()
            return try FanControlEngine(hardware: hardware, journal: journal)
        })
        controller.bind(owner)
        try await waitReady(controller)
        try require(engineFactoryCalls.value == 0, "Ready coordinator eagerly opened the writer before a control request")

        // Explicit app release may decelerate cosmetically, but the same
        // coordinator must retain a separate immediate safety-release path.
        let softEngine = SoftReleaseEngine()
        let softOwner = UUID()
        let soft = FanControlCoordinator(
            validationMessage: nil,
            allowedModes: [.boost, .override],
            makeEngine: { softEngine },
            softReleaseStepDelaySeconds: 0.01
        )
        soft.bind(softOwner)
        try await waitReady(soft)
        try require(await calculate(soft, owner: softOwner) == .ok, "Soft-release fixture could not acquire control")
        await withCheckedContinuation { continuation in
            soft.release(owner: softOwner, graceful: true) { _, _ in continuation.resume() }
        }
        try require(Array(softEngine.events.suffix(4)) == ["soft 5200", "soft 4300", "soft 3400", "restore"],
                    "Explicit release did not execute the bounded soft-ramp sequence: \(softEngine.events)")
        try require((await status(soft)).1 == .system, "Soft release did not finish in System")

        // A fresh 95C calculation must force Boost in the privileged
        // coordinator even when the app asks for a low Manual target.
        let emergencyEngine = SoftReleaseEngine()
        let emergencyOwner = UUID()
        let emergencyController = FanControlCoordinator(
            validationMessage: nil,
            allowedModes: [.boost, .override],
            makeEngine: { emergencyEngine },
            softReleaseStepDelaySeconds: 0,
            emergencyMaximumCelsius: CoolingRulesSafetyProfile.emergencyMaximumCelsius
        )
        emergencyController.bind(emergencyOwner)
        try await waitReady(emergencyController)
        try require(await calculate(emergencyController, owner: emergencyOwner, mode: .override, rpm: 2400, temperature: 95) == .ok,
                    "Privileged 95C emergency floor rejected a valid calculation")
        try require(emergencyEngine.events.first == "apply \(HeliosFanMode.boost.rawValue) 2400",
                    "Privileged 95C emergency floor did not force Boost: \(emergencyEngine.events)")
        await withCheckedContinuation { continuation in
            emergencyController.release(owner: emergencyOwner, graceful: false) { _, _ in continuation.resume() }
        }

        let safetyBefore = softEngine.events.count
        try require(await calculate(soft, owner: softOwner, sequence: 2) == .ok, "Soft-release fixture could not reacquire")
        await withCheckedContinuation { continuation in
            soft.release(owner: softOwner, graceful: false) { _, _ in continuation.resume() }
        }
        let safetyEvents = Array(softEngine.events.dropFirst(safetyBefore))
        try require(safetyEvents.contains("restore") && !safetyEvents.contains(where: { $0.hasPrefix("soft ") }),
                    "Immediate safety release incorrectly waited for soft-ramp targets: \(safetyEvents)")
        await withCheckedContinuation { continuation in soft.shutdown { _ in continuation.resume() } }
        try require(await calculate(controller, owner: owner) == .ok, "Simulated control failed")
        try require(engineFactoryCalls.value == 1, "First control request did not lazily construct exactly one writer")
        try await Task.sleep(for: .milliseconds(5300))
        try require((await status(controller)).1 == .system && (try journal.load()).isEmpty, "Independent lease did not restore System")
        await withCheckedContinuation { continuation in controller.release(owner: owner) { _, _ in continuation.resume() } }
        hardware.setDelay(0.2)
        let before = hardware.events.count
        let pending = Task { await calculate(controller, owner: owner, sequence: 2) }
        try await Task.sleep(for: .milliseconds(50))
        await withCheckedContinuation { continuation in controller.release(owner: owner) { _, _ in continuation.resume() } }
        try require(await pending.value != .ok, "Cancelled in-flight write reported success")
        let lateEvents = Array(hardware.events.dropFirst(before))
        try require(lateEvents.contains("target 0") && !lateEvents.contains("manual 0"), "Cancellation did not exercise a genuinely in-flight write")
        try require((try hardware.mode(0)) == 0 && (try hardware.mode(1)) == 0, "Cancellation failed to roll back a late write")
        hardware.setDelay(0)
        await withCheckedContinuation { continuation in controller.release(owner: owner) { _, _ in continuation.resume() } }
        try require(await calculate(controller, owner: owner, sequence: 3) == .ok, "Could not rearm explicitly before shutdown test")
        await withCheckedContinuation { continuation in controller.shutdown { _ in continuation.resume() } }
        try require((try journal.load()).isEmpty && (try hardware.mode(0)) == 0, "Graceful shutdown did not restore an active override")
        try require(await calculate(controller, owner: owner, sequence: 4) == .invalidSession, "Shutdown accepted a new calculation")
        await withCheckedContinuation { continuation in blocked.shutdown { _ in continuation.resume() } }
        let stalledHardware = FakeFanHardware()
        let stalledJournal = FakeFanJournal()
        // Initial takeover now uses a deliberately separate 12-second
        // acquisition lease (steady-state control is still 5 seconds). Keep the
        // fake driver blocked beyond that acquisition deadline so this remains
        // a real watchdog-vs-stalled-I/O test rather than accidentally asserting
        // the old five-second acquisition behavior.
        stalledHardware.setDelay(13.5)
        let stalled = FanControlCoordinator(validationMessage: nil, makeEngine: {
            try FanControlEngine(hardware: stalledHardware, journal: stalledJournal)
        })
        stalled.bind(owner)
        try await waitReady(stalled)
        let stalledWrite = Task { await calculate(stalled, owner: owner) }
        try await Task.sleep(for: .milliseconds(12_700))
        try require((await status(stalled)).1 == .restoring, "Blocked hardware queue prevented acquisition-watchdog revocation")
        try require(await stalledWrite.value != .ok, "Late driver completion resurrected control")
        try require(!stalledHardware.events.contains("manual 0") && (try stalledJournal.load()).isEmpty, "Expired permit allowed another write or failed rollback")
        await withCheckedContinuation { continuation in stalled.shutdown { _ in continuation.resume() } }
    }
}
