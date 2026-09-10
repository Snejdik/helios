import Foundation

/// Durable ownership intent for the M4 global-ownership path. Phase 4.5
/// physically validated the transition/recovery semantics; Next12 reuses this
/// same state machine for a deliberately narrow production Boost backend. The
/// record remains conservative: if a write may have happened, risk stays
/// journaled until verified release has completed.
enum FanOwnershipRecoveryPhase: UInt8, Sendable {
    case system = 0
    case acquiringGlobal = 1
    case globalOwned = 2
    case acquiringFans = 3
    case owned = 4
    case releasingFans = 5
    case releasingGlobal = 6
    case recoveryRequired = 7
}

struct FanOwnershipRecoveryRecord: Equatable, Sendable {
    static let formatVersion: UInt8 = 2

    var generation: UInt64
    var phase: FanOwnershipRecoveryPhase
    var globalOwnershipMayBeActive: Bool
    var fanIDs: Set<Int>

    static let clean = FanOwnershipRecoveryRecord(
        generation: 0,
        phase: .system,
        globalOwnershipMayBeActive: false,
        fanIDs: []
    )

    var isClean: Bool {
        phase == .system && !globalOwnershipMayBeActive && fanIDs.isEmpty
    }

    var needsRecovery: Bool { !isClean }
}

struct FanOwnershipRecoveryPlan: Equatable, Sendable {
    let fanIDs: [Int]
    let clearGlobalOwnership: Bool

    init(record: FanOwnershipRecoveryRecord) {
        fanIDs = record.fanIDs.sorted()
        clearGlobalOwnership = record.globalOwnershipMayBeActive
    }

    var isEmpty: Bool { fanIDs.isEmpty && !clearGlobalOwnership }
}

protocol FanOwnershipRecoveryJournal: AnyObject {
    func load() throws -> FanOwnershipRecoveryRecord
    func save(_ record: FanOwnershipRecoveryRecord) throws
}

enum FanOwnershipRecoveryError: LocalizedError {
    case invalidTransition(String)
    case invalidFanID(Int)
    case invalidRecord
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let message): return "Invalid fan ownership recovery transition: \(message)"
        case .invalidFanID(let id): return "Invalid fan ID in ownership recovery record: \(id)"
        case .invalidRecord: return "Invalid fan ownership recovery record"
        case .corruptRecord: return "Corrupt fan ownership recovery journal"
        }
    }
}

/// Owns only durable intent transitions. Hardware actions remain external so the
/// production SMC path cannot accidentally become enabled by this Phase 4.4 work.
/// Every method that prepares a future hardware write persists the conservative
/// next state before returning to its caller.
final class FanOwnershipRecoveryStateMachine {
    private let journal: any FanOwnershipRecoveryJournal
    private(set) var record: FanOwnershipRecoveryRecord

    init(journal: any FanOwnershipRecoveryJournal) throws {
        self.journal = journal
        let loaded = try journal.load()
        try Self.validate(loaded)
        record = loaded
    }

    var recoveryPlan: FanOwnershipRecoveryPlan { FanOwnershipRecoveryPlan(record: record) }

    /// Must complete before a future `Ftst = 1` write is attempted.
    func prepareGlobalAcquisition() throws {
        guard record.isClean else {
            throw FanOwnershipRecoveryError.invalidTransition("new acquisition requires a clean System record")
        }
        try persist(
            phase: .acquiringGlobal,
            globalOwnershipMayBeActive: true,
            fanIDs: []
        )
    }

    /// Called only after stable readback confirms the global state is active.
    func confirmGlobalOwnership() throws {
        guard record.phase == .acquiringGlobal, record.globalOwnershipMayBeActive else {
            throw FanOwnershipRecoveryError.invalidTransition("global ownership was not being acquired")
        }
        try persist(
            phase: .globalOwned,
            globalOwnershipMayBeActive: true,
            fanIDs: record.fanIDs
        )
    }

    /// Must complete before touching the named fan. The bit intentionally means
    /// “may have been touched”, not “confirmed owned”.
    func prepareFanWrite(_ id: Int) throws {
        try Self.validateFanID(id)
        guard record.globalOwnershipMayBeActive,
              [.globalOwned, .acquiringFans].contains(record.phase) else {
            throw FanOwnershipRecoveryError.invalidTransition("fan write requires confirmed global acquisition")
        }
        var fanIDs = record.fanIDs
        fanIDs.insert(id)
        try persist(
            phase: .acquiringFans,
            globalOwnershipMayBeActive: true,
            fanIDs: fanIDs
        )
    }

    /// Called only after all requested fans have passed mode/target readback.
    func confirmOwned() throws {
        guard record.phase == .acquiringFans, record.globalOwnershipMayBeActive, !record.fanIDs.isEmpty else {
            throw FanOwnershipRecoveryError.invalidTransition("owned state requires journaled fans and global ownership")
        }
        try persist(
            phase: .owned,
            globalOwnershipMayBeActive: true,
            fanIDs: record.fanIDs
        )
    }

    /// Release never clears risk up front. It only changes the diagnostic phase.
    func beginRelease() throws {
        guard record.needsRecovery else { return }
        try persist(
            phase: .releasingFans,
            globalOwnershipMayBeActive: record.globalOwnershipMayBeActive,
            fanIDs: record.fanIDs
        )
    }

    /// Removes a fan only after automatic/System readback was independently verified.
    func confirmFanReleased(_ id: Int) throws {
        try Self.validateFanID(id)
        guard [.releasingFans, .recoveryRequired].contains(record.phase), record.fanIDs.contains(id) else {
            throw FanOwnershipRecoveryError.invalidTransition("fan was not pending restoration")
        }
        var fanIDs = record.fanIDs
        fanIDs.remove(id)
        try persist(
            phase: record.phase,
            globalOwnershipMayBeActive: record.globalOwnershipMayBeActive,
            fanIDs: fanIDs
        )
    }

    /// Must be persisted before a future `Ftst = 0` write. Phase 4.5 live
    /// evidence showed that per-fan automatic readback can remain ambiguous while
    /// global Ftst ownership is still active, so pending fan risk bits are carried
    /// across the global release instead of blocking it.
    func prepareGlobalRelease() throws {
        guard record.globalOwnershipMayBeActive else {
            throw FanOwnershipRecoveryError.invalidTransition("global release requires recorded global ownership risk")
        }
        try persist(
            phase: .releasingGlobal,
            globalOwnershipMayBeActive: true,
            fanIDs: record.fanIDs
        )
    }

    /// Clears only the global risk after stable consecutive `Ftst == 0`
    /// observations. Any pending fan bits remain durable and must be verified
    /// under released global ownership before the journal can become clean.
    func confirmGlobalReleased() throws {
        guard record.phase == .releasingGlobal, record.globalOwnershipMayBeActive else {
            throw FanOwnershipRecoveryError.invalidTransition("global release was not pending")
        }
        let pendingFans = record.fanIDs
        try persist(
            phase: pendingFans.isEmpty ? .system : .releasingFans,
            globalOwnershipMayBeActive: false,
            fanIDs: pendingFans
        )
    }

    /// Completes the rare fan-only recovery shape where no global ownership
    /// risk was recorded. This remains useful for fail-closed/migration cases
    /// and requires every fan risk bit to have been independently cleared.
    func confirmSystemAfterFanOnlyRecovery() throws {
        guard [.releasingFans, .recoveryRequired].contains(record.phase),
              !record.globalOwnershipMayBeActive,
              record.fanIDs.isEmpty else {
            throw FanOwnershipRecoveryError.invalidTransition("fan-only recovery still has unresolved ownership risk")
        }
        try persist(
            phase: .system,
            globalOwnershipMayBeActive: false,
            fanIDs: []
        )
    }

    /// Preserve all conservative risk information after any ambiguous failure.
    func requireRecovery() throws {
        guard record.needsRecovery else { return }
        try persist(
            phase: .recoveryRequired,
            globalOwnershipMayBeActive: record.globalOwnershipMayBeActive,
            fanIDs: record.fanIDs
        )
    }

    private func persist(phase: FanOwnershipRecoveryPhase, globalOwnershipMayBeActive: Bool, fanIDs: Set<Int>) throws {
        let next = FanOwnershipRecoveryRecord(
            generation: record.generation &+ 1,
            phase: phase,
            globalOwnershipMayBeActive: globalOwnershipMayBeActive,
            fanIDs: fanIDs
        )
        try Self.validate(next)
        // Save succeeds before in-memory state advances. A persistence failure
        // therefore cannot authorize the caller to proceed to a hardware write.
        try journal.save(next)
        record = next
    }

    private static func validate(_ record: FanOwnershipRecoveryRecord) throws {
        try record.fanIDs.forEach(validateFanID)
        if record.phase == .system {
            guard !record.globalOwnershipMayBeActive, record.fanIDs.isEmpty else {
                throw FanOwnershipRecoveryError.invalidRecord
            }
        }
        if [.globalOwned, .acquiringFans, .owned, .releasingGlobal].contains(record.phase) {
            guard record.globalOwnershipMayBeActive else { throw FanOwnershipRecoveryError.invalidRecord }
        }
    }

    private static func validateFanID(_ id: Int) throws {
        guard (0..<FanCodec.maximumFanCount).contains(id) else {
            throw FanOwnershipRecoveryError.invalidFanID(id)
        }
    }
}

/// Fixed-width v2 codec for a future root-owned disk journal. It deliberately
/// detects partial/corrupt records instead of trying to infer recovery state.
/// Disk activation is deferred until the global ownership engine itself exists.
enum FanOwnershipRecoveryCodec {
    static let encodedSize = 24
    private static let magic: [UInt8] = [0x48, 0x4C, 0x46, 0x32] // HLF2
    private static let checksumOffset = 16

    static func encode(_ record: FanOwnershipRecoveryRecord) throws -> Data {
        try record.fanIDs.forEach { id in
            guard (0..<FanCodec.maximumFanCount).contains(id) else {
                throw FanOwnershipRecoveryError.invalidFanID(id)
            }
        }
        var bytes = [UInt8](repeating: 0, count: encodedSize)
        bytes.replaceSubrange(0..<4, with: magic)
        bytes[4] = FanOwnershipRecoveryRecord.formatVersion
        bytes[5] = record.phase.rawValue
        bytes[6] = record.globalOwnershipMayBeActive ? 1 : 0
        bytes[7] = record.fanIDs.reduce(UInt8(0)) { $0 | (UInt8(1) << UInt8($1)) }
        for index in 0..<8 {
            bytes[8 + index] = UInt8(truncatingIfNeeded: record.generation >> UInt64(index * 8))
        }
        let checksum = fnv1a32(bytes[0..<checksumOffset])
        for index in 0..<4 {
            bytes[checksumOffset + index] = UInt8(truncatingIfNeeded: checksum >> UInt32(index * 8))
        }
        return Data(bytes)
    }

    static func decode(_ data: Data) throws -> FanOwnershipRecoveryRecord {
        let bytes = [UInt8](data)
        guard bytes.count == encodedSize,
              Array(bytes[0..<4]) == magic,
              bytes[4] == FanOwnershipRecoveryRecord.formatVersion,
              let phase = FanOwnershipRecoveryPhase(rawValue: bytes[5]),
              bytes[6] <= 1,
              bytes[20..<24].allSatisfy({ $0 == 0 }) else {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        var storedChecksum: UInt32 = 0
        for index in 0..<4 {
            storedChecksum |= UInt32(bytes[checksumOffset + index]) << UInt32(index * 8)
        }
        guard storedChecksum == fnv1a32(bytes[0..<checksumOffset]) else {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        var generation: UInt64 = 0
        for index in 0..<8 {
            generation |= UInt64(bytes[8 + index]) << UInt64(index * 8)
        }
        let fanIDs = Set((0..<FanCodec.maximumFanCount).filter { bytes[7] & (UInt8(1) << UInt8($0)) != 0 })
        let record = FanOwnershipRecoveryRecord(
            generation: generation,
            phase: phase,
            globalOwnershipMayBeActive: bytes[6] == 1,
            fanIDs: fanIDs
        )
        // Reuse the state machine's fail-closed structural validation without
        // mutating any journal or hardware.
        if record.phase == .system && (record.globalOwnershipMayBeActive || !record.fanIDs.isEmpty) {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        if [.globalOwned, .acquiringFans, .owned, .releasingGlobal].contains(record.phase),
           !record.globalOwnershipMayBeActive {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        return record
    }

    private static func fnv1a32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var hash: UInt32 = 2_166_136_261
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}


// MARK: - Recovery executor

/// Hardware-facing recovery operations are injected so ordering, delayed
/// readback, cancellation, and journal semantics stay testable. Production uses
/// both a recovery-only bootstrap conformer and, while live Boost is owned, the
/// narrower validated control conformer.
protocol FanOwnershipRecoveryHardware: AnyObject {
    func restoreFanToSystem(_ id: Int) throws
    func verifyFanIsSystem(_ id: Int) throws -> Bool
    func requestGlobalRelease() throws
    func readGlobalOwnership() throws -> UInt8
}

enum FanOwnershipRecoveryExecutorError: LocalizedError {
    case fanRestoreVerificationFailed(Int)
    case recoveryStatePersistenceFailed(primary: String, persistence: String)

    var errorDescription: String? {
        switch self {
        case .fanRestoreVerificationFailed(let id):
            return "Fan \(id) did not verify as restored to System control"
        case .recoveryStatePersistenceFailed(let primary, let persistence):
            return "Recovery failed (\(primary)); preserving recovery-required state also failed (\(persistence))"
        }
    }
}

/// Executes only a recovery/release plan against an injected backend. It does
/// not implement acquisition. Daemon startup/wake use the recovery-only backend;
/// an active production Boost session uses the same release algorithm.
///
/// Safety ordering:
/// 1. mark durable recovery intent before any recovery hardware action,
/// 2. request automatic mode for each journaled fan while retaining every risk bit,
/// 3. persist `releasingGlobal` before requesting global release,
/// 4. keep global risk set while delayed readback still reports the old state,
/// 5. after stable global release, verify each fan under Apple control before
///    clearing its risk bit and finally returning the journal to System.
final class FanOwnershipRecoveryExecutor {
    private let stateMachine: FanOwnershipRecoveryStateMachine
    private let hardware: any FanOwnershipRecoveryHardware
    private let poller: FanOwnershipTransitionPoller
    private let now: () -> UInt64
    private let pause: () throws -> Void
    private let permit: () throws -> Void

    init(
        stateMachine: FanOwnershipRecoveryStateMachine,
        hardware: any FanOwnershipRecoveryHardware,
        transitionPolicy: FanOwnershipTransitionPolicy,
        now: @escaping () -> UInt64,
        pause: @escaping () throws -> Void,
        permit: @escaping () throws -> Void
    ) {
        self.stateMachine = stateMachine
        self.hardware = hardware
        self.poller = FanOwnershipTransitionPoller(policy: transitionPolicy)
        self.now = now
        self.pause = pause
        self.permit = permit
    }

    func recover() throws {
        guard stateMachine.record.needsRecovery else { return }

        do {
            // Persist recovery mode before the first hardware action. Existing
            // risk flags/bits are preserved exactly.
            try stateMachine.requireRecovery()
            try stateMachine.beginRelease()

            let fanIDs = stateMachine.recoveryPlan.fanIDs

            if stateMachine.record.globalOwnershipMayBeActive {
                // First request the per-fan automatic transition, but do not
                // require final System verification while Ftst is still active.
                // Live Phase 4.5 evidence showed mode/target readback can settle
                // only after the global arbitration flag is released.
                for id in fanIDs {
                    try permit()
                    try hardware.restoreFanToSystem(id)
                }

                // Preserve all pending fan bits while releasing global state.
                try stateMachine.prepareGlobalRelease()
                try permit()
                try hardware.requestGlobalRelease()

                // A successful transport return is not treated as restoration.
                // Phase 4.3 proved global visibility can lag the write.
                try poller.wait(
                    expected: 0,
                    now: now,
                    read: { try self.hardware.readGlobalOwnership() },
                    pause: pause,
                    permit: permit
                )
                try stateMachine.confirmGlobalReleased()

                // Only after stable Ftst==0 do we verify each fan as Apple-managed.
                // Re-issuing the automatic request here is harmless for the
                // allowlisted validation backend and covers a delayed per-fan
                // transition without assuming synchronous firmware behavior.
                for id in fanIDs {
                    try permit()
                    try hardware.restoreFanToSystem(id)
                    try waitForFanSystem(id)
                    try stateMachine.confirmFanReleased(id)
                }
                // If no fan write had happened yet, stable global release already
                // moved the durable record directly to System. Do not force a
                // second fan-only transition on an already-clean record.
                if !stateMachine.record.isClean {
                    try stateMachine.confirmSystemAfterFanOnlyRecovery()
                }
            } else {
                // Fan-only recovery has no global arbitration to release.
                for id in fanIDs {
                    try permit()
                    try hardware.restoreFanToSystem(id)
                    try waitForFanSystem(id)
                    try stateMachine.confirmFanReleased(id)
                }
                try stateMachine.confirmSystemAfterFanOnlyRecovery()
            }
        } catch {
            let primary = error
            guard stateMachine.record.needsRecovery else { throw primary }
            do {
                try stateMachine.requireRecovery()
            } catch {
                throw FanOwnershipRecoveryExecutorError.recoveryStatePersistenceFailed(
                    primary: String(describing: primary),
                    persistence: String(describing: error)
                )
            }
            throw primary
        }
    }

    private func waitForFanSystem(_ id: Int) throws {
        let startedAt = now()
        var stableReads = 0
        while true {
            try permit()
            let observationTime = now()
            let age = HostClock.seconds(from: startedAt, to: observationTime)
            guard age >= 0 else { throw FanOwnershipTransitionError.clockRegression }
            guard age < poller.policy.timeoutSeconds else {
                throw FanOwnershipRecoveryExecutorError.fanRestoreVerificationFailed(id)
            }

            if try hardware.verifyFanIsSystem(id) {
                stableReads += 1
                if stableReads >= poller.policy.requiredStableReads { return }
            } else {
                stableReads = 0
            }
            try permit()
            try pause()
        }
    }
}

// MARK: - Acquisition executor

/// Narrow target surface shared by simulation fixtures and the production M4
/// Boost backend. Concrete production implementations must keep their own write
/// allowlist narrower than this generic protocol.
protocol FanOwnershipTargetHardware: AnyObject {
    func setFanTarget(_ id: Int, rpm: Double) throws
    func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool
}

/// M4 takeover operations. The executor owns ordering, deadlines and permit
/// checks; hardware conformers expose only one bounded write attempt per call.
protocol FanOwnershipAcquisitionHardware: FanOwnershipTargetHardware {
    /// Read-only arbitration check that MUST run before the durable journal is
    /// marked as possibly owning Ftst. If this rejects because another
    /// controller is already active, no Helios recovery write is authorized.
    func validateGlobalAcquisitionBaseline() throws
    func requestGlobalAcquisition() throws
    func readGlobalOwnership() throws -> UInt8
    func readFanMode(_ id: Int) throws -> UInt8
    func requestFanManual(_ id: Int) throws
}

enum FanOwnershipAcquisitionExecutorError: LocalizedError {
    case invalidTargets
    case fanManualTransitionFailed(Int, UInt8)
    case fanVerificationFailed(Int)
    case recoveryStatePersistenceFailed(primary: String, persistence: String)

    var errorDescription: String? {
        switch self {
        case .invalidTargets:
            return "Fan ownership acquisition requires at least one finite positive per-fan target"
        case .fanManualTransitionFailed(let id, let mode):
            return "Fan \(id) did not reach manual mode before the bounded deadline (last mode \(mode))"
        case .fanVerificationFailed(let id):
            return "Fan \(id) did not verify as manually owned at the requested target"
        case .recoveryStatePersistenceFailed(let primary, let persistence):
            return "Acquisition failed (\(primary)); preserving recovery-required state also failed (\(persistence))"
        }
    }
}

/// Models the physically validated M4 entry sequence:
/// read-only clean baseline -> durable global intent -> request global ownership
/// -> stable readback -> durable per-fan intent -> manual mode -> target ->
/// stable readback verification.
///
/// Any ambiguity leaves the conservative v2 journal in `recoveryRequired`.
/// The caller must run the separately tested recovery executor before another
/// acquisition can be considered. A transport-success return is never enough
/// to advance durable ownership state.
final class FanOwnershipAcquisitionExecutor {
    private let stateMachine: FanOwnershipRecoveryStateMachine
    private let hardware: any FanOwnershipAcquisitionHardware
    private let poller: FanOwnershipTransitionPoller
    private let now: () -> UInt64
    private let pause: () throws -> Void
    private let permit: () throws -> Void
    private let manualRetryIntervalSeconds: Double
    private let manualTimeoutSeconds: Double

    init(
        stateMachine: FanOwnershipRecoveryStateMachine,
        hardware: any FanOwnershipAcquisitionHardware,
        transitionPolicy: FanOwnershipTransitionPolicy,
        now: @escaping () -> UInt64,
        pause: @escaping () throws -> Void,
        permit: @escaping () throws -> Void,
        manualRetryIntervalSeconds: Double = 0,
        manualTimeoutSeconds: Double? = nil
    ) {
        self.stateMachine = stateMachine
        self.hardware = hardware
        self.poller = FanOwnershipTransitionPoller(policy: transitionPolicy)
        self.now = now
        self.pause = pause
        self.permit = permit
        self.manualRetryIntervalSeconds = manualRetryIntervalSeconds.isFinite && manualRetryIntervalSeconds > 0
            ? manualRetryIntervalSeconds
            : 0
        if let manualTimeoutSeconds, manualTimeoutSeconds.isFinite, manualTimeoutSeconds > 0 {
            self.manualTimeoutSeconds = manualTimeoutSeconds
        } else {
            self.manualTimeoutSeconds = transitionPolicy.timeoutSeconds
        }
    }

    func acquire(targets: [Int: Double]) throws {
        guard !targets.isEmpty,
              targets.allSatisfy({ id, rpm in
                  (0..<FanCodec.maximumFanCount).contains(id) && rpm.isFinite && rpm > 0
              }) else {
            throw FanOwnershipAcquisitionExecutorError.invalidTargets
        }

        do {
            // Detect an already-active external/stale controller while the
            // durable record is still clean. If this read-only check rejects,
            // Helios must not create recovery risk and must never clear a flag
            // it did not attempt to acquire.
            try permit()
            try hardware.validateGlobalAcquisitionBaseline()
            try permit()

            // This save must finish before a future Ftst/global write. A crash
            // after the hardware write but before visible readback therefore
            // cannot lose evidence that global ownership may become active.
            try stateMachine.prepareGlobalAcquisition()
            try permit()
            try hardware.requestGlobalAcquisition()

            // Phase 4.3 observed delayed visibility. Require stable consecutive
            // `1` observations instead of trusting the write acknowledgement.
            try poller.wait(
                expected: 1,
                now: now,
                read: { try self.hardware.readGlobalOwnership() },
                pause: pause,
                permit: permit
            )
            try stateMachine.confirmGlobalOwnership()

            for id in targets.keys.sorted() {
                guard let rpm = targets[id] else { continue }
                // Persist fan risk before either manual-mode or target write.
                try stateMachine.prepareFanWrite(id)
                // Live M4 validation observed several retryable 0x82 responses
                // after Ftst became visible. The executor, not the hardware,
                // owns the retry loop so every write attempt is preceded by a
                // fresh cancellation/lease permit.
                try waitForFanManual(id)
                try permit()
                try hardware.setFanTarget(id, rpm: rpm)

                // Phase 4.5 live validation showed that a successful F0Tg
                // transport reply does not guarantee the target readback is
                // immediately visible. Treat per-fan ownership verification
                // like Ftst: bounded, cancellation-aware and stable across
                // consecutive observations.
                try waitForFanOwned(id, targetRPM: rpm)
            }

            try stateMachine.confirmOwned()
        } catch {
            let primary = error
            guard stateMachine.record.needsRecovery else { throw primary }
            do {
                try stateMachine.requireRecovery()
            } catch {
                throw FanOwnershipAcquisitionExecutorError.recoveryStatePersistenceFailed(
                    primary: String(describing: primary),
                    persistence: String(describing: error)
                )
            }
            throw primary
        }
    }


    private func waitForFanManual(_ id: Int) throws {
        let startedAt = now()
        var lastMode: UInt8 = 0
        while true {
            try permit()
            let observationTime = now()
            let age = HostClock.seconds(from: startedAt, to: observationTime)
            guard age >= 0 else { throw FanOwnershipTransitionError.clockRegression }
            guard age < manualTimeoutSeconds else {
                throw FanOwnershipAcquisitionExecutorError.fanManualTransitionFailed(id, lastMode)
            }

            let mode = try hardware.readFanMode(id)
            lastMode = mode
            if mode == 1 { return }
            guard mode == 0 || mode == 3 else {
                throw FanOwnershipAcquisitionExecutorError.fanManualTransitionFailed(id, mode)
            }

            try permit()
            try hardware.requestFanManual(id)

            // The validated Mac16,1 firmware returned 0x82 when F0Md writes were
            // repeated too aggressively. After each bounded write attempt, poll
            // read-only mode during a settle interval before another write. This
            // matches the successful physical validation cadence while remaining
            // cancellation-aware throughout the wait.
            if manualRetryIntervalSeconds > 0 {
                let retryStarted = now()
                while true {
                    try permit()
                    let retryNow = now()
                    let totalAge = HostClock.seconds(from: startedAt, to: retryNow)
                    guard totalAge >= 0 else { throw FanOwnershipTransitionError.clockRegression }
                    guard totalAge < manualTimeoutSeconds else {
                        throw FanOwnershipAcquisitionExecutorError.fanManualTransitionFailed(id, lastMode)
                    }
                    let retryAge = HostClock.seconds(from: retryStarted, to: retryNow)
                    guard retryAge >= 0 else { throw FanOwnershipTransitionError.clockRegression }

                    let settledMode = try hardware.readFanMode(id)
                    lastMode = settledMode
                    if settledMode == 1 { return }
                    guard settledMode == 0 || settledMode == 3 else {
                        throw FanOwnershipAcquisitionExecutorError.fanManualTransitionFailed(id, settledMode)
                    }
                    if retryAge >= manualRetryIntervalSeconds { break }
                    try permit()
                    try pause()
                }
            } else {
                try permit()
                try pause()
            }
        }
    }

    private func waitForFanOwned(_ id: Int, targetRPM: Double) throws {
        let startedAt = now()
        var stableReads = 0
        while true {
            try permit()
            let observationTime = now()
            let age = HostClock.seconds(from: startedAt, to: observationTime)
            guard age >= 0 else { throw FanOwnershipTransitionError.clockRegression }
            guard age < poller.policy.timeoutSeconds else {
                throw FanOwnershipAcquisitionExecutorError.fanVerificationFailed(id)
            }

            if try hardware.verifyFanOwned(id, targetRPM: targetRPM) {
                stableReads += 1
                if stableReads >= poller.policy.requiredStableReads { return }
            } else {
                stableReads = 0
            }
            try permit()
            try pause()
        }
    }
}


// MARK: - Owned target update executor

enum FanOwnershipTargetUpdateExecutorError: LocalizedError {
    case invalidTargets
    case notOwned
    case fanSetChanged
    case fanVerificationFailed(Int)
    case recoveryStatePersistenceFailed(primary: String, persistence: String)

    var errorDescription: String? {
        switch self {
        case .invalidTargets:
            return "Owned fan target update requires finite positive per-fan targets"
        case .notOwned:
            return "Fan targets can only be updated from a fully verified owned state"
        case .fanSetChanged:
            return "The active fan set cannot change during an owned session"
        case .fanVerificationFailed(let id):
            return "Fan \(id) did not verify after an owned target update"
        case .recoveryStatePersistenceFailed(let primary, let persistence):
            return "Target update failed (\(primary)); preserving recovery-required state also failed (\(persistence))"
        }
    }
}

/// Models the steady-state path after acquisition: the global/manual ownership
/// transition is NOT repeated for every fresh thermal sample. Only targets for
/// the already journaled/verified fan set may change.
///
/// Safety rules:
/// - every update starts from durable `.owned`,
/// - the fan set is immutable for the lifetime of that ownership session,
/// - each hardware action is preceded by an injected permit,
/// - every target write is followed by ownership/target verification,
/// - any cancellation, transport error, or verification failure marks the
///   durable state `recoveryRequired`; the next allowed action is release/recovery.
///
/// Production Override and cosmetic soft release use this path after ownership
/// is already established. Production supplies a bounded stable-read policy so
/// delayed F0Tg visibility cannot be mistaken for a failed target update.
final class FanOwnershipTargetUpdateExecutor {
    private let stateMachine: FanOwnershipRecoveryStateMachine
    private let hardware: any FanOwnershipTargetHardware
    private let permit: () throws -> Void
    private let transitionPolicy: FanOwnershipTransitionPolicy?
    private let now: () -> UInt64
    private let pause: () throws -> Void

    init(
        stateMachine: FanOwnershipRecoveryStateMachine,
        hardware: any FanOwnershipTargetHardware,
        permit: @escaping () throws -> Void,
        transitionPolicy: FanOwnershipTransitionPolicy? = nil,
        now: @escaping () -> UInt64 = { HostClock.now },
        pause: @escaping () throws -> Void = {}
    ) {
        self.stateMachine = stateMachine
        self.hardware = hardware
        self.permit = permit
        self.transitionPolicy = transitionPolicy
        self.now = now
        self.pause = pause
    }

    func update(targets: [Int: Double]) throws {
        guard !targets.isEmpty,
              targets.allSatisfy({ id, rpm in
                  (0..<FanCodec.maximumFanCount).contains(id) && rpm.isFinite && rpm > 0
              }) else {
            throw FanOwnershipTargetUpdateExecutorError.invalidTargets
        }
        guard stateMachine.record.phase == .owned,
              stateMachine.record.globalOwnershipMayBeActive else {
            throw FanOwnershipTargetUpdateExecutorError.notOwned
        }
        guard Set(targets.keys) == stateMachine.record.fanIDs else {
            throw FanOwnershipTargetUpdateExecutorError.fanSetChanged
        }

        do {
            for id in targets.keys.sorted() {
                guard let rpm = targets[id] else { continue }
                try permit()
                try hardware.setFanTarget(id, rpm: rpm)
                try verifyTarget(id, rpm: rpm)
            }
        } catch {
            let primary = error
            do {
                try stateMachine.requireRecovery()
            } catch {
                throw FanOwnershipTargetUpdateExecutorError.recoveryStatePersistenceFailed(
                    primary: String(describing: primary),
                    persistence: String(describing: error)
                )
            }
            throw primary
        }
    }

    private func verifyTarget(_ id: Int, rpm: Double) throws {
        guard let transitionPolicy else {
            try permit()
            guard try hardware.verifyFanOwned(id, targetRPM: rpm) else {
                throw FanOwnershipTargetUpdateExecutorError.fanVerificationFailed(id)
            }
            return
        }

        let startedAt = now()
        var stableReads = 0
        while true {
            try permit()
            let observationTime = now()
            let age = HostClock.seconds(from: startedAt, to: observationTime)
            guard age >= 0 else { throw FanOwnershipTransitionError.clockRegression }
            guard age < transitionPolicy.timeoutSeconds else {
                throw FanOwnershipTargetUpdateExecutorError.fanVerificationFailed(id)
            }

            if try hardware.verifyFanOwned(id, targetRPM: rpm) {
                stableReads += 1
                if stableReads >= transitionPolicy.requiredStableReads { return }
            } else {
                stableReads = 0
            }
            try permit()
            try pause()
        }
    }
}
