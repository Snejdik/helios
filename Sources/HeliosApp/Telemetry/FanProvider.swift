import Foundation

actor FanProvider {
    private var reader: SMCFanReader?
    private var retryAfter: ContinuousClock.Instant?
    private var failure: TelemetryError?

    func reset() { reader = nil; retryAfter = nil; failure = nil }

    func sample() -> MetricSample<FanInventory> {
        if let retryAfter, ContinuousClock.now < retryAfter, let failure { return MetricSample(.failure(failure)) }
        let date = Date()
        let ticks = HostClock.now
        let result = captureMetric {
            if reader == nil { reader = SMCFanReader(client: SMCClient(transport: try SMCIOKitTransport())) }
            guard let reader else { throw TelemetryError.unavailable("Fan readout unavailable") }
            return try reader.read()
        }
        if case .failure(let error) = result {
            reader = nil
            failure = error
            retryAfter = .now.advanced(by: .seconds(30))
        }
        return MetricSample(result, capturedAt: date, capturedTicks: ticks)
    }
}
