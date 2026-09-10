import Foundation
import OSLog
import Combine

enum DaemonConnectionState: String {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
    case signingRequired = "Signing Required"
    case versionMismatch = "Reinstall Required"
    case failed = "Connection Unavailable"
}

@MainActor
final class DaemonClient: ObservableObject {
    @Published private(set) var state = DaemonConnectionState.disconnected
    @Published private(set) var detail: String?
    @Published private(set) var lastHeartbeat: Date?
    private(set) var negotiatedVersion: Int?
    private(set) var peerPID: pid_t?
    private(set) var peerUID: uid_t?
    private(set) var completedHeartbeats: UInt64 = 0
    @Published private(set) var fanControlAvailable = false
    @Published private(set) var fanState = HeliosFanState.system
    /// Monotonic app-side fault signal. The FanControlModel uses this to require
    /// a deliberate new mode after a failed calculation without conflating a
    /// transient acquisition failure with permanent helper unavailability.
    @Published private(set) var fanControlFaultRevision: UInt64 = 0
    @Published private(set) var fanDetail = "Connect the signed helper to enable fan control."
    private var controlSequence: UInt64 = 0
    private var controlRequest: UUID?
    private var controlRevision = UUID()
    private var controlTimeout: Task<Void, Never>?
    private let logger = Logger(subsystem: HeliosServiceIdentity.appIdentifier, category: "DaemonClient")
    private var connection: NSXPCConnection?
    private var generation = UUID()
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var pendingNonce: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var retryAfter = ContinuousClock.now
    private let trustProvider: @MainActor () throws -> XPCTrustRequirement
    private let connectionFactory: @MainActor () -> NSXPCConnection

    // Dependencies allow isolated NSXPC verification; the shipping app always
    // uses these production defaults. There is no runtime trust override.
    init(trustProvider: @escaping @MainActor () throws -> XPCTrustRequirement = {
        try .production(localIdentifier: HeliosServiceIdentity.appIdentifier, peerIdentifier: HeliosServiceIdentity.machServiceName)
    }, connectionFactory: @escaping @MainActor () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: HeliosServiceIdentity.machServiceName, options: .privileged)
    }) {
        self.trustProvider = trustProvider
        self.connectionFactory = connectionFactory
    }

    func connect(force: Bool = false) {
        guard connection == nil else { return }
        guard force || (state != .signingRequired && state != .versionMismatch && ContinuousClock.now >= retryAfter) else { return }
        let requirement: XPCTrustRequirement
        do {
            requirement = try trustProvider()
        } catch {
            fail(error.localizedDescription, state: .signingRequired)
            return
        }
        let current = UUID()
        generation = current
        state = .connecting
        detail = nil
        let connection = connectionFactory()
        connection.setCodeSigningRequirement(requirement.expression)
        connection.remoteObjectInterface = NSXPCInterface(with: HeliosDaemonXPC.self)
        connection.exportedInterface = NSXPCInterface(with: HeliosAppXPC.self)
        connection.exportedObject = AppHeartbeatReceiver(
            challenge: { [weak self] nonce, reply in
                Task { @MainActor in
                    // A callback must belong to the currently outstanding request.
                    let valid = self?.generation == current && self?.pendingNonce == nonce
                    reply(valid ? nonce : UUID())
                }
            },
            disarm: { [weak self] reason in
                Task { @MainActor in
                    guard self?.generation == current else { return }
                    self?.fail(reason == .leaseExpired ? "The helper session expired. Control is disarmed." : "The helper session was disarmed.")
                }
            }
        )
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard self?.generation == current else { return }
                self?.fail("The helper stopped responding. A new handshake is required.")
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard self?.generation == current else { return }
                self?.fail("The helper connection closed or its signing requirement was not met.")
            }
        }
        self.connection = connection
        connection.activate()
        let nonce = beginRequest()
        guard let remote = remote(current: current) else { return }
        remote.handshake(version: HeliosServiceIdentity.protocolVersion, nonce: nonce) { [weak self] code, version, session, echoed, disarmed in
            Task { @MainActor in
                guard let self, self.generation == current, self.pendingNonce == nonce else { return }
                guard code != .versionMismatch, version == HeliosServiceIdentity.protocolVersion else {
                    self.fail("The app and helper use different protocol versions. Reinstall the helper.", state: .versionMismatch)
                    return
                }
                guard code == .ok, echoed == nonce else {
                    self.fail("The helper handshake returned an invalid response.")
                    return
                }
                self.session = session
                self.negotiatedVersion = version
                self.peerPID = self.connection?.processIdentifier
                self.peerUID = self.connection?.effectiveUserIdentifier
                self.finishRequest()
                self.state = .connected
                self.logger.notice("Authenticated handshake v\(version), daemon PID \(self.peerPID ?? -1), UID \(self.peerUID ?? UInt32.max).")
                self.refreshFanStatus()
                self.heartbeatTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        self?.ping()
                    }
                }
            }
        }
    }

    func disconnect() {
        generation = UUID()
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
        timeoutTask = nil
        heartbeatTask = nil
        pendingNonce = nil
        session = nil
        sequence = 0
        lastHeartbeat = nil
        negotiatedVersion = nil
        peerPID = nil
        peerUID = nil
        completedHeartbeats = 0
        fanControlAvailable = false
        if fanState != .system { fanState = .recoveryRequired }
        fanDetail = "Helper disconnected; automatic restoration is not yet confirmed."
        controlTimeout?.cancel(); controlTimeout = nil; controlRequest = nil
        controlSequence = 0
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.exportedObject = nil
        connection?.invalidate()
        connection = nil
        state = .disconnected
        detail = nil
    }

    private func ping() {
        guard let session, pendingNonce == nil, sequence < UInt64.max else { return }
        sequence += 1
        let sequence = sequence
        let current = generation
        let nonce = beginRequest()
        remote(current: current)?.ping(session: session, sequence: sequence, nonce: nonce) { [weak self] code, echoed, receivedSequence, disarmed in
            Task { @MainActor in
                guard let self, self.generation == current, self.pendingNonce == nonce else { return }
                guard code == .ok, echoed == nonce, receivedSequence == sequence else {
                    self.fail("The helper heartbeat returned an invalid or expired response.")
                    return
                }
                self.finishRequest()
                self.completedHeartbeats = receivedSequence
                self.logger.debug("Authenticated heartbeat \(receivedSequence) completed.")
                self.refreshFanStatus()
            }
        }
    }

    private func refreshFanStatus() {
        guard let session, state == .connected, controlRequest == nil else { return }
        let current = generation
        let revision = controlRevision
        remote(current: current)?.fanStatus(session: session) { [weak self] available, state, detail in
            Task { @MainActor in
                guard let self, self.generation == current, self.controlRevision == revision else { return }
                self.fanControlAvailable = available
                self.fanState = state
                self.fanDetail = detail
            }
        }
    }

    @discardableResult
    func calculate(mode: HeliosFanMode, rpm: Double, temperature: Double, sampleTicks: UInt64) -> Bool {
        guard let session, state == .connected, fanControlAvailable, controlRequest == nil, controlSequence < UInt64.max else { return false }
        controlSequence += 1
        let current = generation
        let acquisitionRequest = fanState == .system && mode != .system
        let request = beginControlRequest(timeoutMilliseconds: acquisitionRequest ? 13_000 : 4_500)
        guard let remote = remote(current: current) else {
            controlTimeout?.cancel(); controlTimeout = nil; controlRequest = nil
            return false
        }
        remote.calculate(session: session, sequence: controlSequence, sampleTicks: sampleTicks,
                         mode: mode, targetRPM: rpm, temperature: temperature) { [weak self] code, state, message in
            Task { @MainActor in
                guard let self, self.generation == current, self.controlRequest == request else { return }
                self.controlTimeout?.cancel(); self.controlRequest = nil
                self.fanState = state
                self.fanDetail = message
                if code != .ok {
                    // Publish the final capability disposition *before* the fault
                    // revision. FanControlModel consumes the revision synchronously
                    // and must never observe the old availability value when
                    // deciding whether Auto may stay armed after verified System
                    // recovery.
                    self.fanControlAvailable = (code == .hardwareFailure && state == .system)
                    self.fanControlFaultRevision &+= 1
                }
            }
        }
        return true
    }

    @discardableResult
    func releaseFans(
        graceful: Bool = true,
        completion: (@MainActor @Sendable (HeliosFanState) -> Void)? = nil
    ) -> Bool {
        guard let session, state == .connected else { return false }
        let current = generation
        // Supersede any pending calculation; its late reply cannot restore UI
        // state after a System/reconfiguration release. Explicit user releases
        // may use the cosmetic soft ramp; safety/internal releases pass false.
        let request = beginControlRequest(timeoutMilliseconds: graceful ? 7_000 : 4_500)
        guard let remote = remote(current: current) else {
            controlTimeout?.cancel(); controlTimeout = nil; controlRequest = nil
            return false
        }
        remote.releaseControl(session: session, graceful: graceful) { [weak self] state, detail in
            Task { @MainActor in
                guard let self, self.generation == current, self.controlRequest == request else { return }
                self.controlTimeout?.cancel(); self.controlRequest = nil
                self.fanState = state
                self.fanDetail = detail
                completion?(state)
            }
        }
        return true
    }

    private func beginControlRequest(timeoutMilliseconds: Int = 4_500) -> UUID {
        controlTimeout?.cancel()
        let id = UUID()
        controlRevision = id
        controlRequest = id
        let current = generation
        controlTimeout = Task { [weak self] in
            // Steady-state requests retain the original 4.5-second app timeout.
            // Initial takeover gets a longer client wait because the daemon now
            // owns a separately bounded 12-second acquisition lease matching the
            // physically observed Ftst/F0Md arbitration. The daemon deadline is
            // intentionally shorter, so it should restore and reply before this
            // connection-level failsafe ever fires.
            do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)) } catch { return }
            guard let self, self.generation == current, self.controlRequest == id else { return }
            let seconds = Double(timeoutMilliseconds) / 1000.0
            self.fail("Fan control did not reply within \(seconds) seconds; the connection was closed to revoke its lease.")
        }
        return id
    }

    private func remote(current: UUID) -> (any HeliosDaemonXPC)? {
        let remote = connection?.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                guard self?.generation == current else { return }
                self?.fail("Helper communication failed: \(message)")
            }
        } as? HeliosDaemonXPC
        if remote == nil { fail("The helper interface is unavailable.") }
        return remote
    }

    private func beginRequest() -> UUID {
        let nonce = UUID()
        let current = generation
        pendingNonce = nonce
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard self?.generation == current, self?.pendingNonce == nonce else { return }
            self?.fail("The helper did not reply within two seconds.")
        }
        return nonce
    }

    private func finishRequest() {
        pendingNonce = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lastHeartbeat = Date()
    }

    private func fail(_ message: String, state: DaemonConnectionState = .failed) {
        disconnect()
        self.state = state
        detail = message
        retryAfter = ContinuousClock.now.advanced(by: .seconds(5))
        logger.error("\(message, privacy: .public)")
    }
}

/// Immutable callback closures hop onto the app's main actor. A hung main actor
/// therefore cannot keep the daemon's diagnostic lease alive on a hidden thread.
private final class AppHeartbeatReceiver: NSObject, HeliosAppXPC, @unchecked Sendable {
    let onChallenge: @Sendable (UUID, @escaping @Sendable (UUID) -> Void) -> Void
    let onDisarm: @Sendable (HeliosDisarmReason) -> Void

    init(challenge: @escaping @Sendable (UUID, @escaping @Sendable (UUID) -> Void) -> Void,
         disarm: @escaping @Sendable (HeliosDisarmReason) -> Void) {
        onChallenge = challenge
        onDisarm = disarm
    }

    func challenge(nonce: UUID, reply: @escaping @Sendable (UUID) -> Void) { onChallenge(nonce, reply) }
    func didDisarm(reason: HeliosDisarmReason) { onDisarm(reason) }
}
