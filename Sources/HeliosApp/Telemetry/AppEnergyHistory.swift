import Darwin
import Foundation

struct AppEnergyEntry: Codable, Sendable, Equatable, Identifiable {
    let appKey: String
    let displayName: String
    let energyWattHours: Double
    let cpuCoreSeconds: Double
    let wakeups: Double
    let peakMemoryBytes: UInt64

    var id: String { appKey }
}

struct AppEnergyBucket: Codable, Sendable, Equatable {
    let capturedAt: Date
    let durationSeconds: TimeInterval
    let onBattery: Bool?
    let batteryPercent: Double?
    let entries: [AppEnergyEntry]
}

struct AppEnergyTrend: Sendable, Equatable, Identifiable {
    let appKey: String
    let displayName: String
    let recentEnergyWattHours: Double
    let previousEnergyWattHours: Double
    let changeWattHours: Double
    let changePercent: Double?

    var id: String { appKey }
}

struct AppEnergySummary: Sendable, Equatable {
    let buckets: [AppEnergyBucket]
    let topAll: [AppEnergyEntry]
    let topOnBattery: [AppEnergyEntry]
    let coverageSeconds: TimeInterval
    let onBatteryCoverageSeconds: TimeInterval
    /// One-hour app-energy comparison anchored to the newest persisted bucket.
    /// This stays descriptive: it never claims undocumented task energy is
    /// billing-grade joule measurement.
    let recentHourTrends: [AppEnergyTrend]
    let recentHourOnBatteryChargeDeltaPercent: Double?

    static let empty = AppEnergySummary(
        buckets: [], topAll: [], topOnBattery: [], coverageSeconds: 0, onBatteryCoverageSeconds: 0,
        recentHourTrends: [], recentHourOnBatteryChargeDeltaPercent: nil
    )
}

private struct MutableAppEnergy {
    var displayName: String
    var energyWattHours = 0.0
    var cpuCoreSeconds = 0.0
    var wakeups = 0.0
    var peakMemoryBytes: UInt64 = 0

    mutating func add(powerWatts: Double?, cpuPercent: Double?, wakeupsPerSecond: Double?, memoryBytes: UInt64, seconds: Double) {
        if let powerWatts, powerWatts.isFinite, powerWatts >= 0 {
            energyWattHours += powerWatts * seconds / 3_600
        }
        if let cpuPercent, cpuPercent.isFinite, cpuPercent >= 0 {
            cpuCoreSeconds += (cpuPercent / 100) * seconds
        }
        if let wakeupsPerSecond, wakeupsPerSecond.isFinite, wakeupsPerSecond >= 0 {
            wakeups += wakeupsPerSecond * seconds
        }
        peakMemoryBytes = max(peakMemoryBytes, memoryBytes)
    }

    func frozen(key: String) -> AppEnergyEntry {
        AppEnergyEntry(appKey: key, displayName: displayName, energyWattHours: energyWattHours,
                       cpuCoreSeconds: cpuCoreSeconds, wakeups: wakeups, peakMemoryBytes: peakMemoryBytes)
    }
}

enum AppEnergyHistoryEngine {
    static let rawRetention: TimeInterval = 7 * 24 * 60 * 60
    static let maximumBuckets = 10_500
    static let flushInterval: TimeInterval = 60

    static func sanitized(_ buckets: [AppEnergyBucket], now: Date) -> [AppEnergyBucket] {
        let cutoff = now.addingTimeInterval(-rawRetention)
        var result: [AppEnergyBucket] = []
        result.reserveCapacity(min(buckets.count, maximumBuckets))
        var last = Date.distantPast
        for bucket in buckets where bucket.capturedAt >= cutoff && bucket.capturedAt <= now.addingTimeInterval(300) {
            guard bucket.capturedAt >= last,
                  bucket.durationSeconds.isFinite, bucket.durationSeconds > 0, bucket.durationSeconds <= 300 else { continue }
            let entries = bucket.entries.filter {
                !$0.appKey.isEmpty && !$0.displayName.isEmpty && $0.energyWattHours.isFinite && $0.energyWattHours >= 0 &&
                $0.cpuCoreSeconds.isFinite && $0.cpuCoreSeconds >= 0 && $0.wakeups.isFinite && $0.wakeups >= 0
            }
            result.append(AppEnergyBucket(capturedAt: bucket.capturedAt, durationSeconds: bucket.durationSeconds,
                                          onBattery: bucket.onBattery, batteryPercent: bucket.batteryPercent, entries: entries))
            last = bucket.capturedAt
        }
        if result.count > maximumBuckets { result.removeFirst(result.count - maximumBuckets) }
        return result
    }

    static func summary(_ buckets: [AppEnergyBucket]) -> AppEnergySummary {
        var all: [String: MutableAppEnergy] = [:]
        var battery: [String: MutableAppEnergy] = [:]
        var coverage = 0.0
        var batteryCoverage = 0.0
        for bucket in buckets {
            coverage += bucket.durationSeconds
            if bucket.onBattery == true { batteryCoverage += bucket.durationSeconds }
            for entry in bucket.entries {
                merge(entry, into: &all)
                if bucket.onBattery == true { merge(entry, into: &battery) }
            }
        }
        func leaders(_ map: [String: MutableAppEnergy]) -> [AppEnergyEntry] {
            map.map { $0.value.frozen(key: $0.key) }
                .sorted {
                    if $0.energyWattHours != $1.energyWattHours { return $0.energyWattHours > $1.energyWattHours }
                    return $0.cpuCoreSeconds > $1.cpuCoreSeconds
                }
                .prefix(20).map { $0 }
        }
        let trends = recentTrends(buckets)
        return AppEnergySummary(
            buckets: buckets, topAll: leaders(all), topOnBattery: leaders(battery),
            coverageSeconds: coverage, onBatteryCoverageSeconds: batteryCoverage,
            recentHourTrends: trends,
            recentHourOnBatteryChargeDeltaPercent: recentOnBatteryChargeDelta(buckets)
        )
    }

    /// Compare the most recent hour with the directly preceding hour. Buckets
    /// are already sanitized/ordered, so the newest sample is a deterministic
    /// anchor even when the wall clock jumps or Helios has been offline.
    private static func recentTrends(_ buckets: [AppEnergyBucket]) -> [AppEnergyTrend] {
        guard let anchor = buckets.last?.capturedAt else { return [] }
        let recentStart = anchor.addingTimeInterval(-3_600)
        let previousStart = anchor.addingTimeInterval(-7_200)
        var recent: [String: MutableAppEnergy] = [:]
        var previous: [String: MutableAppEnergy] = [:]
        for bucket in buckets {
            if bucket.capturedAt > recentStart && bucket.capturedAt <= anchor {
                for entry in bucket.entries { merge(entry, into: &recent) }
            } else if bucket.capturedAt > previousStart && bucket.capturedAt <= recentStart {
                for entry in bucket.entries { merge(entry, into: &previous) }
            }
        }
        return recent.map { key, value in
            let current = value.frozen(key: key)
            let prior = previous[key]?.energyWattHours ?? 0
            let delta = current.energyWattHours - prior
            let percent: Double? = prior >= 0.001 ? (delta / prior) * 100 : nil
            return AppEnergyTrend(
                appKey: key, displayName: current.displayName,
                recentEnergyWattHours: current.energyWattHours,
                previousEnergyWattHours: prior,
                changeWattHours: delta,
                changePercent: percent?.isFinite == true ? percent : nil
            )
        }
        .filter { $0.recentEnergyWattHours >= 0.0001 || $0.previousEnergyWattHours >= 0.0001 }
        .sorted {
            if $0.changeWattHours != $1.changeWattHours { return $0.changeWattHours > $1.changeWattHours }
            return $0.recentEnergyWattHours > $1.recentEnergyWattHours
        }
        .prefix(20).map { $0 }
    }

    private static func recentOnBatteryChargeDelta(_ buckets: [AppEnergyBucket]) -> Double? {
        guard let anchor = buckets.last?.capturedAt else { return nil }
        let start = anchor.addingTimeInterval(-3_600)
        let points = buckets
            .filter { $0.capturedAt > start && $0.onBattery == true }
            .compactMap { bucket -> (Date, Double)? in
                guard let percent = bucket.batteryPercent, percent.isFinite, (0...100).contains(percent) else { return nil }
                return (bucket.capturedAt, percent)
            }
            .sorted { $0.0 < $1.0 }
        guard let first = points.first?.1, let last = points.last?.1, points.count >= 2 else { return nil }
        return last - first
    }

    private static func merge(_ entry: AppEnergyEntry, into map: inout [String: MutableAppEnergy]) {
        var value = map[entry.appKey] ?? MutableAppEnergy(displayName: entry.displayName)
        value.energyWattHours += entry.energyWattHours
        value.cpuCoreSeconds += entry.cpuCoreSeconds
        value.wakeups += entry.wakeups
        value.peakMemoryBytes = max(value.peakMemoryBytes, entry.peakMemoryBytes)
        map[entry.appKey] = value
    }

    static func csv(_ buckets: [AppEnergyBucket]) -> String {
        var lines = ["timestamp,duration_seconds,on_battery,battery_percent,app_key,display_name,energy_wh,cpu_core_seconds,wakeups,peak_memory_bytes"]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for bucket in buckets {
            let timestamp = formatter.string(from: bucket.capturedAt)
            let onBattery = bucket.onBattery.map { $0 ? "true" : "false" } ?? ""
            let battery = bucket.batteryPercent.map { String(format: "%.4f", $0) } ?? ""
            for entry in bucket.entries {
                let fields = [
                    timestamp, String(format: "%.3f", bucket.durationSeconds), onBattery, battery,
                    csvField(entry.appKey), csvField(entry.displayName),
                    String(format: "%.9f", entry.energyWattHours),
                    String(format: "%.6f", entry.cpuCoreSeconds),
                    String(format: "%.3f", entry.wakeups),
                    String(entry.peakMemoryBytes)
                ]
                lines.append(fields.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    static func decodeLines(_ data: Data, decoder: JSONDecoder) -> [AppEnergyBucket] {
        data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? decoder.decode(AppEnergyBucket.self, from: Data(line))
        }
    }
}

actor AppEnergyHistoryStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var buckets: [AppEnergyBucket]?
    private var lastProcessTicks: UInt64?
    private var previousSampleAt: Date?
    private var pendingDuration = 0.0
    private var pending: [String: MutableAppEnergy] = [:]
    private var pendingOnBattery: Bool?
    private var pendingBatteryPercent: Double?
    private var cachedSummary: AppEnergySummary?
    private var appendHandle: FileHandle?
    private var knownFileSize: Int?

    init(url: URL = AppEnergyHistoryStore.defaultURL()) {
        self.url = url
        encoder = JSONEncoder(); decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("app-energy-v1.ndjson")
    }

    func current(now: Date = Date()) -> AppEnergySummary {
        let loaded = loadIfNeeded(now: now)
        if let cachedSummary { return cachedSummary }
        let summary = AppEnergyHistoryEngine.summary(loaded)
        cachedSummary = summary
        return summary
    }

    /// Consumes the 5-second native process deltas in memory and writes one small
    /// aggregate bucket per minute. This keeps long-term attribution useful without
    /// turning Helios itself into a storage workload.
    func consume(snapshot: TelemetrySnapshot, now: Date = Date()) -> AppEnergySummary {
        var loaded = loadIfNeeded(now: now)
        let sample = snapshot.processes
        guard lastProcessTicks != sample.capturedTicks else { return summary(for: loaded) }
        lastProcessTicks = sample.capturedTicks
        guard case .success(let processes) = sample.result else {
            previousSampleAt = nil
            return summary(for: loaded)
        }
        guard let previousSampleAt else {
            self.previousSampleAt = sample.capturedAt
            return summary(for: loaded)
        }
        let elapsed = sample.capturedAt.timeIntervalSince(previousSampleAt)
        self.previousSampleAt = sample.capturedAt
        guard elapsed.isFinite, elapsed > 0, elapsed <= 15 else {
            pending.removeAll(keepingCapacity: true); pendingDuration = 0
            return summary(for: loaded)
        }

        let battery = TelemetryFormatting.fresh(snapshot.battery, maxAge: 20, now: now)
        pendingOnBattery = battery.flatMap(\.powerSource).map { $0 == .battery }.valueOrNil ?? pendingOnBattery
        pendingBatteryPercent = battery.flatMap(\.stateOfChargePercent).valueOrNil ?? pendingBatteryPercent

        for process in processes.energyHistoryLeaders {
            let identity = Self.appIdentity(process)
            var value = pending[identity.key] ?? MutableAppEnergy(displayName: identity.name)
            value.add(powerWatts: process.powerWatts, cpuPercent: process.cpuPercent,
                      wakeupsPerSecond: process.wakeupsPerSecond, memoryBytes: process.physicalFootprintBytes, seconds: elapsed)
            pending[identity.key] = value
        }
        pendingDuration += elapsed
        if pendingDuration < AppEnergyHistoryEngine.flushInterval { return summary(for: loaded) }

        let entries = pending.map { $0.value.frozen(key: $0.key) }
            .sorted { $0.energyWattHours > $1.energyWattHours }
        let bucket = AppEnergyBucket(capturedAt: sample.capturedAt, durationSeconds: pendingDuration,
                                     onBattery: pendingOnBattery, batteryPercent: pendingBatteryPercent, entries: entries)
        loaded.append(bucket)
        loaded = AppEnergyHistoryEngine.sanitized(loaded, now: now)
        buckets = loaded
        appendLine(bucket)
        if loaded.count >= AppEnergyHistoryEngine.maximumBuckets || fileSize() > 24_000_000 { rewrite(loaded) }
        pending.removeAll(keepingCapacity: true); pendingDuration = 0
        pendingOnBattery = nil; pendingBatteryPercent = nil
        let result = AppEnergyHistoryEngine.summary(loaded)
        cachedSummary = result
        return result
    }

    private func summary(for loaded: [AppEnergyBucket]) -> AppEnergySummary {
        if let cachedSummary { return cachedSummary }
        let result = AppEnergyHistoryEngine.summary(loaded)
        cachedSummary = result
        return result
    }

    private static func appIdentity(_ process: ProcessActivity) -> (key: String, name: String) {
        if let path = process.executablePath, let range = path.range(of: ".app/", options: [.caseInsensitive, .backwards]) {
            let prefix = String(path[..<range.lowerBound]) + ".app"
            let url = URL(fileURLWithPath: prefix)
            let name = url.deletingPathExtension().lastPathComponent
            return ("app:" + prefix, name.isEmpty ? process.name : name)
        }
        return ("proc:" + process.name.lowercased(), process.name)
    }

    private func loadIfNeeded(now: Date) -> [AppEnergyBucket] {
        if let buckets { return buckets }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let decoded = AppEnergyHistoryEngine.decodeLines(data, decoder: decoder)
        let clean = AppEnergyHistoryEngine.sanitized(decoded, now: now)
        buckets = clean
        knownFileSize = data.count
        let records = data.split(separator: 0x0A).filter { !$0.isEmpty }.count
        if clean.count != decoded.count || decoded.count != records || (!data.isEmpty && data.last != 0x0A) { rewrite(clean) }
        return clean
    }

    private func appendLine(_ bucket: AppEnergyBucket) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try encoder.encode(bucket); data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? appendHandle?.close()
                appendHandle = nil
                try data.write(to: url, options: .atomic)
                knownFileSize = data.count
                appendHandle = nil
                return
            }
            // A persistent descriptor can outlive atomic replacement or in-place
            // truncation. Validate only at the existing slow append cadence.
            if let appendHandle {
                var descriptor = stat()
                var path = stat()
                guard fstat(appendHandle.fileDescriptor, &descriptor) == 0,
                      stat(url.path, &path) == 0 else { throw CocoaError(.fileReadUnknown) }
                if descriptor.st_dev != path.st_dev || descriptor.st_ino != path.st_ino
                    || knownFileSize != Int(path.st_size) {
                    try appendHandle.close()
                    self.appendHandle = nil
                    knownFileSize = nil
                }
            }
            let handle: FileHandle
            if let appendHandle {
                handle = appendHandle
            } else {
                let opened = try FileHandle(forWritingTo: url)
                knownFileSize = Int(try opened.seekToEnd())
                appendHandle = opened
                handle = opened
            }
            let baseSize = knownFileSize ?? fileSizeFromDisk()
            try handle.write(contentsOf: data)
            knownFileSize = baseSize + data.count
        } catch {
            try? appendHandle?.close()
            appendHandle = nil
            knownFileSize = nil
        }
    }

    private func rewrite(_ values: [AppEnergyBucket]) {
        do {
            try? appendHandle?.close()
            appendHandle = nil
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for value in values { data.append(try encoder.encode(value)); data.append(0x0A) }
            try data.write(to: url, options: .atomic)
            knownFileSize = data.count
        } catch {
            knownFileSize = nil
        }
    }

    private func fileSize() -> Int { knownFileSize ?? fileSizeFromDisk() }

    private func fileSizeFromDisk() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        knownFileSize = size
        return size
    }
}

private extension Result where Failure == TelemetryError {
    var valueOrNil: Success? { try? get() }
}
