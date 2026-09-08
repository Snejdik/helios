import Foundation

struct TelemetryHistoryPoint: Sendable, Equatable {
    let capturedAt: Date
    let cpuPercent: Double?
    let gpuPercent: Double?
    let maxSoCCelsius: Double?
    let systemPowerWatts: Double?
    let fanRPM: Double?
    let networkDownloadBytesPerSecond: Double?
    let networkUploadBytesPerSecond: Double?
}

struct TelemetryHistory: Sendable {
    static let maximumPoints = 3_600

    private(set) var points: [TelemetryHistoryPoint] = []
    private(set) var sessionEnergyWattHours: Double = 0
    private(set) var measuredPowerCoverageSeconds: TimeInterval = 0

    mutating func reset() {
        points.removeAll(keepingCapacity: true)
        sessionEnergyWattHours = 0
        measuredPowerCoverageSeconds = 0
    }

    mutating func append(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
        if let last = points.last, now.timeIntervalSince(last.capturedAt) < 0.75 { return }
        let point = TelemetryHistoryPoint(
            capturedAt: now,
            cpuPercent: value(TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now).map(\.usagePercent)),
            gpuPercent: value(TelemetryFormatting.fresh(snapshot.gpu, maxAge: 5, now: now).flatMap(\.deviceUtilizationPercent)),
            maxSoCCelsius: value(TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now).flatMap(\.maximumSoCCelsius)),
            systemPowerWatts: value(TelemetryFormatting.fresh(snapshot.systemPower, maxAge: 5, now: now).flatMap(\.totalSystemWatts)),
            fanRPM: firstFanRPM(snapshot, now: now),
            networkDownloadBytesPerSecond: value(TelemetryFormatting.fresh(snapshot.network, maxAge: 5, now: now).flatMap(\.throughput).map(\.downloadBytesPerSecond)),
            networkUploadBytesPerSecond: value(TelemetryFormatting.fresh(snapshot.network, maxAge: 5, now: now).flatMap(\.throughput).map(\.uploadBytesPerSecond))
        )

        if let previous = points.last,
           let firstWatts = previous.systemPowerWatts,
           let secondWatts = point.systemPowerWatts {
            let elapsed = point.capturedAt.timeIntervalSince(previous.capturedAt)
            if elapsed > 0, elapsed <= 5,
               firstWatts.isFinite, secondWatts.isFinite,
               firstWatts >= 0, secondWatts >= 0 {
                sessionEnergyWattHours += ((firstWatts + secondWatts) / 2) * elapsed / 3_600
                measuredPowerCoverageSeconds += elapsed
            }
        }

        points.append(point)
        if points.count > Self.maximumPoints {
            points.removeFirst(points.count - Self.maximumPoints)
        }
    }

    var durationSeconds: TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return max(0, last.capturedAt.timeIntervalSince(first.capturedAt))
    }

    private func firstFanRPM(_ snapshot: TelemetrySnapshot, now: Date) -> Double? {
        guard case .success(let inventory) = TelemetryFormatting.fresh(snapshot.fans, maxAge: 5, now: now),
              let first = inventory.fans.first,
              case .success(let rpm) = first.actualRPM,
              rpm.isFinite, rpm >= 0 else { return nil }
        return rpm
    }

    private func value<T>(_ result: MetricResult<T>) -> T? {
        if case .success(let value) = result { return value }
        return nil
    }
}
