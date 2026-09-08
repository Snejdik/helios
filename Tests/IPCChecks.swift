import AppKit
import Security
import ServiceManagement

private enum CheckError: Error {
    case failed(String)
    case timeout(String)
    case transport(String)
}
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw CheckError.failed(message) }
}

/// A deadline and a transport error can race the reply. Resume exactly once.
private final class ReplyGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

private struct Handshake: Sendable {
    let code: HeliosReplyCode
    let version: Int
    let session: UUID
    let nonce: UUID
    let disarmed: Bool
}
private struct Pong: Sendable {
    let code: HeliosReplyCode
    let nonce: UUID
    let sequence: UInt64
    let disarmed: Bool
}

/// Deterministic coordinator backend for app-side Auto Rules state-machine tests.
/// It can delay or fail the first request while remaining permit-cancellable, and
/// records accepted target RPMs. No hardware/SMC API is involved.
private final class AutoModelEngine: FanControlDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var current = HeliosFanState.system
    private let firstDelayMilliseconds: Int
    private let failFirst: Bool
    private let releaseTargets: [Double]
    private var startedCount = 0
    private var restoreCount = 0
    private var acceptedRPMs: [Double] = []

    var state: HeliosFanState { lock.withLock { current } }
    var starts: Int { lock.withLock { startedCount } }
    var restores: Int { lock.withLock { restoreCount } }
    var rpms: [Double] { lock.withLock { acceptedRPMs } }
    var lastRPM: Double? { lock.withLock { acceptedRPMs.last } }

    init(firstDelayMilliseconds: Int = 0, failFirst: Bool = false, releaseTargets: [Double] = []) {
        self.firstDelayMilliseconds = max(0, firstDelayMilliseconds)
        self.failFirst = failFirst
        self.releaseTargets = releaseTargets
    }

    func apply(mode: HeliosFanMode, rpm: Double, permit: () throws -> Void) throws {
        let ordinal = lock.withLock { () -> Int in
            startedCount += 1
            return startedCount
        }
        if ordinal == 1, firstDelayMilliseconds > 0 {
            let slices = max(1, firstDelayMilliseconds / 10)
            for _ in 0..<slices {
                try permit()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        try permit()
        if ordinal == 1, failFirst {
            throw TelemetryError.unavailable("deterministic recoverable Auto acquisition failure")
        }
        lock.withLock {
            acceptedRPMs.append(rpm)
            current = mode == .boost ? .boost : .override
        }
    }

    func softReleaseTargets() -> [Double] { releaseTargets }
    func applySoftReleaseTarget(_ rpm: Double, permit: () throws -> Void) throws { _ = rpm; try permit() }
    func restore() throws {
        lock.withLock {
            restoreCount += 1
            current = .system
        }
    }
}

/// NSXPC invokes callbacks off the main actor; all mutable fixture state is locked.
private final class Receiver: NSObject, HeliosAppXPC, @unchecked Sendable {
    enum Mode { case echo, wrong, silent }
    private let lock = NSLock()
    private var mode = Mode.echo
    private var count = 0
    private var reason: HeliosDisarmReason?
    func setMode(_ value: Mode) { lock.lock(); mode = value; lock.unlock() }
    var challenges: Int { lock.lock(); defer { lock.unlock() }; return count }
    var disarmReason: HeliosDisarmReason? { lock.lock(); defer { lock.unlock() }; return reason }
    func challenge(nonce: UUID, reply: @escaping @Sendable (UUID) -> Void) {
        lock.lock()
        count += 1
        let current = mode
        lock.unlock()
        switch current {
        case .echo: reply(nonce)
        case .wrong: reply(UUID())
        case .silent: break
        }
    }
    func didDisarm(reason: HeliosDisarmReason) { lock.lock(); self.reason = reason; lock.unlock() }
}

@MainActor
private final class Fixture {
    let listener = NSXPCListener.anonymous()
    let delegate: DaemonListenerDelegate
    let receiver = Receiver()
    let connection: NSXPCConnection

    init(serverTrust: XPCTrustRequirement, clientTrust: XPCTrustRequirement, fans: FanControlCoordinator = FanControlCoordinator()) {
        delegate = DaemonListenerDelegate(requirement: serverTrust, fans: fans)
        listener.setConnectionCodeSigningRequirement(serverTrust.expression)
        listener.delegate = delegate
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.setCodeSigningRequirement(clientTrust.expression)
        connection.exportedInterface = NSXPCInterface(with: HeliosAppXPC.self)
        connection.exportedObject = receiver
        connection.remoteObjectInterface = NSXPCInterface(with: HeliosDaemonXPC.self)
        connection.activate()
    }

    func close() { connection.invalidate(); delegate.shutdown(); listener.invalidate() }

    func request<Value: Sendable>(timeout: Double = 3,
                                 send: (any HeliosDaemonXPC, ReplyGate<Value>) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ReplyGate<Value>(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.finish(.failure(CheckError.timeout("typed XPC request exceeded \(timeout)s"))) }
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                gate.finish(.failure(CheckError.transport(error.localizedDescription)))
            }) as? HeliosDaemonXPC else {
                gate.finish(.failure(CheckError.failed("Missing typed interface")))
                return
            }
            send(remote, gate)
        }
    }

    func handshake(version: Int = HeliosServiceIdentity.protocolVersion, nonce: UUID = UUID()) async throws -> Handshake {
        try await request { remote, gate in
            remote.handshake(version: version, nonce: nonce) { code, version, session, echoed, disarmed in
                gate.finish(.success(Handshake(code: code, version: version, session: session, nonce: echoed, disarmed: disarmed)))
            }
        }
    }

    func ping(session: UUID, sequence: UInt64, nonce: UUID = UUID(), timeout: Double = 3) async throws -> Pong {
        try await request(timeout: timeout) { remote, gate in
            remote.ping(session: session, sequence: sequence, nonce: nonce) { code, echoed, sequence, disarmed in
                gate.finish(.success(Pong(code: code, nonce: echoed, sequence: sequence, disarmed: disarmed)))
            }
        }
    }
}

@MainActor
private final class FakeRegistration: ServiceRegistrationDriver {
    var status = SMAppService.Status.notRegistered
    var nextStatus = SMAppService.Status.requiresApproval
    var failure: NSError?
    var removalDelay: Duration = .zero
    var calls: [String] = []
    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = nextStatus
    }
    func unregister() async throws {
        calls.append("unregister began")
        try await Task.sleep(for: .milliseconds(20))
        if let failure { throw failure }
        if removalDelay > .zero {
            let delay = removalDelay
            Task { @MainActor in
                try await Task.sleep(for: delay)
                self.status = .notRegistered
            }
        } else { status = .notRegistered }
        calls.append("unregister completed")
    }
}

@main
@MainActor
private enum IPCChecks {
    static func main() async {
        do {
            try require(geteuid() != 0, "Checks must run as an ordinary user")
            try checkLease()
            try checkRequirements()
            try await checkRegistration()
            try await checkTransport()
            try await checkAppClient()
            try await checkActiveControl()
            try await checkAutoRulesModelTransitions()
            print("PASS: lease boundaries, registration states, signed NSXPC callbacks, rejected peers, hung-client expiry, app reconnect/error handling, and stable Auto Rules edit/retry transitions")
        } catch { print("FAIL: \(error)"); exit(1) }
    }

    static func checkLease() throws {
        let now = ContinuousClock.now
        var lease = DiagnosticLease()
        try require(!lease.completeHeartbeat(sequence: 1, now: now), "Heartbeat before handshake was accepted")
        lease.begin(now: now)
        try require(lease.completeHandshake(now: now) && !lease.completeHandshake(now: now), "Handshake must be single use")
        let original = lease.deadline
        try require(!lease.completeHeartbeat(sequence: 2, now: now) && lease.deadline == original, "Out-of-order traffic renewed the lease")
        try require(lease.completeHeartbeat(sequence: 1, now: now.advanced(by: .seconds(1))), "Fresh heartbeat rejected")
        let renewed = lease.deadline
        try require(!lease.completeHeartbeat(sequence: 1, now: now) && lease.deadline == renewed, "Replay renewed the lease")
        try require(!lease.expire(now: now.advanced(by: .milliseconds(5999))), "Lease expired early")
        try require(lease.expire(now: now.advanced(by: .seconds(6))), "Exact deadline did not expire")
        try require(!lease.completeHeartbeat(sequence: 2, now: now.advanced(by: .seconds(7))), "Late callback resurrected the lease")
        try require(lease.reason == .leaseExpired && !lease.ready, "Expired diagnostic session remained ready")
        lease.begin(now: now)
        try require(!lease.completeHandshake(now: now.advanced(by: .seconds(5))), "Late handshake accepted")
        lease.begin(now: now)
        lease.disarm(.clientDisconnected)
        try require(lease.deadline == nil && !lease.ready, "Disconnect left a lease active")
    }

    static func checkRequirements() throws {
        _ = try XPCTrustRequirement.requirement(team: "ABCDE12345", identifier: HeliosServiceIdentity.appIdentifier)
        _ = try XPCTrustRequirement(validating: "never")
        do {
            _ = try XPCTrustRequirement.requirement(team: "\" or always", identifier: HeliosServiceIdentity.appIdentifier)
            throw CheckError.failed("Unvalidated Team ID accepted")
        } catch is XPCTrustError { }
        do {
            _ = try XPCTrustRequirement(validating: "certificate [")
            throw CheckError.failed("Malformed policy accepted")
        } catch is XPCTrustError { }
        do {
            _ = try XPCTrustRequirement.production(localIdentifier: HeliosServiceIdentity.appIdentifier, peerIdentifier: HeliosServiceIdentity.machServiceName)
            throw CheckError.failed("Ad-hoc process acquired production trust")
        } catch XPCTrustError.signingRequired { }
    }

    static func checkRegistration() async throws {
        let driver = FakeRegistration()
        let service = DaemonService(driver: driver)
        defer { service.shutdown() }
        try require(service.state == .missing, "Missing mapping")
        service.install()
        try require(service.state == .requiresApproval && service.client.state == .disconnected, "Pending approval must not connect")
        await service.uninstall()
        try require(service.state == .missing && !service.busy, "Removal did not refresh state")
        driver.nextStatus = .enabled
        service.install()
        try require(service.state == .installed && service.client.state == .signingRequired, "Installed must be distinct from authenticated IPC")
        driver.calls = []
        await service.reinstall()
        try require(driver.calls == ["unregister began", "unregister completed", "register"], "Reinstall raced helper shutdown")
        driver.calls = []
        driver.removalDelay = .milliseconds(150)
        let replacementStart = ContinuousClock.now
        await service.reinstall()
        try require(replacementStart.duration(to: .now) >= .milliseconds(150), "Reinstall registered before removal status settled")
        try require(driver.calls == ["unregister began", "unregister completed", "register"] && service.state == .installed, "Settled replacement failed")
        driver.removalDelay = .zero
        driver.failure = NSError(domain: "SMAppServiceErrorDomain", code: kSMErrorInvalidSignature)
        await service.uninstall()
        try require(service.state == .installed && service.message != nil && !service.busy, "Failed removal hid the existing service")
        driver.status = .requiresApproval
        driver.failure = NSError(domain: "SMAppServiceErrorDomain", code: kSMErrorLaunchDeniedByUser)
        service.install()
        try require(service.state == .requiresApproval && service.message?.contains("Approve") == true, "Pending approval error was not explained")
        driver.status = .notFound
        service.refresh()
        try require(service.state == .missing, "Missing bundle did not degrade gracefully")
        driver.failure = nil
        driver.status = .enabled
        driver.calls = []
        let removal = Task { await service.uninstall() }
        await Task.yield()
        if service.busy { service.install() }
        await removal.value
        try require(driver.calls == ["unregister began", "unregister completed"], "Concurrent installation escaped the busy guard")
    }

    /// Only this isolated test listener trusts an exact ad-hoc test-binary hash.
    /// Production code has no hash-based or unsigned authentication fallback.
    static func testRequirement() throws -> XPCTrustRequirement {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        try require(SecCodeCopySelf([], &code) == errSecSuccess, "Cannot read test identity")
        guard let code else { throw CheckError.failed("Missing test code") }
        try require(SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, "Cannot read static test identity")
        guard let staticCode else { throw CheckError.failed("Missing static code") }
        try require(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess, "Cannot read test signature")
        guard let info = information as? [String: Any], let hash = info[kSecCodeInfoUnique as String] as? Data else {
            throw CheckError.failed("Test signature has no CDHash")
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return try XPCTrustRequirement(validating: "cdhash H\"\(hex)\"")
    }

    static func checkTransport() async throws {
        let trusted = try testRequirement()
        let denied = try XPCTrustRequirement(validating: "never")
        do {
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted)
            defer { fixture.close() }
            let nonce = UUID()
            let hello = try await fixture.handshake(nonce: nonce)
            try require(hello.code == .ok && hello.version == HeliosServiceIdentity.protocolVersion && hello.nonce == nonce && hello.disarmed, "Invalid handshake reply")
            let pingNonce = UUID()
            let pong = try await fixture.ping(session: hello.session, sequence: 1, nonce: pingNonce)
            try require(pong.code == .ok && pong.nonce == pingNonce && pong.sequence == 1 && pong.disarmed && fixture.receiver.challenges == 2, "Bidirectional heartbeat failed")
            let replay = try await fixture.ping(session: hello.session, sequence: 1)
            try require(replay.code == .invalidSequence && replay.disarmed, "Replayed heartbeat accepted")
        }
        do {
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted)
            defer { fixture.close() }
            let reply = try await fixture.handshake(version: 999)
            try require(reply.code == .versionMismatch && reply.disarmed && fixture.receiver.challenges == 0, "Protocol mismatch not rejected")
        }
        do {
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted)
            defer { fixture.close() }
            fixture.receiver.setMode(.wrong)
            let reply = try await fixture.handshake()
            try require(reply.code == .challengeFailed && reply.disarmed, "Wrong callback nonce accepted")
        }
        for (server, client) in [(denied, trusted), (trusted, denied)] {
            let fixture = Fixture(serverTrust: server, clientTrust: client)
            defer { fixture.close() }
            do {
                _ = try await fixture.handshake()
                throw CheckError.failed("Untrusted XPC peer accepted")
            } catch CheckError.transport { }
            try require(fixture.receiver.challenges == 0, "Untrusted peer reached the callback")
        }
        do {
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted)
            defer { fixture.close() }
            let hello = try await fixture.handshake()
            fixture.receiver.setMode(.silent)
            let start = ContinuousClock.now
            do {
                _ = try await fixture.ping(session: hello.session, sequence: 1, timeout: 7)
                throw CheckError.failed("Hung client renewed the lease")
            } catch CheckError.transport { }
            let elapsed = start.duration(to: .now)
            try require(elapsed >= .seconds(4) && elapsed < .seconds(7), "Daemon did not independently expire a hung callback")
            try require(fixture.receiver.disarmReason == .leaseExpired, "Watchdog did not report disarm")
        }
    }

    /// State propagation through anonymous NSXPC, reverse callbacks and the
    /// main-actor client is asynchronous. This timeout is harness slack only.
    /// Keep it longer than the app's longest normal graceful-release timeout
    /// (7 s), otherwise a busy developer Mac can fail the test harness before
    /// the product-level deadline has even elapsed. Product safety deadlines are
    /// asserted separately below and are not relaxed here.
    static func waitUntil(_ label: String,
                          timeout: Duration = .seconds(9),
                          _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw CheckError.timeout(label)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func checkAppClient() async throws {
        let trusted = try testRequirement()
        let fixture = Fixture(serverTrust: trusted, clientTrust: trusted)
        defer { fixture.close() }
        let client = DaemonClient(trustProvider: { trusted }, connectionFactory: {
            NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
        })
        defer { client.disconnect() }
        client.connect()
        try await waitUntil("app client did not reach connected") { client.state == .connected }
        let first = client.lastHeartbeat
        try await waitUntil("app heartbeat did not advance") { client.lastHeartbeat != first }
        try require(client.state == .connected, "App heartbeat loop lost connection")
        let extra = DaemonClient(trustProvider: { trusted }, connectionFactory: {
            NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
        })
        extra.connect()
        try await waitUntil("second client was not rejected") { extra.state == .failed }
        extra.disconnect()
        try require(client.state == .connected, "Additional client displaced the session owner")
        client.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        client.connect(force: true)
        try await waitUntil("app client did not reach connected") { client.state == .connected }
        fixture.delegate.shutdown()
        try await waitUntil("client did not observe daemon shutdown") { client.state == .failed }
        try require(client.lastHeartbeat == nil, "Daemon shutdown left a stale connected state")
        client.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        let rejected = DaemonClient(trustProvider: { try XPCTrustRequirement(validating: "never") }, connectionFactory: {
            NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
        })
        defer { rejected.disconnect() }
        rejected.connect()
        try await waitUntil("client with denied peer trust was not rejected") { rejected.state == .failed }
        try require(rejected.detail != nil && rejected.lastHeartbeat == nil, "App did not safely report a rejected peer")
    }

    static func controlSnapshot(ticks: UInt64 = HostClock.now, temperature: Double = 50) -> TelemetrySnapshot {
        var snapshot = TelemetrySnapshot()
        snapshot.fans = MetricSample(.success(FanInventory(fans: [
            FanReading(id: 0, actualRPM: .success(0), targetRPM: .success(0), minimumRPM: .success(1_000), maximumRPM: .success(5_000), automatic: .success(true))
        ])), capturedTicks: ticks)
        snapshot.thermals = MetricSample(.success(ThermalMetrics(readings: [
            ThermalReading(key: "Tp01", group: .performanceCPU, celsius: temperature),
            ThermalReading(key: "Te01", group: .efficiencyCPU, celsius: temperature - 2),
            ThermalReading(key: "Tg01", group: .gpu, celsius: temperature - 4)
        ], failures: [:])), capturedTicks: ticks)
        snapshot.battery = MetricSample(.success(BatteryMetrics(
            designCapacityMAh: .success(6_000), maximumCapacityMAh: .success(6_000),
            currentCapacityMAh: .success(5_000), cycleCount: .success(1),
            temperatureCelsius: .success(30),
            power: .success(BatteryPower(signedWatts: 10, usesInstantaneousCurrent: true)),
            powerSource: .success(.powerAdapter)
        )), capturedTicks: ticks)
        return snapshot
    }

    static func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let name = "com.snejda.Helios.IPCChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { throw CheckError.failed("Could not create isolated Auto Rules defaults") }
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    /// Auto must behave as a persistent policy, not as a sequence of one-shot
    /// Manual requests. Live edits do not cancel a healthy/in-flight acquisition;
    /// the newest rule is applied on the next fresh sample. A transient hardware
    /// failure that verified System recovery keeps Auto armed and retries only
    /// after a short backoff. Manual -> empty Auto must still release ownership.
    static func checkAutoRulesModelTransitions() async throws {
        let trusted = try testRequirement()

        // Live edit during acquisition: do not tear down ownership just because
        // the user changed a Stepper/menu value. Complete the first command, then
        // update the already-owned target from the newest fresh thermal batch.
        do {
            let engine = AutoModelEngine(firstDelayMilliseconds: 400)
            let fans = FanControlCoordinator(validationMessage: nil, makeEngine: { engine })
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted, fans: fans)
            defer { fixture.close() }
            let client = DaemonClient(trustProvider: { trusted }, connectionFactory: {
                NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
            })
            defer { client.disconnect() }
            let (defaults, suite) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = FanControlModel(client: client, defaults: defaults)
            try require(model.availableRuleSensors.first?.source.kind == .always,
                        "Always condition must exist before dynamic thermal-sensor discovery")

            client.connect()
            try await waitUntil("Auto Rules client did not become available") { client.state == .connected && client.fanControlAvailable }

            var snapshot = controlSnapshot()
            model.refresh(snapshot)
            model.accept(snapshot.thermals)
            try require(model.availableRuleSensors.first?.source.kind == .always,
                        "Always condition is missing or buried in the Auto Rules sensor menu")

            guard let ruleID = model.rules(for: .powerAdapter).first?.id else { throw CheckError.failed("Safe Auto Rules profile is empty") }
            model.updateRule(profile: .powerAdapter, id: ruleID) {
                $0.sensor = .always
                $0.speedPercent = 40
            }
            model.setMode(.auto)
            snapshot = controlSnapshot()
            model.refresh(snapshot)
            model.accept(snapshot.thermals)
            try await waitUntil("Auto Rules acquisition did not enter the deterministic test engine") { engine.starts >= 1 }

            // This used to cancel the acquisition and cause Ftst/F0Md churn.
            model.updateRule(profile: .powerAdapter, id: ruleID) { $0.speedPercent = 50 }
            try await Task.sleep(for: .milliseconds(100))
            try require(engine.restores == 0, "Live Auto rule edit incorrectly forced a System restoration")
            try require(model.selection == .auto, "Live Auto rule edit disarmed Auto")

            try await waitUntil("Initial Auto acquisition did not complete") { client.fanState == .override }
            snapshot = controlSnapshot()
            model.refresh(snapshot)
            model.accept(snapshot.thermals)
            try await waitUntil("Edited Auto target was not applied without reacquisition") {
                engine.starts >= 2 && abs((engine.lastRPM ?? 0) - 3_000) <= 0.5
            }
            try require(engine.restores == 0 && model.selection == .auto && model.automaticDemandPercent == 50,
                        "Auto live edit did not preserve stable ownership and apply the newest rule")

            // Editing the inactive Battery profile remains configuration-only.
            let restoresBeforeInactiveEdit = engine.restores
            guard let batteryRuleID = model.rules(for: .battery).first?.id else {
                throw CheckError.failed("Safe Battery Auto Rules profile is empty")
            }
            model.updateRule(profile: .battery, id: batteryRuleID) { $0.speedPercent = 33 }
            try await Task.sleep(for: .milliseconds(150))
            try require(engine.restores == restoresBeforeInactiveEdit && client.fanState == .override && model.selection == .auto,
                        "Editing the inactive power profile interrupted active Auto cooling")

            model.setMode(.system)
            try await waitUntil("Auto Rules test did not return to System") { client.fanState == .system }
            await withCheckedContinuation { continuation in fans.shutdown { _ in continuation.resume() } }
        }

        // A transient hardware/acquisition failure is not a reason to permanently
        // turn Auto off. Verified System recovery + capability still available
        // leaves the policy armed, waits out a short retry backoff, then retries
        // only from newer telemetry.
        do {
            let engine = AutoModelEngine(failFirst: true)
            let fans = FanControlCoordinator(validationMessage: nil, makeEngine: { engine })
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted, fans: fans)
            defer { fixture.close() }
            let client = DaemonClient(trustProvider: { trusted }, connectionFactory: {
                NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
            })
            defer { client.disconnect() }
            let (defaults, suite) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = FanControlModel(client: client, defaults: defaults)

            client.connect()
            try await waitUntil("Auto retry client did not become available") { client.state == .connected && client.fanControlAvailable }
            var snapshot = controlSnapshot()
            model.refresh(snapshot); model.accept(snapshot.thermals)
            guard let ruleID = model.rules(for: .powerAdapter).first?.id else { throw CheckError.failed("Safe Auto Rules profile is empty") }
            model.updateRule(profile: .powerAdapter, id: ruleID) { $0.sensor = .always; $0.speedPercent = 40 }
            model.setMode(.auto)
            snapshot = controlSnapshot(); model.refresh(snapshot); model.accept(snapshot.thermals)

            try await waitUntil("Recoverable Auto failure did not restore System") { engine.restores >= 1 && client.fanState == .system }
            try require(model.selection == .auto && client.fanControlAvailable,
                        "Recoverable Auto acquisition failure incorrectly disarmed the policy")

            // Feed genuinely new samples while the 2-second backoff expires.
            for _ in 0..<6 where client.fanState != .override {
                try await Task.sleep(for: .milliseconds(500))
                snapshot = controlSnapshot()
                model.refresh(snapshot); model.accept(snapshot.thermals)
            }
            try await waitUntil("Auto did not retry after verified recoverable failure") { client.fanState == .override }
            try require(engine.starts >= 2 && model.selection == .auto,
                        "Auto retry did not use a new acquisition attempt")

            model.setMode(.system)
            try require(model.selection == .system, "Explicit System selection did not disarm Auto locally")
            try await waitUntil("Auto retry test did not return to System") { client.fanState == .system }
            await withCheckedContinuation { continuation in fans.shutdown { _ in continuation.resume() } }
        }

        // Explicit System must not depend forever on the cosmetic soft-release
        // ramp. Hold a deterministic graceful release between steps, then verify
        // the app-side fallback supersedes it with an immediate restore. This is
        // intentionally an XPC/state-machine test: the lower-level soft-release
        // sequence itself is covered independently by FanChecks.
        do {
            let engine = AutoModelEngine(releaseTargets: [4_200, 3_200])
            let fans = FanControlCoordinator(
                validationMessage: nil,
                makeEngine: { engine },
                softReleaseStepDelaySeconds: 5
            )
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted, fans: fans)
            defer { fixture.close() }
            let client = DaemonClient(trustProvider: { trusted }, connectionFactory: {
                NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
            })
            defer { client.disconnect() }
            let (defaults, suite) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = FanControlModel(
                client: client,
                defaults: defaults,
                explicitSystemFallbackDelay: .milliseconds(150)
            )

            client.connect()
            try await waitUntil("System fallback client did not become available") {
                client.state == .connected && client.fanControlAvailable
            }
            var snapshot = controlSnapshot()
            model.refresh(snapshot); model.accept(snapshot.thermals)
            guard let ruleID = model.rules(for: .powerAdapter).first?.id else {
                throw CheckError.failed("Safe Auto Rules profile is empty")
            }
            model.updateRule(profile: .powerAdapter, id: ruleID) {
                $0.sensor = .always
                $0.speedPercent = 40
            }
            model.setMode(.auto)
            snapshot = controlSnapshot()
            model.refresh(snapshot); model.accept(snapshot.thermals)
            try await waitUntil("System fallback fixture did not acquire Auto control") {
                client.fanState == .override
            }

            model.setMode(.system)
            try require(model.selection == .system, "System fallback fixture did not select System locally")
            try await waitUntil(
                "Explicit System fallback did not pre-empt a stalled graceful release",
                timeout: .seconds(2)
            ) {
                client.fanState == .system
            }
            try require(engine.restores >= 1, "Explicit System fallback never reached the restore executor")
            await withCheckedContinuation { continuation in fans.shutdown { _ in continuation.resume() } }
        }

        // Existing Manual ownership + empty Auto profile must return to System.
        do {
            let engine = AutoModelEngine()
            let fans = FanControlCoordinator(validationMessage: nil, makeEngine: { engine })
            let fixture = Fixture(serverTrust: trusted, clientTrust: trusted, fans: fans)
            defer { fixture.close() }
            let client = DaemonClient(trustProvider: { trusted }, connectionFactory: {
                NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
            })
            defer { client.disconnect() }
            let (defaults, suite) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = FanControlModel(client: client, defaults: defaults)

            client.connect()
            try await waitUntil("Manual-to-Auto client did not become available") { client.state == .connected && client.fanControlAvailable }
            var snapshot = controlSnapshot()
            model.refresh(snapshot); model.accept(snapshot.thermals)
            model.setMode(.override)
            snapshot = controlSnapshot(); model.refresh(snapshot); model.accept(snapshot.thermals)
            try await waitUntil("Manual precondition did not become active") { client.fanState == .override }

            for rule in model.rules(for: .powerAdapter) { model.removeRule(profile: .powerAdapter, id: rule.id) }
            model.setMode(.auto)
            snapshot = controlSnapshot(); model.refresh(snapshot); model.accept(snapshot.thermals)
            try await waitUntil("Manual -> empty Auto profile failed to release owned hardware") { client.fanState == .system }
            try require(model.selection == .auto && model.automaticDemandPercent == nil,
                        "Empty Auto profile should stay armed in System control")
            await withCheckedContinuation { continuation in fans.shutdown { _ in continuation.resume() } }
        }

        print("PASS Auto Rules stable live edits, recoverable retry backoff, bounded explicit-System fallback, inactive-profile isolation, unconditional source, and Manual-to-empty-Auto System handoff")
    }

    static func checkActiveControl() async throws {
        let trusted = try testRequirement()
        let hardware = FakeFanHardware()
        let journal = FakeFanJournal()
        let fans = FanControlCoordinator(validationMessage: nil, makeEngine: {
            try FanControlEngine(hardware: hardware, journal: journal)
        })
        let fixture = Fixture(serverTrust: trusted, clientTrust: trusted, fans: fans)
        defer { fixture.close() }
        let client = DaemonClient(trustProvider: { trusted }, connectionFactory: {
            NSXPCConnection(listenerEndpoint: fixture.listener.endpoint)
        })
        defer { client.disconnect() }
        client.connect()
        try await waitUntil("fan-control client did not become connected/available") { client.state == .connected && client.fanControlAvailable }
        hardware.setFailure("manual 0")
        let failedRevision = client.fanControlFaultRevision
        client.calculate(mode: .override, rpm: 0, temperature: 90, sampleTicks: HostClock.now)
        try await waitUntil("recoverable hardware failure did not reach the app") { client.fanControlFaultRevision > failedRevision }
        try require(client.fanState == .system && client.fanControlAvailable, "Recoverable hardware failure permanently disabled the validated fan-control UI")
        hardware.setFailure(nil)
        try require((try journal.load()).isEmpty && (try hardware.mode(0)) == 0 && (try hardware.mode(1)) == 0,
                    "Recoverable acquisition failure did not verify a clean System baseline")
        let ticks = HostClock.now
        client.calculate(mode: .override, rpm: 0, temperature: 90, sampleTicks: ticks)
        try await waitUntil("fresh manual retry after verified recovery did not become active") { client.fanState == .override }
        try require(hardware.target(0) == 1000 && hardware.target(1) == 1200, "XPC manual request escaped per-fan clamping")
        client.releaseFans()
        try await waitUntil("fan control did not return to System") { client.fanState == .system }
        client.calculate(mode: .boost, rpm: 0, temperature: 90, sampleTicks: ticks)
        try await waitUntil("stale calculation did not revoke fan-control availability") { !client.fanControlAvailable }
        try require(client.fanState == .system, "Replayed sample after System selection regained control")
        client.releaseFans()
        try await waitUntil("fan-control availability did not recover after explicit System") { client.fanControlAvailable }
        client.calculate(mode: .boost, rpm: 0, temperature: 90, sampleTicks: HostClock.now)
        try await waitUntil("Boost request did not become active") { client.fanState == .boost }
        try require(hardware.target(0) == 5000 && hardware.target(1) == 6000, "XPC Boost did not select factory maximums")
        // The normal client's one-second ping loop keeps running. There are no
        // additional thermal calculations, so control MUST expire independently.
        try await Task.sleep(for: .milliseconds(6100))
        try require(client.state == .connected && client.fanState == .system, "Heartbeat traffic renewed the hardware-control lease")
        try require((try journal.load()).isEmpty, "Expiry did not finish restoration")
        client.releaseFans()
        try await Task.sleep(for: .milliseconds(100))
        client.calculate(mode: .boost, rpm: 0, temperature: 90, sampleTicks: HostClock.now)
        try await waitUntil("Boost request did not become active") { client.fanState == .boost }
        client.disconnect()
        try await Task.sleep(for: .milliseconds(150))
        try require((try journal.load()).isEmpty && (try hardware.mode(0)) == 0, "XPC disconnect did not restore owned fans")
        await withCheckedContinuation { continuation in fans.shutdown { _ in continuation.resume() } }
        print("PASS typed control XPC, stale-sample replay rejection, heartbeat-independent expiry, and disconnect restoration")
    }
}
