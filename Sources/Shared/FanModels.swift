import Foundation

@objc enum HeliosFanMode: Int, Sendable, CaseIterable {
    case system, boost, override
    var label: String {
        switch self { case .system: "System"; case .boost: "Boost"; case .override: "Override" }
    }
}

@objc enum HeliosFanState: Int, Sendable {
    case system, boost, override, restoring, recoveryRequired
}

/// Cross-process thermal safety constant. The app uses it for the emergency
/// Auto Rules latch and the privileged helper independently uses the same
/// threshold as a hard floor that forces factory-max cooling.
enum CoolingRulesSafetyProfile {
    static let emergencyMaximumCelsius = 95.0
}

struct FanReading: Sendable, Identifiable {
    let id: Int
    let actualRPM: MetricResult<Double>
    let targetRPM: MetricResult<Double>
    let minimumRPM: MetricResult<Double>
    let maximumRPM: MetricResult<Double>
    let automatic: MetricResult<Bool>
}

struct FanInventory: Sendable { let fans: [FanReading] }

enum FanCodec {
    static let maximumFanCount = 8
    static func key(_ id: Int, _ suffix: String) throws -> String {
        guard (0..<maximumFanCount).contains(id), ["Ac", "Tg", "Mn", "Mx", "Md", "md"].contains(suffix) else {
            throw TelemetryError.invalidData("Invalid fan key")
        }
        return "F\(id)\(suffix)"
    }

    static func rpm(type: String, bytes: [UInt8]) throws -> Double {
        let value: Double
        switch (type, bytes.count) {
        case ("fpe2", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("flt ", 4): value = Double(Float(bitPattern: try SMCCodec.uint32(bytes, at: 0)))
        default: throw TelemetryError.invalidData("Unsupported fan RPM encoding")
        }
        guard value.isFinite, (0...30_000).contains(value) else { throw TelemetryError.invalidData("Invalid fan RPM") }
        return value
    }

    static func count(_ value: (info: SMCKeyInfo, bytes: [UInt8])) throws -> Int {
        guard value.info.type == "ui8 ", value.bytes.count == 1,
              Int(value.bytes[0]) <= maximumFanCount else { throw TelemetryError.invalidData("Invalid fan count") }
        return Int(value.bytes[0]) // Zero is a valid fanless Mac.
    }
}

/// Shared read-only parsing. Neither this reader nor its transport can write.
final class SMCFanReader {
    let client: SMCClient
    init(client: SMCClient) { self.client = client }

    func rpm(_ id: Int, _ suffix: String) throws -> Double {
        let value = try client.value(FanCodec.key(id, suffix))
        return try FanCodec.rpm(type: value.info.type, bytes: value.bytes)
    }

    func modeKey(_ id: Int) throws -> String {
        // Probe capabilities. The lowercase variant exists on newer SoCs;
        // never infer a writeable mode from a temperature-key prefix.
        for suffix in ["md", "Md"] {
            let key = try FanCodec.key(id, suffix)
            if let info = try? client.keyInfo(key), info.type == "ui8 ", info.size == 1 { return key }
        }
        throw TelemetryError.unavailable("Fan mode readout unavailable")
    }

    func mode(_ id: Int) throws -> UInt8 {
        let value = try client.value(modeKey(id))
        guard value.info.type == "ui8 ", value.bytes.count == 1 else { throw TelemetryError.invalidData("Invalid fan mode") }
        return value.bytes[0]
    }

    func read() throws -> FanInventory {
        let count = try FanCodec.count(client.value("FNum"))
        return FanInventory(fans: (0..<count).map { id in
            FanReading(id: id, actualRPM: captureMetric { try rpm(id, "Ac") },
                       targetRPM: captureMetric { try rpm(id, "Tg") },
                       minimumRPM: captureMetric { try rpm(id, "Mn") },
                       maximumRPM: captureMetric { try rpm(id, "Mx") },
                       automatic: captureMetric {
                let mode = try mode(id)
                guard [0, 1, 3].contains(mode) else { throw TelemetryError.unavailable("Unknown fan mode") }
                return mode == 0 || mode == 3
            })
        })
    }
}
