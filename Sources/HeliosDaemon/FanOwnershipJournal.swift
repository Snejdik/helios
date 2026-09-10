import Foundation

protocol FanOwnershipJournal: AnyObject {
    func load() throws -> Set<Int>
    func save(_ ids: Set<Int>) throws
}

/// A fixed, root-owned, non-symlink file records possibly touched fans BEFORE
/// any write. It survives crashes; failed restoration never clears ownership.
final class DiskFanOwnershipJournal: FanOwnershipJournal {
    private let descriptor: Int32
    init() throws {
        guard geteuid() == 0 else { throw TelemetryError.unavailable("Fan journal requires the privileged daemon") }
        let descriptor = open("/var/db/com.snejda.Helios.fan-ownership", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw TelemetryError.kernel("Open fan recovery journal", errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw TelemetryError.unavailable("Fan recovery journal is not private or is already in use")
        }
        self.descriptor = descriptor
    }
    deinit { close(descriptor) }
    func load() throws -> Set<Int> {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size <= 1 else { throw TelemetryError.invalidData("Invalid recovery journal") }
        if info.st_size == 0 { return [] }
        var mask: UInt8 = 0
        guard pread(descriptor, &mask, 1, 0) == 1 else { throw TelemetryError.kernel("Read fan journal", errno) }
        return Set((0..<FanCodec.maximumFanCount).filter { mask & (1 << $0) != 0 })
    }
    func save(_ ids: Set<Int>) throws {
        guard ids.allSatisfy({ (0..<FanCodec.maximumFanCount).contains($0) }) else { throw TelemetryError.invalidData("Invalid recovery fan IDs") }
        var mask = ids.reduce(UInt8(0)) { $0 | (1 << $1) }
        guard pwrite(descriptor, &mask, 1, 0) == 1, fsync(descriptor) == 0 else {
            throw TelemetryError.kernel("Persist fan recovery journal", errno)
        }
    }
}
