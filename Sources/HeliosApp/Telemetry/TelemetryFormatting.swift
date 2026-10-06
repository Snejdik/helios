import Foundation

/// Presentation-only interpretation. The source result is retained even when
/// expired; a stale reading is not evidence of provider failure or recovery.
struct MetricObservation<Value: Sendable>: Sendable {
    enum State: Sendable, Equatable { case available, waiting, stale, unavailable }
    let source: MetricResult<Value>
    let isStale: Bool

    var state: State {
        switch source {
        case .failure(.warmingUp): return .waiting
        case .failure: return .unavailable
        case .success: return isStale ? .stale : .available
        }
    }

    var freshResult: MetricResult<Value> {
        isStale ? .failure(.unavailable("Reading is stale")) : source
    }
}

enum TelemetryFormatting {
    private static let unsignedFormats = ["%.0f", "%.1f", "%.2f", "%.3f"]
    private static let signedFormats = ["%+.0f", "%+.1f", "%+.2f", "%+.3f"]
    static func observation<Value>(_ sample: MetricSample<Value>, maxAge: TimeInterval,
                                   now: Date = Date()) -> MetricObservation<Value> {
        let age = now.timeIntervalSince(sample.capturedAt)
        let current = age.isFinite && maxAge.isFinite && maxAge >= 0
            && age >= -1 && age <= maxAge
        return MetricObservation(source: sample.result, isStale: !current)
    }

    static func fresh<Value>(_ sample: MetricSample<Value>, maxAge: TimeInterval, now: Date = Date()) -> MetricResult<Value> {
        observation(sample, maxAge: maxAge, now: now).freshResult
    }

    // Fixed precision policies avoid view-local format strings. Invalid input
    // becomes unavailable; telemetry precision and signed battery flow are kept.
    static func percent(_ value: Double, decimals: Int = 0) -> String {
        number(value, decimals: decimals, suffix: "%", nonnegative: true)
    }

    static func temperature(_ value: Double, decimals: Int = 0) -> String {
        guard value.isFinite else { return "—" }
        return TemperatureUnit.current.format(value, decimals: decimals)
    }

    static func watts(_ value: Double, decimals: Int = 1, signed: Bool = false,
                      showPositiveSign: Bool = true) -> String {
        number(value, decimals: decimals, suffix: " W", signed: signed && showPositiveSign,
               nonnegative: !signed)
    }

    static func rpm(_ value: Double) -> String {
        number(value, decimals: 0, suffix: " RPM", nonnegative: true)
    }

    static func fanRPM(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return value < 50 ? "Fan off" : rpm(value)
    }

    static func fanSummary(_ inventory: FanInventory) -> String {
        guard let fan = inventory.fans.first else { return "Fanless" }
        return (try? fan.actualRPM.get()).map(fanRPM) ?? "—"
    }

    static func ageSeconds(since date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed.isFinite, let seconds = Int(exactly: max(0, elapsed).rounded(.down))
        else { return "—" }
        return "\(seconds)s"
    }

    private static func number(_ value: Double, decimals: Int, suffix: String,
                               signed: Bool = false, nonnegative: Bool = false) -> String {
        guard value.isFinite, !nonnegative || value >= 0 else { return "—" }
        let formats = signed ? signedFormats : unsignedFormats
        return String(format: formats[min(3, max(0, decimals))], value) + suffix
    }

    static func menuBar(_ snapshot: TelemetrySnapshot, now: Date = Date()) -> String {
        let cpu: String
        switch fresh(snapshot.cpu, maxAge: 5, now: now) {
        case .success(let value): cpu = percent(value.usagePercent)
        case .failure: cpu = "—"
        }
        let temperature: String
        switch fresh(snapshot.thermals, maxAge: 6, now: now).flatMap(\.maximumSoCCelsius) {
        case .success(let value): temperature = Self.temperature(value)
        case .failure: temperature = "—"
        }
        return "CPU \(cpu) · SoC \(temperature)"
    }

    static func text<Value>(_ result: MetricResult<Value>, format: (Value) -> String) -> String {
        switch result {
        case .success(let value): return format(value)
        case .failure(let error): return "Unavailable — \(error.localizedDescription)"
        }
    }

    /// `ProcessActivity.cpuPercent` follows Activity Monitor semantics: 100% means
    /// one logical CPU fully occupied, so a multi-threaded process can exceed 100%.
    /// Normal user-facing process lists instead show the process share of the
    /// machine's total logical CPU capacity on a familiar 0...100% scale.
    static func processCPUSharePercent(
        _ activityMonitorPercent: Double?,
        logicalProcessorCount: Int = max(1, ProcessInfo.processInfo.processorCount)
    ) -> Double? {
        guard let activityMonitorPercent,
              activityMonitorPercent.isFinite,
              activityMonitorPercent >= 0,
              logicalProcessorCount > 0 else { return nil }
        return min(100, activityMonitorPercent / Double(logicalProcessorCount))
    }

    static func processCPUShareText(
        _ activityMonitorPercent: Double?,
        logicalProcessorCount: Int = max(1, ProcessInfo.processInfo.processorCount)
    ) -> String {
        processCPUSharePercent(
            activityMonitorPercent, logicalProcessorCount: logicalProcessorCount
        ).map { String(format: "%.1f%%", $0) } ?? "—"
    }

    static func gibibytes(_ bytes: UInt64) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

    static func storageBytes(_ bytes: UInt64) -> String { decimalBytes(Double(bytes)) }

    static func decimalBytes(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes >= 1_000_000_000_000 { return String(format: "%.2f TB", bytes / 1_000_000_000_000) }
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB", bytes / 1_000) }
        return String(format: "%.0f B", bytes)
    }

    static func count(_ value: UInt64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }

    static func iops(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
        return String(format: "%.0f", value)
    }

    static func bitsPerSecond(_ bitsPerSecond: UInt64) -> String {
        let value = Double(bitsPerSecond)
        if value >= 1_000_000_000 { return String(format: "%.1f Gb/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0f Mb/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f Kb/s", value / 1_000) }
        return "\(bitsPerSecond) b/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0,
              let total = Int(exactly: seconds.rounded(.down)) else { return "—" }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    static func batteryTimeRemaining(_ value: BatteryTimeRemaining) -> String {
        switch value {
        case .seconds(let seconds): return duration(seconds)
        case .calculating: return "Calculating"
        case .unlimited: return "On AC"
        }
    }

    static func bytesPerSecond(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        if bytesPerSecond >= 1_000_000_000 { return String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000) }
        if bytesPerSecond >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000) }
        if bytesPerSecond >= 1_000 { return String(format: "%.1f KB/s", bytesPerSecond / 1_000) }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}
