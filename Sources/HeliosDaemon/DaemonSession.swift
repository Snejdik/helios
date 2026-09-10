import Foundation
import OSLog

/// Mutable session state is confined to queue. NSXPC callbacks only enqueue work;
/// no peer response is ever waited for synchronously on the watchdog queue.
final class DaemonSession: NSObject, HeliosDaemonXPC, @unchecked Sendable {
    let id = UUID()
    private let connection: NSXPCConnection
    private let queue = DispatchQueue(label: "com.snejda.Helios.Daemon.session", qos: .utility)
    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "Session")
    private let onClose: @Sendable (UUID) -> Void
    private var timer: DispatchSourceTimer?
    private var lease = DiagnosticLease()
    private var pendingNonce: UUID?
    private var lastNonce: UUID?
    private var closed = false
    private let fans: FanControlCoordinator

    init(connection: NSXPCConnection, requirement: XPCTrustRequirement, fans: FanControlCoordinator, onClose: @escaping @Sendable (UUID) -> Void) {
        self.connection = connection
        self.onClose = onClose
        self.fans = fans
        super.init()
        connection.setCodeSigningRequirement(requirement.expression)
        connection.exportedInterface = NSXPCInterface(with: HeliosDaemonXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: HeliosAppXPC.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in self?.stop(.clientDisconnected) }
        connection.invalidationHandler = { [weak self] in self?.stop(.clientDisconnected) }
    }

    func start() {
        fans.bind(id)
        queue.async { [self] in
            lease.begin(now: .now)
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(25))
            source.setEventHandler { [weak self] in
                guard let self, self.lease.expire(now: .now) else { return }
                self.close(.leaseExpired)
            }
            timer = source
            source.activate()
        }
        connection.activate()
    }

    func stop(_ reason: HeliosDisarmReason) { queue.async { [self] in close(reason) } }

    func fanStatus(session: UUID, reply: @escaping @Sendable (Bool, HeliosFanState, String) -> Void) {
        queue.async { [self] in
            guard !closed, lease.ready, session == id else { reply(false, .recoveryRequired, "Handshake required"); return }
            fans.status(reply: reply)
        }
    }

    func calculate(session: UUID, sequence: UInt64, sampleTicks: UInt64, mode: HeliosFanMode, targetRPM: Double, temperature: Double,
                   reply: @escaping @Sendable (HeliosReplyCode, HeliosFanState, String) -> Void) {
        queue.async { [self] in
            guard !closed, lease.ready, !lease.expire(now: .now), session == id else {
                reply(.invalidSession, .recoveryRequired, "Handshake required"); close(.invalidRequest); return
            }
            // Only completed calculations reach the control lease. Heartbeats
            // and status requests deliberately cannot renew it.
            fans.calculate(owner: id, sequence: sequence, sample: sampleTicks, mode: mode, rpm: targetRPM, temperature: temperature, reply: reply)
        }
    }

    func releaseControl(session: UUID, graceful: Bool, reply: @escaping @Sendable (HeliosFanState, String) -> Void) {
        queue.async { [self] in
            guard !closed, session == id else { reply(.recoveryRequired, "Session closed"); return }
            fans.release(owner: id, graceful: graceful, reply: reply)
        }
    }

    func handshake(version: Int, nonce: UUID,
                   reply: @escaping @Sendable (HeliosReplyCode, Int, UUID, UUID, Bool) -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            guard version == HeliosServiceIdentity.protocolVersion else {
                reply(.versionMismatch, HeliosServiceIdentity.protocolVersion, id, nonce, true)
                close(.invalidRequest)
                return
            }
            guard !lease.ready, pendingNonce == nil else {
                reply(.busy, HeliosServiceIdentity.protocolVersion, id, nonce, true)
                close(.invalidRequest)
                return
            }
            challenge(nonce) { [self] valid in
                guard valid, lease.completeHandshake(now: .now) else {
                    reply(.challengeFailed, HeliosServiceIdentity.protocolVersion, id, nonce, true)
                    close(.invalidRequest)
                    return
                }
                logger.notice("Handshake v\(version) accepted for client PID \(self.connection.processIdentifier), UID \(self.connection.effectiveUserIdentifier).")
                fans.status { [id] _, state, _ in reply(.ok, HeliosServiceIdentity.protocolVersion, id, nonce, state == .system) }
            }
        }
    }

    func ping(session: UUID, sequence: UInt64, nonce: UUID,
              reply: @escaping @Sendable (HeliosReplyCode, UUID, UInt64, Bool) -> Void) {
        queue.async { [self] in
            guard !closed else { return }
            guard session == id, lease.ready else {
                reply(.invalidSession, nonce, sequence, true)
                close(.invalidRequest)
                return
            }
            guard pendingNonce == nil, lastNonce != nonce, lease.lastSequence < UInt64.max,
                  sequence == lease.lastSequence + 1 else {
                reply(.invalidSequence, nonce, sequence, true)
                close(.invalidRequest)
                return
            }
            challenge(nonce) { [self] valid in
                guard valid, lease.completeHeartbeat(sequence: sequence, now: .now) else {
                    reply(.expired, nonce, sequence, true)
                    close(.leaseExpired)
                    return
                }
                logger.debug("Heartbeat \(sequence) completed after reverse challenge.")
                fans.status { _, state, _ in reply(.ok, nonce, sequence, state == .system) }
            }
        }
    }

    private func challenge(_ nonce: UUID, completion: @escaping @Sendable (Bool) -> Void) {
        guard !lease.expire(now: .now) else { close(.leaseExpired); return }
        pendingNonce = nonce
        let remote = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.logger.error("App callback failed: \(error.localizedDescription, privacy: .public)")
            self?.stop(.clientDisconnected)
        } as? HeliosAppXPC
        guard let remote else { close(.invalidRequest); return }
        remote.challenge(nonce: nonce) { [weak self] echoed in
            guard let self else { return }
            self.queue.async {
                guard !self.closed, self.pendingNonce == nonce else { return }
                self.pendingNonce = nil
                self.lastNonce = nonce
                completion(echoed == nonce)
            }
        }
    }

    private func close(_ reason: HeliosDisarmReason) {
        guard !closed else { return }
        closed = true
        lease.disarm(reason)
        pendingNonce = nil
        timer?.cancel()
        timer = nil
        logger.notice("Session disarmed, reason \(reason.rawValue). Restoring owned fans.")
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in } as? HeliosAppXPC
        remote?.didDisarm(reason: reason)
        // Give queued replies/events a chance to leave, without waiting on the app.
        connection.scheduleSendBarrierBlock { [self] in
            connection.invalidate()
        }
        // A stalled transport must not retain a closed session indefinitely.
        queue.asyncAfter(deadline: .now() + 1) { [self] in connection.invalidate() }
        connection.exportedObject = nil
        // Keep the listener slot until restoration completes, so a new client
        // cannot race cleanup of the previous client's hardware state.
        fans.release(owner: id, disconnect: true) { [self] _, _ in onClose(id) }
    }
}
