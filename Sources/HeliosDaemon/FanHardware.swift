import Foundation
import IOKit
import OSLog

struct FanChannel: Sendable {
    let id: Int
    let minimum: Double
    let maximum: Double
}

protocol FanHardware: AnyObject {
    func channels() throws -> [FanChannel]
    func mode(_ id: Int) throws -> UInt8
    func setTarget(_ channel: FanChannel, rpm: Double) throws
    func setManual(_ id: Int) throws
    func restoreAutomatic(_ id: Int) throws
    func verify(_ channel: FanChannel, rpm: Double) throws
}

/// The only SMC write transport in the project. Compiled into HeliosDaemon only.
/// All callers are confined to the controller's hardware queue.
final class SMCFanHardware: FanHardware {
    private let reader: SMCFanReader
    private var connection: io_connect_t = 0
    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanSMC")

    init() throws {
        guard geteuid() == 0 else { throw TelemetryError.unavailable("Fan writes require the privileged helper") }
        reader = SMCFanReader(client: SMCClient(transport: try SMCIOKitTransport()))
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TelemetryError.unavailable("AppleSMC unavailable") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Open fan writer", result) }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func channels() throws -> [FanChannel] {
        let count = try FanCodec.count(reader.client.value("FNum"))
        return try (0..<count).map { id in
            let minimum = try reader.rpm(id, "Mn")
            let maximum = try reader.rpm(id, "Mx")
            guard minimum >= 0, maximum > minimum else { throw TelemetryError.invalidData("Invalid factory fan limits") }
            _ = try reader.modeKey(id)
            let target = try reader.client.value(FanCodec.key(id, "Tg"))
            _ = try FanCodec.rpm(type: target.info.type, bytes: target.bytes)
            return FanChannel(id: id, minimum: minimum, maximum: maximum)
        }
    }

    func mode(_ id: Int) throws -> UInt8 { try reader.mode(id) }

    static func encodedRPM(_ rpm: Double, channel: FanChannel, type: String) throws -> [UInt8] {
        guard rpm.isFinite, channel.minimum.isFinite, channel.maximum.isFinite,
              channel.minimum >= 0, channel.maximum > channel.minimum else { throw TelemetryError.invalidData("Invalid RPM request or limits") }
        let clamped = min(channel.maximum, max(channel.minimum, rpm))
        switch type {
        case "fpe2":
            let low = ceil(channel.minimum * 4)
            let high = floor(channel.maximum * 4)
            guard low <= high, high <= Double(UInt16.max) else { throw TelemetryError.invalidData("Unrepresentable fpe2 limits") }
            let value = UInt16(min(high, max(low, (clamped * 4).rounded())))
            return [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
        case "flt ":
            var value = Float(clamped)
            if Double(value) > channel.maximum { value = value.nextDown }
            if Double(value) < channel.minimum { value = value.nextUp }
            guard value.isFinite, Double(value) >= channel.minimum, Double(value) <= channel.maximum else {
                throw TelemetryError.invalidData("Unrepresentable float limits")
            }
            return (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
        default: throw TelemetryError.invalidData("Unsupported fan target encoding")
        }
    }

    func setTarget(_ channel: FanChannel, rpm: Double) throws {
        let key = try FanCodec.key(channel.id, "Tg")
        let info = try reader.client.keyInfo(key)
        try write(key, payload: Self.encodedRPM(rpm, channel: channel, type: info.type))
    }

    func setManual(_ id: Int) throws { try write(reader.modeKey(id), payload: [1]) }

    func restoreAutomatic(_ id: Int) throws {
        // Never write FS! or firmware test/unlock keys. Unsupported/locked
        // per-fan modes fail explicitly instead of escalating firmware access.
        // If a rejected takeover left the fan automatic, do not issue another
        // unnecessary mode write. Always verify the final mode and target.
        if ![0, 3].contains(try mode(id)) { try write(reader.modeKey(id), payload: [0]) }
        let target = try FanCodec.key(id, "Tg")
        let info = try reader.client.keyInfo(target)
        guard (info.type == "flt " && info.size == 4) || (info.type == "fpe2" && info.size == 2) else {
            throw TelemetryError.invalidData("Unsupported automatic target reset")
        }
        // Zero clears the target after switching to automatic; it is not a
        // manual RPM command and is never used to bypass the manual bounds.
        if try reader.rpm(id, "Tg") != 0 {
            try write(target, payload: [UInt8](repeating: 0, count: Int(info.size)))
        }
        guard [0, 3].contains(try mode(id)), try reader.rpm(id, "Tg") == 0 else {
            throw TelemetryError.unavailable("Automatic mode and cleared target were not confirmed")
        }
    }

    func verify(_ channel: FanChannel, rpm: Double) throws {
        let expected = min(channel.maximum, max(channel.minimum, rpm))
        guard try mode(channel.id) == 1, abs(try reader.rpm(channel.id, "Tg") - expected) <= 0.5 else {
            throw TelemetryError.unavailable("Firmware did not accept the requested fan target")
        }
    }

    private func write(_ key: String, payload: [UInt8]) throws {
        // This private sink accepts only discovered per-fan target/mode keys.
        let allowed = try (0..<FanCodec.maximumFanCount).flatMap { id in try ["Tg", "Md", "md"].map { try FanCodec.key(id, $0) } }
        let info = try reader.client.keyInfo(key)
        guard allowed.contains(key), payload.count == Int(info.size), !payload.isEmpty, payload.count <= 32 else {
            throw TelemetryError.invalidData("Fan write rejected")
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
        logger.notice("Write key=\(key, privacy: .public) type='\(info.type, privacy: .public)' size=\(info.size) bytes=[\(raw, privacy: .public)] IOReturn=0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public) SMCResult=0x\(String(output[40], radix: 16), privacy: .public) SMCStatus=0x\(String(output[41], radix: 16), privacy: .public) replySize=\(size)")
        guard result == KERN_SUCCESS else { throw TelemetryError.ioKit("Write \(key) type '\(info.type)'", result) }
        guard size == SMCCodec.frameSize else { throw TelemetryError.invalidData("Truncated fan write response") }
        guard output[40] == 0 else { throw TelemetryError.smc(key, output[40]) }
    }
}
