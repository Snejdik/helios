import Darwin
import Foundation

/// Fixed-width v3 ownership record: the v2 state machine record plus the model
/// and OS build that wrote it (docs/FAN_LAYER_DESIGN.md §7). Corruption is
/// detected, never repaired by guessing.
enum FanLayerJournalCodec {
    static let encodedSize = 64
    static let formatVersion: UInt8 = 3
    private static let magic: [UInt8] = [0x48, 0x4C, 0x46, 0x33] // HLF3
    private static let modelOffset = 16
    private static let buildOffset = 32
    private static let checksumOffset = 48

    static func encode(_ record: FanOwnershipRecoveryRecord, identity: FanLayerMachineIdentity) throws -> Data {
        try record.fanIDs.forEach { id in
            guard (0..<FanCodec.maximumFanCount).contains(id) else { throw FanOwnershipRecoveryError.invalidFanID(id) }
        }
        var bytes = [UInt8](repeating: 0, count: encodedSize)
        bytes.replaceSubrange(0..<4, with: magic)
        bytes[4] = formatVersion
        bytes[5] = record.phase.rawValue
        bytes[6] = record.globalOwnershipMayBeActive ? 1 : 0
        bytes[7] = record.fanIDs.reduce(UInt8(0)) { $0 | (UInt8(1) << UInt8($1)) }
        for index in 0..<8 { bytes[8 + index] = UInt8(truncatingIfNeeded: record.generation >> UInt64(index * 8)) }
        put(identity.modelIdentifier, into: &bytes, at: modelOffset)
        put(identity.osBuild, into: &bytes, at: buildOffset)
        let checksum = fnv1a32(bytes[0..<checksumOffset])
        for index in 0..<4 { bytes[checksumOffset + index] = UInt8(truncatingIfNeeded: checksum >> UInt32(index * 8)) }
        return Data(bytes)
    }

    static func decode(_ data: Data) throws -> (record: FanOwnershipRecoveryRecord, identity: FanLayerMachineIdentity) {
        let bytes = [UInt8](data)
        guard bytes.count == encodedSize, Array(bytes[0..<4]) == magic, bytes[4] == formatVersion,
              let phase = FanOwnershipRecoveryPhase(rawValue: bytes[5]), bytes[6] <= 1,
              bytes[(checksumOffset + 4)..<encodedSize].allSatisfy({ $0 == 0 }) else {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        var stored: UInt32 = 0
        for index in 0..<4 { stored |= UInt32(bytes[checksumOffset + index]) << UInt32(index * 8) }
        guard stored == fnv1a32(bytes[0..<checksumOffset]) else { throw FanOwnershipRecoveryError.corruptRecord }
        var generation: UInt64 = 0
        for index in 0..<8 { generation |= UInt64(bytes[8 + index]) << UInt64(index * 8) }
        let fanIDs = Set((0..<FanCodec.maximumFanCount).filter { bytes[7] & (UInt8(1) << UInt8($0)) != 0 })
        let record = FanOwnershipRecoveryRecord(generation: generation, phase: phase,
                                                globalOwnershipMayBeActive: bytes[6] == 1, fanIDs: fanIDs)
        if record.phase == .system && (record.globalOwnershipMayBeActive || !record.fanIDs.isEmpty) {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        if [.globalOwned, .acquiringFans, .owned, .releasingGlobal].contains(record.phase),
           !record.globalOwnershipMayBeActive {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        guard let model = take(bytes, at: modelOffset), let build = take(bytes, at: buildOffset),
              let identity = try? FanLayerMachineIdentity(modelIdentifier: model, osBuild: build) else {
            throw FanOwnershipRecoveryError.corruptRecord
        }
        return (record, identity)
    }

    private static func put(_ text: String, into bytes: inout [UInt8], at offset: Int) {
        let raw = Array(text.utf8.prefix(FanLayerMachineIdentity.maximumLength))
        bytes.replaceSubrange(offset..<(offset + raw.count), with: raw)
    }

    private static func take(_ bytes: [UInt8], at offset: Int) -> String? {
        let field = bytes[offset..<(offset + FanLayerMachineIdentity.maximumLength)]
        let text = field.prefix { $0 != 0 }
        // Bytes after the terminator must stay zero.
        guard field.dropFirst(text.count).allSatisfy({ $0 == 0 }) else { return nil }
        return String(decoding: text, as: UTF8.self)
    }

    private static func fnv1a32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var hash: UInt32 = 2_166_136_261
        for byte in bytes { hash ^= UInt32(byte); hash = hash &* 16_777_619 }
        return hash
    }
}

/// What a fresh daemon may do with a journal it finds at start.
enum FanLayerRecoveryDisposition: Equatable, Sendable {
    /// Nothing to recover.
    case clean
    /// Recover with the narrow restore-only writer (Ftst=0, FxMd=0).
    case recover(crossBuild: Bool)
    /// Written on another Mac model: its risk is not this machine's state.
    /// No writes; the record is set aside and the live preflight still refuses
    /// control while Ftst or a fan mode is not under macOS.
    case foreignModel

    static func evaluate(record: FanOwnershipRecoveryRecord, origin: FanLayerMachineIdentity?,
                         current: FanLayerMachineIdentity) -> FanLayerRecoveryDisposition {
        guard record.needsRecovery else { return .clean }
        // A legacy v2 record carries no identity; it was written on this disk by
        // the only model that ever had a production writer, so recover.
        guard let origin else { return .recover(crossBuild: true) }
        guard origin.modelIdentifier == current.modelIdentifier else { return .foreignModel }
        return .recover(crossBuild: origin.osBuild != current.osBuild)
    }
}

/// Journal used by the fan layer state machine. Every save stamps the current
/// identity; `origin` is the identity found on disk at load.
protocol FanLayerJournal: FanOwnershipRecoveryJournal {
    var origin: FanLayerMachineIdentity? { get }
    /// Moves an unusable record aside without deleting it (diagnostics).
    func quarantine() throws
}

final class FanLayerDiskJournal: FanLayerJournal {
    static let path = "/var/db/com.snejda.Helios.fan-ownership-v3"

    private let descriptor: Int32
    private let identity: FanLayerMachineIdentity
    private(set) var origin: FanLayerMachineIdentity?

    init(identity: FanLayerMachineIdentity) throws {
        guard geteuid() == 0 else { throw TelemetryError.unavailable("Fan layer journal requires the privileged helper") }
        descriptor = try FanLayerPrivateFile.open(Self.path)
        self.identity = identity
    }

    deinit { close(descriptor) }

    func load() throws -> FanOwnershipRecoveryRecord {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw TelemetryError.kernel("Stat fan layer journal", errno) }
        if info.st_size == 0 { origin = nil; return .clean }
        guard info.st_size == FanLayerJournalCodec.encodedSize else { throw FanOwnershipRecoveryError.corruptRecord }
        var bytes = [UInt8](repeating: 0, count: FanLayerJournalCodec.encodedSize)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == bytes.count else { throw TelemetryError.kernel("Read fan layer journal", errno) }
        let decoded = try FanLayerJournalCodec.decode(Data(bytes))
        origin = decoded.identity
        return decoded.record
    }

    func save(_ record: FanOwnershipRecoveryRecord) throws {
        let data = try FanLayerJournalCodec.encode(record, identity: identity)
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count, ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Persist fan layer journal", errno)
        }
        origin = identity
    }

    func quarantine() throws {
        // Copy, never hard-link: the live journal must keep exactly one link.
        var bytes = [UInt8](repeating: 0, count: FanLayerJournalCodec.encodedSize)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        if count > 0 {
            let copy = Darwin.open(Self.path + ".quarantined", O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC,
                                   S_IRUSR | S_IWUSR)
            if copy >= 0 {
                _ = bytes.withUnsafeBytes { write(copy, $0.baseAddress, count) }
                fsync(copy)
                close(copy)
            }
        }
        guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Clear quarantined fan journal", errno)
        }
        origin = nil
    }
}

/// Explicit, per model + OS build consent for the experimental layer. Absence
/// of a matching record is the default-off switch. A new macOS build asks again.
protocol FanLayerConsentStore: AnyObject {
    func consentedIdentity() throws -> FanLayerMachineIdentity?
    func grant(_ identity: FanLayerMachineIdentity) throws
    func revoke() throws
}

extension FanLayerConsentStore {
    func isConsented(_ identity: FanLayerMachineIdentity) -> Bool {
        (try? consentedIdentity()) == identity
    }
}

final class FanLayerDiskConsentStore: FanLayerConsentStore {
    static let path = "/var/db/com.snejda.Helios.fan-layer-consent"
    private static let header = "helios-fan-layer-consent-v1"

    func consentedIdentity() throws -> FanLayerMachineIdentity? {
        guard geteuid() == 0 else { return nil }
        let descriptor = try FanLayerPrivateFile.open(Self.path)
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else { throw TelemetryError.kernel("Read fan layer consent", errno) }
        guard count > 0 else { return nil }
        let lines = String(decoding: bytes.prefix(count), as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count == 3, lines[0] == Self.header else { return nil }
        return try? FanLayerMachineIdentity(modelIdentifier: lines[1], osBuild: lines[2])
    }

    func grant(_ identity: FanLayerMachineIdentity) throws {
        try write("\(Self.header)\n\(identity.modelIdentifier)\n\(identity.osBuild)\n")
    }

    func revoke() throws { try write("") }

    private func write(_ text: String) throws {
        guard geteuid() == 0 else { throw TelemetryError.unavailable("Consent is stored by the privileged helper") }
        let descriptor = try FanLayerPrivateFile.open(Self.path)
        defer { close(descriptor) }
        let data = Array(text.utf8)
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count, ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Persist fan layer consent", errno)
        }
    }
}

/// The user's unlock of the full factory maximum (`FanLayerCeiling`). Off by
/// default: an empty or unreadable record means the 90 % limit applies.
protocol FanLayerLimitStore: AnyObject {
    func fullMaximumAllowed() throws -> Bool
    func setFullMaximumAllowed(_ allowed: Bool) throws
}

final class FanLayerDiskLimitStore: FanLayerLimitStore {
    static let path = "/var/db/com.snejda.Helios.fan-layer-limit"
    private static let record = "helios-fan-layer-limit-v1\nfull-maximum\n"

    func fullMaximumAllowed() throws -> Bool {
        guard geteuid() == 0 else { return false }
        let descriptor = try FanLayerPrivateFile.open(Self.path)
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else { throw TelemetryError.kernel("Read fan layer limit", errno) }
        return String(decoding: bytes.prefix(count), as: UTF8.self) == Self.record
    }

    func setFullMaximumAllowed(_ allowed: Bool) throws {
        guard geteuid() == 0 else { throw TelemetryError.unavailable("The fan limit is stored by the privileged helper") }
        let descriptor = try FanLayerPrivateFile.open(Self.path)
        defer { close(descriptor) }
        let data = Array((allowed ? Self.record : "").utf8)
        let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guard count == data.count, ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Persist fan layer limit", errno)
        }
    }
}

/// Root-owned, mode 0600, single-link, non-symlink file with an exclusive lock.
enum FanLayerPrivateFile {
    static func open(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TelemetryError.kernel("Open \(path)", errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw TelemetryError.unavailable("\(path) is not private or is already in use")
        }
        return descriptor
    }
}
