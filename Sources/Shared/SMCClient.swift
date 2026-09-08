import Foundation
import IOKit
import OSLog

/// Only SMC read commands can be represented. There is no write entry point.
enum SMCReadCommand: UInt8, Sendable {
    case bytes = 5
    case keyAtIndex = 8
    case keyInfo = 9
}

struct SMCReadRequest: Sendable {
    let command: SMCReadCommand
    var key: String = "    "
    var dataSize: UInt32 = 0
    var index: UInt32 = 0
}

protocol SMCReadTransport: AnyObject {
    func exchange(_ request: SMCReadRequest) throws -> [UInt8]
}

enum SMCCodec {
    static let frameSize = 80

    static func fourCC(_ text: String) throws -> UInt32 {
        let bytes = Array(text.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else {
            throw TelemetryError.invalidData("Invalid SMC key/type identifier")
        }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ value: UInt32) throws -> String {
        let bytes = [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        guard bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else {
            throw TelemetryError.invalidData("Invalid SMC key/type bytes")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func uint32(_ bytes: [UInt8], at offset: Int, littleEndian: Bool = true) throws -> UInt32 {
        guard offset >= 0, bytes.count >= 4, offset <= bytes.count - 4 else {
            throw TelemetryError.invalidData("Truncated SMC integer")
        }
        let slice = bytes[offset..<(offset + 4)]
        return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func frame(_ request: SMCReadRequest) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: frameSize)
        func put(_ value: UInt32, at offset: Int) {
            for n in 0..<4 { bytes[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
        }
        // Explicit C ABI offsets avoid relying on Swift struct padding/alignment.
        put(try fourCC(request.key), at: 0)
        put(request.dataSize, at: 28)
        bytes[42] = request.command.rawValue
        put(request.index, at: 44)
        return bytes
    }

    static func numeric(type: String, bytes: [UInt8]) throws -> Double {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count == 4 else { throw TelemetryError.invalidData("flt requires 4 bytes") }
            value = Double(Float(bitPattern: try uint32(bytes, at: 0)))
        case "ui8 ":
            guard bytes.count == 1 else { throw TelemetryError.invalidData("ui8 requires 1 byte") }
            value = Double(bytes[0])
        case "ui16":
            guard bytes.count == 2 else { throw TelemetryError.invalidData("ui16 requires 2 bytes") }
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count == 4 else { throw TelemetryError.invalidData("ui32 requires 4 bytes") }
            value = Double(try uint32(bytes, at: 0, littleEndian: false))
        case "si8 ":
            guard bytes.count == 1 else { throw TelemetryError.invalidData("si8 requires 1 byte") }
            value = Double(Int8(bitPattern: bytes[0]))
        case "si16":
            guard bytes.count == 2 else { throw TelemetryError.invalidData("si16 requires 2 bytes") }
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "si32":
            guard bytes.count == 4 else { throw TelemetryError.invalidData("si32 requires 4 bytes") }
            value = Double(Int32(bitPattern: try uint32(bytes, at: 0, littleEndian: false)))
        default:
            let characters = Array(type)
            guard characters.count == 4, characters[1] == "p",
                  let integerBits = Int(String(characters[2]), radix: 16),
                  let fractionBits = Int(String(characters[3]), radix: 16), bytes.count == 2 else {
                throw TelemetryError.invalidData("Unsupported SMC numeric format: \(type)")
            }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            if characters[0] == "s", integerBits + fractionBits == 15 {
                value = Double(Int16(bitPattern: raw)) / Double(1 << fractionBits)
            } else if characters[0] == "f", integerBits + fractionBits == 16 {
                value = Double(raw) / Double(1 << fractionBits)
            } else {
                throw TelemetryError.invalidData("Unsupported SMC fixed-point format: \(type)")
            }
        }
        guard value.isFinite else { throw TelemetryError.invalidData("Non-finite SMC numeric value") }
        return value
    }

    static func temperature(type: String, bytes: [UInt8]) throws -> Double {
        let value: Double
        switch type {
        case "sp78":
            guard bytes.count == 2 else { throw TelemetryError.invalidData("sp78 requires 2 bytes") }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            value = Double(Int16(bitPattern: raw)) / 256
        case "flt ":
            guard bytes.count == 4 else { throw TelemetryError.invalidData("flt requires 4 bytes") }
            value = Double(Float(bitPattern: try uint32(bytes, at: 0)))
        default: throw TelemetryError.invalidData("Unsupported SMC temperature format: \(type)")
        }
        guard value.isFinite else { throw TelemetryError.invalidData("Non-finite SMC temperature") }
        return value
    }
}

final class SMCIOKitTransport: SMCReadTransport {
    private var connection: io_connect_t = 0
    private let logger = Logger(subsystem: "com.snejda.Helios", category: "SMC")

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw TelemetryError.unavailable("AppleSMC service unavailable") }
        defer { IOObjectRelease(service) }
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == KERN_SUCCESS else { throw TelemetryError.ioKit("Open AppleSMC", status) }
    }

    deinit {
        if connection != 0 {
            let status = IOServiceClose(connection)
            if status != KERN_SUCCESS { logger.error("Closing AppleSMC failed: \(status)") }
        }
    }

    func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
        guard connection != 0 else { throw TelemetryError.unavailable("AppleSMC connection unavailable") }
        let input = try SMCCodec.frame(request)
        var output = [UInt8](repeating: 0, count: SMCCodec.frameSize)
        var outputSize = SMCCodec.frameSize
        let status = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                IOConnectCallStructMethod(connection, 2, inputBuffer.baseAddress, inputBuffer.count, outputBuffer.baseAddress, &outputSize)
            }
        }
        guard status == KERN_SUCCESS else { throw TelemetryError.ioKit("Read SMC \(request.key)", status) }
        guard outputSize == SMCCodec.frameSize else { throw TelemetryError.invalidData("Unexpected AppleSMC response size") }
        guard output[40] == 0 else { throw TelemetryError.smc(request.key, output[40]) }
        return output
    }
}

struct SMCKeyInfo: Sendable {
    let type: String
    let size: UInt32
}

struct SMCKeyDiscovery {
    let keys: [String]
    let failures: [String: TelemetryError]
}

/// Confined to one provider actor or the daemon's hardware queue.
final class SMCClient {
    private let transport: any SMCReadTransport
    private var metadata: [String: SMCKeyInfo] = [:]

    init(transport: any SMCReadTransport) { self.transport = transport }

    private func exchange(_ request: SMCReadRequest) throws -> [UInt8] {
        let reply = try transport.exchange(request)
        guard reply.count == SMCCodec.frameSize else { throw TelemetryError.invalidData("Truncated SMC frame") }
        guard reply[40] == 0 else { throw TelemetryError.smc(request.key, reply[40]) }
        return reply
    }

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = metadata[key] { return cached }
        let reply = try exchange(SMCReadRequest(command: .keyInfo, key: key))
        let size = try SMCCodec.uint32(reply, at: 28)
        guard size > 0, size <= 32 else { throw TelemetryError.invalidData("Invalid SMC payload size for \(key)") }
        let info = SMCKeyInfo(type: try SMCCodec.string(SMCCodec.uint32(reply, at: 32)), size: size)
        metadata[key] = info
        return info
    }

    func value(_ key: String) throws -> (info: SMCKeyInfo, bytes: [UInt8]) {
        let info = try keyInfo(key)
        let reply = try exchange(SMCReadRequest(command: .bytes, key: key, dataSize: info.size))
        return (info, Array(reply[48..<(48 + Int(info.size))]))
    }

    func discoverKeys() throws -> SMCKeyDiscovery {
        let countValue = try value("#KEY")
        guard countValue.info.type == "ui32", countValue.bytes.count == 4 else {
            throw TelemetryError.invalidData("Invalid SMC key count format")
        }
        let count = try SMCCodec.uint32(countValue.bytes, at: 0, littleEndian: false)
        guard count > 0, count <= 16_384 else { throw TelemetryError.invalidData("SMC key count outside supported bounds") }
        var keys = Set<String>()
        var failures: [String: TelemetryError] = [:]
        for index in 0..<count {
            let result = captureMetric {
                let reply = try exchange(SMCReadRequest(command: .keyAtIndex, index: index))
                return try SMCCodec.string(SMCCodec.uint32(reply, at: 0))
            }
            switch result {
            case .success(let key): keys.insert(key)
            case .failure(let error):
                if case .ioKit = error { throw error }
                failures["Key index \(index)"] = error
            }
        }
        guard !keys.isEmpty else { throw TelemetryError.unavailable("No SMC keys discovered") }
        return SMCKeyDiscovery(keys: keys.sorted(), failures: failures)
    }
}
