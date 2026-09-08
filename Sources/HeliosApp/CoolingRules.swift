import Foundation

/// App-only presentation/control mode. The privileged helper deliberately stays
/// limited to System/Boost/Override; Auto Rules compiles down to the already
/// validated Override/Boost requests from fresh telemetry calculations.
enum FanControlSelection: String, CaseIterable, Sendable {
    case system
    case boost
    case override
    case auto

    var label: String {
        switch self {
        case .system: "System"
        case .boost: "Boost"
        case .override: "Manual"
        case .auto: "Auto"
        }
    }
}

enum CoolingPowerProfile: String, Codable, CaseIterable, Sendable {
    case powerAdapter
    case battery

    var label: String {
        switch self {
        case .powerAdapter: "Power Adapter"
        case .battery: "Battery"
        }
    }
}

enum CoolingRuleSensorKind: String, Codable, CaseIterable, Sendable {
    case anySensor
    case always
    case averageCPU
    case highestCPU
    case maximumSoC
    case performanceCPU
    case efficiencyCPU
    case gpu
    case battery
    case storage
    case individual

    var label: String {
        switch self {
        case .anySensor: "Any Sensor"
        case .always: "Always"
        case .averageCPU: "Average CPU"
        case .highestCPU: "Highest CPU"
        case .maximumSoC: "Max SoC"
        case .performanceCPU: "P-Cores"
        case .efficiencyCPU: "E-Cores"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .storage: "SSD"
        case .individual: "Sensor"
        }
    }

    /// `Always` is unconditional and deliberately has no temperature field in
    /// the editor. Every other source is a threshold rule.
    var usesThreshold: Bool { self != .always }
}

struct CoolingRuleSensor: Codable, Hashable, Sendable {
    var kind: CoolingRuleSensorKind
    var key: String?

    static let anySensor = Self(kind: .anySensor, key: nil)
    static let always = Self(kind: .always, key: nil)
    static let averageCPU = Self(kind: .averageCPU, key: nil)
    static let highestCPU = Self(kind: .highestCPU, key: nil)
    static let maximumSoC = Self(kind: .maximumSoC, key: nil)
    static let performanceCPU = Self(kind: .performanceCPU, key: nil)
    static let efficiencyCPU = Self(kind: .efficiencyCPU, key: nil)
    static let gpu = Self(kind: .gpu, key: nil)
    static let battery = Self(kind: .battery, key: nil)
    static let storage = Self(kind: .storage, key: nil)

    static func individual(_ key: String) -> Self { Self(kind: .individual, key: key) }

    var stableID: String { kind == .individual ? "individual:\(key ?? "")" : kind.rawValue }
}

struct CoolingRuleTarget: Codable, Hashable, Sendable {
    /// nil means All Fans. An explicit fan id is retained in the app model even
    /// though the current physically validated production profile has one fan.
    var fanID: Int?

    static let allFans = Self(fanID: nil)
    static func fan(_ id: Int) -> Self { Self(fanID: id) }
}

struct CoolingRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var enabled: Bool
    var target: CoolingRuleTarget
    var speedPercent: Int
    var sensor: CoolingRuleSensor
    var thresholdCelsius: Double

    init(id: UUID = UUID(), enabled: Bool = true, target: CoolingRuleTarget = .allFans,
         speedPercent: Int, sensor: CoolingRuleSensor, thresholdCelsius: Double = 70) {
        self.id = id
        self.enabled = enabled
        self.target = target
        self.speedPercent = speedPercent
        self.sensor = sensor
        self.thresholdCelsius = thresholdCelsius
        normalize()
    }

    mutating func normalize() {
        speedPercent = min(100, max(0, speedPercent))
        if !thresholdCelsius.isFinite { thresholdCelsius = 70 }
        thresholdCelsius = min(120, max(20, thresholdCelsius))
        if let fanID = target.fanID, !(0..<FanCodec.maximumFanCount).contains(fanID) {
            target = .allFans
        }
        if sensor.kind != .individual { sensor.key = nil }
        if sensor.kind == .individual, sensor.key?.isEmpty != false { sensor = .maximumSoC }
    }
}

struct CoolingRuleProfile: Codable, Equatable, Sendable {
    var rules: [CoolingRule]

    mutating func normalize(maxRules: Int = CoolingRulesConfiguration.maximumRuleCount) {
        if rules.count > maxRules { rules = Array(rules.prefix(maxRules)) }
        var seen: Set<UUID> = []
        for index in rules.indices {
            rules[index].normalize()
            if seen.contains(rules[index].id) { rules[index].id = UUID() }
            seen.insert(rules[index].id)
        }
    }
}

struct CoolingRulesConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumRuleCount = 24
    static let maximumTransitionSeconds = 10.0

    var version = currentVersion
    var powerAdapter: CoolingRuleProfile
    var battery: CoolingRuleProfile
    /// Human-facing downshift transition. Cooling increases are deliberately
    /// immediate; this setting only smooths reductions between active rules.
    var transitionSeconds: Double

    mutating func normalize() {
        version = Self.currentVersion
        powerAdapter.normalize()
        battery.normalize()
        if !transitionSeconds.isFinite { transitionSeconds = 2 }
        transitionSeconds = min(Self.maximumTransitionSeconds, max(0, transitionSeconds))
    }

    func profile(_ power: CoolingPowerProfile) -> CoolingRuleProfile {
        switch power { case .powerAdapter: powerAdapter; case .battery: battery }
    }

    mutating func setProfile(_ profile: CoolingRuleProfile, for power: CoolingPowerProfile) {
        switch power { case .powerAdapter: powerAdapter = profile; case .battery: battery = profile }
    }

    static var safeDefault: Self {
        // Intentionally no Always rule: below the first threshold Apple keeps
        // System control, including zero-RPM behavior. Once Helios takes over,
        // the steps form a complete rising curve and the independent 95°C
        // emergency guard always wins.
        let adapter = CoolingRuleProfile(rules: [
            CoolingRule(speedPercent: 20, sensor: .highestCPU, thresholdCelsius: 55),
            CoolingRule(speedPercent: 40, sensor: .highestCPU, thresholdCelsius: 65),
            CoolingRule(speedPercent: 60, sensor: .highestCPU, thresholdCelsius: 75),
            CoolingRule(speedPercent: 80, sensor: .highestCPU, thresholdCelsius: 82),
            CoolingRule(speedPercent: 100, sensor: .highestCPU, thresholdCelsius: 88)
        ])
        let battery = CoolingRuleProfile(rules: [
            CoolingRule(speedPercent: 20, sensor: .highestCPU, thresholdCelsius: 60),
            CoolingRule(speedPercent: 40, sensor: .highestCPU, thresholdCelsius: 70),
            CoolingRule(speedPercent: 70, sensor: .highestCPU, thresholdCelsius: 80),
            CoolingRule(speedPercent: 100, sensor: .highestCPU, thresholdCelsius: 88)
        ])
        return Self(powerAdapter: adapter, battery: battery, transitionSeconds: 2.0)
    }
}

struct CoolingRuleSensorOption: Hashable, Sendable {
    let source: CoolingRuleSensor
    let label: String
}

struct CoolingRuleInputs: Sendable {
    let thermals: ThermalMetrics
    let batteryCelsius: Double?
    let storageCelsius: Double?

    var trustedReadings: [ThermalReading] { thermals.readings.filter { $0.group != .unclassified } }

    func value(for sensor: CoolingRuleSensor) -> Double? {
        let trusted = trustedReadings
        switch sensor.kind {
        case .always:
            return 0
        case .anySensor:
            var values = trusted.map(\.celsius)
            if let batteryCelsius, batteryCelsius.isFinite { values.append(batteryCelsius) }
            if let storageCelsius, storageCelsius.isFinite { values.append(storageCelsius) }
            return values.max()
        case .averageCPU:
            let values = trusted.filter { $0.group == .performanceCPU || $0.group == .efficiencyCPU }.map(\.celsius)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        case .highestCPU:
            return trusted.filter { $0.group == .performanceCPU || $0.group == .efficiencyCPU }.map(\.celsius).max()
        case .maximumSoC:
            return trusted.map(\.celsius).max()
        case .performanceCPU:
            return trusted.filter { $0.group == .performanceCPU }.map(\.celsius).max()
        case .efficiencyCPU:
            return trusted.filter { $0.group == .efficiencyCPU }.map(\.celsius).max()
        case .gpu:
            return trusted.filter { $0.group == .gpu }.map(\.celsius).max()
        case .battery:
            guard let batteryCelsius, batteryCelsius.isFinite else { return nil }
            return batteryCelsius
        case .storage:
            guard let storageCelsius, storageCelsius.isFinite else { return nil }
            return storageCelsius
        case .individual:
            guard let key = sensor.key else { return nil }
            return trusted.first(where: { $0.key == key })?.celsius
        }
    }
}

struct CoolingRuleDecision: Sendable, Equatable {
    let fanPercent: [Int: Int]
    let activeRuleIDs: Set<UUID>
    let emergency: Bool

    var isActive: Bool { !fanPercent.isEmpty }
    var maximumPercent: Int? { fanPercent.values.max() }
}

/// Stateful rules evaluator strongly inspired by TG Pro's Auto Boost semantics:
/// rules can target All Fans or an individual fan, 0% maps to factory minimum,
/// and when multiple rules match the highest fan percentage wins. Helios adds
/// bounded hysteresis/debounce and an independent emergency maximum guard.
struct CoolingRulesEngine {
    static let engageDebounceSeconds = 0.50
    static let releaseDebounceSeconds = 3.0
    static let hysteresisCelsius = 3.0
    static let emergencyCelsius = CoolingRulesSafetyProfile.emergencyMaximumCelsius
    static let emergencyReleaseCelsius = 88.0
    static let emergencyReleaseDebounceSeconds = 5.0

    private struct Runtime {
        var active = false
        var candidate: UInt64?
    }

    private var runtime: [UUID: Runtime] = [:]
    private var emergency = false
    private var emergencyReleaseCandidate: UInt64?

    mutating func reset() {
        runtime.removeAll(keepingCapacity: true)
        emergency = false
        emergencyReleaseCandidate = nil
    }

    mutating func evaluate(profile: CoolingRuleProfile, inputs: CoolingRuleInputs,
                           fanIDs: [Int], ticks: UInt64) -> CoolingRuleDecision {
        let fanIDs = Array(Set(fanIDs.filter { (0..<FanCodec.maximumFanCount).contains($0) })).sorted()
        guard !fanIDs.isEmpty else { return CoolingRuleDecision(fanPercent: [:], activeRuleIDs: [], emergency: false) }

        updateEmergency(maximumSoC: inputs.value(for: .maximumSoC), ticks: ticks)
        if emergency {
            return CoolingRuleDecision(fanPercent: Dictionary(uniqueKeysWithValues: fanIDs.map { ($0, 100) }),
                                       activeRuleIDs: [], emergency: true)
        }

        let validIDs = Set(profile.rules.map(\.id))
        runtime = runtime.filter { validIDs.contains($0.key) }
        var activeIDs: Set<UUID> = []
        var demand: [Int: Int] = [:]

        for rule in profile.rules where rule.enabled {
            var normalized = rule
            normalized.normalize()
            let isActive = evaluateRule(normalized, value: inputs.value(for: normalized.sensor), ticks: ticks)
            guard isActive else { continue }
            activeIDs.insert(normalized.id)
            let targets = normalized.target.fanID.map { fanIDs.contains($0) ? [$0] : [] } ?? fanIDs
            for id in targets { demand[id] = max(demand[id] ?? 0, normalized.speedPercent) }
        }

        return CoolingRuleDecision(fanPercent: demand, activeRuleIDs: activeIDs, emergency: false)
    }

    private mutating func evaluateRule(_ rule: CoolingRule, value: Double?, ticks: UInt64) -> Bool {
        if rule.sensor.kind == .always {
            runtime[rule.id] = Runtime(active: true, candidate: nil)
            return true
        }
        guard let value, value.isFinite else {
            runtime[rule.id] = Runtime()
            return false
        }
        var state = runtime[rule.id] ?? Runtime()
        if !state.active {
            if value >= rule.thresholdCelsius {
                if state.candidate == nil { state.candidate = ticks }
                if let candidate = state.candidate,
                   HostClock.seconds(from: candidate, to: ticks) >= Self.engageDebounceSeconds {
                    state.active = true
                    state.candidate = nil
                }
            } else {
                state.candidate = nil
            }
        } else {
            let releaseThreshold = rule.thresholdCelsius - Self.hysteresisCelsius
            if value <= releaseThreshold {
                if state.candidate == nil { state.candidate = ticks }
                if let candidate = state.candidate,
                   HostClock.seconds(from: candidate, to: ticks) >= Self.releaseDebounceSeconds {
                    state.active = false
                    state.candidate = nil
                }
            } else {
                state.candidate = nil
            }
        }
        runtime[rule.id] = state
        return state.active
    }

    private mutating func updateEmergency(maximumSoC: Double?, ticks: UInt64) {
        guard let maximumSoC, maximumSoC.isFinite else {
            // Missing trusted thermal input must not silently clear a latched
            // emergency. The caller will independently fail closed to System on
            // stale/missing thermal telemetry.
            return
        }
        if !emergency, maximumSoC >= Self.emergencyCelsius {
            emergency = true
            emergencyReleaseCandidate = nil
            return
        }
        guard emergency else { return }
        if maximumSoC <= Self.emergencyReleaseCelsius {
            if emergencyReleaseCandidate == nil { emergencyReleaseCandidate = ticks }
            if let candidate = emergencyReleaseCandidate,
               HostClock.seconds(from: candidate, to: ticks) >= Self.emergencyReleaseDebounceSeconds {
                emergency = false
                emergencyReleaseCandidate = nil
            }
        } else {
            emergencyReleaseCandidate = nil
        }
    }
}

enum CoolingRulePercentCodec {
    static func rpm(percent: Int, bounds: ClosedRange<Double>) throws -> Double {
        guard bounds.lowerBound.isFinite, bounds.upperBound.isFinite,
              bounds.lowerBound >= 0, bounds.upperBound > bounds.lowerBound else {
            throw TelemetryError.invalidData("Invalid fan bounds")
        }
        let percent = min(100, max(0, percent))
        let fraction = Double(percent) / 100.0
        return bounds.lowerBound + ((bounds.upperBound - bounds.lowerBound) * fraction)
    }
}

enum CoolingRulesPersistence {
    static let defaultsKey = "CoolingRules.v1"

    static func encode(_ configuration: CoolingRulesConfiguration) throws -> Data {
        var normalized = configuration
        normalized.normalize()
        return try JSONEncoder().encode(normalized)
    }

    static func decode(_ data: Data) throws -> CoolingRulesConfiguration {
        var value = try JSONDecoder().decode(CoolingRulesConfiguration.self, from: data)
        guard value.version == CoolingRulesConfiguration.currentVersion else {
            throw TelemetryError.invalidData("Unsupported cooling-rules version")
        }
        value.normalize()
        return value
    }
}
