import Foundation
import Combine

/// Decisions are made only from completed telemetry batches in the app. UI
/// refreshes, slider events, editor changes, and IPC heartbeats never renew the
/// daemon's control lease.
@MainActor
final class FanControlModel: ObservableObject {
    /// Core conditions must remain editable even while a live thermal batch is
    /// temporarily unavailable. Dynamic per-zone entries are appended whenever
    /// trusted telemetry is present. Keeping Always first also mirrors the
    /// unconditional TG-style rule without making it depend on sensor discovery.
    private static let baseRuleSensorOptions: [CoolingRuleSensorOption] = [
        .init(source: .always, label: "Always"),
        .init(source: .anySensor, label: "Any Sensor"),
        .init(source: .averageCPU, label: "Average CPU"),
        .init(source: .highestCPU, label: "Highest CPU"),
        .init(source: .maximumSoC, label: "Max SoC")
    ]
    @Published private(set) var selection = FanControlSelection.system
    @Published var targetRPM = 3_000.0
    @Published private(set) var telemetryReady = false
    @Published private(set) var inventory: MetricSample<FanInventory> = MetricSample(.failure(.warmingUp))
    @Published private(set) var rulesConfiguration: CoolingRulesConfiguration
    @Published private(set) var availableRuleSensors: [CoolingRuleSensorOption]
    @Published private(set) var activeRuleIDs: Set<UUID> = []
    @Published private(set) var activePowerProfile: CoolingPowerProfile?
    @Published private(set) var automaticDemandPercent: Int?
    @Published private(set) var automaticEmergency = false
    @Published private(set) var autoDetail = ""

    private var rulesEngine = CoolingRulesEngine()
    private var lastSample: UInt64 = 0
    /// Last command that the daemon actually confirmed as owning hardware.
    /// Never advance this merely because an XPC request was accepted locally.
    private var lastCommand = HeliosFanMode.system
    /// Command accepted by DaemonClient but not yet confirmed by a daemon reply.
    /// This matters for Auto edits: cancelling an in-flight takeover is allowed,
    /// but the subsequent verified System reply must clear the barrier even when
    /// ownership was never reached.
    private var pendingCommand: HeliosFanMode?
    private var lastTemperature = 0.0
    private var confirmedControl = false
    private var subscriptions: Set<AnyCancellable> = []
    private var latestBattery: MetricSample<BatteryMetrics> = MetricSample(.failure(.warmingUp))
    private var latestStorage: MetricSample<StorageMetrics> = MetricSample(.failure(.warmingUp))
    private var autoAppliedPercent: Double?
    private var autoAppliedTicks: UInt64?
    private var pendingExpectedAutoRelease = false
    /// Auto is a persistent policy mode. A transient, fully recovered takeover
    /// failure must not kick the user back to System or immediately hammer Ftst.
    /// Retry only from a later fresh thermal batch, with a short bounded backoff.
    private var autoRetryNotBefore: ContinuousClock.Instant?
    private static let autoRetryDelay: Duration = .seconds(2)

    /// Explicit System selection is a safety boundary, while the graceful
    /// soft-release ramp is cosmetic. If that ramp or its XPC reply ever stalls,
    /// supersede it with an immediate restore as long as the user still wants
    /// System. Selecting another mode cancels this fallback before it can fire.
    private var explicitSystemFallbackTask: Task<Void, Never>?
    private let explicitSystemFallbackDelay: Duration

    private let defaults: UserDefaults
    let client: DaemonClient

    init(
        client: DaemonClient,
        defaults: UserDefaults = .standard,
        explicitSystemFallbackDelay: Duration = .seconds(3)
    ) {
        self.client = client
        self.defaults = defaults
        self.explicitSystemFallbackDelay = explicitSystemFallbackDelay
        if let data = defaults.data(forKey: CoolingRulesPersistence.defaultsKey),
           let decoded = try? CoolingRulesPersistence.decode(data) {
            rulesConfiguration = decoded
        } else {
            rulesConfiguration = .safeDefault
        }
        availableRuleSensors = FanControlModel.baseRuleSensorOptions

        client.$fanControlAvailable.sink { [weak self] available in
            // Loss of control readiness is a safety disarm, never a cosmetic
            // soft release. A recoverable hardware-acquisition failure is
            // reported separately by `fanControlFaultRevision`, so it can
            // disarm the mode without permanently hiding the Auto editor.
            guard let self, !available, self.selection != .system else { return }
            self.transitionToSystem(graceful: false)
        }.store(in: &subscriptions)
        client.$fanControlFaultRevision.dropFirst().sink { [weak self] _ in
            guard let self, self.selection != .system else { return }

            // Auto is intentionally persistent like TG-style automatic cooling.
            // If a calculation failed but the daemon independently verified a
            // clean System restoration and the capability is still available,
            // keep Auto armed and retry from a later *fresh* thermal batch. This
            // avoids the old failure loop where one F0Md arbitration miss kicked
            // Auto to System forever. A short backoff also prevents hammering Ftst.
            if self.selection == .auto, self.client.fanControlAvailable,
               self.client.fanState == .system {
                self.pendingCommand = nil
                self.lastCommand = .system
                self.confirmedControl = false
                self.pendingExpectedAutoRelease = false
                self.resetAutomationRuntime()
                self.autoRetryNotBefore = ContinuousClock.now.advanced(by: Self.autoRetryDelay)
                self.autoDetail = "Auto Rules recovered safely to System · retrying from fresh telemetry"
                return
            }

            // Manual/Boost failures remain explicit opt-in failures. Likewise any
            // non-recoverable Auto failure disarms instead of retrying blindly.
            self.selection = .system
            self.pendingCommand = nil
            self.lastCommand = .system
            self.confirmedControl = false
            self.pendingExpectedAutoRelease = false
            self.autoRetryNotBefore = nil
            self.resetAutomationRuntime()
            if self.client.fanState != .system { self.client.releaseFans(graceful: false) }
        }.store(in: &subscriptions)
        client.$state.sink { [weak self] state in
            guard let self, state != .connected else { return }
            self.cancelExplicitSystemFallback()
            self.selection = .system
            self.pendingCommand = nil
            self.lastCommand = .system
            self.confirmedControl = false
            self.pendingExpectedAutoRelease = false
            self.autoRetryNotBefore = nil
            self.resetAutomationRuntime()
        }.store(in: &subscriptions)
        client.$fanState.sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .boost:
                self.pendingCommand = nil
                self.lastCommand = .boost
                self.confirmedControl = true
                self.autoRetryNotBefore = nil
            case .override:
                self.pendingCommand = nil
                self.lastCommand = .override
                self.confirmedControl = true
                self.autoRetryNotBefore = nil
            case .system:
                self.cancelExplicitSystemFallback()
                let hadPotentialControl = self.pendingCommand != nil || self.confirmedControl || self.lastCommand != .system
                self.pendingCommand = nil
                if self.pendingExpectedAutoRelease {
                    // Expected Auto no-match/profile-boundary release. System is
                    // the exact completion condition even if takeover was still
                    // in flight and ownership had never become visible.
                    self.finishExpectedAutoRelease()
                } else if self.selection == .auto {
                    // Auto is an armed policy, not a one-shot Manual command. A
                    // daemon-side safe restoration therefore leaves Auto selected;
                    // the next fresh rule evaluation may reacquire. Safety events
                    // that invalidate telemetry/session independently transition
                    // the model to System through their dedicated paths.
                    self.lastCommand = .system
                    self.confirmedControl = false
                    if hadPotentialControl, self.autoRetryNotBefore == nil {
                        self.autoRetryNotBefore = ContinuousClock.now.advanced(by: .seconds(1))
                        self.autoDetail = "Auto Rules returned safely to System · waiting for a fresh retry"
                    }
                } else if self.confirmedControl && self.lastCommand != .system {
                    // Manual/Boost remain explicit one-shot modes. Unexpected
                    // restoration requires the user to opt in again.
                    self.selection = .system
                    self.lastCommand = .system
                    self.confirmedControl = false
                    self.autoRetryNotBefore = nil
                    self.resetAutomationRuntime()
                } else {
                    self.lastCommand = .system
                    self.confirmedControl = false
                }
            case .restoring:
                break
            case .recoveryRequired:
                self.pendingCommand = nil
            }
        }.store(in: &subscriptions)
    }

    var pollingInterval: Duration {
        switch selection {
        case .system: .seconds(2)
        case .boost: lastTemperature >= 75 ? .milliseconds(500) : .seconds(2)
        case .override, .auto: .milliseconds(500)
        }
    }

    var sliderBounds: ClosedRange<Double>? {
        guard case .success(let inventory) = inventory.result, !inventory.fans.isEmpty else { return nil }
        let minimums = inventory.fans.compactMap { try? $0.minimumRPM.get() }
        let maximums = inventory.fans.compactMap { try? $0.maximumRPM.get() }
        guard minimums.count == inventory.fans.count, maximums.count == inventory.fans.count,
              let low = minimums.min(), let high = maximums.max(), low.isFinite, high.isFinite,
              low >= 0, high > low else { return nil }
        return low...high // The daemon clamps separately for each fan.
    }

    var fanTargets: [CoolingRuleTarget] {
        guard case .success(let inventory) = inventory.result else { return [.allFans] }
        return [.allFans] + inventory.fans.map { .fan($0.id) }
    }

    var canSelectBoost: Bool { client.fanControlAvailable && telemetryReady && sliderBounds != nil }
    var canSelectOverride: Bool { canSelectBoost }
    /// Auto is also the rules editor. An empty AC or Battery profile is valid
    /// and means "no matching rule -> System", so an empty profile must never
    /// make the Auto tab impossible to reopen and repair.
    var canSelectAuto: Bool { canSelectBoost }
    var canSelectControl: Bool { canSelectBoost }
    var automaticRulesArmed: Bool { selection == .auto && canSelectAuto }
    var automaticHardwareConfirmed: Bool {
        selection == .auto && (client.fanState == .override || client.fanState == .boost)
    }

    func canSelectMode(_ mode: FanControlSelection) -> Bool {
        switch mode {
        case .system: true
        case .boost: canSelectBoost
        case .override: canSelectOverride
        case .auto: canSelectAuto
        }
    }

    func setMode(_ mode: FanControlSelection) {
        guard canSelectMode(mode) else { return }
        if mode == .system {
            transitionToSystem(graceful: true)
            return
        }
        cancelExplicitSystemFallback()
        if mode == .override, let bounds = sliderBounds {
            targetRPM = targetRPM.isFinite ? min(bounds.upperBound, max(bounds.lowerBound, targetRPM)) : bounds.lowerBound
            targetRPM = (targetRPM / 50).rounded() * 50
            targetRPM = min(bounds.upperBound, max(bounds.lowerBound, targetRPM))
        }
        selection = mode
        autoRetryNotBefore = nil
        // Preserve independently confirmed daemon ownership when moving between
        // Boost/Manual/Auto. In particular, Manual -> Auto with no matching rule
        // must still know there is hardware to release back to macOS.
        switch client.fanState {
        case .boost:
            lastCommand = .boost; confirmedControl = true
        case .override:
            lastCommand = .override; confirmedControl = true
        case .system:
            if pendingCommand == nil { lastCommand = .system; confirmedControl = false }
        case .restoring, .recoveryRequired:
            break
        }
        resetAutomationRuntime()
        // A non-System selection waits for a NEW completed thermal batch. If an
        // internal System release is already in flight, `accept` waits for its
        // verified completion before issuing a new takeover.
    }

    func refresh(_ snapshot: TelemetrySnapshot) {
        inventory = snapshot.fans
        latestBattery = snapshot.battery
        latestStorage = snapshot.storage
        updatePowerProfile(snapshot.battery)
        updateAvailableSensors(snapshot)

        let age = HostClock.seconds(from: snapshot.thermals.capturedTicks, to: HostClock.now)
        let fanAge = HostClock.seconds(from: snapshot.fans.capturedTicks, to: HostClock.now)
        if fanAge < 0 || fanAge > 3 {
            inventory = MetricSample(.failure(.unavailable("Fan readings are stale")))
        }
        if age < 0 || age > 3 || fanAge < 0 || fanAge > 3 {
            telemetryReady = false
            if selection != .system { transitionToSystem(graceful: false) }
        }
        if sliderBounds == nil && selection != .system { transitionToSystem(graceful: false) }
    }

    func accept(_ sample: MetricSample<ThermalMetrics>) {
        let age = HostClock.seconds(from: sample.capturedTicks, to: HostClock.now)
        guard age >= 0, age <= 3, sample.capturedTicks > lastSample,
              case .success(let thermals) = sample.result,
              Set(thermals.readings.map(\.group)).isSuperset(of: [.performanceCPU, .efficiencyCPU, .gpu]),
              !thermals.failures.keys.contains(where: { $0.hasPrefix("Tp") || $0.hasPrefix("Te") || $0.hasPrefix("Tg") }),
              let temperature = try? thermals.maximumSoCCelsius.get(), temperature.isFinite else {
            telemetryReady = false
            if selection != .system { transitionToSystem(graceful: false) }
            return
        }

        lastSample = sample.capturedTicks
        lastTemperature = temperature
        telemetryReady = true
        guard selection != .system, canSelectControl else { return }
        // Reconfiguration/profile changes may intentionally supersede an
        // in-flight acquisition with an immediate System release. Do not race a
        // new calculation against that cleanup; the next genuinely fresh thermal
        // sample after the verified System reply will retry automatically.
        guard !pendingExpectedAutoRelease else { return }

        switch selection {
        case .system:
            return
        case .boost:
            send(mode: .boost, rpm: targetRPM, temperature: temperature, sampleTicks: sample.capturedTicks)
        case .override:
            // The daemon independently forces factory max at the emergency
            // temperature even if this requested Manual target is too low.
            send(mode: .override, rpm: targetRPM, temperature: temperature, sampleTicks: sample.capturedTicks)
        case .auto:
            evaluateAutomaticRules(thermals: thermals, temperature: temperature, sampleTicks: sample.capturedTicks)
        }
    }

    // MARK: - Cooling rules configuration

    func rules(for profile: CoolingPowerProfile) -> [CoolingRule] { rulesConfiguration.profile(profile).rules }

    func rule(profile: CoolingPowerProfile, id: UUID) -> CoolingRule? {
        rulesConfiguration.profile(profile).rules.first { $0.id == id }
    }

    func updateRule(profile: CoolingPowerProfile, id: UUID, _ update: (inout CoolingRule) -> Void) {
        var configured = rulesConfiguration
        var rules = configured.profile(profile).rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        update(&rules[index])
        rules[index].normalize()
        configured.setProfile(CoolingRuleProfile(rules: rules), for: profile)
        commitConfiguration(configured, affectedProfiles: [profile])
    }

    func addRule(profile: CoolingPowerProfile) {
        var configured = rulesConfiguration
        var rules = configured.profile(profile).rules
        guard rules.count < CoolingRulesConfiguration.maximumRuleCount else { return }
        let nextThreshold = min(95, (rules.compactMap { $0.sensor.kind == .always ? nil : $0.thresholdCelsius }.max() ?? 65) + 5)
        let nextPercent = min(100, (rules.map(\.speedPercent).max() ?? 0) + 20)
        rules.append(CoolingRule(speedPercent: nextPercent, sensor: .highestCPU, thresholdCelsius: nextThreshold))
        configured.setProfile(CoolingRuleProfile(rules: rules), for: profile)
        commitConfiguration(configured, affectedProfiles: [profile])
    }

    func addAlwaysRule(profile: CoolingPowerProfile) {
        var configured = rulesConfiguration
        var rules = configured.profile(profile).rules
        guard rules.count < CoolingRulesConfiguration.maximumRuleCount else { return }
        let nextPercent = min(100, max(20, (rules.map(\.speedPercent).max() ?? 0) + 20))
        rules.append(CoolingRule(speedPercent: nextPercent, sensor: .always))
        configured.setProfile(CoolingRuleProfile(rules: rules), for: profile)
        commitConfiguration(configured, affectedProfiles: [profile])
    }

    func removeRule(profile: CoolingPowerProfile, id: UUID) {
        var configured = rulesConfiguration
        var rules = configured.profile(profile).rules
        rules.removeAll { $0.id == id }
        configured.setProfile(CoolingRuleProfile(rules: rules), for: profile)
        commitConfiguration(configured, affectedProfiles: [profile])
    }

    func moveRule(profile: CoolingPowerProfile, id: UUID, offset: Int) {
        guard offset == -1 || offset == 1 else { return }
        var configured = rulesConfiguration
        var rules = configured.profile(profile).rules
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard rules.indices.contains(destination) else { return }
        rules.swapAt(index, destination)
        configured.setProfile(CoolingRuleProfile(rules: rules), for: profile)
        commitConfiguration(configured, affectedProfiles: [profile])
    }

    func copyRules(from source: CoolingPowerProfile, to destination: CoolingPowerProfile) {
        guard source != destination else { return }
        var configured = rulesConfiguration
        let copied = configured.profile(source).rules.map {
            CoolingRule(enabled: $0.enabled, target: $0.target, speedPercent: $0.speedPercent,
                        sensor: $0.sensor, thresholdCelsius: $0.thresholdCelsius)
        }
        configured.setProfile(CoolingRuleProfile(rules: copied), for: destination)
        commitConfiguration(configured, affectedProfiles: [destination])
    }

    func resetSafeRules() { commitConfiguration(.safeDefault) }

    func setTransitionSeconds(_ value: Double) {
        var configured = rulesConfiguration
        configured.transitionSeconds = value
        configured.normalize()
        rulesConfiguration = configured
        persistConfiguration(configured)
        // This setting only changes the rate of future downward transitions. It
        // cannot increase a target or weaken a safety release, so changing it
        // must not tear down an otherwise valid active Auto rule.
    }

    func label(for source: CoolingRuleSensor) -> String {
        if source.kind == .individual {
            guard let key = source.key else { return "Sensor" }
            if let option = availableRuleSensors.first(where: { $0.source == source }) { return option.label }
            return "Sensor \(key)"
        }
        return source.kind.label
    }

    func targetLabel(_ target: CoolingRuleTarget) -> String {
        target.fanID.map { "Fan \($0 + 1)" } ?? "All Fans"
    }

    // MARK: - Automatic evaluation

    private func evaluateAutomaticRules(thermals: ThermalMetrics, temperature: Double, sampleTicks: UInt64) {
        guard let power = activePowerProfile else {
            autoDetail = "Waiting for a trustworthy power-source reading; System remains in control."
            releaseAutoIfNeeded(graceful: false)
            return
        }
        guard let bounds = sliderBounds,
              case .success(let fanInventory) = inventory.result,
              !fanInventory.fans.isEmpty else {
            autoDetail = "Waiting for current fan limits."
            releaseAutoIfNeeded(graceful: false)
            return
        }

        let batteryAge = HostClock.seconds(from: latestBattery.capturedTicks, to: HostClock.now)
        let batteryTemperature: Double?
        if batteryAge >= 0, batteryAge <= 10,
           case .success(let battery) = latestBattery.result,
           case .success(let value) = battery.temperatureCelsius,
           value.isFinite {
            batteryTemperature = value
        } else {
            batteryTemperature = nil
        }

        let decision = rulesEngine.evaluate(
            profile: rulesConfiguration.profile(power),
            inputs: CoolingRuleInputs(thermals: thermals, batteryCelsius: batteryTemperature, storageCelsius: freshStorageTemperature()),
            fanIDs: fanInventory.fans.map(\.id),
            ticks: sampleTicks
        )
        activeRuleIDs = decision.activeRuleIDs
        automaticDemandPercent = decision.maximumPercent
        automaticEmergency = decision.emergency

        guard let percent = decision.maximumPercent else {
            autoRetryNotBefore = nil
            autoDetail = "No rule active · \(power.label) · System control"
            releaseAutoIfNeeded(graceful: true)
            return
        }

        // A safely recovered transient acquisition failure keeps Auto armed but
        // backs off before trying Ftst/F0Md again. Emergency cooling bypasses the
        // cosmetic retry delay and is attempted from this fresh sample immediately.
        if !decision.emergency, let retry = autoRetryNotBefore, ContinuousClock.now < retry {
            autoDetail = "\(power.label) · \(percent)% matching · retrying fan takeover shortly"
            return
        }
        autoRetryNotBefore = nil

        let appliedPercent = automaticPercent(desired: Double(percent), emergency: decision.emergency, ticks: sampleTicks)
        guard let rpm = try? CoolingRulePercentCodec.rpm(percent: Int(appliedPercent.rounded()), bounds: bounds) else {
            autoDetail = "Automatic target could not be mapped to validated fan limits."
            releaseAutoIfNeeded(graceful: false)
            return
        }
        let mode: HeliosFanMode = decision.emergency || appliedPercent >= 99.5 ? .boost : .override
        let suffix = decision.emergency ? " · Emergency Max" : ""
        if pendingExpectedAutoRelease {
            autoDetail = "Waiting for verified System release before applying the next rule."
            return
        }
        autoDetail = "\(power.label) · \(Int(appliedPercent.rounded()))% · \(Int(rpm.rounded())) RPM\(suffix)"
        send(mode: mode, rpm: rpm, temperature: temperature, sampleTicks: sampleTicks)
    }

    private func freshStorageTemperature() -> Double? {
        guard case .success(let storage) = latestStorage.result,
              case .success(let smart) = storage.smartHealth,
              let captured = storage.smartHealthCapturedTicks,
              let value = smart.temperatureCelsius, value.isFinite else { return nil }
        let age = HostClock.seconds(from: captured, to: HostClock.now)
        guard age >= 0, age <= 90 else { return nil }
        return value
    }

    /// Upward cooling changes are immediate. Only reductions use the user-facing
    /// transition duration; this preserves TG-style smooth step changes without
    /// allowing a cosmetic setting to delay needed cooling.
    private func automaticPercent(desired: Double, emergency: Bool, ticks: UInt64) -> Double {
        let desired = min(100, max(0, desired))
        guard !emergency, let current = autoAppliedPercent, desired < current,
              let previousTicks = autoAppliedTicks, rulesConfiguration.transitionSeconds > 0 else {
            autoAppliedPercent = desired
            autoAppliedTicks = ticks
            return desired
        }
        let elapsed = max(0, HostClock.seconds(from: previousTicks, to: ticks))
        let rate = 100.0 / rulesConfiguration.transitionSeconds
        let next = max(desired, current - (rate * elapsed))
        autoAppliedPercent = next
        autoAppliedTicks = ticks
        return next
    }

    private func send(mode: HeliosFanMode, rpm: Double, temperature: Double, sampleTicks: UInt64) {
        // Accepted XPC traffic is not the same thing as confirmed hardware
        // ownership. Keep it separate until `fanState` reports Boost/Override.
        if client.calculate(mode: mode, rpm: rpm, temperature: temperature, sampleTicks: sampleTicks) {
            pendingCommand = mode
        }
    }

    private var hasPotentialControl: Bool {
        pendingCommand != nil || confirmedControl || lastCommand != .system || client.fanState != .system
    }

    private func releaseAutoIfNeeded(graceful: Bool) {
        guard hasPotentialControl else {
            autoAppliedPercent = nil
            autoAppliedTicks = nil
            return
        }
        beginExpectedAutoRelease(graceful: graceful)
        autoAppliedPercent = nil
        autoAppliedTicks = nil
    }

    private func beginExpectedAutoRelease(graceful: Bool) {
        guard !pendingExpectedAutoRelease else { return }
        pendingExpectedAutoRelease = true
        if selection == .auto { autoDetail = "Returning to System before applying updated rules…" }
        let accepted = client.releaseFans(graceful: graceful) { [weak self] state in
            guard let self else { return }
            if state == .system { self.finishExpectedAutoRelease() }
        }
        if !accepted {
            // Disconnect/unavailability has its own safety path. Never leave the
            // app-side Auto barrier wedged merely because no release request could
            // be queued; if System is already known, finish locally.
            if client.fanState == .system { finishExpectedAutoRelease() }
            else { pendingExpectedAutoRelease = false }
        }
    }

    private func finishExpectedAutoRelease() {
        pendingExpectedAutoRelease = false
        pendingCommand = nil
        lastCommand = .system
        confirmedControl = false
        autoRetryNotBefore = nil
        autoAppliedPercent = nil
        autoAppliedTicks = nil
        if selection == .auto { autoDetail = "" }
    }

    private func transitionToSystem(graceful: Bool) {
        cancelExplicitSystemFallback()
        selection = .system
        pendingCommand = nil
        lastCommand = .system
        confirmedControl = false
        pendingExpectedAutoRelease = false
        autoRetryNotBefore = nil
        resetAutomationRuntime()

        let accepted = client.releaseFans(graceful: graceful)
        guard accepted, graceful, client.fanState != .system else { return }

        let delay = explicitSystemFallbackDelay
        explicitSystemFallbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.explicitSystemFallbackTask = nil
            guard self.selection == .system,
                  self.client.state == .connected,
                  self.client.fanState != .system else { return }

            // The user's requested end state is System. A cosmetic soft ramp is
            // never allowed to outlive that intent indefinitely; a fresh
            // immediate release supersedes the graceful request and the daemon's
            // normal restore/recovery machinery remains the source of truth.
            _ = self.client.releaseFans(graceful: false)
        }
    }

    private func cancelExplicitSystemFallback() {
        explicitSystemFallbackTask?.cancel()
        explicitSystemFallbackTask = nil
    }

    private func resetAutomationRuntime() {
        rulesEngine.reset()
        activeRuleIDs = []
        automaticDemandPercent = nil
        automaticEmergency = false
        autoDetail = ""
        autoAppliedPercent = nil
        autoAppliedTicks = nil
    }

    private func commitConfiguration(
        _ value: CoolingRulesConfiguration,
        affectedProfiles: Set<CoolingPowerProfile> = Set(CoolingPowerProfile.allCases)
    ) {
        var value = value
        value.normalize()
        rulesConfiguration = value
        persistConfiguration(value)

        // Editing the inactive AC/Battery profile is configuration-only. Live
        // Auto edits are also *not* a reason to tear down ownership: cancelling
        // every Stepper/menu change was the source of the unstable Next15 loop.
        // Reset rule debounce/downshift state and let the next fresh 500 ms thermal
        // batch compile the newest configuration into either a same-ownership
        // target update or, if nothing matches, one verified System release.
        let affectsLiveProfile = activePowerProfile.map { affectedProfiles.contains($0) } ?? false
        guard selection == .auto, affectsLiveProfile else { return }
        resetAutomationRuntime()
    }

    private func persistConfiguration(_ value: CoolingRulesConfiguration) {
        if let data = try? CoolingRulesPersistence.encode(value) {
            defaults.set(data, forKey: CoolingRulesPersistence.defaultsKey)
        }
    }

    private func updatePowerProfile(_ sample: MetricSample<BatteryMetrics>) {
        let age = HostClock.seconds(from: sample.capturedTicks, to: HostClock.now)
        guard age >= 0, age <= 10, case .success(let battery) = sample.result,
              case .success(let source) = battery.powerSource else {
            // We cannot safely choose between the independently configured AC
            // and battery rule sets. If Auto currently owns the fan, release it
            // immediately and require a new trustworthy power-source sample.
            if activePowerProfile != nil, selection == .auto, hasPotentialControl {
                beginExpectedAutoRelease(graceful: false)
            }
            activePowerProfile = nil
            rulesEngine.reset()
            activeRuleIDs = []
            automaticDemandPercent = nil
            automaticEmergency = false
            autoAppliedPercent = nil
            autoAppliedTicks = nil
            return
        }
        let profile: CoolingPowerProfile = source == .powerAdapter ? .powerAdapter : .battery
        if activePowerProfile != profile {
            // A charger transition changes the entire rule set. Never carry an
            // old-profile target across that boundary; return to Apple first,
            // then let the next fresh thermal batch evaluate the new profile.
            if activePowerProfile != nil, selection == .auto, hasPotentialControl {
                beginExpectedAutoRelease(graceful: false)
            }
            activePowerProfile = profile
            rulesEngine.reset()
            activeRuleIDs = []
            automaticDemandPercent = nil
            automaticEmergency = false
            autoAppliedPercent = nil
            autoAppliedTicks = nil
        }
    }

    private func updateAvailableSensors(_ snapshot: TelemetrySnapshot) {
        var options = Self.baseRuleSensorOptions
        guard case .success(let thermals) = snapshot.thermals.result else {
            // Never make the unconditional/core choices disappear just because
            // dynamic SMC discovery is temporarily unavailable.
            availableRuleSensors = options
            return
        }
        let trusted = thermals.readings.filter { $0.group != .unclassified }
        if trusted.contains(where: { $0.group == .performanceCPU }) {
            options.append(.init(source: .performanceCPU, label: "P-Cores"))
        }
        if trusted.contains(where: { $0.group == .efficiencyCPU }) {
            options.append(.init(source: .efficiencyCPU, label: "E-Cores"))
        }
        if trusted.contains(where: { $0.group == .gpu }) {
            options.append(.init(source: .gpu, label: "GPU"))
        }
        if case .success(let battery) = snapshot.battery.result,
           case .success = battery.temperatureCelsius {
            options.append(.init(source: .battery, label: "Battery"))
        }
        if case .success(let storage) = snapshot.storage.result,
           case .success(let smart) = storage.smartHealth, smart.temperatureCelsius != nil {
            options.append(.init(source: .storage, label: "SSD"))
        }
        for reading in trusted.sorted(by: { $0.key < $1.key }) {
            let group: String = switch reading.group {
            case .performanceCPU: "P-Core"
            case .efficiencyCPU: "E-Core"
            case .gpu: "GPU"
            case .validatedHotspot: "Validated hotspot"
            case .unclassified: "Sensor"
            }
            options.append(.init(source: .individual(reading.key), label: "\(group) · \(reading.key)"))
        }
        availableRuleSensors = options
    }
}
