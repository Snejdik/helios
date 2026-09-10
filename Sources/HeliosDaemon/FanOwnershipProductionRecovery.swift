import Darwin
import Foundation
import IOKit
import OSLog

/// Root-owned v2 ownership journal reserved for the production daemon path.
/// It is intentionally separate from both the legacy per-fan journal and the
/// Phase 4.5 validation journal. A clean/absent record cannot authorize writes.
final class ProductionFanOwnershipRecoveryJournal: FanOwnershipRecoveryJournal {
    static let path = "/var/db/com.snejda.Helios.fan-ownership-v2"

    private let descriptor: Int32

    init() throws {
        guard geteuid() == 0 else {
            throw TelemetryError.unavailable("Production fan recovery journal requires the privileged helper")
        }
        let fd = open(Self.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw TelemetryError.kernel("Open production fan recovery journal", errno) }

        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == 0,
              info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw TelemetryError.unavailable("Production fan recovery journal is not private or is already in use")
        }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func load() throws -> FanOwnershipRecoveryRecord {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw TelemetryError.kernel("Stat production fan recovery journal", errno)
        }
        if info.st_size == 0 { return .clean }
        guard info.st_size == FanOwnershipRecoveryCodec.encodedSize else {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        var bytes = [UInt8](repeating: 0, count: FanOwnershipRecoveryCodec.encodedSize)
        let count = bytes.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count == bytes.count else {
            throw TelemetryError.kernel("Read production fan recovery journal", errno)
        }
        return try FanOwnershipRecoveryCodec.decode(Data(bytes))
    }

    func save(_ record: FanOwnershipRecoveryRecord) throws {
        let data = try FanOwnershipRecoveryCodec.encode(record)
        let count = data.withUnsafeBytes { buffer in
            pwrite(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count == data.count,
              ftruncate(descriptor, off_t(data.count)) == 0,
              fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Persist production fan recovery journal", errno)
        }
    }
}

/// Recovery-only AppleSMC backend for the physically validated primary profile.
/// This type cannot acquire ownership and cannot write fan targets. Its complete
/// write allowlist is Ftst=0 and F0Md=0, and construction fails on any profile
/// drift from Mac16,1 / 25G83 / one fan.
final class ProductionM4FanRecoveryHardware: FanOwnershipRecoveryHardware {
    private let client: SMCClient
    private let reader: SMCFanReader
    private var connection: io_connect_t = 0

    init() throws {
        guard geteuid() == 0 else {
            throw TelemetryError.unavailable("Production fan recovery requires the privileged helper")
        }
        let model = try HeliosMachineIdentity.modelIdentifier
        let build = try HeliosMachineIdentity.osBuild
        guard model == FanOwnershipMachineProfile.primaryM4.modelIdentifier,
              build == FanOwnershipMachineProfile.primaryM4.osBuild else {
            throw TelemetryError.unavailable("No production recovery profile exists for this Mac or OS build")
        }

        client = SMCClient(transport: try SMCIOKitTransport())
        reader = SMCFanReader(client: client)
        try validateSurface()

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TelemetryError.unavailable("AppleSMC unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Open production recovery writer", result) }
    }

    deinit { if connection != 0 { _ = IOServiceClose(connection) } }

    func restoreFanToSystem(_ id: Int) throws {
        try requireFan0(id)
        let mode = try reader.mode(0)
        guard [UInt8(0), UInt8(1), UInt8(3)].contains(mode) else {
            throw TelemetryError.invalidData("Unexpected fan mode during production recovery")
        }
        if mode == 1 { try writeZero("F0Md") }
    }

    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        try requireFan0(id)
        let mode = try reader.mode(0)
        let target = try reader.rpm(0, "Tg")
        let actual = try reader.rpm(0, "Ac")
        return [UInt8(0), UInt8(3)].contains(mode) && target.isFinite && actual.isFinite
    }

    func requestGlobalRelease() throws {
        // Once the durable journal says Ftst may have been written, always send
        // an explicit release. A just-accepted Ftst=1 can still be invisible in
        // readback for hundreds of milliseconds; skipping the zero write because
        // an immediate read still says 0 can leave a delayed stale ownership flag.
        try writeZero("Ftst")
    }

    func readGlobalOwnership() throws -> UInt8 {
        let value = try client.value("Ftst")
        guard value.info.type == "ui8 ", value.info.size == 1, value.bytes.count == 1,
              value.bytes[0] == 0 || value.bytes[0] == 1 else {
            throw TelemetryError.invalidData("Invalid Ftst production recovery readback")
        }
        return value.bytes[0]
    }

    private func validateSurface() throws {
        let count = try FanCodec.count(client.value("FNum"))
        guard count == FanOwnershipMachineProfile.primaryM4.fanCount else {
            throw TelemetryError.unavailable("Production recovery fan count no longer matches the validated profile")
        }
        let global = try client.value("Ftst")
        guard global.info.type == "ui8 ", global.info.size == 1, global.bytes.count == 1,
              global.bytes[0] == 0 || global.bytes[0] == 1 else {
            throw TelemetryError.invalidData("Production recovery Ftst metadata changed")
        }
        guard try reader.modeKey(0) == "F0Md" else {
            throw TelemetryError.unavailable("Production recovery mode key changed")
        }
        let mode = try reader.mode(0)
        guard [UInt8(0), UInt8(1), UInt8(3)].contains(mode) else {
            throw TelemetryError.invalidData("Production recovery observed an unexpected fan mode")
        }
        let target = try client.value("F0Tg")
        let targetRPM = try FanCodec.rpm(type: target.info.type, bytes: target.bytes)
        let actualRPM = try reader.rpm(0, "Ac")
        let minimumRPM = try reader.rpm(0, "Mn")
        let maximumRPM = try reader.rpm(0, "Mx")
        guard ["flt ", "fpe2"].contains(target.info.type),
              targetRPM.isFinite, actualRPM.isFinite, minimumRPM.isFinite, maximumRPM.isFinite,
              minimumRPM >= 0, maximumRPM > minimumRPM else {
            throw TelemetryError.invalidData("Production recovery fan surface changed")
        }
    }

    private func requireFan0(_ id: Int) throws {
        guard id == 0 else { throw FanOwnershipRecoveryError.invalidFanID(id) }
    }

    private func writeZero(_ key: String) throws {
        guard key == "Ftst" || key == "F0Md" else {
            throw TelemetryError.invalidData("Production recovery write key is not allowlisted")
        }
        let info = try client.keyInfo(key)
        guard info.type == "ui8 ", info.size == 1 else {
            throw TelemetryError.invalidData("Production recovery write metadata changed")
        }
        var frame = try SMCCodec.frame(SMCReadRequest(command: .bytes, key: key, dataSize: info.size))
        frame[42] = 6 // kSMCWriteBytes
        frame[48] = 0
        var output = [UInt8](repeating: 0, count: SMCCodec.frameSize)
        var outputSize = output.count
        let result = frame.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { reply in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count,
                                          reply.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Production recovery write \(key)", result) }
        guard outputSize == SMCCodec.frameSize else {
            throw TelemetryError.invalidData("Truncated production recovery write response")
        }
        guard output[40] == 0 else { throw TelemetryError.smc(key, output[40]) }
    }
}



// MARK: - Physically validated production Boost profile

/// Deliberately narrow production takeover profile. These are not generic M4
/// assumptions: they are the exact surface physically validated on this Mac in
/// Phase 4.5. Any model/build/key/encoding/factory-limit drift disables takeover
/// instead of being guessed or silently generalized.
enum ProductionM4FanControlProfile {
    static let fanID = 0
    static let modeKey = "F0Md"
    static let targetType = "flt "
    static let minimumRPM = 2_317.0
    static let maximumRPM = 6_550.0

    static func validate(_ snapshot: FanOwnershipPreflightSnapshot) throws {
        guard snapshot.isReadyForValidation else {
            let reason = snapshot.reasons.isEmpty ? "read-only preflight is blocked" : snapshot.reasons.joined(separator: "; ")
            throw TelemetryError.unavailable("Production fan-control preflight is not clean: \(reason)")
        }
        let evidence = snapshot.evidence
        guard evidence.modelIdentifier == FanOwnershipMachineProfile.primaryM4.modelIdentifier,
              evidence.osBuild == FanOwnershipMachineProfile.primaryM4.osBuild,
              evidence.fanCount == 1,
              evidence.globalKeyType == "ui8 ", evidence.globalKeySize == 1, evidence.globalValue == 0,
              evidence.fans.count == 1,
              let fan = evidence.fans.first,
              fan.id == fanID,
              fan.modeKey == modeKey,
              fan.mode == 0 || fan.mode == 3,
              fan.targetType == targetType,
              fan.minimumRPM.isFinite, fan.maximumRPM.isFinite,
              abs(fan.minimumRPM - minimumRPM) <= 0.5,
              abs(fan.maximumRPM - maximumRPM) <= 0.5,
              fan.actualRPM.isFinite, fan.targetRPM.isFinite,
              fan.actualRPM >= 0, fan.actualRPM <= 30_000,
              fan.targetRPM >= 0, fan.targetRPM <= 30_000 else {
            throw TelemetryError.unavailable("Production fan-control surface no longer matches the physically validated Mac16,1 profile")
        }
    }

    static func target(for mode: HeliosFanMode, requestedRPM: Double) throws -> Double {
        switch mode {
        case .boost:
            return maximumRPM
        case .override:
            guard requestedRPM.isFinite else {
                throw TelemetryError.invalidData("Override target must be finite")
            }
            // Quantize in the privileged daemon so a compromised or buggy app
            // cannot smuggle fractional/out-of-range targets into the write sink.
            let clamped = min(maximumRPM, max(minimumRPM, requestedRPM))
            return clamped.rounded()
        case .system:
            throw TelemetryError.unavailable("System mode does not have a manual fan target")
        }
    }

    /// Human-friendly deceleration points used only for an explicit app-requested
    /// release. Safety releases (sleep, disconnect, timeout, crash/recovery) skip
    /// this path and restore System immediately.
    static func softReleaseTargets(from currentRPM: Double?) -> [Double] {
        guard let currentRPM, currentRPM.isFinite, currentRPM > minimumRPM else { return [] }
        let candidates = [5_200.0, 4_300.0, 3_400.0, 2_800.0]
        return candidates.filter { $0 < currentRPM && $0 >= minimumRPM && $0 <= maximumRPM }
    }

    static func validateManualTarget(_ rpm: Double) throws -> Double {
        guard rpm.isFinite, rpm >= minimumRPM, rpm <= maximumRPM,
              abs(rpm.rounded() - rpm) <= 0.01 else {
            throw TelemetryError.invalidData("Production fan target is outside the validated integral RPM range")
        }
        return rpm
    }
}

/// Read-only gate used before the daemon advertises production Boost. It cannot
/// open a writer. The actual writer is constructed lazily only after a fresh,
/// authenticated control calculation arrives from the app.
enum ProductionFanTakeoverGate {
    static func run() throws {
        let snapshot = try SMCFanOwnershipPreflightReader().read()
        try ProductionM4FanControlProfile.validate(snapshot)
    }
}

/// Live production writer for the physically validated Mac16,1 fan surface.
///
/// Complete write surface:
/// - Ftst = 1 to acquire, Ftst = 0 to release
/// - F0Md = 1 to request manual, F0Md = 0 to restore automatic
/// - F0Tg = an integral target clamped by the daemon to 2317...6550 RPM
///
/// It cannot write min/max keys, another fan, an out-of-range target, or any
/// firmware test key. Retryable F0Md/0x82 arbitration is surfaced as a no-op attempt; the shared
/// acquisition executor owns the bounded retry loop and performs a fresh lease
/// permit check before every subsequent write.
final class ProductionM4FanControlHardware: FanOwnershipAcquisitionHardware, FanOwnershipRecoveryHardware {
    private let client: SMCClient
    private let reader: SMCFanReader
    private var connection: io_connect_t = 0
    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanSMC")

    init() throws {
        guard geteuid() == 0 else {
            throw TelemetryError.unavailable("Production fan control requires the privileged helper")
        }
        let model = try HeliosMachineIdentity.modelIdentifier
        let build = try HeliosMachineIdentity.osBuild
        guard model == FanOwnershipMachineProfile.primaryM4.modelIdentifier,
              build == FanOwnershipMachineProfile.primaryM4.osBuild else {
            throw TelemetryError.unavailable("No production fan-control profile exists for this Mac or OS build")
        }

        client = SMCClient(transport: try SMCIOKitTransport())
        reader = SMCFanReader(client: client)
        let baseline = try SMCFanOwnershipPreflightReader(client: client).read(modelIdentifier: model, osBuild: build)
        try ProductionM4FanControlProfile.validate(baseline)

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TelemetryError.unavailable("AppleSMC unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Open production fan writer", result) }
    }

    deinit { if connection != 0 { _ = IOServiceClose(connection) } }

    func requireCleanSystemBaseline() throws {
        let model = try HeliosMachineIdentity.modelIdentifier
        let build = try HeliosMachineIdentity.osBuild
        let snapshot = try SMCFanOwnershipPreflightReader(client: client).read(modelIdentifier: model, osBuild: build)
        try ProductionM4FanControlProfile.validate(snapshot)
    }

    func validateGlobalAcquisitionBaseline() throws {
        // This complete read-only check runs while the Helios journal is still
        // clean. If an external controller already owns Ftst, acquisition stops
        // without creating recovery authority over that controller's state.
        try requireCleanSystemBaseline()
    }

    func requestGlobalAcquisition() throws {
        // The shared executor has already persisted conservative global risk and
        // performed a fresh lease check. Do not add another pre-write baseline
        // rejection here: once risk is persisted, a read-only rejection could
        // otherwise tempt cleanup code to clear ownership Helios never wrote.
        try write("Ftst", payload: [1])
    }

    func readGlobalOwnership() throws -> UInt8 {
        let value = try client.value("Ftst")
        guard value.info.type == "ui8 ", value.info.size == 1, value.bytes.count == 1,
              value.bytes[0] == 0 || value.bytes[0] == 1 else {
            throw TelemetryError.invalidData("Invalid Ftst production fan-control readback")
        }
        return value.bytes[0]
    }

    func readFanMode(_ id: Int) throws -> UInt8 {
        try requireFan0(id)
        guard try reader.modeKey(0) == ProductionM4FanControlProfile.modeKey else {
            throw TelemetryError.unavailable("Production fan-control mode key changed")
        }
        let mode = try reader.mode(0)
        guard [UInt8(0), UInt8(1), UInt8(3)].contains(mode) else {
            throw TelemetryError.invalidData("Unexpected fan mode during production fan control")
        }
        return mode
    }

    func requestFanManual(_ id: Int) throws {
        try requireFan0(id)
        guard try readGlobalOwnership() == 1 else {
            throw TelemetryError.unavailable("Manual fan request requires confirmed Ftst ownership")
        }
        let mode = try readFanMode(0)
        if mode == 1 { return }
        guard mode == 0 || mode == 3 else {
            throw TelemetryError.invalidData("Unexpected automatic mode before production fan control")
        }
        do {
            try write("F0Md", payload: [1])
        } catch TelemetryError.smc(_, let code) where code == 0x82 {
            logger.debug("F0Md production arbitration returned retryable SMC result 0x82.")
        }
    }

    func setFanTarget(_ id: Int, rpm: Double) throws {
        try requireFan0(id)
        let target = try ProductionM4FanControlProfile.validateManualTarget(rpm)
        guard try readGlobalOwnership() == 1, try readFanMode(0) == 1 else {
            throw TelemetryError.unavailable("Production fan target requires confirmed Ftst=1 and F0Md=1")
        }
        try write("F0Tg", payload: try encodedTarget(target))
    }

    func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool {
        try requireFan0(id)
        let expected = try ProductionM4FanControlProfile.validateManualTarget(targetRPM)
        guard try readGlobalOwnership() == 1,
              try readFanMode(0) == 1 else { return false }
        let target = try reader.rpm(0, "Tg")
        return target.isFinite && abs(target - expected) <= 1.0
    }

    func restoreFanToSystem(_ id: Int) throws {
        try requireFan0(id)
        let mode = try readFanMode(0)
        if mode == 1 { try write("F0Md", payload: [0]) }
    }

    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        try requireFan0(id)
        let mode = try readFanMode(0)
        let target = try reader.rpm(0, "Tg")
        let actual = try reader.rpm(0, "Ac")
        let global = try readGlobalOwnership()
        return global == 0 && [UInt8(0), UInt8(3)].contains(mode) && target.isFinite && actual.isFinite
    }

    func requestGlobalRelease() throws {
        // Same conservative rule as bootstrap recovery: journaled global risk
        // authorizes an unconditional Ftst=0, even when the old readback has not
        // yet exposed the preceding Ftst=1 write.
        try write("Ftst", payload: [0])
    }

    private func requireFan0(_ id: Int) throws {
        guard id == ProductionM4FanControlProfile.fanID else {
            throw FanOwnershipRecoveryError.invalidFanID(id)
        }
    }

    private func encodedTarget(_ rpm: Double) throws -> [UInt8] {
        let target = try ProductionM4FanControlProfile.validateManualTarget(rpm)
        let info = try client.keyInfo("F0Tg")
        guard info.type == ProductionM4FanControlProfile.targetType, info.size == 4 else {
            throw TelemetryError.invalidData("Production fan target encoding changed")
        }
        let value = Float(target)
        guard value.isFinite, abs(Double(value) - target) <= 0.5 else {
            throw TelemetryError.invalidData("Production fan target is not representable")
        }
        return (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
    }

    private func write(_ key: String, payload: [UInt8]) throws {
        let info = try client.keyInfo(key)
        switch key {
        case "Ftst":
            guard info.type == "ui8 ", info.size == 1, payload.count == 1,
                  payload[0] == 0 || payload[0] == 1 else {
                throw TelemetryError.invalidData("Rejected production Ftst write")
            }
        case "F0Md":
            guard info.type == "ui8 ", info.size == 1, payload.count == 1,
                  payload[0] == 0 || payload[0] == 1 else {
                throw TelemetryError.invalidData("Rejected production F0Md write")
            }
        case "F0Tg":
            guard info.type == ProductionM4FanControlProfile.targetType, info.size == 4,
                  payload.count == 4 else {
                throw TelemetryError.invalidData("Rejected production F0Tg write")
            }
            let decoded = try FanCodec.rpm(type: info.type, bytes: payload)
            _ = try ProductionM4FanControlProfile.validateManualTarget(decoded)
        default:
            throw TelemetryError.invalidData("Production fan write key is not allowlisted")
        }

        var frame = try SMCCodec.frame(SMCReadRequest(command: .bytes, key: key, dataSize: info.size))
        frame[42] = 6 // kSMCWriteBytes
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
        logger.notice("Production fan write key=\(key, privacy: .public) type='\(info.type, privacy: .public)' bytes=[\(raw, privacy: .public)] IOReturn=0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public) SMCResult=0x\(String(output[40], radix: 16), privacy: .public)")
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Production fan write \(key)", result) }
        guard outputSize == SMCCodec.frameSize else {
            throw TelemetryError.invalidData("Truncated production fan write response")
        }
        guard output[40] == 0 else { throw TelemetryError.smc(key, output[40]) }
    }
}

enum ProductionFanRecoveryBootstrapResult: Equatable, Sendable {
    case clean
    case recovered
}

/// Generic bootstrap used by daemon startup and focused tests. The hardware
/// factory is never invoked for a clean journal, which proves a normal daemon
/// launch cannot accidentally open or exercise the recovery writer.
struct FanRecoveryBootstrap {
    let journal: any FanOwnershipRecoveryJournal
    let makeHardware: () throws -> any FanOwnershipRecoveryHardware
    let transitionPolicy: FanOwnershipTransitionPolicy
    let now: () -> UInt64
    let pause: () throws -> Void

    func run() throws -> ProductionFanRecoveryBootstrapResult {
        let stateMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        guard stateMachine.record.needsRecovery else { return .clean }
        let hardware = try makeHardware()
        let executor = FanOwnershipRecoveryExecutor(
            stateMachine: stateMachine,
            hardware: hardware,
            transitionPolicy: transitionPolicy,
            now: now,
            pause: pause,
            permit: {}
        )
        try executor.recover()
        guard stateMachine.record.isClean else {
            throw TelemetryError.unavailable("Production fan recovery did not reach a clean System record")
        }
        return .recovered
    }
}

enum ProductionFanRecoveryBootstrap {
    private static let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanRecovery")

    static func run() throws -> ProductionFanRecoveryBootstrapResult {
        let journal = try ProductionFanOwnershipRecoveryJournal()
        let bootstrap = FanRecoveryBootstrap(
            journal: journal,
            makeHardware: { try ProductionM4FanRecoveryHardware() },
            transitionPolicy: try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 10),
            now: { HostClock.now },
            pause: { Thread.sleep(forTimeInterval: 0.10) }
        )
        let result = try bootstrap.run()
        switch result {
        case .clean:
            logger.notice("Production v2 fan recovery bootstrap: clean journal; no recovery hardware opened.")
        case .recovered:
            logger.notice("Production v2 fan recovery bootstrap: stale ownership recovered before XPC listener start.")
        }
        return result
    }
}

/// Wake verification is deliberately separate from acquisition. It first runs
/// journal-gated recovery, then creates a fresh read-only SMC preflight reader.
/// A clean journal therefore performs no writes; an unclean journal may only
/// exercise the recovery-only Ftst=0 / F0Md=0 backend above.
struct FanWakeSafetyVerifier {
    let recover: () throws -> ProductionFanRecoveryBootstrapResult
    let readPreflight: () throws -> FanOwnershipPreflightSnapshot
    let timeoutSeconds: Double
    let now: () -> UInt64
    let pause: () throws -> Void

    @discardableResult
    func run() throws -> ProductionFanRecoveryBootstrapResult {
        guard timeoutSeconds > 0, timeoutSeconds.isFinite else {
            throw TelemetryError.invalidData("Invalid wake reprobe timeout")
        }
        let recovery = try recover()
        let started = now()
        var lastReason = "AppleSMC produced no post-wake sample"

        while HostClock.seconds(from: started, to: now()) < timeoutSeconds {
            let snapshot: FanOwnershipPreflightSnapshot
            do {
                snapshot = try readPreflight()
            } catch {
                lastReason = error.localizedDescription
                try pause()
                continue
            }

            // A different machine/OS build is a profile drift, not a transient
            // post-wake condition. Fail closed immediately instead of polling.
            guard snapshot.evidence.modelIdentifier == FanOwnershipMachineProfile.primaryM4.modelIdentifier,
                  snapshot.evidence.osBuild == FanOwnershipMachineProfile.primaryM4.osBuild else {
                throw TelemetryError.unavailable("Wake SMC reprobe no longer matches the validated Mac/OS profile")
            }
            if snapshot.isReadyForValidation { return recovery }
            lastReason = snapshot.reasons.isEmpty ? "wake preflight remained blocked" : snapshot.reasons.joined(separator: "; ")
            try pause()
        }
        throw TelemetryError.unavailable("Wake SMC reprobe did not reach a clean System baseline: \(lastReason)")
    }
}

enum ProductionFanWakeSafety {
    private static let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanRecovery")

    @discardableResult
    static func run() throws -> ProductionFanRecoveryBootstrapResult {
        let verifier = FanWakeSafetyVerifier(
            recover: { try ProductionFanRecoveryBootstrap.run() },
            // Construct a new reader on every retry. This intentionally drops
            // any pre-sleep AppleSMC/IOKit read transport assumptions and also
            // tolerates the service taking a short time to republish after wake.
            readPreflight: { try SMCFanOwnershipPreflightReader().read() },
            timeoutSeconds: 8.0,
            now: { HostClock.now },
            pause: { Thread.sleep(forTimeInterval: 0.25) }
        )
        let result = try verifier.run()
        switch result {
        case .clean:
            logger.notice("Wake SMC reprobe verified a clean System baseline; production recovery journal was clean.")
        case .recovered:
            logger.notice("Wake SMC reprobe verified a clean System baseline after journal-gated recovery.")
        }
        return result
    }
}
