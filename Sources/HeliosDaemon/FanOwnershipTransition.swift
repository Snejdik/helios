import Foundation

/// Pure, hardware-agnostic tracking for the delayed global ownership state
/// observed during the Phase 4.3 M4 validation. This type performs no SMC I/O
/// and is not wired into the production takeover path while validation is gated.
struct FanOwnershipTransitionPolicy: Sendable {
    let timeoutSeconds: Double
    let requiredStableReads: Int

    init(timeoutSeconds: Double, requiredStableReads: Int) throws {
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, requiredStableReads > 0 else {
            throw TelemetryError.invalidData("Invalid ownership transition policy")
        }
        self.timeoutSeconds = timeoutSeconds
        self.requiredStableReads = requiredStableReads
    }
}

enum FanOwnershipTransitionError: LocalizedError {
    case clockRegression
    case unexpectedGlobalState(UInt8)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .clockRegression:
            return "Fan ownership transition clock moved backwards"
        case .unexpectedGlobalState(let value):
            return "Unexpected global fan ownership state \(value)"
        case .timedOut:
            return "Fan ownership transition did not stabilize before its deadline"
        }
    }
}

/// Requires consecutive readback observations before a delayed firmware state
/// is treated as stable. Values other than the two source-backed Ftst states
/// (0 and 1) fail closed instead of being guessed or coerced.
struct FanOwnershipTransitionTracker {
    private let expected: UInt8
    private let startedAt: UInt64
    private let policy: FanOwnershipTransitionPolicy
    private var stableReads = 0

    init(expected: UInt8, startedAt: UInt64, policy: FanOwnershipTransitionPolicy) throws {
        guard expected == 0 || expected == 1 else {
            throw FanOwnershipTransitionError.unexpectedGlobalState(expected)
        }
        self.expected = expected
        self.startedAt = startedAt
        self.policy = policy
    }

    func checkDeadline(at now: UInt64) throws {
        let age = HostClock.seconds(from: startedAt, to: now)
        guard age >= 0 else { throw FanOwnershipTransitionError.clockRegression }
        guard age < policy.timeoutSeconds else { throw FanOwnershipTransitionError.timedOut }
    }

    mutating func observe(_ value: UInt8, at now: UInt64) throws -> Bool {
        try checkDeadline(at: now)
        guard value == 0 || value == 1 else {
            throw FanOwnershipTransitionError.unexpectedGlobalState(value)
        }

        if value == expected {
            stableReads += 1
        } else {
            stableReads = 0
        }
        return stableReads >= policy.requiredStableReads
    }
}

/// Polling orchestration is fully injected so tests can model delayed firmware
/// visibility without sleeping, and future hardware integration must explicitly
/// provide a bounded wait, readback source, and lease/cancellation permit.
struct FanOwnershipTransitionPoller {
    let policy: FanOwnershipTransitionPolicy

    func wait(
        expected: UInt8,
        now: () -> UInt64,
        read: () throws -> UInt8,
        pause: () throws -> Void,
        permit: () throws -> Void
    ) throws {
        var tracker = try FanOwnershipTransitionTracker(expected: expected, startedAt: now(), policy: policy)
        while true {
            try permit()
            let observationTime = now()
            try tracker.checkDeadline(at: observationTime)
            let value = try read()
            if try tracker.observe(value, at: observationTime) { return }
            try permit()
            try pause()
        }
    }
}
