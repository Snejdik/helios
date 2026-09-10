import Foundation

actor FanOwnershipPreflightProvider {
    private var reader: SMCFanOwnershipPreflightReader?

    func reset() { reader = nil }

    func sample() -> MetricSample<FanOwnershipPreflightSnapshot> {
        MetricSample(captureMetric {
            if reader == nil { reader = try SMCFanOwnershipPreflightReader() }
            guard let reader else { throw TelemetryError.unavailable("Fan ownership preflight unavailable") }
            return try reader.read()
        })
    }
}
