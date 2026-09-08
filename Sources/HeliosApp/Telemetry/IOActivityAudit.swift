import Foundation

/// A sparse, append-friendly audit sample that helps explain physical storage
/// traffic without pretending libproc process counters equal device I/O. APFS,
/// VM paging, cached writeback and other kernel work can legitimately create a
/// gap between these two accounting layers.
struct IOActivityRecord: Codable, Sendable, Equatable {
    let capturedAt: Date
    let deviceBSDName: String?
    let deviceReadSinceBootBytes: UInt64?
    let deviceWrittenSinceBootBytes: UInt64?
    let deviceReadBytesPerSecond: Double?
    let deviceWriteBytesPerSecond: Double?
    let processAccountedReadBytesPerSecond: Double?
    let processAccountedWriteBytesPerSecond: Double?
    let topReaderName: String?
    let topReaderPID: Int32?
    let topReaderBytesPerSecond: Double?
    let topWriterName: String?
    let topWriterPID: Int32?
    let topWriterBytesPerSecond: Double?
    let heliosReadBytesPerSecond: Double?
    let heliosWriteBytesPerSecond: Double?
}

struct IOActivitySummary: Sendable, Equatable {
    let records: [IOActivityRecord]
    let observedDeviceReadBytes: UInt64
    let observedDeviceWrittenBytes: UInt64
    let observedCoverageSeconds: TimeInterval

    static let empty = IOActivitySummary(records: [], observedDeviceReadBytes: 0, observedDeviceWrittenBytes: 0, observedCoverageSeconds: 0)

    var durationSeconds: TimeInterval {
        guard let first = records.first, let last = records.last else { return 0 }
        return max(0, last.capturedAt.timeIntervalSince(first.capturedAt))
    }

    var peakReadBytesPerSecond: Double? { records.compactMap(\.deviceReadBytesPerSecond).max() }
    var peakWriteBytesPerSecond: Double? { records.compactMap(\.deviceWriteBytesPerSecond).max() }
    var latest: IOActivityRecord? { records.last }
}

enum IOActivityAuditEngine {
    static let retention: TimeInterval = 24 * 60 * 60
    static let minimumInterval: TimeInterval = 30
    static let maximumObservedGap: TimeInterval = 90
    static let maximumRecords = 3_000

    static func sanitized(_ records: [IOActivityRecord], now: Date) -> [IOActivityRecord] {
        let cutoff = now.addingTimeInterval(-retention)
        var result: [IOActivityRecord] = []
        result.reserveCapacity(min(records.count, maximumRecords))
        for record in records where record.capturedAt >= cutoff && record.capturedAt <= now.addingTimeInterval(300) {
            if let last = result.last, record.capturedAt <= last.capturedAt { continue }
            result.append(record)
        }
        if result.count > maximumRecords { result.removeFirst(result.count - maximumRecords) }
        return result
    }

    static func summary(_ records: [IOActivityRecord]) -> IOActivitySummary {
        var readBytes: UInt64 = 0
        var writtenBytes: UInt64 = 0
        var coverage: TimeInterval = 0
        for pair in zip(records, records.dropFirst()) {
            let elapsed = pair.1.capturedAt.timeIntervalSince(pair.0.capturedAt)
            guard elapsed > 0, elapsed <= maximumObservedGap,
                  pair.0.deviceBSDName != nil, pair.0.deviceBSDName == pair.1.deviceBSDName,
                  let firstRead = pair.0.deviceReadSinceBootBytes,
                  let secondRead = pair.1.deviceReadSinceBootBytes,
                  let firstWrite = pair.0.deviceWrittenSinceBootBytes,
                  let secondWrite = pair.1.deviceWrittenSinceBootBytes,
                  secondRead >= firstRead, secondWrite >= firstWrite else { continue }
            readBytes = saturatingAdd(readBytes, secondRead - firstRead)
            writtenBytes = saturatingAdd(writtenBytes, secondWrite - firstWrite)
            coverage += elapsed
        }
        return IOActivitySummary(records: records, observedDeviceReadBytes: readBytes, observedDeviceWrittenBytes: writtenBytes, observedCoverageSeconds: coverage)
    }

    static func decodeLines(_ data: Data, decoder: JSONDecoder = JSONDecoder()) -> [IOActivityRecord] {
        guard !data.isEmpty else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? decoder.decode(IOActivityRecord.self, from: Data(line))
        }
    }

    static func csv(_ records: [IOActivityRecord]) -> String {
        var lines = ["timestamp,device,read_since_boot_bytes,write_since_boot_bytes,device_read_Bps,device_write_Bps,process_read_Bps,process_write_Bps,top_reader,top_reader_pid,top_reader_Bps,top_writer,top_writer_pid,top_writer_Bps,helios_read_Bps,helios_write_Bps"]
        let formatter = ISO8601DateFormatter()
        func quote(_ value: String?) -> String {
            guard let value else { return "" }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func d(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
        func u(_ value: UInt64?) -> String { value.map(String.init) ?? "" }
        func i(_ value: Int32?) -> String { value.map(String.init) ?? "" }
        for record in records {
            lines.append([
                formatter.string(from: record.capturedAt), quote(record.deviceBSDName), u(record.deviceReadSinceBootBytes), u(record.deviceWrittenSinceBootBytes),
                d(record.deviceReadBytesPerSecond), d(record.deviceWriteBytesPerSecond), d(record.processAccountedReadBytesPerSecond), d(record.processAccountedWriteBytesPerSecond),
                quote(record.topReaderName), i(record.topReaderPID), d(record.topReaderBytesPerSecond), quote(record.topWriterName), i(record.topWriterPID), d(record.topWriterBytesPerSecond),
                d(record.heliosReadBytesPerSecond), d(record.heliosWriteBytesPerSecond)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}

actor IOActivityAuditStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var records: [IOActivityRecord]?

    init(url: URL = IOActivityAuditStore.defaultURL()) {
        self.url = url
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("io-activity-v1.ndjson")
    }

    func current(now: Date = Date()) -> IOActivitySummary {
        IOActivityAuditEngine.summary(loadIfNeeded(now: now))
    }

    func append(snapshot: TelemetrySnapshot, now: Date = Date()) -> IOActivitySummary {
        var loaded = loadIfNeeded(now: now)
        let record = Self.record(snapshot, now: now)
        if let last = loaded.last {
            let elapsed = now.timeIntervalSince(last.capturedAt)
            if elapsed < 0 {
                loaded = [record]
                records = loaded
                rewrite(loaded)
                return IOActivityAuditEngine.summary(loaded)
            }
            if elapsed < IOActivityAuditEngine.minimumInterval { return IOActivityAuditEngine.summary(loaded) }
        }
        loaded.append(record)
        loaded = IOActivityAuditEngine.sanitized(loaded, now: now)
        records = loaded
        if loaded.count >= IOActivityAuditEngine.maximumRecords || fileSize() > 2_000_000 { rewrite(loaded) }
        else { appendLine(record) }
        return IOActivityAuditEngine.summary(loaded)
    }

    private func loadIfNeeded(now: Date) -> [IOActivityRecord] {
        if let records { return records }
        let data = (try? Data(contentsOf: url)) ?? Data()
        let decoded = IOActivityAuditEngine.decodeLines(data, decoder: decoder)
        let clean = IOActivityAuditEngine.sanitized(decoded, now: now)
        records = clean
        let rawCount = data.split(separator: 0x0A).reduce(into: 0) { count, line in if !line.isEmpty { count += 1 } }
        if clean.count != decoded.count || decoded.count != rawCount { rewrite(clean) }
        return clean
    }

    private func appendLine(_ record: IOActivityRecord) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try encoder.encode(record); data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic); return }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch {
            // Audit persistence is best-effort observability only.
        }
    }

    private func rewrite(_ records: [IOActivityRecord]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for record in records { data.append(try encoder.encode(record)); data.append(0x0A) }
            try data.write(to: url, options: .atomic)
        } catch {
            // Live telemetry remains authoritative even if the audit file is unavailable.
        }
    }

    private func fileSize() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func record(_ snapshot: TelemetrySnapshot, now: Date) -> IOActivityRecord {
        var deviceName: String?
        var bootRead: UInt64?
        var bootWrite: UInt64?
        var deviceReadRate: Double?
        var deviceWriteRate: Double?
        if case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 8, now: now) {
            deviceName = storage.primaryDeviceBSDName
            if let primary = storage.primaryDevice, case .success(let counters) = primary.counters {
                bootRead = counters.bytesRead; bootWrite = counters.bytesWritten
            }
            if case .success(let rate) = storage.throughput {
                deviceReadRate = rate.readBytesPerSecond; deviceWriteRate = rate.writeBytesPerSecond
            }
        }

        var processRead: Double?
        var processWrite: Double?
        var topReader: ProcessActivity?
        var topWriter: ProcessActivity?
        var helios: ProcessActivity?
        if case .success(let processes) = TelemetryFormatting.fresh(snapshot.processes, maxAge: 12, now: now) {
            processRead = processes.accountedDiskReadBytesPerSecond
            processWrite = processes.accountedDiskWriteBytesPerSecond
            topReader = processes.topByDiskRead.first(where: { ($0.diskReadBytesPerSecond ?? 0) > 0 })
            topWriter = processes.topByDiskWrite.first(where: { ($0.diskWriteBytesPerSecond ?? 0) > 0 })
            helios = processes.heliosActivity
        }

        return IOActivityRecord(
            capturedAt: now,
            deviceBSDName: deviceName,
            deviceReadSinceBootBytes: bootRead,
            deviceWrittenSinceBootBytes: bootWrite,
            deviceReadBytesPerSecond: deviceReadRate,
            deviceWriteBytesPerSecond: deviceWriteRate,
            processAccountedReadBytesPerSecond: processRead,
            processAccountedWriteBytesPerSecond: processWrite,
            topReaderName: topReader?.name,
            topReaderPID: topReader?.pid,
            topReaderBytesPerSecond: topReader?.diskReadBytesPerSecond,
            topWriterName: topWriter?.name,
            topWriterPID: topWriter?.pid,
            topWriterBytesPerSecond: topWriter?.diskWriteBytesPerSecond,
            heliosReadBytesPerSecond: helios?.diskReadBytesPerSecond,
            heliosWriteBytesPerSecond: helios?.diskWriteBytesPerSecond
        )
    }
}
