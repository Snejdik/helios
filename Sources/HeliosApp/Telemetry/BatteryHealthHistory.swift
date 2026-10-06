import Foundation

/// One day of battery condition: the long-term trend a single reading cannot show.
struct BatteryDayRecord: Codable, Sendable, Equatable, Identifiable {
    /// Start of the local day.
    let day: Date
    let healthPercent: Double?
    let maximumCapacityMAh: Int?
    let designCapacityMAh: Int?
    let cycleCount: Int?

    var id: Date { day }
}

struct BatteryHealthSummary: Sendable, Equatable {
    let days: [BatteryDayRecord]
    static let empty = BatteryHealthSummary(days: [])

    var latest: BatteryDayRecord? { days.last }

    /// Health change over the recorded span in percentage points (negative = wear).
    var healthChangePoints: Double? {
        guard let first = days.first(where: { $0.healthPercent != nil })?.healthPercent,
              let last = days.last(where: { $0.healthPercent != nil })?.healthPercent,
              days.count >= 2 else { return nil }
        return last - first
    }

    /// Charge cycles added over the recorded span.
    var cyclesAdded: Int? {
        guard let first = days.first(where: { $0.cycleCount != nil })?.cycleCount,
              let last = days.last(where: { $0.cycleCount != nil })?.cycleCount,
              days.count >= 2 else { return nil }
        return last - first
    }
}

enum BatteryHealthEngine {
    /// About three years of one record a day: a few hundred KB at most.
    static let retentionDays = 1_100
    /// A health reading moves a little as macOS refines it; only a real change is
    /// written again within the same day.
    static let persistenceThresholdPoints = 0.3

    static func record(from battery: BatteryMetrics, now: Date, calendar: Calendar = .current)
        -> BatteryDayRecord?
    {
        func value<T>(_ result: MetricResult<T>) -> T? {
            if case .success(let value) = result { return value }
            return nil
        }
        let health = value(battery.healthPercent).flatMap { $0.isFinite && (0...150).contains($0) ? $0 : nil }
        let record = BatteryDayRecord(
            day: calendar.startOfDay(for: now), healthPercent: health,
            maximumCapacityMAh: value(battery.maximumCapacityMAh),
            designCapacityMAh: value(battery.designCapacityMAh), cycleCount: value(battery.cycleCount))
        guard record.healthPercent != nil || record.cycleCount != nil else { return nil }
        return record
    }

    /// Folds a new reading into the list. Readings older than the newest day (a
    /// clock rollback) are ignored; the same day replaces its record.
    static func merged(_ days: [BatteryDayRecord], with record: BatteryDayRecord) -> [BatteryDayRecord] {
        var result = days
        if let last = result.last {
            if record.day < last.day { return result }
            if record.day == last.day { result[result.count - 1] = record } else { result.append(record) }
        } else {
            result.append(record)
        }
        if result.count > retentionDays { result.removeFirst(result.count - retentionDays) }
        return result
    }

    /// Whether a record differs enough from what was last written to be written again.
    static func needsPersisting(_ record: BatteryDayRecord, after persisted: BatteryDayRecord?) -> Bool {
        guard let persisted, persisted.day == record.day else { return true }
        if record.cycleCount != persisted.cycleCount { return true }
        switch (record.healthPercent, persisted.healthPercent) {
        case (let new?, let old?): return abs(new - old) >= persistenceThresholdPoints
        case (nil, nil): return false
        default: return true
        }
    }

    /// Loaded lines: later lines for the same day win; order and bounds are enforced.
    static func sanitized(_ days: [BatteryDayRecord], now: Date) -> [BatteryDayRecord] {
        var byDay: [Date: BatteryDayRecord] = [:]
        for day in days where day.day <= now.addingTimeInterval(86_400) { byDay[day.day] = day }
        let ordered = byDay.values.sorted { $0.day < $1.day }
        return Array(ordered.suffix(retentionDays))
    }
}

/// Append-only daily battery record. One line per day (rarely two); the file stays
/// tiny, so there is nothing to compact except the occasional duplicate day.
actor BatteryHealthHistoryStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var days: [BatteryDayRecord]?
    private var persisted: BatteryDayRecord?
    private var rawLineCount = 0

    init(url: URL = BatteryHealthHistoryStore.defaultURL()) {
        self.url = url
        encoder = JSONEncoder(); decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("battery-health-v1.ndjson")
    }

    func current(now: Date = Date()) -> BatteryHealthSummary {
        BatteryHealthSummary(days: loadIfNeeded(now: now))
    }

    func record(snapshot: TelemetrySnapshot, now: Date = Date(), calendar: Calendar = .current)
        -> BatteryHealthSummary
    {
        var loaded = loadIfNeeded(now: now)
        guard case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 30, now: now),
              let record = BatteryHealthEngine.record(from: battery, now: now, calendar: calendar)
        else { return BatteryHealthSummary(days: loaded) }
        let updated = BatteryHealthEngine.merged(loaded, with: record)
        guard updated != loaded else { return BatteryHealthSummary(days: loaded) }
        loaded = updated
        days = loaded
        if BatteryHealthEngine.needsPersisting(record, after: persisted) {
            appendLine(record)
            persisted = record
        }
        return BatteryHealthSummary(days: loaded)
    }

    private func loadIfNeeded(now: Date) -> [BatteryDayRecord] {
        if let days { return days }
        let data = HistoryCompactionPolicy.read(url)
        var decoded: [BatteryDayRecord] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let record = try? decoder.decode(BatteryDayRecord.self, from: Data(line)) { decoded.append(record) }
        }
        rawLineCount = decoded.count
        let clean = BatteryHealthEngine.sanitized(decoded, now: now)
        days = clean
        persisted = clean.last
        if decoded.count > clean.count + 30 || (!data.isEmpty && data.last != 0x0A) { rewrite(clean) }
        return clean
    }

    private func appendLine(_ record: BatteryDayRecord) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try encoder.encode(record); data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            rawLineCount += 1
            if rawLineCount > (days?.count ?? 0) + 30, let days { rewrite(days) }
        } catch {
            // Observability only: a write failure never affects telemetry.
        }
    }

    private func rewrite(_ records: [BatteryDayRecord]) {
        if (try? HistoryCompactionPolicy.writeLines(records, encoder: encoder, to: url)) != nil {
            rawLineCount = records.count
        }
    }
}
