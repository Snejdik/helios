import Foundation
import OSLog

/// Start-up recovery for every ownership journal Helios may have left behind,
/// on any model/build. Clean journals open no
/// writer at all. Recovery writes only Ftst=0 and FxMd=0.
enum FanLayerRecoveryBootstrap {
    private static let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanRecovery")

    static func policy() throws -> FanOwnershipTransitionPolicy {
        try FanOwnershipTransitionPolicy(timeoutSeconds: 4.0, requiredStableReads: 10)
    }

    /// Generic, injectable core used by the daemon and the tests.
    static func recover(journal: any FanLayerJournal, current: FanLayerMachineIdentity,
                        makeHardware: @escaping () throws -> any FanOwnershipRecoveryHardware,
                        now: @escaping () -> UInt64, pause: @escaping () throws -> Void) throws -> FanLayerRecoveryDisposition {
        let record = try journal.load()
        let disposition = FanLayerRecoveryDisposition.evaluate(record: record, origin: journal.origin, current: current)
        switch disposition {
        case .clean:
            return disposition
        case .foreignModel:
            try journal.quarantine()
            return disposition
        case .recover:
            let bootstrap = FanRecoveryBootstrap(journal: journal, makeHardware: makeHardware,
                                                 transitionPolicy: try policy(), now: now, pause: pause)
            _ = try bootstrap.run()
            return disposition
        }
    }

    /// Daemon entry: the legacy v2 production journal first, then the v3 layer journal.
    static func run(current: FanLayerMachineIdentity) throws {
        let now: @Sendable () -> UInt64 = { HostClock.now }
        let pause: @Sendable () throws -> Void = { Thread.sleep(forTimeInterval: 0.10) }
        let legacy = FanLegacyJournalAdapter(journal: try ProductionFanOwnershipRecoveryJournal())
        let legacyResult = try recover(journal: legacy, current: current,
                                       makeHardware: { try FanLayerRecoveryHardware() }, now: now, pause: pause)
        if legacyResult != .clean {
            logger.notice("Legacy v2 fan journal recovered to System on \(current.summary, privacy: .public).")
        }
        let journal = try FanLayerDiskJournal(identity: current)
        let result = try recover(journal: journal, current: current, makeHardware: { try FanLayerRecoveryHardware() },
                                 now: now, pause: pause)
        switch result {
        case .clean: logger.notice("Fan layer journal clean; no recovery writer opened.")
        case .recover(let crossBuild):
            logger.notice("Fan layer journal recovered to System\(crossBuild ? " after a macOS build change" : "", privacy: .public).")
        case .foreignModel: logger.fault("Fan layer journal from another Mac model was set aside without writes.")
        }
    }
}

/// The v2 journal carries no identity; present it as a layer journal whose
/// origin is unknown so the shared disposition rules apply.
final class FanLegacyJournalAdapter: FanLayerJournal {
    private let journal: any FanOwnershipRecoveryJournal
    init(journal: any FanOwnershipRecoveryJournal) { self.journal = journal }
    var origin: FanLayerMachineIdentity? { nil }
    func load() throws -> FanOwnershipRecoveryRecord { try journal.load() }
    func save(_ record: FanOwnershipRecoveryRecord) throws { try journal.save(record) }
    func quarantine() throws { throw TelemetryError.unavailable("The legacy journal is never set aside") }
}

/// Everything the daemon knows about the fan layer on this Mac: read-only
/// probe, per model+build consent (the default-off switch), the learned macOS
/// envelope, engine construction and the wake check.
final class FanLayerRuntime: @unchecked Sendable {
    private static let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "FanLayer")
    static let samplingIntervalSeconds = 3

    let identity: FanLayerMachineIdentity?
    let profile: FanLayerProfile?
    let probeFailure: String?
    let consented: Bool
    let observer = FanLayerSystemObserver()
    private let consentStore: any FanLayerConsentStore
    private let limitStore: any FanLayerLimitStore
    private let entryTestStore: any FanLayerEntryTestStore
    private let limitLock = NSLock()
    private var fullMaximum: Bool
    private var entryTestState: FanLayerEntryTestState
    private var entryTestDetail = ""
    private var entryTestRunning = false
    private let samplerQueue = DispatchQueue(label: "com.snejda.Helios.fan-layer-sampler", qos: .utility)
    private var samplerTimer: DispatchSourceTimer?
    private var samplerThermals: (any FanLayerThermalSource)?
    private var samplerReader: SMCFanReader?
    /// Last time the sampler saw Ftst=1. Fans spinning down after a release
    /// are Helios's doing, not macOS's, so the envelope ignores that window.
    private var samplerLastOwned: UInt64?
    static let settleAfterOwnershipSeconds = 20.0

    init(identity: FanLayerMachineIdentity?, profile: FanLayerProfile?, probeFailure: String?,
         consentStore: any FanLayerConsentStore,
         limitStore: any FanLayerLimitStore = FanLayerDiskLimitStore(),
         entryTestStore: any FanLayerEntryTestStore = FanLayerDiskEntryTestStore()) {
        self.identity = identity
        self.profile = profile
        self.probeFailure = probeFailure
        self.consentStore = consentStore
        self.limitStore = limitStore
        self.entryTestStore = entryTestStore
        consented = identity.map { consentStore.isConsented($0) } ?? false
        // Unreadable means the safe default: the 90 % limit applies.
        fullMaximum = (try? limitStore.fullMaximumAllowed()) ?? false
        entryTestState = identity.map { entryTestStore.state(for: $0) } ?? .notRun
    }

    /// The user's unlock of the full factory maximum (`FanLayerCeiling`). Only the
    /// validated tuple can unlock it; elsewhere the 70 % limit always applies.
    var fullMaximumAllowed: Bool {
        limitLock.lock(); defer { limitLock.unlock() }
        return fullMaximum && (profile?.fullMaximumUnlockable ?? false)
    }

    /// Persists first, then applies to the next calculation; no restart needed.
    func setFullMaximumAllowed(_ allowed: Bool) throws {
        if allowed, !(profile?.fullMaximumUnlockable ?? false) {
            throw TelemetryError.unavailable("On a Mac that is not validated the fan limit stays at 70 % of the factory maximum.")
        }
        try limitStore.setFullMaximumAllowed(allowed)
        limitLock.lock(); fullMaximum = allowed; limitLock.unlock()
    }

    /// Read-only probe. Never throws: any failure becomes an honest reason.
    static func probe(consentStore: any FanLayerConsentStore = FanLayerDiskConsentStore()) -> FanLayerRuntime {
        let identity = try? FanLayerMachineIdentity.current()
        do {
            let transport = try SMCIOKitTransport()
            let client = SMCClient(transport: transport)
            let evidence = try SMCFanOwnershipPreflightReader(client: client).read().evidence
            let access = try? FanLayerKeyAccess.read(keys: FanLayerProbe.accessKeys(evidence: evidence),
                                                     transport: transport)
            let cpuBrand = (try? HeliosMachineIdentity.sysctlString("machdep.cpu.brand_string")) ?? ""
            let thermals = (try? SMCFanLayerThermals(client: client, cpuBrand: cpuBrand))
                .flatMap { try? $0.maximumSoCCelsius() } != nil
            let profile = try FanLayerProbe.evaluate(evidence: evidence, cpuBrand: cpuBrand, access: access,
                                                     trustedThermalsAvailable: thermals)
            logger.notice("Fan layer probe: \(profile.tier.label, privacy: .public) (\(profile.strategy.rawValue, privacy: .public), \(profile.thermalTrust.rawValue, privacy: .public) thermals) on \(profile.identity.summary, privacy: .public); reasons: \(profile.reasons.joined(separator: " "), privacy: .public)")
            return FanLayerRuntime(identity: identity, profile: profile, probeFailure: nil, consentStore: consentStore)
        } catch {
            logger.error("Fan layer probe failed: \(error.localizedDescription, privacy: .public)")
            return FanLayerRuntime(identity: identity, profile: nil,
                                   probeFailure: "Fan hardware could not be read: \(error.localizedDescription)",
                                   consentStore: consentStore)
        }
    }

    var tier: FanLayerTier { profile?.tier ?? .unsupported }

    var entryTest: FanLayerEntryTestState {
        limitLock.lock(); defer { limitLock.unlock() }
        return entryTestState
    }

    var entryTestSummary: String {
        limitLock.lock(); defer { limitLock.unlock() }
        return entryTestDetail
    }

    /// Consent alone is not enough on an unvalidated Mac: the entry test must have passed
    /// for this exact model + build.
    var enabled: Bool {
        guard tier != .unsupported, consented, let profile else { return false }
        return !profile.needsEntryTest || entryTest == .passed
    }

    var reason: String {
        if let probeFailure { return probeFailure }
        guard let profile else { return "Fan hardware was not probed." }
        switch profile.tier {
        case .unsupported: return profile.reasons.joined(separator: " ")
        case .experimental, .validated:
            guard consented else {
                return "\(profile.tier.label) fan layer is available but off until you turn it on in Settings."
            }
            if profile.needsEntryTest {
                switch entryTest {
                case .failed:
                    return "The 20-second fan test failed on \(profile.identity.summary), so fan control stays off on this Mac and macOS build."
                case .notRun:
                    return "Run the 20-second fan test in Settings › Cooling to finish turning on fan control."
                case .passed:
                    break
                }
            }
            return "\(profile.tier.label) fan layer is on for \(profile.identity.summary)."
        }
    }

    var readyDetail: String {
        let limit = Int(((profile?.ceilingFraction ?? FanLayerCeiling.defaultFraction) * 100).rounded())
        return "\(tier.label) fan layer: Helios only adds cooling over macOS, stays within your speed limit (\(limit) % unless unlocked on a validated Mac), and returns control to macOS on any error or when more cooling is needed."
    }

    /// The mandatory first test on an unvalidated model + build. Runs only while the
    /// layer is consented but not yet enabled, so no coordinator writer exists.
    func runEntryTest() -> FanLayerEntryTestOutcome {
        guard consented, let identity, let profile, profile.needsEntryTest else {
            return .inconclusive("The fan test is only needed on a Mac that is not validated, after you turn fan control on.")
        }
        limitLock.lock()
        guard !entryTestRunning, entryTestState != .passed else {
            let state = entryTestState
            limitLock.unlock()
            return state == .passed ? .passed : .inconclusive("The fan test is already running.")
        }
        guard entryTestState != .failed else {
            limitLock.unlock()
            return .failed("The fan test already failed on this Mac and macOS build.")
        }
        entryTestRunning = true
        limitLock.unlock()
        defer { limitLock.lock(); entryTestRunning = false; limitLock.unlock() }

        let outcome: FanLayerEntryTestOutcome
        do {
            let journal = try FanLayerDiskJournal(identity: identity)
            let stateMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
            let hardware = try FanLayerSMCHardware(profile: profile)
            let thermals = try SMCFanLayerThermals(client: SMCClient(transport: try SMCIOKitTransport()),
                                                   cpuBrand: profile.cpuBrand)
            outcome = FanLayerEntryTest(profile: profile, stateMachine: stateMachine, hardware: hardware,
                                        thermals: thermals).run()
        } catch {
            return .inconclusive("The fan test could not start: \(error.localizedDescription)")
        }
        let stored: FanLayerEntryTestState?
        switch outcome {
        case .passed: stored = .passed
        case .failed: stored = .failed
        case .inconclusive: stored = nil
        }
        if let stored {
            do { try entryTestStore.record(stored, for: identity) } catch {
                Self.logger.error("Could not store the fan test result: \(error.localizedDescription, privacy: .public)")
            }
            limitLock.lock(); entryTestState = stored; limitLock.unlock()
        }
        limitLock.lock()
        switch outcome {
        case .passed: entryTestDetail = "Passed: every fan held its factory minimum for 20 seconds and returned to macOS."
        case .failed(let reason): entryTestDetail = reason
        case .inconclusive(let reason): entryTestDetail = reason
        }
        limitLock.unlock()
        return outcome
    }

    func makeEngine() throws -> FanLayerEngine {
        guard enabled, let profile, let identity else {
            throw TelemetryError.unavailable("The fan layer is not enabled on this Mac")
        }
        let journal = try FanLayerDiskJournal(identity: identity)
        let stateMachine = try FanOwnershipRecoveryStateMachine(journal: journal)
        let hardware = try FanLayerSMCHardware(profile: profile)
        let thermals = try SMCFanLayerThermals(client: SMCClient(transport: try SMCIOKitTransport()),
                                               cpuBrand: profile.cpuBrand)
        return try FanLayerEngine(profile: profile, stateMachine: stateMachine, hardware: hardware,
                                  thermals: thermals, observer: observer,
                                  fullMaximum: { [weak self] in self?.fullMaximumAllowed ?? false })
    }

    /// Recovery, then a fresh read-only reprobe that must show the same surface
    /// with Ftst=0 and every fan under macOS before control can resume.
    func wakeSafetyCheck() throws {
        guard let identity else { throw TelemetryError.unavailable("Machine identity unavailable after wake") }
        try FanLayerRecoveryBootstrap.run(current: identity)
        guard enabled, let profile else { return }
        let started = HostClock.now
        var lastReason = "no post-wake sample"
        while HostClock.seconds(from: started, to: HostClock.now) < 8 {
            do {
                let transport = try SMCIOKitTransport()
                let evidence = try SMCFanOwnershipPreflightReader(client: SMCClient(transport: transport)).read().evidence
                let access = try FanLayerKeyAccess.read(keys: FanLayerProbe.accessKeys(evidence: evidence),
                                                        transport: transport)
                let live = try FanLayerProbe.evaluate(evidence: evidence, cpuBrand: profile.cpuBrand, access: access,
                                                      trustedThermalsAvailable: true)
                if FanLayerProbe.sameSurface(live, as: profile) { return }
                lastReason = live.reasons.first ?? "fan surface changed"
            } catch {
                lastReason = error.localizedDescription
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw TelemetryError.unavailable("Wake fan reprobe did not reach a clean macOS baseline: \(lastReason)")
    }

    /// Only recovery (for Macs where the layer is off): never blocks wake on a
    /// profile that was never usable.
    func recoverOnly() throws {
        guard let identity else { return }
        try FanLayerRecoveryBootstrap.run(current: identity)
    }

    func setConsent(_ accepted: Bool) throws -> Bool {
        if accepted {
            guard let identity, tier != .unsupported else {
                throw TelemetryError.unavailable("The fan layer is not supported on this Mac")
            }
            try consentStore.grant(identity)
        } else {
            try consentStore.revoke()
        }
        return accepted != consented
    }

    /// Learns what macOS does (the envelope) with cheap read-only samples while
    /// macOS controls the fans. Only runs while the layer is enabled.
    func startSampling() {
        guard enabled, let profile, samplerTimer == nil else { return }
        // A previous helper may have just released the fans; let them settle.
        samplerQueue.sync { samplerLastOwned = HostClock.now }
        let timer = DispatchSource.makeTimerSource(queue: samplerQueue)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(Self.samplingIntervalSeconds),
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.sample(profile) }
        samplerTimer = timer
        timer.activate()
    }

    private func sample(_ profile: FanLayerProfile) {
        do {
            if samplerReader == nil || samplerThermals == nil {
                let client = SMCClient(transport: try SMCIOKitTransport())
                samplerReader = SMCFanReader(client: client)
                samplerThermals = try SMCFanLayerThermals(client: client, cpuBrand: profile.cpuBrand)
            }
            guard let reader = samplerReader, let thermals = samplerThermals else { return }
            let now = HostClock.now
            // Ftst on the validated path; on a direct-strategy Mac any fan in manual mode.
            let owned: Bool
            switch profile.strategy {
            case .ftst: owned = try reader.client.value("Ftst").bytes.first != 0
            case .direct: owned = try profile.fans.contains { try reader.mode($0.id) == 1 }
            }
            guard !owned else {
                samplerLastOwned = now // Helios or someone else owns the fans.
                return
            }
            if let owned = samplerLastOwned {
                let age = HostClock.seconds(from: owned, to: now)
                guard age.isFinite, age >= Self.settleAfterOwnershipSeconds else { return }
            }
            let celsius = try thermals.maximumSoCCelsius()
            for fan in profile.fans {
                // Only macOS's own command (mode 3, target) describes macOS.
                guard try reader.mode(fan.id) == 3 else { continue }
                observer.observe(fanID: fan.id, celsius: celsius, systemRPM: try reader.rpm(fan.id, "Tg"))
            }
        } catch {
            // Drop the reader; the next tick reopens it. Sampling never blocks control.
            samplerReader = nil
            samplerThermals = nil
        }
    }
}
