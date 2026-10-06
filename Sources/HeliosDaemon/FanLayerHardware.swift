import Darwin
import Foundation
import IOKit
import OSLog

/// One AppleSMC write connection with a caller-supplied allowlist. Every write
/// is checked against live key metadata, logged with both result codes, and
/// a non-zero SMC result is an error (a transport success is not acceptance).
final class FanLayerSMCWriteChannel {
    private var connection: io_connect_t = 0
    private let client: SMCClient
    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanLayerSMC")

    init(client: SMCClient) throws {
        guard geteuid() == 0 else { throw TelemetryError.unavailable("Fan writes require the privileged helper") }
        self.client = client
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TelemetryError.unavailable("AppleSMC unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Open fan layer writer", result) }
    }

    deinit { if connection != 0 { _ = IOServiceClose(connection) } }

    func write(_ key: String, payload: [UInt8], allowed: (String, SMCKeyInfo, [UInt8]) -> Bool) throws {
        let info = try client.keyInfo(key)
        guard !payload.isEmpty, payload.count == Int(info.size), payload.count <= 32,
              allowed(key, info, payload) else {
            throw TelemetryError.invalidData("Fan layer write rejected for \(key)")
        }
        var frame = try SMCCodec.frame(SMCReadRequest(command: .bytes, key: key, dataSize: info.size))
        frame[42] = 6 // kSMCWriteBytes, intentionally absent from SMCReadCommand.
        frame.replaceSubrange(48..<(48 + payload.count), with: payload)
        var output = [UInt8](repeating: 0, count: SMCCodec.frameSize)
        var size = output.count
        let result = frame.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { reply in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, reply.baseAddress, &size)
            }
        }
        let raw = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        logger.notice("Fan layer write key=\(key, privacy: .public) bytes=[\(raw, privacy: .public)] IOReturn=0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public) SMCResult=0x\(String(output[40], radix: 16), privacy: .public)")
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Fan layer write \(key)", result) }
        guard size == SMCCodec.frameSize else { throw TelemetryError.invalidData("Truncated fan layer write response") }
        guard output[40] == 0 else { throw TelemetryError.smc(key, output[40]) }
    }
}

private func flt(_ rpm: Double) -> [UInt8] {
    let value = Float(rpm)
    return (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
}

/// Restore-only backend for start-up/wake recovery on any Apple silicon model
/// and OS build (recovery must run after a macOS update). Its complete write
/// surface is Ftst=0 and FxMd=0 for journaled fans.
/// It cannot acquire, cannot write targets and never needs a passing probe,
/// because recovery is exactly the case where the probe would refuse.
final class FanLayerRecoveryHardware: FanOwnershipRecoveryHardware {
    private let client: SMCClient
    private let reader: SMCFanReader
    private let channel: FanLayerSMCWriteChannel

    init() throws {
        client = SMCClient(transport: try SMCIOKitTransport())
        reader = SMCFanReader(client: client)
        let global = try client.keyInfo("Ftst")
        guard global.type == "ui8 ", global.size == 1 else {
            throw TelemetryError.invalidData("Recovery Ftst metadata is unexpected")
        }
        channel = try FanLayerSMCWriteChannel(client: client)
    }

    private func modeKey(_ id: Int) throws -> String {
        guard (0..<FanCodec.maximumFanCount).contains(id) else { throw FanOwnershipRecoveryError.invalidFanID(id) }
        let key = try FanCodec.key(id, "Md")
        let info = try client.keyInfo(key)
        guard info.type == "ui8 ", info.size == 1 else { throw TelemetryError.invalidData("Recovery mode key is unexpected") }
        return key
    }

    private func mode(_ id: Int) throws -> UInt8 {
        let value = try client.value(modeKey(id))
        guard value.bytes.count == 1 else { throw TelemetryError.invalidData("Invalid fan mode") }
        return value.bytes[0]
    }

    func restoreFanToSystem(_ id: Int) throws {
        let current = try mode(id)
        guard [UInt8(0), 1, 3].contains(current) else {
            throw TelemetryError.invalidData("Unexpected fan mode during recovery")
        }
        if current == 1 {
            try channel.write(try modeKey(id), payload: [0]) { key, info, payload in
                key.hasPrefix("F") && key.hasSuffix("Md") && info.type == "ui8 " && payload == [0]
            }
        }
    }

    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        let current = try mode(id)
        let target = try reader.rpm(id, "Tg")
        let actual = try reader.rpm(id, "Ac")
        return try readGlobalOwnership() == 0 && (current == 0 || current == 3) && target.isFinite && actual.isFinite
    }

    func requestGlobalRelease() throws {
        try channel.write("Ftst", payload: [0]) { key, info, payload in
            key == "Ftst" && info.type == "ui8 " && payload == [0]
        }
    }

    func readGlobalOwnership() throws -> UInt8 {
        let value = try client.value("Ftst")
        guard value.info.type == "ui8 ", value.bytes.count == 1, value.bytes[0] <= 1 else {
            throw TelemetryError.invalidData("Invalid Ftst readback during recovery")
        }
        return value.bytes[0]
    }
}

/// Hardware surface the fan layer engine needs beyond the shared executors.
protocol FanLayerControlHardware: FanOwnershipAcquisitionHardware, FanOwnershipRecoveryHardware {
    /// What macOS is commanding and doing right now (only meaningful while
    /// macOS owns the fan).
    func systemReading(_ id: Int) throws -> (targetRPM: Double, actualRPM: Double)
}

/// Profile-bound writer for the layer. Complete write surface:
/// Ftst = 0/1, FxMd = 0/1 and FxTg = integral RPM inside that fan's live
/// factory range, for the fans of the probed profile only.
final class FanLayerSMCHardware: FanLayerControlHardware {
    private let profile: FanLayerProfile
    private let client: SMCClient
    private let transport: SMCIOKitTransport
    private let reader: SMCFanReader
    private let channel: FanLayerSMCWriteChannel
    private let limits: [Int: FanLayerFanLimits]

    init(profile: FanLayerProfile) throws {
        guard profile.tier != .unsupported, !profile.fans.isEmpty else {
            throw TelemetryError.unavailable("This Mac has no supported fan layer profile")
        }
        self.profile = profile
        transport = try SMCIOKitTransport()
        client = SMCClient(transport: transport)
        reader = SMCFanReader(client: client)
        limits = Dictionary(uniqueKeysWithValues: profile.fans.map { ($0.id, $0.limits) })
        channel = try FanLayerSMCWriteChannel(client: client)
        try validateGlobalAcquisitionBaseline()
    }

    private func requireFan(_ id: Int) throws -> FanLayerFanLimits {
        guard let value = limits[id] else { throw FanOwnershipRecoveryError.invalidFanID(id) }
        return value
    }

    /// Full read-only re-probe: same model/build/fans/keys/limits, Ftst=0 and
    /// every fan under macOS. Runs while the journal is still clean.
    func validateGlobalAcquisitionBaseline() throws {
        let evidence = try SMCFanOwnershipPreflightReader(client: client).read(
            modelIdentifier: profile.identity.modelIdentifier, osBuild: profile.identity.osBuild).evidence
        let access = try FanLayerKeyAccess.read(keys: FanLayerProbe.accessKeys(fanCount: evidence.fanCount),
                                                transport: transport)
        let live = try FanLayerProbe.evaluate(evidence: evidence, cpuBrand: profile.cpuBrand, access: access,
                                              trustedThermalsAvailable: true)
        guard live.tier != .unsupported else {
            throw TelemetryError.unavailable("Fan takeover refused: \(live.reasons.first ?? "baseline is not clean")")
        }
        guard FanLayerProbe.sameSurface(live, as: profile) else {
            throw TelemetryError.unavailable("Fan takeover refused: the fan surface changed since the helper started")
        }
        let foreign = FanLayerForeignControllers.running()
        guard foreign.isEmpty else {
            throw TelemetryError.unavailable("Fan takeover refused: another fan controller is running (\(foreign.joined(separator: ", ")))")
        }
    }

    func systemReading(_ id: Int) throws -> (targetRPM: Double, actualRPM: Double) {
        _ = try requireFan(id)
        return (try reader.rpm(id, "Tg"), try reader.rpm(id, "Ac"))
    }

    func requestGlobalAcquisition() throws {
        try channel.write("Ftst", payload: [1]) { key, info, payload in
            key == "Ftst" && info.type == "ui8 " && payload == [1]
        }
    }

    func readGlobalOwnership() throws -> UInt8 {
        let value = try client.value("Ftst")
        guard value.info.type == "ui8 ", value.bytes.count == 1, value.bytes[0] <= 1 else {
            throw TelemetryError.invalidData("Invalid Ftst readback")
        }
        return value.bytes[0]
    }

    func readFanMode(_ id: Int) throws -> UInt8 {
        _ = try requireFan(id)
        guard try reader.modeKey(id) == "F\(id)Md" else { throw TelemetryError.unavailable("Fan mode key changed") }
        let mode = try reader.mode(id)
        guard [UInt8(0), 1, 3].contains(mode) else { throw TelemetryError.invalidData("Unexpected fan mode") }
        return mode
    }

    func requestFanManual(_ id: Int) throws {
        _ = try requireFan(id)
        guard try readGlobalOwnership() == 1 else {
            throw TelemetryError.unavailable("Manual fan request requires confirmed Ftst ownership")
        }
        let mode = try readFanMode(id)
        if mode == 1 { return }
        do {
            try channel.write("F\(id)Md", payload: [1]) { key, info, payload in
                key == "F\(id)Md" && info.type == "ui8 " && payload == [1]
            }
        } catch TelemetryError.smc(_, let code) where code == 0x82 {
            // Retryable arbitration: the shared executor owns pacing and retries.
        }
    }

    func setFanTarget(_ id: Int, rpm: Double) throws {
        let fan = try requireFan(id)
        guard rpm.isFinite, rpm == rpm.rounded(), rpm >= ceil(fan.minimumRPM), rpm <= floor(fan.maximumRPM) else {
            throw TelemetryError.invalidData("Fan layer target outside the factory range")
        }
        guard try readGlobalOwnership() == 1, try readFanMode(id) == 1 else {
            throw TelemetryError.unavailable("Fan target requires confirmed Ftst=1 and manual mode")
        }
        try channel.write("F\(id)Tg", payload: flt(rpm)) { key, info, payload in
            guard key == "F\(id)Tg", info.type == "flt ", info.size == 4,
                  let decoded = try? FanCodec.rpm(type: info.type, bytes: payload) else { return false }
            return decoded >= ceil(fan.minimumRPM) && decoded <= floor(fan.maximumRPM)
        }
    }

    func verifyFanOwned(_ id: Int, targetRPM: Double) throws -> Bool {
        _ = try requireFan(id)
        guard try readGlobalOwnership() == 1, try readFanMode(id) == 1 else { return false }
        let target = try reader.rpm(id, "Tg")
        return target.isFinite && abs(target - targetRPM) <= 1.0
    }

    func restoreFanToSystem(_ id: Int) throws {
        _ = try requireFan(id)
        if try readFanMode(id) == 1 {
            try channel.write("F\(id)Md", payload: [0]) { key, info, payload in
                key == "F\(id)Md" && info.type == "ui8 " && payload == [0]
            }
        }
    }

    func verifyFanIsSystem(_ id: Int) throws -> Bool {
        let mode = try readFanMode(id)
        let reading = try systemReading(id)
        return try readGlobalOwnership() == 0 && (mode == 0 || mode == 3)
            && reading.targetRPM.isFinite && reading.actualRPM.isFinite
    }

    func requestGlobalRelease() throws {
        try channel.write("Ftst", payload: [0]) { key, info, payload in
            key == "Ftst" && info.type == "ui8 " && payload == [0]
        }
    }
}

/// Coexisting fan controllers are refused, never fought (design §2). The live
/// Ftst/mode baseline is the primary check; this catches a known helper that
/// is running but idle.
enum FanLayerForeignControllers {
    static let markers = [
        "macsfancontrol", "tunabelly", "TG Pro.app", "eu.exelban.Stats.SMC", "smcFanControl",
        "ThermalForge", "fanpro", "MacFanControl", "SMCFanHelper",
    ]

    static func running() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        var found: Set<String> = []
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != getpid() {
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { continue }
            let text = path.withUnsafeBufferPointer { buffer in
                String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            for marker in markers where text.localizedCaseInsensitiveContains(marker) {
                found.insert(marker)
            }
        }
        return found.sorted()
    }
}
