import Foundation

enum TelemetryFormatting {
    static func fresh<Value>(_ sample: MetricSample<Value>, maxAge: TimeInterval, now: Date = Date()) -> MetricResult<Value> {
        let age = now.timeIntervalSince(sample.capturedAt)
        guard age >= -1, age <= maxAge else { return .failure(.unavailable("Reading is stale")) }
        return sample.result
    }

    static func menuBar(_ snapshot: TelemetrySnapshot, now: Date = Date()) -> String {
        let cpu: String
        switch fresh(snapshot.cpu, maxAge: 5, now: now) {
        case .success(let value): cpu = String(format: "%.0f%%", value.usagePercent)
        case .failure: cpu = "—"
        }
        let temperature: String
        switch fresh(snapshot.thermals, maxAge: 6, now: now).flatMap(\.maximumSoCCelsius) {
        case .success(let value): temperature = String(format: "%.0f°C", value)
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

    static func gibibytes(_ bytes: UInt64) -> String { String(format: "%.2f GiB", Double(bytes) / 1_073_741_824) }

    static func storageBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000_000 { return String(format: "%.2f TB", value / 1_000_000_000_000) }
        if value >= 1_000_000_000 { return String(format: "%.1f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1f KB", value / 1_000) }
        return "\(bytes) B"
    }

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
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded(.down))
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
