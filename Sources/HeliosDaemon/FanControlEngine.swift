import Foundation

/// Small coordinator-facing surface shared by the legacy test engine and the
/// physically validated production M4 Boost engine. The coordinator never sees
/// raw SMC keys or write primitives.
protocol FanControlDriving: AnyObject {
    var state: HeliosFanState { get }
    func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws
    /// Optional human-facing deceleration path used only for an explicit app
    /// release. Safety restoration never waits for these cosmetic steps.
    func softReleaseTargets() -> [Double]
    func applySoftReleaseTarget(_ rpm: Double, permit: () throws -> Void) throws
    func restore() throws
}

extension FanControlDriving {
    func softReleaseTargets() -> [Double] { [] }
    func applySoftReleaseTarget(_ rpm: Double, permit: () throws -> Void) throws {
        _ = rpm
        try permit()
    }
}

/// Legacy per-fan engine retained for focused tests while the production path is
/// migrated to the durable v2 global-ownership state machine below.
final class FanControlEngine: FanControlDriving {
    private let hardware: any FanHardware
    private let journal: any FanOwnershipJournal
    private var owned: Set<Int> = []
    private(set) var state = HeliosFanState.system

    init(hardware: any FanHardware, journal: any FanOwnershipJournal) throws {
        self.hardware = hardware
        self.journal = journal
        owned = try journal.load()
        if !owned.isEmpty {
            state = .recoveryRequired
            try restore() // Recovery precedes all new sessions/calculations.
        }
    }

    func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
        if mode == .system { try restore(); return }
        guard state != .recoveryRequired else { throw TelemetryError.unavailable("Fan restoration must complete first") }
        guard rpm.isFinite else { throw TelemetryError.invalidData("Non-finite fan request") }
        do {
            try permit()
            let channels = try hardware.channels() // Re-read factory bounds each calculation.
            guard !channels.isEmpty else { throw TelemetryError.unavailable("This Mac has no fans") }
            for channel in channels {
                guard channel.minimum.isFinite, channel.maximum.isFinite, channel.minimum >= 0,
                      channel.maximum > channel.minimum, channel.maximum <= 30_000 else {
                    throw TelemetryError.invalidData("Invalid factory fan limits")
                }
                let current = try hardware.mode(channel.id)
                guard owned.contains(channel.id) ? current == 1 : [0, 3].contains(current) else {
                    throw TelemetryError.unavailable("Fan ownership changed or another controller is active")
                }
            }
            try permit()
            let previouslyOwned = owned
            let touched = owned.union(channels.map(\.id))
            if touched != owned {
                try journal.save(touched)
                owned = touched
            }
            for channel in channels {
                let target = mode == .boost ? channel.maximum : min(channel.maximum, max(channel.minimum, rpm))
                try permit()
                try hardware.setTarget(channel, rpm: target)
                try permit()
                if !previouslyOwned.contains(channel.id) { try hardware.setManual(channel.id) }
                try permit()
                try hardware.verify(channel, rpm: target)
            }
            try permit()
            state = mode == .boost ? .boost : .override
        } catch {
            let original = error
            // Includes partial writes and cancellation while a driver call was in
            // flight. Attempt every owned fan even when one reset fails.
            try restore()
            throw original
        }
    }

    func restore() throws {
        state = owned.isEmpty ? .system : .restoring
        var first: (any Error)?
        for id in owned.sorted() {
            do { try hardware.restoreAutomatic(id) }
            catch { if first == nil { first = error } }
        }
        if let first { state = .recoveryRequired; throw first }
        do { try journal.save([]) }
        catch { state = .recoveryRequired; throw error }
        owned = []
        state = .system
    }
}

/// Production fan-control backend for the single physically validated
/// Mac16,1 / 25G83 profile. Boost remains factory max; Override accepts only an
/// integral daemon-clamped target inside the discovered/validated 2317...6550 RPM
/// range. No min/max, firmware-test, or second-fan writes are exposed.
///
/// Acquisition uses the durable v2 journal and the physically validated ordering:
/// global risk -> Ftst=1 -> stable readback -> fan risk -> bounded F0Md arbitration
/// -> target -> stable owned verification. Once owned, target changes reuse the
/// target-update executor and never repeat Ftst/F0Md acquisition.
final class ProductionM4FanControlEngine: FanControlDriving {
    private let stateMachine: FanOwnershipRecoveryStateMachine
    private let hardware: ProductionM4FanControlHardware
    private let acquisitionPolicy: FanOwnershipTransitionPolicy
    private let releasePolicy: FanOwnershipTransitionPolicy
    private(set) var state = HeliosFanState.system
    private var currentTargetRPM: Double?

    init() throws {
        let journal = try ProductionFanOwnershipRecoveryJournal()
        let stateMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        guard stateMachine.record.isClean else {
            throw TelemetryError.unavailable("Production takeover requires startup recovery to finish first")
        }
        let hardware = try ProductionM4FanControlHardware()
        try hardware.requireCleanSystemBaseline()

        self.stateMachine = stateMachine
        self.hardware = hardware
        acquisitionPolicy = try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 2)
        // Release must survive the race where Ftst=1 was accepted but has not
        // become visible yet when cancellation begins.
        releasePolicy = try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 10)
    }

    func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
        guard mode == .boost || mode == .override else {
            throw TelemetryError.unavailable("Only Boost and validated Override are enabled by the production safety profile")
        }
        guard stateMachine.record.phase == .owned || stateMachine.record.isClean else {
            state = .recoveryRequired
            throw TelemetryError.unavailable("Fan ownership journal requires recovery before another takeover")
        }

        do {
            let target = try ProductionM4FanControlProfile.target(for: mode, requestedRPM: rpm)
            if stateMachine.record.isClean {
                try withoutActuallyEscaping(permit) { escapingPermit in
                    let acquire = FanOwnershipAcquisitionExecutor(
                        stateMachine: stateMachine,
                        hardware: hardware,
                        transitionPolicy: acquisitionPolicy,
                        now: { HostClock.now },
                        pause: { Thread.sleep(forTimeInterval: 0.10) },
                        permit: escapingPermit,
                        manualRetryIntervalSeconds: 1.0,
                        manualTimeoutSeconds: 8.0
                    )
                    try acquire.acquire(targets: [ProductionM4FanControlProfile.fanID: target])
                }
                currentTargetRPM = target
            } else if let currentTargetRPM, abs(currentTargetRPM - target) <= 0.5 {
                // Fresh samples renew the lease but same-target control stays
                // write-free. Verify ownership so external interference fails closed.
                try permit()
                guard try hardware.verifyFanOwned(ProductionM4FanControlProfile.fanID, targetRPM: target) else {
                    try stateMachine.requireRecovery()
                    throw TelemetryError.unavailable("Fan ownership changed or the requested target was not retained")
                }
            } else {
                try withoutActuallyEscaping(permit) { escapingPermit in
                    let update = FanOwnershipTargetUpdateExecutor(
                        stateMachine: stateMachine,
                        hardware: hardware,
                        permit: escapingPermit,
                        transitionPolicy: acquisitionPolicy,
                        now: { HostClock.now },
                        pause: { Thread.sleep(forTimeInterval: 0.10) }
                    )
                    try update.update(targets: [ProductionM4FanControlProfile.fanID: target])
                }
                currentTargetRPM = target
            }
            try permit()
            state = mode == .boost ? .boost : .override
        } catch {
            if stateMachine.record.needsRecovery { state = .recoveryRequired }
            throw error
        }
    }

    func softReleaseTargets() -> [Double] {
        guard stateMachine.record.phase == .owned else { return [] }
        return ProductionM4FanControlProfile.softReleaseTargets(from: currentTargetRPM)
    }

    func applySoftReleaseTarget(_ rpm: Double, permit: () throws -> Void) throws {
        guard stateMachine.record.phase == .owned else {
            throw TelemetryError.unavailable("Soft release requires a fully owned fan")
        }
        let target = try ProductionM4FanControlProfile.target(for: .override, requestedRPM: rpm)
        try withoutActuallyEscaping(permit) { escapingPermit in
            let update = FanOwnershipTargetUpdateExecutor(
                stateMachine: stateMachine,
                hardware: hardware,
                permit: escapingPermit,
                transitionPolicy: acquisitionPolicy,
                now: { HostClock.now },
                pause: { Thread.sleep(forTimeInterval: 0.10) }
            )
            try update.update(targets: [ProductionM4FanControlProfile.fanID: target])
        }
        currentTargetRPM = target
    }

    func restore() throws {
        guard stateMachine.record.needsRecovery else {
            currentTargetRPM = nil
            state = .system
            return
        }
        state = .restoring
        let recovery = FanOwnershipRecoveryExecutor(
            stateMachine: stateMachine,
            hardware: hardware,
            transitionPolicy: releasePolicy,
            now: { HostClock.now },
            pause: { Thread.sleep(forTimeInterval: 0.10) },
            // Recovery is intentionally independent of the revoked control lease.
            // Once risk is journaled, cleanup must continue even if the app died.
            permit: {}
        )
        do {
            try recovery.recover()
            guard stateMachine.record.isClean else {
                throw TelemetryError.unavailable("Production fan recovery did not reach a clean journal")
            }
            try hardware.requireCleanSystemBaseline()
            currentTargetRPM = nil
            state = .system
        } catch {
            state = .recoveryRequired
            throw error
        }
    }
}
