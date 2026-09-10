import Foundation

enum FanFixtureFailure: Error { case simulated }

/// Fixtures can be inspected while a coordinator owns them on its I/O queue.
final class FakeFanHardware: FanHardware, @unchecked Sendable {
    let lock = NSLock()
    var channelValues = [FanChannel(id: 0, minimum: 1_000, maximum: 5_000), FanChannel(id: 1, minimum: 1_200, maximum: 6_000)]
    private var log: [String] = []
    private var targets: [Int: Double] = [:]
    private var modes: [Int: UInt8] = [:]
    private var failure: String?
    private var delay: TimeInterval = 0
    func setFailure(_ value: String?) { lock.withLock { failure = value } }
    func setDelay(_ value: TimeInterval) { lock.withLock { delay = value } }
    func target(_ id: Int) -> Double? { lock.withLock { targets[id] } }
    var events: [String] { lock.withLock { log } }
    func channels() throws -> [FanChannel] { lock.withLock { channelValues } }
    func mode(_ id: Int) throws -> UInt8 { lock.withLock { modes[id] ?? 0 } }
    func setTarget(_ channel: FanChannel, rpm: Double) throws {
        let pause = lock.withLock { delay }
        if pause > 0 { Thread.sleep(forTimeInterval: pause) } // Test-only stalled driver.
        try lock.withLock {
            log.append("target \(channel.id)")
            if failure == "target \(channel.id)" { throw FanFixtureFailure.simulated }
            targets[channel.id] = rpm
        }
    }
    func setManual(_ id: Int) throws {
        try lock.withLock {
            log.append("manual \(id)")
            if failure == "manual \(id)" { throw FanFixtureFailure.simulated }
            modes[id] = 1
        }
    }
    func restoreAutomatic(_ id: Int) throws {
        try lock.withLock {
            log.append("restore \(id)")
            if failure == "restore \(id)" { throw FanFixtureFailure.simulated }
            modes[id] = 0
        }
    }
    func verify(_ channel: FanChannel, rpm: Double) throws {
        try lock.withLock {
            guard modes[channel.id] == 1, targets[channel.id] == rpm else { throw FanFixtureFailure.simulated }
        }
    }
}

final class FakeFanJournal: FanOwnershipJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<Int> = []
    var fail = false // Only changed between synchronous engine operations.
    func load() throws -> Set<Int> { lock.withLock { ids } }
    func save(_ ids: Set<Int>) throws {
        try lock.withLock { if fail { throw FanFixtureFailure.simulated }; self.ids = ids }
    }
}
