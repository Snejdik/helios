import Foundation

struct CleanupCandidate: Sendable, Identifiable, Equatable {
    let id: String
    let label: String
    let path: String
    let estimatedBytes: UInt64
    let scannedEntries: Int
    let truncated: Bool
}

struct CleanupMetrics: Sendable, Equatable {
    let candidates: [CleanupCandidate]
    var estimatedBytes: UInt64 { candidates.reduce(0) { Self.saturatingAdd($0, $1.estimatedBytes) } }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

actor CleanupProvider {
    func sample() -> MetricSample<CleanupMetrics> { MetricSample(.success(Self.read())) }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, entryBudget: Int = 200_000) -> CleanupMetrics {
        let roots: [(String, String)] = [
            ("User caches", "Library/Caches"),
            ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
            ("Xcode Archives", "Library/Developer/Xcode/Archives"),
            ("Simulator caches", "Library/Developer/CoreSimulator/Caches"),
            ("Homebrew cache", "Library/Caches/Homebrew")
        ]
        var remaining = max(1, entryBudget)
        var candidates: [CleanupCandidate] = []
        for (label, relative) in roots where remaining > 0 {
            let url = home.appendingPathComponent(relative, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let result = directorySize(url, entryBudget: remaining)
            remaining = max(0, remaining - result.entries)
            candidates.append(CleanupCandidate(
                id: relative,
                label: label,
                path: url.path,
                estimatedBytes: result.bytes,
                scannedEntries: result.entries,
                truncated: result.truncated
            ))
        }
        return CleanupMetrics(candidates: candidates)
    }

    private static func directorySize(_ root: URL, entryBudget: Int) -> (bytes: UInt64, entries: Int, truncated: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return (0, 0, false) }
        var total: UInt64 = 0
        var entries = 0
        var truncated = false
        while let url = enumerator.nextObject() as? URL {
            if entries >= entryBudget { truncated = true; break }
            entries += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            guard size > 0 else { continue }
            let (next, overflow) = total.addingReportingOverflow(UInt64(size))
            total = overflow ? .max : next
        }
        return (total, entries, truncated)
    }
}

enum AppBinaryArchitecture: String, Sendable, Equatable {
    case appleSilicon = "Apple Silicon"
    case intel = "Intel"
    case universal = "Universal"
    case unknown = "Unknown"
}

struct InstalledApplicationMetrics: Sendable, Identifiable, Equatable {
    let path: String
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let architecture: AppBinaryArchitecture
    /// Best-effort recursively allocated bytes observed during the explicit
    /// maintenance scan. Nil means the scan budget was exhausted before this
    /// bundle could be measured.
    let estimatedSizeBytes: UInt64?
    let sizeTruncated: Bool

    var id: String { path }
}

struct ApplicationsMetrics: Sendable, Equatable {
    let applications: [InstalledApplicationMetrics]
}

actor ApplicationsProvider {
    func sample() -> MetricSample<ApplicationsMetrics> { MetricSample(.success(Self.read())) }

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser, entryBudget: Int = 500_000) -> ApplicationsMetrics {
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
        var seen = Set<String>()
        var apps: [InstalledApplicationMetrics] = []
        var remainingEntries = max(0, entryBudget)
        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                guard seen.insert(url.path).inserted else { continue }
                let bundle = Bundle(url: url)
                let executable = bundle?.executableURL
                let measured: (bytes: UInt64, entries: Int, truncated: Bool)?
                if remainingEntries > 0 {
                    let result = bundleAllocatedSize(url, entryBudget: remainingEntries)
                    remainingEntries = max(0, remainingEntries - result.entries)
                    measured = result
                } else {
                    measured = nil
                }
                apps.append(InstalledApplicationMetrics(
                    path: url.path,
                    name: (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    version: (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                        ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
                    architecture: executable.map(binaryArchitecture) ?? .unknown,
                    estimatedSizeBytes: measured?.bytes,
                    sizeTruncated: measured?.truncated ?? true
                ))
            }
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ApplicationsMetrics(applications: apps)
    }


    private static func bundleAllocatedSize(_ root: URL, entryBudget: Int) -> (bytes: UInt64, entries: Int, truncated: Bool) {
        guard entryBudget > 0 else { return (0, 0, true) }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return (0, 0, false) }
        var bytes: UInt64 = 0
        var entries = 0
        var truncated = false
        while let item = enumerator.nextObject() as? URL {
            if entries >= entryBudget { truncated = true; break }
            entries += 1
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            guard allocated > 0 else { continue }
            let (next, overflow) = bytes.addingReportingOverflow(UInt64(allocated))
            bytes = overflow ? .max : next
        }
        return (bytes, entries, truncated)
    }

    static func binaryArchitecture(_ url: URL) -> AppBinaryArchitecture {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return .unknown }
        let magicBE = data.uint32BE(at: 0)
        let magicLE = data.uint32LE(at: 0)
        let cpuArm64: UInt32 = 0x0100000c
        let cpuX8664: UInt32 = 0x01000007
        if magicLE == 0xfeedfacf {
            let cpu = data.uint32LE(at: 4)
            if cpu == cpuArm64 { return .appleSilicon }
            if cpu == cpuX8664 { return .intel }
            return .unknown
        }
        if magicBE == 0xcafebabe || magicBE == 0xcafebabf {
            let count = Int(data.uint32BE(at: 4))
            guard count > 0, count <= 64 else { return .unknown }
            let stride = magicBE == 0xcafebabf ? 32 : 20
            var arm = false
            var intel = false
            for index in 0..<count {
                let offset = 8 + index * stride
                guard offset + 4 <= data.count else { break }
                let cpu = data.uint32BE(at: offset)
                arm = arm || cpu == cpuArm64
                intel = intel || cpu == cpuX8664
            }
            if arm && intel { return .universal }
            if arm { return .appleSilicon }
            if intel { return .intel }
        }
        return .unknown
    }
}

private extension Data {
    func uint32BE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return self[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
