import Foundation

enum SystemPowerParser {
    static func watts(type: String, bytes: [UInt8]) throws -> Double {
        let watts = try SMCCodec.numeric(type: type, bytes: bytes)
        // This is a board/system rail, not battery charge power. Reject nonsense
        // instead of allowing an undocumented format change to look plausible.
        guard (0...500).contains(watts) else {
            throw TelemetryError.invalidData("System power outside plausible range")
        }
        return watts
    }
}

actor SystemPowerProvider {
    private var client: SMCClient?

    func reset() { client = nil }

    func sample() -> MetricSample<SystemPowerMetrics> {
        let result = captureMetric { try read() }
        if case .failure = result { reset() }
        return MetricSample(result)
    }

    private func read() throws -> SystemPowerMetrics {
        if client == nil { client = SMCClient(transport: try SMCIOKitTransport()) }
        guard let client else { throw TelemetryError.unavailable("AppleSMC power reader unavailable") }
        let raw = try client.value("PSTR")
        return SystemPowerMetrics(totalSystemWatts: .success(try SystemPowerParser.watts(type: raw.info.type, bytes: raw.bytes)))
    }
}
