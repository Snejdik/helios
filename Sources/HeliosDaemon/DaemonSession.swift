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
    private let layer: FanLayerRuntime?
    private let requestRestart: @Sendable () -> Void

    init(connection: NSXPCConnection, requirement: XPCTrustRequirement, fans: FanControlCoordinator,
         layer: FanLayerRuntime? = nil, requestRestart: @escaping @Sendable () -> Void = {},
         onClose: @escaping @Sendable (UUID) -> Void) {
        self.connection = connection
        self.onClose = onClose
        self.fans = fans
        self.layer = layer
        self.requestRestart = requestRestart
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
                   smoothness: Double,
                   reply: @escaping @Sendable (HeliosReplyCode, HeliosFanState, String) -> Void) {
        queue.async { [self] in
            guard !closed, lease.ready, !lease.expire(now: .now), session == id else {
                reply(.invalidSession, .recoveryRequired, "Handshake required"); close(.invalidRequest); return
            }
            guard let response = FanLayerResponse(smoothness: smoothness) else {
                reply(.invalidCalculation, .recoveryRequired, "Invalid response setting"); close(.invalidRequest); return
            }
            // Only completed calculations reach the control lease. Heartbeats
            // and status requests deliberately cannot renew it.
            fans.calculate(owner: id, sequence: sequence, sample: sampleTicks, mode: mode, rpm: targetRPM,
                           temperature: temperature, response: response, reply: reply)
        }
    }

    func fanLayerInfo(session: UUID, reply: @escaping @Sendable (Int, Bool, String, String, Bool) -> Void) {
        queue.async { [self] in
            guard !closed, lease.ready, session == id else {
                reply(FanLayerTier.unsupported.rawValue, false, "", "Handshake required", false); return
            }
            guard let layer else {
                reply(FanLayerTier.unsupported.rawValue, false, "", "This helper has no fan layer.", false); return
            }
            reply(layer.tier.rawValue, layer.consented, layer.identity?.summary ?? "", layer.reason,
                  layer.fullMaximumAllowed)
        }
    }

    func setFanLayerFullMaximum(session: UUID, allowed: Bool, reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [self] in
            guard !closed, lease.ready, session == id, let layer else {
                reply(false, "Handshake required"); return
            }
            do {
                try layer.setFullMaximumAllowed(allowed)
                logger.notice("Fan layer speed limit \(allowed ? "unlocked to the full factory maximum" : "set to 90 % of the factory maximum", privacy: .public).")
                reply(true, allowed ? "The full factory maximum is allowed." : "Fans stay at or below 90 % of the factory maximum.")
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    func setFanLayerConsent(session: UUID, accepted: Bool, reply: @escaping @Sendable (Bool, String) -> Void) {
        queue.async { [self] in
            guard !closed, lease.ready, session == id, let layer else {
                reply(false, "Handshake required"); return
            }
            do {
                let changed = try layer.setConsent(accepted)
                logger.notice("Fan layer consent \(accepted ? "granted" : "revoked", privacy: .public) for \(layer.identity?.summary ?? "?", privacy: .public).")
                reply(true, changed ? "The helper restarts to apply this change." : "No change.")
                // Restore System and restart so the new setting starts from a
                // fresh process, probe and journal check.
                if changed { requestRestart() }
            } catch {
                reply(false, error.localizedDescription)
            }
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
