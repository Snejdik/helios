import Foundation
import OSLog

/// The listener and session queues share ownership only under lock.
final class DaemonListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let requirement: XPCTrustRequirement
    private let fans: FanControlCoordinator
    private let lock = NSLock()
    private var sessions: [UUID: DaemonSession] = [:]
    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "Listener")

    init(requirement: XPCTrustRequirement, fans: FanControlCoordinator = FanControlCoordinator()) {
        self.requirement = requirement
        self.fans = fans
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connection.effectiveUserIdentifier != 0, sessions.isEmpty else {
            logger.notice("Rejected root client or additional session.")
            return false
        }
        let session = DaemonSession(connection: connection, requirement: requirement, fans: fans) { [weak self] id in
            guard let self else { return }
            self.lock.lock()
            self.sessions.removeValue(forKey: id)
            self.lock.unlock()
        }
        sessions[session.id] = session
        session.start()
        return true
    }

    func shutdown() {
        lock.lock()
        let active = Array(sessions.values)
        lock.unlock()
        active.forEach { $0.stop(.shutdown) }
    }
}
