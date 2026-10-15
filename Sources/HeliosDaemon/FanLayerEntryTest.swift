import Foundation
import OSLog

/// Outcome of the mandatory first test on an unvalidated model + OS build
/// (PLAN_0_3_0 M2.4, decision 2). Stored by the helper; the app only reads it.
enum FanLayerEntryTestState: Int, Sendable {
    case notRun = 0
    case passed = 1
    case failed = 2

    var label: String {
        switch self {
        case .notRun: "Not run"
        case .passed: "Passed"
        case .failed: "Failed"
        }
    }
}

enum FanLayerEntryTestOutcome: Equatable, Sendable {
    case passed
    /// The hardware did not behave as expected; this model + build stays off for good.
    case failed(String)
    /// Stopped for a reason that says nothing final about the hardware (too warm, a
    /// takeover macOS refused or delayed, a failed read). Nothing is stored; the user may
    /// try again.
    case inconclusive(String)
}

/// The entry test: take every fan at its factory minimum (the quietest level a takeover
/// can hold), verify by readback once a second for 20 seconds, then hand the fans back to
/// macOS and verify that too. It uses the very same journal, executors and writer as the
/// layer, so a crash mid-test is recovered by the normal start-up path. It never commands
/// more than the factory minimum and it aborts above `abortCelsius`.
final class FanLayerEntryTest {
    static let holdSeconds = 20.0
    /// Stop (inconclusive) when the Mac is this warm: the test is about the takeover,
    /// not about cooling, and macOS should keep full control of a hot Mac.
    static let abortCelsius = 85.0
    /// Hard bound on the whole run, acquisition included.
    static let totalBudgetSeconds = 60.0

    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanEntryTest")
    private let profile: FanLayerProfile
    private let stateMachine: FanOwnershipRecoveryStateMachine
    private let hardware: any FanLayerControlHardware
    private let thermals: any FanLayerThermalSource
    private let now: () -> UInt64
    private let pause: () throws -> Void
    private let holdSeconds: Double

    init(profile: FanLayerProfile, stateMachine: FanOwnershipRecoveryStateMachine,
         hardware: any FanLayerControlHardware, thermals: any FanLayerThermalSource,
         now: @escaping () -> UInt64 = { HostClock.now },
         pause: @escaping () throws -> Void = { Thread.sleep(forTimeInterval: 0.10) },
         holdSeconds: Double = FanLayerEntryTest.holdSeconds) {
        self.profile = profile
        self.stateMachine = stateMachine
        self.hardware = hardware
        self.thermals = thermals
        self.now = now
        self.pause = pause
        self.holdSeconds = holdSeconds
    }

    func run() -> FanLayerEntryTestOutcome {
        guard profile.tier != .unsupported, !profile.fans.isEmpty else {
            return .inconclusive("This Mac has no supported fan surface.")
        }
        guard stateMachine.record.isClean else {
            return .inconclusive("Fan recovery has to finish first.")
        }
        do {
            guard try thermals.maximumSoCCelsius() < Self.abortCelsius else {
                return .inconclusive("The Mac is too warm for the fan test right now.")
            }
        } catch {
            return .inconclusive("Temperatures could not be read: \(error.localizedDescription)")
        }
        let started = now()
        let permit: () throws -> Void = { [now] in
            let age = HostClock.seconds(from: started, to: now())
            guard age >= 0, age < Self.totalBudgetSeconds else {
                throw TelemetryError.unavailable("The fan test ran out of time")
            }
        }
        let targets = Dictionary(uniqueKeysWithValues: profile.fans.map { ($0.id, ceil($0.minimumRPM)) })
        logger.notice("Fan entry test started (\(self.profile.strategy.rawValue, privacy: .public), \(self.profile.fans.count) fan(s)) on \(self.profile.identity.summary, privacy: .public).")

        var outcome: FanLayerEntryTestOutcome = .passed
        do {
            let policy = try FanOwnershipTransitionPolicy(
                timeoutSeconds: FanLayerTimings.transitionTimeoutSeconds, requiredStableReads: 2)
            let acquire = FanOwnershipAcquisitionExecutor(
                stateMachine: stateMachine, hardware: hardware, transitionPolicy: policy,
                now: now, pause: pause, permit: permit,
                manualRetryIntervalSeconds: FanLayerEngine.manualRetryIntervalSeconds,
                manualTimeoutSeconds: FanLayerEngine.manualTimeoutSeconds)
            try acquire.acquire(targets: targets)
            outcome = hold(targets: targets, permit: permit)
        } catch {
            // macOS may refuse or delay a takeover for a while (firmware cooldown after
            // other fan activity). That says nothing final about this Mac, so the user may
            // try again later; only a fan that was taken and then misbehaved fails the test.
            outcome = .inconclusive("macOS did not hand over the fans this time: \(error.localizedDescription) Try again in a few minutes.")
        }
        // Always hand the fans back and verify it, whatever happened above.
        if let failure = restore() {
            outcome = .failed(failure)
        }
        switch outcome {
        case .passed: logger.notice("Fan entry test passed.")
        case .failed(let reason): logger.error("Fan entry test failed: \(reason, privacy: .public)")
        case .inconclusive(let reason): logger.notice("Fan entry test stopped: \(reason, privacy: .public)")
        }
        return outcome
    }

    private func hold(targets: [Int: Double], permit: () throws -> Void) -> FanLayerEntryTestOutcome {
        let holdStarted = now()
        var lastCheck: UInt64?
        do {
            while HostClock.seconds(from: holdStarted, to: now()) < holdSeconds {
                try permit()
                if lastCheck.map({ HostClock.seconds(from: $0, to: now()) >= 1 }) ?? true {
                    lastCheck = now()
                    for (id, rpm) in targets.sorted(by: { $0.key < $1.key }) {
                        guard try hardware.verifyFanOwned(id, targetRPM: rpm) else {
                            return .failed("Fan \(id + 1) did not hold its target; macOS took it back.")
                        }
                    }
                    if try thermals.maximumSoCCelsius() >= Self.abortCelsius {
                        return .inconclusive("The Mac got too warm during the fan test.")
                    }
                }
                try pause()
            }
        } catch {
            return .inconclusive("A fan reading failed during the test: \(error.localizedDescription)")
        }
        return .passed
    }

    /// nil when every fan is verified back under macOS; otherwise the failure.
    private func restore() -> String? {
        guard stateMachine.record.needsRecovery else { return nil }
        do {
            let policy = try FanOwnershipTransitionPolicy(
                timeoutSeconds: FanLayerTimings.transitionTimeoutSeconds, requiredStableReads: 10)
            let recovery = FanOwnershipRecoveryExecutor(
                stateMachine: stateMachine, hardware: hardware, transitionPolicy: policy,
                now: now, pause: pause, permit: {})
            try recovery.recover()
            guard stateMachine.record.isClean, try hardware.readGlobalOwnership() == 0 else {
                return "The fans did not return cleanly to macOS."
            }
            for fan in profile.fans where !(try hardware.verifyFanIsSystem(fan.id)) {
                return "Fan \(fan.id + 1) did not return to macOS control."
            }
            return nil
        } catch {
            return "Returning the fans to macOS failed: \(error.localizedDescription)"
        }
    }
}

/// One record per Mac: the model + build it was run on and the outcome. A new macOS
/// build needs a new test. Root-owned 0600 like the consent record.
protocol FanLayerEntryTestStore: AnyObject {
    func state(for identity: FanLayerMachineIdentity) -> FanLayerEntryTestState
    func record(_ state: FanLayerEntryTestState, for identity: FanLayerMachineIdentity) throws
}

final class FanLayerDiskEntryTestStore: FanLayerEntryTestStore {
    static let path = "/var/db/com.snejda.Helios.fan-layer-entry-test"
    private static let header = "helios-fan-layer-entry-test-v1"

    func state(for identity: FanLayerMachineIdentity) -> FanLayerEntryTestState {
        guard geteuid() == 0, let descriptor = try? FanLayerPrivateFile.open(Self.path) else { return .notRun }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count > 0 else { return .notRun }
        let lines = String(decoding: bytes.prefix(count), as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 4, lines[0] == Self.header,
              lines[1] == identity.modelIdentifier, lines[2] == identity.osBuild,
              let raw = Int(lines[3]), let state = FanLayerEntryTestState(rawValue: raw) else { return .notRun }
        return state
    }

    func record(_ state: FanLayerEntryTestState, for identity: FanLayerMachineIdentity) throws {
        guard geteuid() == 0 else { throw TelemetryError.unavailable("The fan test result is stored by the privileged helper") }
        let descriptor = try FanLayerPrivateFile.open(Self.path)
        defer { close(descriptor) }
        let data = Array("\(Self.header)\n\(identity.modelIdentifier)\n\(identity.osBuild)\n\(state.rawValue)\n".utf8)
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count, ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Persist fan entry test", errno)
        }
    }
}
