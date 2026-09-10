import Foundation

/// Diagnostic liveness only. Hardware state and its independent fresh-sample
/// lease live in FanControlCoordinator; heartbeats never renew that lease.
struct DiagnosticLease: Sendable {
    static let window: Duration = .seconds(5)
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var ready = false
    private(set) var lastSequence: UInt64 = 0
    private(set) var reason: HeliosDisarmReason = .startup

    mutating func begin(now: ContinuousClock.Instant) {
        ready = false
        lastSequence = 0
        deadline = now.advanced(by: Self.window)
    }

    mutating func completeHandshake(now: ContinuousClock.Instant) -> Bool {
        guard !ready, deadline != nil, !expire(now: now) else { return false }
        ready = true
        deadline = now.advanced(by: Self.window)
        return true
    }

    mutating func completeHeartbeat(sequence: UInt64, now: ContinuousClock.Instant) -> Bool {
        guard ready, !expire(now: now), lastSequence < UInt64.max, sequence == lastSequence + 1 else { return false }
        lastSequence = sequence
        deadline = now.advanced(by: Self.window)
        return true
    }

    @discardableResult mutating func expire(now: ContinuousClock.Instant) -> Bool {
        guard let deadline, now >= deadline else { return false }
        disarm(.leaseExpired)
        return true
    }

    mutating func disarm(_ reason: HeliosDisarmReason) {
        ready = false
        deadline = nil
        self.reason = reason
    }
}
