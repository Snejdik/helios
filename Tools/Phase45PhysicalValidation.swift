import Foundation
import Dispatch
import Darwin
import IOKit
import IOKit.pwr_mgt

// Phase 4.5 Step 2 is deliberately a standalone validation executable.
// It is NOT compiled into Helios.app or HeliosDaemon and therefore cannot
// accidentally open a production Ftst write path.

enum Phase45ValidationError: LocalizedError {
    case rootRequired
    case explicitConfirmationRequired
    case preflightBlocked(String)
    case journalNotClean(String)
    case cancelled
    case transactionTimedOut
    case unsupportedFan(Int)
    case unexpectedMode(UInt8)
    case unexpectedGlobal(UInt8)
    case manualModeTimedOut
    case physicalResponseNotObserved(Double)
    case finalBaselineNotRestored(String)
    case crashHarnessOnly
    case crashMarkerUnavailable
    case powerNotificationsUnavailable
    case sleepRequestTimedOut
    case wakeReprobeTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .rootRequired:
            return "Phase 4.5 physical validation must run as root"
        case .explicitConfirmationRequired:
            return "Physical validation requires the exact confirmation token"
        case .preflightBlocked(let text):
            return "Read-only preflight is not ready for validation: \(text)"
        case .journalNotClean(let text):
            return "Validation recovery journal is not clean: \(text)"
        case .cancelled:
            return "Physical validation was cancelled"
        case .transactionTimedOut:
            return "Physical validation exceeded its total deadline"
        case .unsupportedFan(let id):
            return "Physical validation is restricted to fan \(id) on Mac16,1"
        case .unexpectedMode(let mode):
            return "Unexpected fan mode \(mode)"
        case .unexpectedGlobal(let value):
            return "Unexpected Ftst value \(value)"
        case .manualModeTimedOut:
            return "F0Md did not reach manual mode before the bounded deadline"
        case .physicalResponseNotObserved(let rpm):
            return "Target was accepted, but physical fan rotation was not observed (max actual \(Int(rpm.rounded())) RPM)"
        case .finalBaselineNotRestored(let text):
            return "Final System baseline did not verify: \(text)"
        case .crashHarnessOnly:
            return "Crash arming is restricted to the Phase 4.5 crash harness"
        case .crashMarkerUnavailable:
            return "Crash harness ready marker could not be created safely"
        case .powerNotificationsUnavailable:
            return "System power notifications could not be registered; sleep/wake validation cannot proceed"
        case .sleepRequestTimedOut:
            return "No SystemWillSleep event was observed before the validation timeout"
        case .wakeReprobeTimedOut(let text):
            return "Fresh AppleSMC reprobe after wake did not reach a clean baseline: \(text)"
        }
    }
}

final class Phase45CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func request() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isRequested: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func check() throws {
        if isRequested { throw Phase45ValidationError.cancelled }
    }
}

func phase45ImmediatePrint(_ text: String) {
    let bytes = Array((text + "\n").utf8)
    _ = bytes.withUnsafeBytes { buffer in
        Darwin.write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
    }
}

func installPhase45SignalHandlers(_ flag: Phase45CancellationFlag) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler { flag.request() }
        source.resume()
        return source
    }
}

enum Phase45CrashReadyMarker {
    static let path = "/var/db/com.snejda.Helios.phase45-crash-ready-v1"

    static func createForCurrentProcess() throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Phase45ValidationError.crashMarkerUnavailable }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == 0,
              info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0 else {
            throw Phase45ValidationError.crashMarkerUnavailable
        }

        let text = "\(getpid())\n"
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count, fsync(fd) == 0 else {
            throw Phase45ValidationError.crashMarkerUnavailable
        }
    }
}

final class Phase45DiskRecoveryJournal: FanOwnershipRecoveryJournal {
    private let descriptor: Int32
    private static let path = "/var/db/com.snejda.Helios.phase45-validation-v2"

    init() throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }
        let fd = open(Self.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw TelemetryError.kernel("Open Phase 4.5 recovery journal", errno) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == 0,
              info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw TelemetryError.unavailable("Phase 4.5 recovery journal is not private or is already in use")
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func load() throws -> FanOwnershipRecoveryRecord {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw TelemetryError.kernel("Stat Phase 4.5 recovery journal", errno)
        }
        if info.st_size == 0 { return .clean }
        guard info.st_size == FanOwnershipRecoveryCodec.encodedSize else {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        var bytes = [UInt8](repeating: 0, count: FanOwnershipRecoveryCodec.encodedSize)
        let count = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count == bytes.count else { throw TelemetryError.kernel("Read Phase 4.5 recovery journal", errno) }
        return try FanOwnershipRecoveryCodec.decode(Data(bytes))
    }

    func save(_ record: FanOwnershipRecoveryRecord) throws {
        let data = try FanOwnershipRecoveryCodec.encode(record)
        let written = data.withUnsafeBytes { buffer in
            pwrite(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard written == data.count,
              ftruncate(descriptor, off_t(data.count)) == 0,
              fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Persist Phase 4.5 recovery journal", errno)
        }
    }
}

final class Phase45SMCHardware: FanOwnershipAcquisitionHardware, FanOwnershipRecoveryHardware {
    private let client: SMCClient
    private let reader: SMCFanReader
    private var connection: io_connect_t = 0
    private let baseline: FanOwnershipPreflightSnapshot

    init(baseline: FanOwnershipPreflightSnapshot) throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }
        guard baseline.isReadyForValidation else {
            throw Phase45ValidationError.preflightBlocked(baseline.reasons.joined(separator: "; "))
        }
        guard baseline.evidence.modelIdentifier == "Mac16,1",
              baseline.evidence.osBuild == "25G83",
              baseline.evidence.fanCount == 1,
              baseline.evidence.fans.count == 1 else {
            throw Phase45ValidationError.preflightBlocked("physical writer is pinned to Mac16,1 / 25G83 / one fan")
        }
        self.baseline = baseline
        client = SMCClient(transport: try SMCIOKitTransport())
        reader = SMCFanReader(client: client)

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TelemetryError.unavailable("AppleSMC unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Open Phase 4.5 SMC writer", result) }
    }

    deinit {
        if connection != 0 { _ = IOServiceClose(connection) }
    }

    func validateGlobalAcquisitionBaseline() throws {
        let current = try readGlobalOwnership()
        guard current == 0 else { throw Phase45ValidationError.unexpectedGlobal(current) }
        let mode = try reader.mode(0)
        guard mode == 0 || mode == 3 else { throw Phase45ValidationError.unexpectedMode(mode) }
    }

    func requestGlobalAcquisition() throws {
        try write("Ftst", payload: [1])
    }

    func readGlobalOwnership() throws -> UInt8 {
        let value = try client.value("Ftst")
        guard value.info.type == "ui8 ", value.info.size == 1, value.bytes.count == 1 else {
            throw TelemetryError.invalidData("Ftst metadata changed during validation")
        }
        guard value.bytes[0] == 0 || value.bytes[0] == 1 else {
            throw Phase45ValidationError.unexpectedGlobal(value.bytes[0])
        }
        return value.bytes[0]
    }

    func readFanMode(_ id: Int) throws -> UInt8 {
        try requireFan0(id)
        return try reader.mode(0)
    }

    func requestFanManual(_ id: Int) throws {
        try requireFan0(id)
        let global = try readGlobalOwnership()
        guard global == 1 else { throw Phase45ValidationError.unexpectedGlobal(global) }
        let mode = try reader.mode(0)
        if mode == 1 { return }
        guard mode == 0 || mode == 3 else { throw Phase45ValidationError.unexpectedMode(mode) }
        do {
            try write("F0Md", payload: [1])
        } catch TelemetryError.smc(_, let code) where code == 0x82 {
            // Retryable protected-mode arbitration response. The shared
            // acquisition executor owns the bounded retry loop and performs a
            // fresh permit check before every subsequent write attempt.
        }
    }

    func setFanTarget(_ id: Int, rpm: Double) throws {
        try requireFan0(id)
        guard try readGlobalOwnership() == 1, try reader.mode(0) == 1 else {
            throw TelemetryError.unavailable("Target write requires confirmed Ftst=1 and F0Md=1")
        }
        let fan = try baselineFan0()
        guard rpm.isFinite, rpm >= fan.minimumRPM, rpm <= fan.maximumRPM else {
            throw TelemetryError.invalidData("Validation target is outside factory limits")
        }
        try write("F0Tg", payload: try encodeRPM(rpm, type: fan.targetType, minimum: fan.minimumRPM, maximum: fan.maximumRPM))
    }

    func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool {
        try requireFan0(id)
        guard try readGlobalOwnership() == 1, try reader.mode(0) == 1 else { return false }
        let target = try reader.rpm(0, "Tg")
        return abs(target - targetRPM) <= 0.5
    }

    func restoreFanToSystem(_ id: Int) throws {
        try requireFan0(id)
        let mode = try reader.mode(0)
        guard [UInt8(0), UInt8(1), UInt8(3)].contains(mode) else {
            throw Phase45ValidationError.unexpectedMode(mode)
        }
        // Phase 4.5 live evidence showed that once automatic mode is requested,
        // Apple may immediately repopulate F0Tg with the factory minimum (2317
        // RPM on this Mac). Zero target is therefore not a System invariant and
        // recovery must not fight the firmware by repeatedly clearing F0Tg.
        if mode == 1 { try write("F0Md", payload: [0]) }
    }

    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        try requireFan0(id)
        let mode = try reader.mode(0)
        let target = try reader.rpm(0, "Tg")
        let actual = try reader.rpm(0, "Ac")
        return [UInt8(0), UInt8(3)].contains(mode) && target.isFinite && actual.isFinite
    }

    func requestGlobalRelease() throws {
        // Durable risk, not an immediate asynchronous readback, decides whether
        // release is required. Always enqueue Ftst=0 once recovery begins.
        try write("Ftst", payload: [0])
    }

    func actualRPM() throws -> Double { try reader.rpm(0, "Ac") }
    func targetRPM() throws -> Double { try reader.rpm(0, "Tg") }
    func mode() throws -> UInt8 { try reader.mode(0) }

    private func baselineFan0() throws -> FanOwnershipPreflightFan {
        guard let fan = baseline.evidence.fans.first, fan.id == 0 else {
            throw Phase45ValidationError.unsupportedFan(0)
        }
        return fan
    }

    private func requireFan0(_ id: Int) throws {
        guard id == 0 else { throw Phase45ValidationError.unsupportedFan(id) }
    }

    private func encodeRPM(_ rpm: Double, type: String, minimum: Double, maximum: Double) throws -> [UInt8] {
        let clamped = min(maximum, max(minimum, rpm))
        switch type {
        case "flt ":
            let value = Float(clamped)
            guard value.isFinite else { throw TelemetryError.invalidData("Invalid float RPM") }
            return (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
        case "fpe2":
            let raw = UInt16((clamped * 4).rounded())
            return [UInt8(raw >> 8), UInt8(truncatingIfNeeded: raw)]
        default:
            throw TelemetryError.invalidData("Unsupported validation target encoding")
        }
    }

    private func write(_ key: String, payload: [UInt8]) throws {
        let info = try client.keyInfo(key)
        switch key {
        case "Ftst":
            guard info.type == "ui8 ", info.size == 1, payload.count == 1, payload[0] == 0 || payload[0] == 1 else {
                throw TelemetryError.invalidData("Rejected Ftst validation write")
            }
        case "F0Md":
            guard info.type == "ui8 ", info.size == 1, payload.count == 1, payload[0] == 0 || payload[0] == 1 else {
                throw TelemetryError.invalidData("Rejected F0Md validation write")
            }
        case "F0Tg":
            let fan = try baselineFan0()
            guard info.type == fan.targetType,
                  ((info.type == "flt " && info.size == 4) || (info.type == "fpe2" && info.size == 2)),
                  payload.count == Int(info.size) else {
                throw TelemetryError.invalidData("Rejected F0Tg validation write")
            }
        default:
            throw TelemetryError.invalidData("Physical validation write key is not allowlisted")
        }

        var frame = try SMCCodec.frame(SMCReadRequest(command: .bytes, key: key, dataSize: info.size))
        frame[42] = 6 // kSMCWriteBytes; validation-only local sink.
        frame.replaceSubrange(48..<(48 + payload.count), with: payload)
        var output = [UInt8](repeating: 0, count: SMCCodec.frameSize)
        var outputSize = output.count
        let result = frame.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { reply in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count,
                                          reply.baseAddress, &outputSize)
            }
        }
        let raw = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("WRITE \(key) type='\(info.type)' bytes=[\(raw)] IOReturn=0x\(String(UInt32(bitPattern: result), radix: 16)) SMCResult=0x\(String(output[40], radix: 16))")
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Write \(key)", result) }
        guard outputSize == SMCCodec.frameSize else { throw TelemetryError.invalidData("Truncated validation write response") }
        guard output[40] == 0 else { throw TelemetryError.smc(key, output[40]) }
    }
}

struct Phase45PhysicalValidator {
    static let confirmation = "HELIOS-PHASE45-MAC16,1-25G83"
    static let staleGlobalConfirmation = "HELIOS-CLEAR-STALE-FTST-MAC16,1-25G83"
    static let crashHarnessConfirmation = "HELIOS-PHASE45-CRASH-WRAPPER-V1"
    static let targetRPM = 3000.0

    let cancellation: Phase45CancellationFlag

    func run() throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }

        let preflight = try SMCFanOwnershipPreflightReader().read()
        print(preflight.diagnosticText)
        guard preflight.isReadyForValidation else {
            throw Phase45ValidationError.preflightBlocked(preflight.reasons.joined(separator: "; "))
        }

        let journal = try Phase45DiskRecoveryJournal()
        let stateMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        guard stateMachine.record.isClean else {
            throw Phase45ValidationError.journalNotClean("phase=\(stateMachine.record.phase) fans=\(stateMachine.record.fanIDs.sorted()) globalRisk=\(stateMachine.record.globalOwnershipMayBeActive)")
        }

        let hardware = try Phase45SMCHardware(baseline: preflight)
        let transactionStart = HostClock.now
        let permit: () throws -> Void = {
            try self.cancellation.check()
            if HostClock.seconds(from: transactionStart, to: HostClock.now) >= 25.0 {
                throw Phase45ValidationError.transactionTimedOut
            }
        }
        let pause: () throws -> Void = {
            try permit()
            Thread.sleep(forTimeInterval: 0.10)
        }

        let acquirePolicy = try FanOwnershipTransitionPolicy(timeoutSeconds: 2.5, requiredStableReads: 2)
        let releasePolicy = try FanOwnershipTransitionPolicy(timeoutSeconds: 3.5, requiredStableReads: 2)
        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: stateMachine,
            hardware: hardware,
            transitionPolicy: acquirePolicy,
            now: { HostClock.now },
            pause: pause,
            permit: permit
        )
        let recovery = FanOwnershipRecoveryExecutor(
            stateMachine: stateMachine,
            hardware: hardware,
            transitionPolicy: releasePolicy,
            now: { HostClock.now },
            pause: pause,
            permit: permit
        )

        var primaryFailure: Error?
        var maxActual = 0.0
        do {
            print("\n=== ACQUIRE: Ftst -> F0Md -> F0Tg 3000 RPM ===")
            try acquire.acquire(targets: [0: Self.targetRPM])
            print("OWNED: Ftst=\(try hardware.readGlobalOwnership()) mode=\(try hardware.mode()) target=\(Int((try hardware.targetRPM()).rounded()))")

            let fan0 = preflight.evidence.fans[0]
            let baselineActual = fan0.actualRPM
            // The first trial used >=1000 RPM, which is meaningless on this
            // Mac because Apple may already idle the fan at its 2317 RPM
            // factory minimum. Require a material increase toward the 3000 RPM
            // command instead of merely observing any rotation.
            let responseThreshold = max(
                baselineActual + 200.0,
                fan0.minimumRPM + 200.0,
                Self.targetRPM * 0.90
            )
            print("PHYSICAL RESPONSE threshold=\(Int(responseThreshold.rounded())) baseline=\(Int(baselineActual.rounded()))")

            let observationStart = HostClock.now
            while HostClock.seconds(from: observationStart, to: HostClock.now) < 6.0 {
                try permit()
                let actual = try hardware.actualRPM()
                maxActual = max(maxActual, actual)
                print("OBSERVE actual=\(Int(actual.rounded())) target=\(Int((try hardware.targetRPM()).rounded()))")
                if actual >= responseThreshold { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if maxActual < responseThreshold {
                primaryFailure = Phase45ValidationError.physicalResponseNotObserved(maxActual)
            }
        } catch {
            primaryFailure = error
        }

        print("\n=== RESTORE: automatic request -> Ftst 0 -> stable System verify ===")
        do {
            try recovery.recover()
        } catch {
            print("RESTORE FAILED: \(error.localizedDescription)")
            print("EMERGENCY: rerun this executable immediately with --restore-only")
            throw error
        }

        let final = try SMCFanOwnershipPreflightReader().read()
        print("\n=== FINAL READ-ONLY BASELINE ===")
        print(final.diagnosticText)
        guard final.isReadyForValidation else {
            throw Phase45ValidationError.finalBaselineNotRestored(final.reasons.joined(separator: "; "))
        }

        if let primaryFailure { throw primaryFailure }
        print("\nPHASE45 PHYSICAL VALIDATION PASSED")
        print("Observed fan response up to \(Int(maxActual.rounded())) RPM and verified deterministic graceful restoration.")
        print("Crash/SIGKILL restoration is NOT validated by this result; production takeover remains gated.")
    }

    func preflightOnly() throws {
        let preflight = try SMCFanOwnershipPreflightReader().read()
        print(preflight.diagnosticText)
        if !preflight.isReadyForValidation { Foundation.exit(2) }
    }

    /// Phase 4.5 Step 3 intentionally acquires ownership and then waits for the
    /// external root-owned harness to SIGKILL this process. There is deliberately
    /// no cleanup path after the ready marker is committed: recovery must happen
    /// in a fresh process from the durable journal, which is the property under test.
    func armCrashAndHold() throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }

        let preflight = try SMCFanOwnershipPreflightReader().read()
        print(preflight.diagnosticText)
        guard preflight.isReadyForValidation else {
            throw Phase45ValidationError.preflightBlocked(preflight.reasons.joined(separator: "; "))
        }

        let journal = try Phase45DiskRecoveryJournal()
        let stateMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        guard stateMachine.record.isClean else {
            throw Phase45ValidationError.journalNotClean("phase=\(stateMachine.record.phase) fans=\(stateMachine.record.fanIDs.sorted()) globalRisk=\(stateMachine.record.globalOwnershipMayBeActive)")
        }

        let hardware = try Phase45SMCHardware(baseline: preflight)
        let started = HostClock.now
        let permit: () throws -> Void = {
            try self.cancellation.check()
            if HostClock.seconds(from: started, to: HostClock.now) >= 25.0 {
                throw Phase45ValidationError.transactionTimedOut
            }
        }
        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: stateMachine,
            hardware: hardware,
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 2.5, requiredStableReads: 2),
            now: { HostClock.now },
            pause: {
                try permit()
                Thread.sleep(forTimeInterval: 0.10)
            },
            permit: permit
        )

        phase45ImmediatePrint("\n=== CRASH ARM: acquire durable ownership at 3000 RPM ===")
        try acquire.acquire(targets: [0: Self.targetRPM])
        guard stateMachine.record.phase == .owned,
              stateMachine.record.globalOwnershipMayBeActive,
              stateMachine.record.fanIDs == [0] else {
            throw Phase45ValidationError.journalNotClean("crash arm did not reach durable owned state")
        }

        let fan0 = preflight.evidence.fans[0]
        let responseThreshold = max(
            fan0.actualRPM + 200.0,
            fan0.minimumRPM + 200.0,
            Self.targetRPM * 0.90
        )
        var maxActual = 0.0
        let observationStart = HostClock.now
        while HostClock.seconds(from: observationStart, to: HostClock.now) < 6.0 {
            try permit()
            let actual = try hardware.actualRPM()
            maxActual = max(maxActual, actual)
            phase45ImmediatePrint("CRASH ARM OBSERVE actual=\(Int(actual.rounded())) target=\(Int((try hardware.targetRPM()).rounded()))")
            if actual >= responseThreshold { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard maxActual >= responseThreshold else {
            throw Phase45ValidationError.physicalResponseNotObserved(maxActual)
        }

        guard try hardware.readGlobalOwnership() == 1,
              try hardware.mode() == 1,
              abs(try hardware.targetRPM() - Self.targetRPM) <= 0.5 else {
            throw Phase45ValidationError.preflightBlocked("ownership changed before crash marker")
        }

        try Phase45CrashReadyMarker.createForCurrentProcess()
        phase45ImmediatePrint("CRASH_ARMED pid=\(getpid()) journalPhase=\(stateMachine.record.phase) fan=0 target=\(Int(Self.targetRPM))")
        phase45ImmediatePrint("The harness must now SIGKILL this process; no graceful cleanup will run.")

        while true {
            Thread.sleep(forTimeInterval: 60.0)
        }
    }

    func sleepWake() throws {
        try Phase45SleepWakeHarness(cancellation: cancellation).run()
    }


    /// One-time repair for the Next13 cancellation race where production Helios
    /// durably intended global ownership, wrote Ftst=1, then cancelled before the
    /// delayed readback became visible and prematurely lost journal authority.
    /// This path can only write Ftst=0, requires an exact manual confirmation, and
    /// accepts only the validated Mac16,1/25G83 surface with an automatic fan.
    func clearStaleProductionGlobal() throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }
        let observed = try SMCFanOwnershipPreflightReader().read()
        print(observed.diagnosticText)
        guard observed.evidence.modelIdentifier == "Mac16,1",
              observed.evidence.osBuild == "25G83",
              observed.evidence.fanCount == 1,
              observed.evidence.globalKeyType == "ui8 ",
              observed.evidence.globalKeySize == 1,
              observed.evidence.globalValue == 1,
              observed.evidence.fans.count == 1 else {
            throw Phase45ValidationError.preflightBlocked("stale-global repair requires the exact validated profile with Ftst=1")
        }
        let fan = observed.evidence.fans[0]
        guard fan.id == 0, fan.modeKey == "F0Md", [UInt8(0), UInt8(3)].contains(fan.mode),
              ["flt ", "fpe2"].contains(fan.targetType),
              fan.actualRPM.isFinite, fan.targetRPM.isFinite,
              fan.minimumRPM.isFinite, fan.maximumRPM.isFinite,
              fan.minimumRPM >= 0, fan.maximumRPM > fan.minimumRPM else {
            throw Phase45ValidationError.preflightBlocked("stale-global repair refuses manual/unexpected fan state")
        }
        guard observed.reasons.count == 1,
              observed.reasons[0].contains("Ftst is already active") else {
            throw Phase45ValidationError.preflightBlocked("stale-global repair found additional preflight blockers")
        }

        let hardware = try Phase45SMCHardwareForRecovery(observed: observed)
        print("\n=== ONE-TIME STALE PRODUCTION Ftst REPAIR ===")
        print("Writing Ftst=0 only. No fan mode/target write is permitted by this repair path.")
        try cancellation.check()
        try hardware.requestGlobalRelease()

        let started = HostClock.now
        var stableZeros = 0
        while HostClock.seconds(from: started, to: HostClock.now) < 4.0 {
            try cancellation.check()
            let age = HostClock.seconds(from: started, to: HostClock.now)
            let value = try hardware.readGlobalOwnership()
            if age >= 1.5, value == 0 {
                stableZeros += 1
                if stableZeros >= 10 { break }
            } else {
                stableZeros = 0
            }
            Thread.sleep(forTimeInterval: 0.10)
        }
        guard stableZeros >= 10 else {
            throw Phase45ValidationError.finalBaselineNotRestored("Ftst=0 did not remain stable after the repair write")
        }

        let final = try SMCFanOwnershipPreflightReader().read()
        print("\n=== FINAL READ-ONLY BASELINE ===")
        print(final.diagnosticText)
        guard final.isReadyForValidation else {
            throw Phase45ValidationError.finalBaselineNotRestored(final.reasons.joined(separator: "; "))
        }
        print("STALE PRODUCTION Ftst REPAIR PASSED")
    }

    func restoreOnly() throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }
        let journal = try Phase45DiskRecoveryJournal()
        let stateMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        guard stateMachine.record.needsRecovery else {
            print("RESTORE-ONLY: journal is clean; refusing to write or disturb any external controller.")
            return
        }

        print("RESTORE-ONLY: phase=\(stateMachine.record.phase) fans=\(stateMachine.record.fanIDs.sorted()) globalRisk=\(stateMachine.record.globalOwnershipMayBeActive)")
        let baselineReader = try SMCFanOwnershipPreflightReader()
        let observed = try baselineReader.read()
        // Recovery is allowed from a blocked preflight because the journal proves
        // this validation transaction may have touched the hardware. The model,
        // OS build, fan inventory, key metadata and bounds must still match.
        guard observed.evidence.modelIdentifier == "Mac16,1",
              observed.evidence.osBuild == "25G83",
              observed.evidence.fanCount == 1,
              observed.evidence.fans.count == 1,
              observed.evidence.globalKeyType == "ui8 ",
              observed.evidence.globalKeySize == 1,
              observed.evidence.fans[0].modeKey == "F0Md" else {
            throw Phase45ValidationError.preflightBlocked("recovery hardware profile changed")
        }

        let hardware = try Phase45SMCHardwareForRecovery(observed: observed)
        let started = HostClock.now
        let permit: () throws -> Void = {
            try self.cancellation.check()
            if HostClock.seconds(from: started, to: HostClock.now) >= 15.0 {
                throw Phase45ValidationError.transactionTimedOut
            }
        }
        let recovery = FanOwnershipRecoveryExecutor(
            stateMachine: stateMachine,
            hardware: hardware,
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 2),
            now: { HostClock.now },
            pause: {
                try permit()
                Thread.sleep(forTimeInterval: 0.10)
            },
            permit: permit
        )
        try recovery.recover()
        let final = try SMCFanOwnershipPreflightReader().read()
        print(final.diagnosticText)
        guard final.isReadyForValidation else {
            throw Phase45ValidationError.finalBaselineNotRestored(final.reasons.joined(separator: "; "))
        }
        print("RESTORE-ONLY PASSED")
    }
}


/// Phase 4.5 Step 5 validates the exact sleep path we intend to use in the
/// daemon: own the fan, restore synchronously on SystemWillSleep before power
/// acknowledgement, discard the pre-sleep SMC writer, then open fresh AppleSMC
/// transports after SystemHasPoweredOn. The user triggers normal macOS sleep;
/// no private power API or subprocess is used by Helios.
final class Phase45SleepWakeHarness: @unchecked Sendable {
    private enum Stage { case idle, armed, restoringForSleep, sleeping, waking, finished }

    private let cancellation: Phase45CancellationFlag
    private var stage = Stage.idle
    private var powerConnection: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var armTimer: DispatchSourceTimer?
    private var journal: Phase45DiskRecoveryJournal?
    private var stateMachine: FanOwnershipRecoveryStateMachine?
    private var hardware: Phase45SMCHardware?
    private var preSleepFailure: Error?
    private var result: Result<Void, Error>?
    private var maxActual = 0.0

    init(cancellation: Phase45CancellationFlag) { self.cancellation = cancellation }

    func run() throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }
        try registerPowerNotifications()

        let baseline = try SMCFanOwnershipPreflightReader().read()
        print(baseline.diagnosticText)
        guard baseline.isReadyForValidation else {
            throw Phase45ValidationError.preflightBlocked(baseline.reasons.joined(separator: "; "))
        }

        let journal = try Phase45DiskRecoveryJournal()
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        guard machine.record.isClean else {
            throw Phase45ValidationError.journalNotClean("phase=\(machine.record.phase) fans=\(machine.record.fanIDs.sorted()) globalRisk=\(machine.record.globalOwnershipMayBeActive)")
        }
        self.journal = journal
        stateMachine = machine

        let hardware = try Phase45SMCHardware(baseline: baseline)
        self.hardware = hardware
        let started = HostClock.now
        let permit: () throws -> Void = {
            try self.cancellation.check()
            if HostClock.seconds(from: started, to: HostClock.now) >= 25.0 {
                throw Phase45ValidationError.transactionTimedOut
            }
        }
        let acquire = FanOwnershipAcquisitionExecutor(
            stateMachine: machine,
            hardware: hardware,
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 2.5, requiredStableReads: 2),
            now: { HostClock.now },
            pause: { try permit(); Thread.sleep(forTimeInterval: 0.10) },
            permit: permit
        )

        phase45ImmediatePrint("\n=== STEP 5A: acquire 3000 RPM before real system sleep ===")
        do {
            try acquire.acquire(targets: [0: Phase45PhysicalValidator.targetRPM])
            let fan0 = baseline.evidence.fans[0]
            let threshold = max(
                fan0.actualRPM + 200.0,
                fan0.minimumRPM + 200.0,
                Phase45PhysicalValidator.targetRPM * 0.90
            )
            let observationStart = HostClock.now
            while HostClock.seconds(from: observationStart, to: HostClock.now) < 6.0 {
                try permit()
                let actual = try hardware.actualRPM()
                maxActual = max(maxActual, actual)
                phase45ImmediatePrint("SLEEP ARM OBSERVE actual=\(Int(actual.rounded())) target=\(Int((try hardware.targetRPM()).rounded()))")
                if actual >= threshold { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard maxActual >= threshold else {
                throw Phase45ValidationError.physicalResponseNotObserved(maxActual)
            }
        } catch {
            try? emergencyRecoveryWhileAwake()
            throw error
        }

        stage = .armed
        phase45ImmediatePrint("\nSLEEP_WAKE_ARMED: durable owned state confirmed at 3000 RPM.")
        phase45ImmediatePrint("Now put this Mac to sleep normally (Apple menu > Sleep, or briefly close the lid).")
        phase45ImmediatePrint("Wait at least 10 seconds, then wake it. Do not kill this validator or run another fan controller.")
        installArmingTimer()
        CFRunLoopRun()
        armTimer?.cancel()
        armTimer = nil
        stage = .finished

        guard let result else {
            try? emergencyRecoveryWhileAwake()
            throw Phase45ValidationError.wakeReprobeTimedOut("validation run loop ended without a result")
        }
        try result.get()
        print("\nPHASE45 SLEEP/WAKE RESTORATION PASSED")
        print("Validated: owned fan -> SystemWillSleep restore -> power acknowledgement -> wake -> fresh AppleSMC reprobe.")
        print("Observed fan response up to \(Int(maxActual.rounded())) RPM before sleep.")
    }

    private func registerPowerNotifications() throws {
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let harness = Unmanaged<Phase45SleepWakeHarness>.fromOpaque(context).takeUnretainedValue()
            harness.powerEvent(message, token: Int(bitPattern: argument))
        }, &notifier)
        guard powerConnection != 0,
              let port,
              let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw Phase45ValidationError.powerNotificationsUnavailable
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    }

    private func installArmingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(25))
        let armedAt = HostClock.now
        timer.setEventHandler { [weak self] in
            guard let self, self.stage == .armed else { return }
            if self.cancellation.isRequested {
                do { try self.emergencyRecoveryWhileAwake() }
                catch { self.finish(.failure(error)); return }
                self.finish(.failure(Phase45ValidationError.cancelled))
                return
            }
            if HostClock.seconds(from: armedAt, to: HostClock.now) >= 180.0 {
                do { try self.emergencyRecoveryWhileAwake() }
                catch { self.finish(.failure(error)); return }
                self.finish(.failure(Phase45ValidationError.sleepRequestTimedOut))
            }
        }
        armTimer = timer
        timer.activate()
    }

    private func powerEvent(_ message: UInt32, token: Int) {
        switch message {
        case 0xe0000270: // CanSystemSleep
            IOAllowPowerChange(powerConnection, token)
        case 0xe0000280: // SystemWillSleep
            guard stage == .armed else {
                IOAllowPowerChange(powerConnection, token)
                return
            }
            stage = .restoringForSleep
            armTimer?.cancel()
            armTimer = nil
            phase45ImmediatePrint("\n=== STEP 5B: SystemWillSleep -> restore before power acknowledgement ===")
            do {
                try recoverBeforeSleep()
                phase45ImmediatePrint("PRE-SLEEP RESTORE PASSED: journal clean and read-only System baseline confirmed.")
            } catch {
                preSleepFailure = error
                phase45ImmediatePrint("PRE-SLEEP RESTORE FAILED: \(error.localizedDescription)")
                phase45ImmediatePrint("Sleep will still be acknowledged; wake recovery remains journal-gated.")
            }
            // Drop the entire pre-sleep writer/reader facade. The wake step must
            // prove it can succeed using newly opened AppleSMC transports.
            hardware = nil
            stage = .sleeping
            phase45ImmediatePrint("SMC pre-sleep facade discarded; allowing system sleep now.")
            IOAllowPowerChange(powerConnection, token)
        case 0xe0000300: // SystemHasPoweredOn
            guard stage == .sleeping || stage == .restoringForSleep else { return }
            stage = .waking
            phase45ImmediatePrint("\n=== STEP 5C: SystemHasPoweredOn -> fresh AppleSMC reprobe ===")
            do {
                try recoverAfterWakeIfNeeded()
                let final = try waitForFreshReadyPreflight(timeoutSeconds: 12.0)
                phase45ImmediatePrint(final.diagnosticText)
                if let preSleepFailure { throw preSleepFailure }
                try cancellation.check()
                finish(.success(()))
            } catch {
                finish(.failure(error))
            }
        default:
            break
        }
    }

    private func recoverBeforeSleep() throws {
        guard let machine = stateMachine, let hardware else {
            throw TelemetryError.unavailable("Sleep validation ownership state is unavailable")
        }
        let started = HostClock.now
        let permit: () throws -> Void = {
            if HostClock.seconds(from: started, to: HostClock.now) >= 12.0 {
                throw Phase45ValidationError.transactionTimedOut
            }
        }
        let recovery = FanOwnershipRecoveryExecutor(
            stateMachine: machine,
            hardware: hardware,
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 2),
            now: { HostClock.now },
            pause: { try permit(); Thread.sleep(forTimeInterval: 0.10) },
            permit: permit
        )
        try recovery.recover()
        guard machine.record.isClean else {
            throw Phase45ValidationError.journalNotClean("pre-sleep recovery did not reach clean state")
        }
        let clean = try waitForFreshReadyPreflight(timeoutSeconds: 4.0)
        guard clean.isReadyForValidation else {
            throw Phase45ValidationError.finalBaselineNotRestored(clean.reasons.joined(separator: "; "))
        }
    }

    private func recoverAfterWakeIfNeeded() throws {
        guard let journal else { throw TelemetryError.unavailable("Sleep validation journal unavailable after wake") }
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        stateMachine = machine
        guard machine.record.needsRecovery else {
            phase45ImmediatePrint("WAKE RECOVERY: journal already clean; no recovery write required.")
            return
        }

        phase45ImmediatePrint("WAKE RECOVERY: journal phase=\(machine.record.phase) fans=\(machine.record.fanIDs.sorted()) globalRisk=\(machine.record.globalOwnershipMayBeActive)")
        let observed = try waitForAnyFreshPreflight(timeoutSeconds: 10.0)
        let recoveryHardware = try Phase45SMCHardwareForRecovery(observed: observed)
        let started = HostClock.now
        let permit: () throws -> Void = {
            if HostClock.seconds(from: started, to: HostClock.now) >= 12.0 {
                throw Phase45ValidationError.transactionTimedOut
            }
        }
        let recovery = FanOwnershipRecoveryExecutor(
            stateMachine: machine,
            hardware: recoveryHardware,
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 2),
            now: { HostClock.now },
            pause: { try permit(); Thread.sleep(forTimeInterval: 0.10) },
            permit: permit
        )
        try recovery.recover()
        guard machine.record.isClean else {
            throw Phase45ValidationError.journalNotClean("wake recovery did not reach clean state")
        }
    }

    private func emergencyRecoveryWhileAwake() throws {
        guard let journal else { return }
        let machine = try FanOwnershipRecoveryStateMachine(journal: journal)
        stateMachine = machine
        guard machine.record.needsRecovery else { return }
        let observed = try SMCFanOwnershipPreflightReader().read()
        let recoveryHardware = try Phase45SMCHardwareForRecovery(observed: observed)
        let recovery = FanOwnershipRecoveryExecutor(
            stateMachine: machine,
            hardware: recoveryHardware,
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 2),
            now: { HostClock.now },
            pause: { Thread.sleep(forTimeInterval: 0.10) },
            permit: {}
        )
        try recovery.recover()
    }

    private func waitForAnyFreshPreflight(timeoutSeconds: Double) throws -> FanOwnershipPreflightSnapshot {
        let started = HostClock.now
        var lastError: Error?
        while HostClock.seconds(from: started, to: HostClock.now) < timeoutSeconds {
            do {
                // New reader on every attempt: the test must not inherit a
                // pre-sleep AppleSMC user-client or cached key metadata.
                return try SMCFanOwnershipPreflightReader().read()
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw Phase45ValidationError.wakeReprobeTimedOut(lastError?.localizedDescription ?? "AppleSMC remained unavailable")
    }

    private func waitForFreshReadyPreflight(timeoutSeconds: Double) throws -> FanOwnershipPreflightSnapshot {
        let started = HostClock.now
        var lastText = "no post-wake sample"
        while HostClock.seconds(from: started, to: HostClock.now) < timeoutSeconds {
            do {
                let snapshot = try SMCFanOwnershipPreflightReader().read()
                if snapshot.isReadyForValidation { return snapshot }
                lastText = snapshot.reasons.joined(separator: "; ")
            } catch {
                lastText = error.localizedDescription
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw Phase45ValidationError.wakeReprobeTimedOut(lastText)
    }

    private func finish(_ value: Result<Void, Error>) {
        guard result == nil else { return }
        result = value
        stage = .finished
        armTimer?.cancel()
        armTimer = nil
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

/// Recovery needs the same strict write allowlist, but it must be constructible
/// when Ftst/manual mode makes the ordinary Ready preflight intentionally fail.
final class Phase45SMCHardwareForRecovery: FanOwnershipRecoveryHardware {
    private let client: SMCClient
    private let reader: SMCFanReader
    private var connection: io_connect_t = 0
    private let targetType: String

    init(observed: FanOwnershipPreflightSnapshot) throws {
        guard geteuid() == 0 else { throw Phase45ValidationError.rootRequired }
        guard observed.evidence.modelIdentifier == "Mac16,1",
              observed.evidence.osBuild == "25G83",
              observed.evidence.fanCount == 1,
              let fan = observed.evidence.fans.first,
              fan.id == 0,
              fan.modeKey == "F0Md",
              ["flt ", "fpe2"].contains(fan.targetType) else {
            throw Phase45ValidationError.preflightBlocked("recovery profile mismatch")
        }
        targetType = fan.targetType
        client = SMCClient(transport: try SMCIOKitTransport())
        reader = SMCFanReader(client: client)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TelemetryError.unavailable("AppleSMC unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Open Phase 4.5 recovery writer", result) }
    }

    deinit { if connection != 0 { _ = IOServiceClose(connection) } }

    func restoreFanToSystem(_ id: Int) throws {
        guard id == 0 else { throw Phase45ValidationError.unsupportedFan(id) }
        let mode = try reader.mode(0)
        guard [UInt8(0), UInt8(1), UInt8(3)].contains(mode) else {
            throw Phase45ValidationError.unexpectedMode(mode)
        }
        if mode == 1 { try write("F0Md", payload: [0]) }
    }

    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        guard id == 0 else { throw Phase45ValidationError.unsupportedFan(id) }
        let mode = try reader.mode(0)
        let target = try reader.rpm(0, "Tg")
        let actual = try reader.rpm(0, "Ac")
        return [UInt8(0), UInt8(3)].contains(mode) && target.isFinite && actual.isFinite
    }

    func requestGlobalRelease() throws {
        // Recovery is authorized by durable risk, not by an immediate Ftst
        // readback that may still be showing the pre-acquisition zero.
        try write("Ftst", payload: [0])
    }

    func readGlobalOwnership() throws -> UInt8 {
        let value = try client.value("Ftst")
        guard value.info.type == "ui8 ", value.info.size == 1, value.bytes.count == 1,
              value.bytes[0] == 0 || value.bytes[0] == 1 else {
            throw TelemetryError.invalidData("Invalid Ftst recovery readback")
        }
        return value.bytes[0]
    }

    private func write(_ key: String, payload: [UInt8]) throws {
        let info = try client.keyInfo(key)
        switch key {
        case "Ftst", "F0Md":
            guard info.type == "ui8 ", info.size == 1, payload.count == 1, payload[0] == 0 else {
                throw TelemetryError.invalidData("Recovery write rejected")
            }
        case "F0Tg":
            guard info.type == targetType,
                  ((targetType == "flt " && info.size == 4) || (targetType == "fpe2" && info.size == 2)),
                  payload.allSatisfy({ $0 == 0 }) else {
                throw TelemetryError.invalidData("Recovery target clear rejected")
            }
        default:
            throw TelemetryError.invalidData("Recovery write key is not allowlisted")
        }

        var frame = try SMCCodec.frame(SMCReadRequest(command: .bytes, key: key, dataSize: info.size))
        frame[42] = 6
        frame.replaceSubrange(48..<(48 + payload.count), with: payload)
        var output = [UInt8](repeating: 0, count: SMCCodec.frameSize)
        var outputSize = output.count
        let result = frame.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { reply in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count,
                                          reply.baseAddress, &outputSize)
            }
        }
        print("RESTORE WRITE \(key) IOReturn=0x\(String(UInt32(bitPattern: result), radix: 16)) SMCResult=0x\(String(output[40], radix: 16))")
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Recovery write \(key)", result) }
        guard outputSize == SMCCodec.frameSize else { throw TelemetryError.invalidData("Truncated recovery write response") }
        guard output[40] == 0 else { throw TelemetryError.smc(key, output[40]) }
    }
}

func phase45Usage() {
    print("""
    Phase 4.5 Step 5 sleep/wake validation tool

    Read-only preflight:
      Phase45PhysicalValidation --preflight

    Graceful physical validation (WRITES Ftst, F0Md and F0Tg only):
      sudo Phase45PhysicalValidation --run --confirm \(Phase45PhysicalValidator.confirmation)

    Recovery only (writes only when the durable validation journal proves risk):
      sudo Phase45PhysicalValidation --restore-only

    One-time Next13 stale production Ftst repair (WRITES Ftst=0 only):
      sudo Phase45PhysicalValidation --clear-stale-production-ftst --confirm \(Phase45PhysicalValidator.staleGlobalConfirmation)

    Sleep/wake validation (WRITES during acquisition/release, then waits for a real sleep cycle):
      sudo Phase45PhysicalValidation --sleep-wake --confirm \(Phase45PhysicalValidator.confirmation)

    Crash arming remains restricted to scripts/run-phase45-crash-validation.sh.

    Sleep/wake validation restores ownership before acknowledging SystemWillSleep,
    discards the pre-sleep SMC facade, then requires a fresh AppleSMC preflight after wake.
    This remains a standalone validation executable. Production Helios takeover is gated.
    """)
}

@main
private enum Phase45PhysicalValidationMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--describe") {
            phase45Usage()
            return
        }

        let cancellation = Phase45CancellationFlag()
        let signalSources = installPhase45SignalHandlers(cancellation)
        withExtendedLifetime(signalSources) {
            do {
                if args.contains("--preflight") {
                    try Phase45PhysicalValidator(cancellation: cancellation).preflightOnly()
                    return
                }
                if args.contains("--clear-stale-production-ftst") {
                    guard let confirmIndex = args.firstIndex(of: "--confirm"),
                          args.indices.contains(confirmIndex + 1),
                          args[confirmIndex + 1] == Phase45PhysicalValidator.staleGlobalConfirmation else {
                        throw Phase45ValidationError.explicitConfirmationRequired
                    }
                    try Phase45PhysicalValidator(cancellation: cancellation).clearStaleProductionGlobal()
                    return
                }
                if args.contains("--sleep-wake") {
                    guard let confirmIndex = args.firstIndex(of: "--confirm"),
                          args.indices.contains(confirmIndex + 1),
                          args[confirmIndex + 1] == Phase45PhysicalValidator.confirmation else {
                        throw Phase45ValidationError.explicitConfirmationRequired
                    }
                    try Phase45PhysicalValidator(cancellation: cancellation).sleepWake()
                    return
                }
                if args.contains("--arm-crash") {
                    guard let confirmIndex = args.firstIndex(of: "--confirm"),
                          args.indices.contains(confirmIndex + 1),
                          args[confirmIndex + 1] == Phase45PhysicalValidator.confirmation,
                          let harnessIndex = args.firstIndex(of: "--orchestrated-by"),
                          args.indices.contains(harnessIndex + 1),
                          args[harnessIndex + 1] == Phase45PhysicalValidator.crashHarnessConfirmation else {
                        throw Phase45ValidationError.crashHarnessOnly
                    }
                    try Phase45PhysicalValidator(cancellation: cancellation).armCrashAndHold()
                    return
                }
                if args.contains("--restore-only") {
                    try Phase45PhysicalValidator(cancellation: cancellation).restoreOnly()
                    return
                }
                if args.contains("--run") {
                    guard let confirmIndex = args.firstIndex(of: "--confirm"),
                          args.indices.contains(confirmIndex + 1),
                          args[confirmIndex + 1] == Phase45PhysicalValidator.confirmation else {
                        throw Phase45ValidationError.explicitConfirmationRequired
                    }
                    try Phase45PhysicalValidator(cancellation: cancellation).run()
                    return
                }
                phase45Usage()
            } catch {
                print("PHASE45 FAILED: \(error.localizedDescription)")
                if geteuid() == 0 {
                    print("If the tool reports unresolved recovery state, run: sudo .build/Validation/Phase45PhysicalValidation --restore-only")
                }
                Foundation.exit(1)
            }
        }
    }
}
