import Foundation

/// This lock is never held across IOKit. Revocation does not wait for a driver.
final class ControlLease: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var owner: UUID?
    private var sample: UInt64 = 0
    private var sequence: UInt64 = 0
    private var revoked = false
    private var active = false
    private var leaseAnchor: UInt64 = 0
    private var acquisitionStarted: UInt64?

    static let steadyTimeoutSeconds = 5.0
    static let acquisitionTimeoutSeconds = 12.0

    func accept(owner: UUID, sequence: UInt64, sample: UInt64, now: UInt64) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let age = HostClock.seconds(from: sample, to: now)
        if active && acquisitionStarted == nil && HostClock.seconds(from: leaseAnchor, to: now) >= Self.steadyTimeoutSeconds {
            active = false; revoked = true; acquisitionStarted = nil; generation &+= 1
        }
        guard age >= 0, age <= 3, !revoked, self.owner == nil || self.owner == owner,
              sample > self.sample, sequence > self.sequence else {
            throw TelemetryError.unavailable("Stale, repeated, or disarmed control calculation")
        }
        self.owner = owner
        self.sequence = sequence
        self.sample = sample
        leaseAnchor = sample
        acquisitionStarted = nil
        active = true
        generation &+= 1
        return generation
    }

    /// A fresh calculation may need longer than the steady 5-second lease while
    /// Ftst/F0Md firmware arbitration settles. This does not relax cancellation:
    /// revocation/generation changes are still observed on every permit check,
    /// and the transaction has its own hard 12-second deadline.
    func beginAcquisition(_ token: UInt64, now: UInt64 = HostClock.now) throws {
        lock.lock(); defer { lock.unlock() }
        let age = HostClock.seconds(from: leaseAnchor, to: now)
        guard active, !revoked, generation == token, acquisitionStarted == nil,
              age >= 0, age < Self.steadyTimeoutSeconds else {
            throw TelemetryError.unavailable("Fan acquisition lease could not be armed")
        }
        acquisitionStarted = now
    }

    func checkAcquisition(_ token: UInt64, now: UInt64 = HostClock.now) throws {
        lock.lock(); defer { lock.unlock() }
        guard active, !revoked, generation == token, let started = acquisitionStarted else {
            throw TelemetryError.unavailable("Fan acquisition lease expired or was cancelled")
        }
        let age = HostClock.seconds(from: started, to: now)
        guard age >= 0, age < Self.acquisitionTimeoutSeconds else {
            throw TelemetryError.unavailable("Fan acquisition lease expired or was cancelled")
        }
    }

    /// After a bounded acquisition succeeds, give the app one ordinary steady
    /// lease window to deliver the next genuinely fresh telemetry calculation.
    /// Keep the original sample/sequence history so replayed calculations remain
    /// rejected.
    func completeAcquisition(_ token: UInt64, now: UInt64 = HostClock.now) throws {
        lock.lock(); defer { lock.unlock() }
        guard active, !revoked, generation == token, let started = acquisitionStarted else {
            throw TelemetryError.unavailable("Fan acquisition lease expired or was cancelled")
        }
        let age = HostClock.seconds(from: started, to: now)
        guard age >= 0, age < Self.acquisitionTimeoutSeconds else {
            throw TelemetryError.unavailable("Fan acquisition lease expired or was cancelled")
        }
        acquisitionStarted = nil
        leaseAnchor = now
    }

    func check(_ token: UInt64, now: UInt64 = HostClock.now) throws {
        lock.lock(); defer { lock.unlock() }
        let age = HostClock.seconds(from: leaseAnchor, to: now)
        guard active, !revoked, acquisitionStarted == nil, generation == token,
              age >= 0, age < Self.steadyTimeoutSeconds else {
            throw TelemetryError.unavailable("Fan control lease expired or was cancelled")
        }
    }

    func expire(now: UInt64 = HostClock.now) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        let expired: Bool
        if let started = acquisitionStarted {
            expired = HostClock.seconds(from: started, to: now) >= Self.acquisitionTimeoutSeconds
        } else {
            expired = HostClock.seconds(from: leaseAnchor, to: now) >= Self.steadyTimeoutSeconds
        }
        guard expired else { return false }
        active = false; revoked = true; acquisitionStarted = nil; generation &+= 1
        return true
    }


    /// Atomically convert a still-valid failed calculation into a recovery-only
    /// lease generation. The caller may perform hardware restoration, then call
    /// `completeRecoverableFailureReset`. Any concurrent safety revocation bumps
    /// `generation`, so the later completion cannot accidentally re-arm control.
    ///
    /// Sample/sequence history is intentionally retained across this transition.
    func beginRecoverableFailureReset(_ token: UInt64, acquisition: Bool, now: UInt64 = HostClock.now) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard active, !revoked, generation == token else { return nil }

        if acquisition {
            guard let started = acquisitionStarted else { return nil }
            let age = HostClock.seconds(from: started, to: now)
            guard age >= 0, age < Self.acquisitionTimeoutSeconds else { return nil }
        } else {
            guard acquisitionStarted == nil else { return nil }
            let age = HostClock.seconds(from: leaseAnchor, to: now)
            guard age >= 0, age < Self.steadyTimeoutSeconds else { return nil }
        }

        active = false
        revoked = true
        acquisitionStarted = nil
        generation &+= 1
        return generation
    }

    /// Re-arm after independently verified System restoration only if nothing
    /// revoked the recovery generation in the meantime. Returns false on a race
    /// and deliberately leaves the lease disarmed.
    @discardableResult
    func completeRecoverableFailureReset(_ recoveryGeneration: UInt64, clearHistory: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active, revoked, acquisitionStarted == nil, generation == recoveryGeneration else { return false }
        owner = nil
        if clearHistory { sample = 0; sequence = 0 }
        leaseAnchor = 0
        revoked = false
        generation &+= 1
        return true
    }

    func revoke(owner: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil || self.owner == owner else { return }
        active = false; revoked = true; acquisitionStarted = nil; generation &+= 1
    }

    /// Called only after verified System restoration.
    func reset(clearHistory: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        owner = nil
        if clearHistory { sample = 0; sequence = 0 }
        active = false
        revoked = false
        leaseAnchor = 0
        acquisitionStarted = nil
        generation &+= 1
    }
}
