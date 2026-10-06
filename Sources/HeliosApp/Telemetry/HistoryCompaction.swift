import Darwin
import Foundation

/// Append-only history files are compacted once they have grown by `slack`
/// beyond the size of their last compacted (or loaded) content. An absolute
/// size limit is not enough: when the retained content itself exceeds it, every
/// append would rewrite the whole file again (a large app-energy history re-encoded
/// every minute, a telemetry history every 30 s).
enum HistoryCompactionPolicy {
    static func shouldCompact(fileSize: Int, compactedSize: Int, slack: Int) -> Bool {
        let (limit, overflow) = max(0, compactedSize).addingReportingOverflow(max(0, slack))
        return !overflow && fileSize > limit
    }

    /// Mapped reads keep a large history file out of the dirty footprint while
    /// decoding (`.mappedIfSafe` would copy a large file into a malloc buffer that
    /// stays resident after release). Safe here: the stores only append to or
    /// atomically replace (new inode) their files, never truncate them in place.
    static func read(_ url: URL) -> Data {
        (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data()
    }

    /// A crash or force-quit during `writeLines` leaves its hidden temporary file
    /// behind (tens of MB for app energy). Called once per load, before any
    /// write of this process; files younger than the grace period are left alone
    /// in case another Helios instance is still writing.
    static func removeStaleTemporaries(for url: URL, olderThan grace: TimeInterval = 600, now: Date = Date()) {
        let directory = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            let file = directory.appendingPathComponent(name)
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, now.timeIntervalSince(modified) > grace else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Loaded files are rewritten only to repair them (torn/malformed lines, a
    /// missing final newline, out-of-order or future records). Records that merely
    /// expired at the head of the chronological file are left for the next
    /// compaction; rewriting a week of history on every launch for that reason
    /// would dominate startup.
    static func needsRepair(rawRecords: Int, decoded: Int, clean: Int, expiredPrefix: Int,
                            endsWithNewline: Bool) -> Bool {
        decoded != rawRecords || !endsWithNewline || clean != decoded - expiredPrefix
    }

    /// Streams JSON lines to a temporary file and atomically renames it into
    /// place, so compaction never holds the whole file in one buffer. Returns the
    /// number of bytes written.
    static func writeLines<Value: Encodable>(_ values: [Value], encoder: JSONEncoder, to url: URL)
        throws -> Int
    {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var written = 0
            var chunk = Data()
            chunk.reserveCapacity(256 * 1_024)
            for value in values {
                chunk.append(try encoder.encode(value))
                chunk.append(0x0A)
                if chunk.count >= 256 * 1_024 {
                    try handle.write(contentsOf: chunk)
                    written += chunk.count
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                written += chunk.count
            }
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return written
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
