import Foundation

struct PersistedTelemetryPoint: Codable, Sendable, Equatable {
    let capturedAt: Date
    let cpuPercent: Double?
    let memoryPercent: Double?
    let gpuPercent: Double?
    let maxSoCCelsius: Double?
    let systemPowerWatts: Double?
    let batteryPercent: Double?
    let batteryHealthPercent: Double?
    /// Positive means charging the battery, negative means discharging.
    let batteryPowerWatts: Double?
    let batteryOnAC: Bool?
    let batteryTemperatureCelsius: Double?
    let batteryCycleCount: Int?
    let storageTemperatureCelsius: Double?
    let storageDeviceBSDName: String?
    let storageLifetimeReadBytes: Double?
    let storageLifetimeWrittenBytes: Double?
    let storageReadBytesPerSecond: Double?
    let storageWriteBytesPerSecond: Double?
    let processAccountedReadBytesPerSecond: Double?
    let processAccountedWriteBytesPerSecond: Double?
    let heliosCPUPercent: Double?
    let heliosPowerWatts: Double?
    let heliosMemoryBytes: UInt64?
    let heliosWakeupsPerSecond: Double?
    let fanRPM: Double?
    let networkDownloadBytesPerSecond: Double?
    let networkUploadBytesPerSecond: Double?

    init(capturedAt: Date, cpuPercent: Double?, memoryPercent: Double? = nil, gpuPercent: Double?, maxSoCCelsius: Double?, systemPowerWatts: Double?,
         batteryPercent: Double?, batteryHealthPercent: Double? = nil, batteryPowerWatts: Double? = nil, batteryOnAC: Bool? = nil,
         batteryTemperatureCelsius: Double? = nil, batteryCycleCount: Int? = nil,
         storageTemperatureCelsius: Double?, storageDeviceBSDName: String? = nil, storageLifetimeReadBytes: Double? = nil, storageLifetimeWrittenBytes: Double? = nil,
         storageReadBytesPerSecond: Double? = nil, storageWriteBytesPerSecond: Double? = nil,
         processAccountedReadBytesPerSecond: Double? = nil, processAccountedWriteBytesPerSecond: Double? = nil,
         heliosCPUPercent: Double? = nil, heliosPowerWatts: Double? = nil, heliosMemoryBytes: UInt64? = nil, heliosWakeupsPerSecond: Double? = nil,
         fanRPM: Double?, networkDownloadBytesPerSecond: Double?, networkUploadBytesPerSecond: Double?) {
        self.capturedAt = capturedAt
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.gpuPercent = gpuPercent
        self.maxSoCCelsius = maxSoCCelsius
        self.systemPowerWatts = systemPowerWatts
        self.batteryPercent = batteryPercent
        self.batteryHealthPercent = batteryHealthPercent
        self.batteryPowerWatts = batteryPowerWatts
        self.batteryOnAC = batteryOnAC
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
        self.batteryCycleCount = batteryCycleCount
        self.storageTemperatureCelsius = storageTemperatureCelsius
        self.storageDeviceBSDName = storageDeviceBSDName
        self.storageLifetimeReadBytes = storageLifetimeReadBytes
        self.storageLifetimeWrittenBytes = storageLifetimeWrittenBytes
        self.storageReadBytesPerSecond = storageReadBytesPerSecond
        self.storageWriteBytesPerSecond = storageWriteBytesPerSecond
        self.processAccountedReadBytesPerSecond = processAccountedReadBytesPerSecond
        self.processAccountedWriteBytesPerSecond = processAccountedWriteBytesPerSecond
        self.heliosCPUPercent = heliosCPUPercent
        self.heliosPowerWatts = heliosPowerWatts
        self.heliosMemoryBytes = heliosMemoryBytes
        self.heliosWakeupsPerSecond = heliosWakeupsPerSecond
        self.fanRPM = fanRPM
        self.networkDownloadBytesPerSecond = networkDownloadBytesPerSecond
        self.networkUploadBytesPerSecond = networkUploadBytesPerSecond
    }
}

struct PersistentHistorySummary: Sendable, Equatable {
    let points: [PersistedTelemetryPoint]
    let energyWattHours: Double
    let measuredPowerCoverageSeconds: TimeInterval

    static let empty = PersistentHistorySummary(points: [], energyWattHours: 0, measuredPowerCoverageSeconds: 0)

    var durationSeconds: TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return max(0, last.capturedAt.timeIntervalSince(first.capturedAt))
    }

    var batteryChargeDeltaPercent: Double? {
        guard let first = points.first(where: { $0.batteryPercent != nil })?.batteryPercent,
              let last = points.last(where: { $0.batteryPercent != nil })?.batteryPercent else { return nil }
        return last - first
    }

    var batteryMinimumPercent: Double? { points.compactMap(\.batteryPercent).min() }
    var batteryMaximumPercent: Double? { points.compactMap(\.batteryPercent).max() }
    var batteryMinimumTemperatureCelsius: Double? { points.compactMap(\.batteryTemperatureCelsius).filter { $0.isFinite }.min() }
    var batteryMaximumTemperatureCelsius: Double? { points.compactMap(\.batteryTemperatureCelsius).filter { $0.isFinite }.max() }
    var batteryMinimumHealthPercent: Double? { points.compactMap(\.batteryHealthPercent).filter { $0.isFinite }.min() }
    var batteryMaximumHealthPercent: Double? { points.compactMap(\.batteryHealthPercent).filter { $0.isFinite }.max() }
    var latestBatteryCycleCount: Int? { points.reversed().compactMap(\.batteryCycleCount).first }

    var storageLifetimeReadDeltaBytes: Double? { PersistentHistoryEngine.monotonicStorageDelta(points, value: \.storageLifetimeReadBytes) }
    var storageLifetimeWrittenDeltaBytes: Double? { PersistentHistoryEngine.monotonicStorageDelta(points, value: \.storageLifetimeWrittenBytes) }

    var heliosAverageCPUPercent: Double? { PersistentHistoryEngine.average(points.compactMap(\.heliosCPUPercent)) }
    var heliosPeakCPUPercent: Double? { points.compactMap(\.heliosCPUPercent).filter { $0.isFinite && $0 >= 0 }.max() }
    var heliosAveragePowerWatts: Double? { PersistentHistoryEngine.average(points.compactMap(\.heliosPowerWatts)) }
    var heliosPeakPowerWatts: Double? { points.compactMap(\.heliosPowerWatts).filter { $0.isFinite && $0 >= 0 }.max() }
    var heliosPeakMemoryBytes: UInt64? { points.compactMap(\.heliosMemoryBytes).max() }
    var heliosAverageWakeupsPerSecond: Double? { PersistentHistoryEngine.average(points.compactMap(\.heliosWakeupsPerSecond)) }

    /// Signed energy into the battery. Negative values represent net discharge.
    var batteryEnergyWattHours: Double {
        PersistentHistoryEngine.integrateSignedPower(points, value: \.batteryPowerWatts).energy
    }

    var measuredBatteryPowerCoverageSeconds: TimeInterval {
        PersistentHistoryEngine.integrateSignedPower(points, value: \.batteryPowerWatts).coverage
    }
}

enum PersistentHistoryEngine {
    static let retention: TimeInterval = 24 * 60 * 60
    static let minimumInterval: TimeInterval = 30
    static let maximumEnergyGap: TimeInterval = 90
    static let maximumPoints = 3_000

    static func sanitized(_ points: [PersistedTelemetryPoint], now: Date) -> [PersistedTelemetryPoint] {
        let cutoff = now.addingTimeInterval(-retention)
        var result: [PersistedTelemetryPoint] = []
        result.reserveCapacity(min(points.count, maximumPoints))
        for point in points where point.capturedAt >= cutoff && point.capturedAt <= now.addingTimeInterval(300) {
            if let last = result.last, point.capturedAt <= last.capturedAt { continue }
            result.append(point)
        }
        if result.count > maximumPoints { result.removeFirst(result.count - maximumPoints) }
        return result
    }

    static func summary(_ points: [PersistedTelemetryPoint]) -> PersistentHistorySummary {
        var energy: Double = 0
        var coverage: TimeInterval = 0
        for pair in zip(points, points.dropFirst()) {
            guard let first = pair.0.systemPowerWatts,
                  let second = pair.1.systemPowerWatts,
                  first.isFinite, second.isFinite, first >= 0, second >= 0 else { continue }
            let elapsed = pair.1.capturedAt.timeIntervalSince(pair.0.capturedAt)
            guard elapsed > 0, elapsed <= maximumEnergyGap else { continue }
            energy += ((first + second) / 2) * elapsed / 3_600
            coverage += elapsed
        }
        return PersistentHistorySummary(points: points, energyWattHours: energy, measuredPowerCoverageSeconds: coverage)
    }

    static func integrateSignedPower(_ points: [PersistedTelemetryPoint], value: KeyPath<PersistedTelemetryPoint, Double?>) -> (energy: Double, coverage: TimeInterval) {
        var energy = 0.0
        var coverage: TimeInterval = 0
        for pair in zip(points, points.dropFirst()) {
            guard let first = pair.0[keyPath: value], let second = pair.1[keyPath: value],
                  first.isFinite, second.isFinite, abs(first) < 10_000, abs(second) < 10_000 else { continue }
            let elapsed = pair.1.capturedAt.timeIntervalSince(pair.0.capturedAt)
            guard elapsed > 0, elapsed <= maximumEnergyGap else { continue }
            energy += ((first + second) / 2) * elapsed / 3_600
            coverage += elapsed
        }
        return (energy, coverage)
    }

    static func average(_ values: [Double]) -> Double? {
        let valid = values.filter { $0.isFinite && $0 >= 0 }
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    static func monotonicStorageDelta(_ points: [PersistedTelemetryPoint], value: KeyPath<PersistedTelemetryPoint, Double?>) -> Double? {
        var activeDevice: String?
        var first: Double?
        var last: Double?
        for point in points {
            guard let device = point.storageDeviceBSDName, !device.isEmpty,
                  let current = point[keyPath: value], current.isFinite, current >= 0 else { continue }
            if activeDevice != device || (last.map { current < $0 } ?? false) {
                activeDevice = device
                first = current
                last = current
                continue
            }
            if first == nil { first = current }
            last = current
        }
        guard let first, let last, last >= first else { return nil }
        return last - first
    }

    static func csv(_ points: [PersistedTelemetryPoint]) -> String {
        var lines = ["timestamp,cpu_percent,memory_percent,gpu_percent,max_soc_c,system_power_w,battery_percent,battery_health_percent,battery_power_w,on_ac,battery_temp_c,battery_cycles,ssd_temp_c,storage_device,lifetime_read_bytes,lifetime_write_bytes,device_read_Bps,device_write_Bps,process_read_Bps,process_write_Bps,helios_cpu_percent,helios_power_w,helios_memory_bytes,helios_wakeups_s,fan_rpm,network_down_Bps,network_up_Bps"]
        let formatter = ISO8601DateFormatter()
        func field(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "" }
        func integer(_ value: Int?) -> String { value.map(String.init) ?? "" }
        func unsigned(_ value: UInt64?) -> String { value.map(String.init) ?? "" }
        func quoted(_ value: String?) -> String { guard let value else { return "" }; return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for point in points {
            lines.append([
                formatter.string(from: point.capturedAt), field(point.cpuPercent), field(point.memoryPercent), field(point.gpuPercent), field(point.maxSoCCelsius),
                field(point.systemPowerWatts), field(point.batteryPercent), field(point.batteryHealthPercent), field(point.batteryPowerWatts),
                point.batteryOnAC.map { $0 ? "1" : "0" } ?? "", field(point.batteryTemperatureCelsius), integer(point.batteryCycleCount),
                field(point.storageTemperatureCelsius), quoted(point.storageDeviceBSDName), field(point.storageLifetimeReadBytes), field(point.storageLifetimeWrittenBytes),
                field(point.storageReadBytesPerSecond), field(point.storageWriteBytesPerSecond), field(point.processAccountedReadBytesPerSecond), field(point.processAccountedWriteBytesPerSecond),
                field(point.heliosCPUPercent), field(point.heliosPowerWatts), unsigned(point.heliosMemoryBytes), field(point.heliosWakeupsPerSecond),
                field(point.fanRPM), field(point.networkDownloadBytesPerSecond), field(point.networkUploadBytesPerSecond)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func decodeLines(_ data: Data, decoder: JSONDecoder = JSONDecoder()) -> [PersistedTelemetryPoint] {
        guard !data.isEmpty else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? decoder.decode(PersistedTelemetryPoint.self, from: Data(line))
        }
    }
}

actor PersistentHistoryStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var points: [PersistedTelemetryPoint]?

    init(url: URL = PersistentHistoryStore.defaultURL()) {
        self.url = url
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("history-v1.ndjson")
    }

    func current(now: Date = Date()) -> PersistentHistorySummary {
        let loaded = loadIfNeeded(now: now)
        return PersistentHistoryEngine.summary(loaded)
    }

    func append(snapshot: TelemetrySnapshot, now: Date = Date()) -> PersistentHistorySummary {
        var loaded = loadIfNeeded(now: now)
        let point = Self.point(snapshot, now: now)
        if let last = loaded.last {
            let elapsed = now.timeIntervalSince(last.capturedAt)
            if elapsed < 0 {
                // Wall-clock rollback: start a new ordered window instead of corrupting the timeline.
                loaded = [point]
                points = loaded
                rewrite(loaded)
                return PersistentHistoryEngine.summary(loaded)
            }
            if elapsed < PersistentHistoryEngine.minimumInterval {
                return PersistentHistoryEngine.summary(loaded)
            }
        }

        loaded.append(point)
        loaded = PersistentHistoryEngine.sanitized(loaded, now: now)
        let needsCompaction = loaded.count >= PersistentHistoryEngine.maximumPoints || fileSize() > 2_000_000
        points = loaded
        if needsCompaction { rewrite(loaded) } else { appendLine(point) }
        return PersistentHistoryEngine.summary(loaded)
    }

    private func loadIfNeeded(now: Date) -> [PersistedTelemetryPoint] {
        if let points { return points }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let decoded = PersistentHistoryEngine.decodeLines(data, decoder: decoder)
        let clean = PersistentHistoryEngine.sanitized(decoded, now: now)
        points = clean

        // Rewrite not only when retention/ordering drops valid points, but also when
        // the file contains malformed non-empty records (for example a truncated
        // tail after a crash). Otherwise a later append could be concatenated onto
        // that malformed tail and make the next valid sample unreadable as well.
        let rawRecordCount = data.split(separator: 0x0A).reduce(into: 0) { count, line in
            if !line.isEmpty { count += 1 }
        }
        if clean.count != decoded.count || decoded.count != rawRecordCount { rewrite(clean) }
        return clean
    }

    private func appendLine(_ point: PersistedTelemetryPoint) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try encoder.encode(point)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Persistence is observability-only. A filesystem failure must never affect live telemetry or fan safety.
        }
    }

    private func rewrite(_ points: [PersistedTelemetryPoint]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for point in points {
                data.append(try encoder.encode(point))
                data.append(0x0A)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort only; callers continue with in-memory history.
        }
    }

    private func fileSize() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func point(_ snapshot: TelemetrySnapshot, now: Date) -> PersistedTelemetryPoint {
        let lifetime = storageLifetime(snapshot, now: now)
        let own = heliosActivity(snapshot, now: now)
        return PersistedTelemetryPoint(
            capturedAt: now,
            cpuPercent: value(TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now).map(\.usagePercent)),
            memoryPercent: value(TelemetryFormatting.fresh(snapshot.memory, maxAge: 5, now: now).map(\.usagePercent)),
            gpuPercent: value(TelemetryFormatting.fresh(snapshot.gpu, maxAge: 5, now: now).flatMap(\.deviceUtilizationPercent)),
            maxSoCCelsius: value(TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now).flatMap(\.maximumSoCCelsius)),
            systemPowerWatts: value(TelemetryFormatting.fresh(snapshot.systemPower, maxAge: 5, now: now).flatMap(\.totalSystemWatts)),
            batteryPercent: value(TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now).flatMap(\.stateOfChargePercent)),
            batteryHealthPercent: value(TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now).flatMap(\.healthPercent)),
            batteryPowerWatts: batteryPower(snapshot, now: now),
            batteryOnAC: batteryOnAC(snapshot, now: now),
            batteryTemperatureCelsius: value(TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now).flatMap(\.temperatureCelsius)),
            batteryCycleCount: value(TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now).flatMap(\.cycleCount)),
            storageTemperatureCelsius: storageTemperature(snapshot, now: now),
            storageDeviceBSDName: lifetime?.device,
            storageLifetimeReadBytes: lifetime?.read,
            storageLifetimeWrittenBytes: lifetime?.written,
            storageReadBytesPerSecond: value(TelemetryFormatting.fresh(snapshot.storage, maxAge: 8, now: now).flatMap(\.throughput).map(\.readBytesPerSecond)),
            storageWriteBytesPerSecond: value(TelemetryFormatting.fresh(snapshot.storage, maxAge: 8, now: now).flatMap(\.throughput).map(\.writeBytesPerSecond)),
            processAccountedReadBytesPerSecond: processIO(snapshot, now: now)?.0,
            processAccountedWriteBytesPerSecond: processIO(snapshot, now: now)?.1,
            heliosCPUPercent: own?.cpuPercent,
            heliosPowerWatts: own?.powerWatts,
            heliosMemoryBytes: own?.physicalFootprintBytes,
            heliosWakeupsPerSecond: own?.wakeupsPerSecond,
            fanRPM: fanRPM(snapshot, now: now),
            networkDownloadBytesPerSecond: value(TelemetryFormatting.fresh(snapshot.network, maxAge: 5, now: now).flatMap(\.throughput).map(\.downloadBytesPerSecond)),
            networkUploadBytesPerSecond: value(TelemetryFormatting.fresh(snapshot.network, maxAge: 5, now: now).flatMap(\.throughput).map(\.uploadBytesPerSecond))
        )
    }

    private static func batteryPower(_ snapshot: TelemetrySnapshot, now: Date) -> Double? {
        guard case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now),
              case .success(let power) = battery.power else { return nil }
        return power.signedWatts
    }

    private static func batteryOnAC(_ snapshot: TelemetrySnapshot, now: Date) -> Bool? {
        guard case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now),
              case .success(let source) = battery.powerSource else { return nil }
        return source == .powerAdapter
    }

    private static func processIO(_ snapshot: TelemetrySnapshot, now: Date) -> (Double, Double)? {
        guard case .success(let processes) = TelemetryFormatting.fresh(snapshot.processes, maxAge: 12, now: now) else { return nil }
        return (processes.accountedDiskReadBytesPerSecond, processes.accountedDiskWriteBytesPerSecond)
    }

    private static func heliosActivity(_ snapshot: TelemetrySnapshot, now: Date) -> ProcessActivity? {
        guard case .success(let processes) = TelemetryFormatting.fresh(snapshot.processes, maxAge: 12, now: now) else { return nil }
        return processes.heliosActivity
    }

    private static func storageLifetime(_ snapshot: TelemetrySnapshot, now: Date) -> (device: String, read: Double, written: Double)? {
        guard case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 40, now: now),
              let device = storage.primaryDeviceBSDName,
              case .success(let smart) = storage.smartHealth else { return nil }
        let read = smart.lifetimeReadBytes
        let written = smart.lifetimeWrittenBytes
        guard read.isFinite, written.isFinite, read >= 0, written >= 0 else { return nil }
        return (device, read, written)
    }

    private static func storageTemperature(_ snapshot: TelemetrySnapshot, now: Date) -> Double? {
        guard case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 8, now: now),
              case .success(let smart) = storage.smartHealth,
              let temperature = smart.temperatureCelsius else { return nil }
        return temperature
    }

    private static func fanRPM(_ snapshot: TelemetrySnapshot, now: Date) -> Double? {
        guard case .success(let fans) = TelemetryFormatting.fresh(snapshot.fans, maxAge: 5, now: now),
              let first = fans.fans.first,
              case .success(let rpm) = first.actualRPM else { return nil }
        return rpm
    }

    private static func value<T>(_ result: MetricResult<T>) -> T? {
        if case .success(let value) = result { return value }
        return nil
    }
}
