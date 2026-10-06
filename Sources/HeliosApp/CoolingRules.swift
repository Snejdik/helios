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
    /// Response-dependent release gap (fan layer smoothing); defaults to the
    /// historical 3 °C.
    var releaseHysteresisCelsius = CoolingRulesEngine.hysteresisCelsius {
        didSet {
            if !releaseHysteresisCelsius.isFinite || releaseHysteresisCelsius < 1 || releaseHysteresisCelsius > 10 {
                releaseHysteresisCelsius = Self.hysteresisCelsius
            }
        }
    }
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
            let releaseThreshold = rule.thresholdCelsius - releaseHysteresisCelsius
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

// MARK: - Fan curve

/// The sensor a fan curve follows.
enum CoolingCurveSensor: String, Codable, CaseIterable, Sendable {
    case maximumSoC
    case cpu
    case gpu

    var label: String {
        switch self {
        case .maximumSoC: "Max SoC"
        case .cpu: "CPU"
        case .gpu: "GPU"
        }
    }

    var ruleSensor: CoolingRuleSensor {
        switch self {
        case .maximumSoC: .maximumSoC
        case .cpu: .highestCPU
        case .gpu: .gpu
        }
    }
}

struct CoolingCurvePoint: Codable, Equatable, Hashable, Sendable {
    var celsius: Double
    /// Share of factory minimum … the user's speed limit (0 = minimum).
    var percent: Double
}

/// Auto as a temperature → speed curve. Below the first point macOS keeps the
/// fans (including zero-RPM). From the first point on, speed follows straight
/// lines between the points. Speeds never fall as the temperature rises. The
/// helper still adds its own floors and returns the fans to macOS when more
/// cooling than the user's limit is needed.
struct CoolingCurve: Codable, Equatable, Sendable {
    static let celsiusRange: ClosedRange<Double> = 30...100
    static let minimumPoints = 2
    static let maximumPoints = 6
    static let minimumSpacingCelsius = 2.0

    var sensor: CoolingCurveSensor
    var points: [CoolingCurvePoint]

    init(sensor: CoolingCurveSensor, points: [CoolingCurvePoint]) {
        self.sensor = sensor
        self.points = points
        normalize()
    }

    private init(_ sensor: CoolingCurveSensor, _ pairs: [(Double, Double)]) {
        self.init(sensor: sensor, points: pairs.map { CoolingCurvePoint(celsius: $0.0, percent: $0.1) })
    }

    static let recommendedPowerAdapter = CoolingCurve(.maximumSoC, [(55, 0), (65, 25), (75, 50), (82, 75), (88, 100)])
    static let recommendedBattery = CoolingCurve(.maximumSoC, [(60, 0), (70, 25), (80, 60), (88, 100)])

    static func recommended(_ power: CoolingPowerProfile) -> CoolingCurve {
        power == .powerAdapter ? recommendedPowerAdapter : recommendedBattery
    }

    /// Sorted, inside the editor range, at least `minimumSpacingCelsius` apart,
    /// speeds never falling, 2…6 points. Never throws: anything unusable becomes
    /// the recommended curve's points.
    mutating func normalize() {
        var cleaned = points.filter { $0.celsius.isFinite && $0.percent.isFinite }.map {
            CoolingCurvePoint(celsius: (min(Self.celsiusRange.upperBound, max(Self.celsiusRange.lowerBound, $0.celsius)) * 2).rounded() / 2,
                              percent: min(100, max(0, $0.percent)).rounded())
        }
        cleaned.sort { $0.celsius != $1.celsius ? $0.celsius < $1.celsius : $0.percent < $1.percent }
        var spaced: [CoolingCurvePoint] = []
        for point in cleaned {
            if let last = spaced.last, point.celsius < last.celsius + Self.minimumSpacingCelsius { continue }
            spaced.append(point)
        }
        if spaced.count > Self.maximumPoints { spaced = Array(spaced.prefix(Self.maximumPoints)) }
        if spaced.count < Self.minimumPoints {
            spaced = [CoolingCurvePoint(celsius: 55, percent: 0), CoolingCurvePoint(celsius: 88, percent: 100)]
        }
        for index in spaced.indices.dropFirst() {
            spaced[index].percent = max(spaced[index].percent, spaced[index - 1].percent)
        }
        points = spaced
    }

    /// Speed share for a temperature, nil below the first point (macOS keeps the fans).
    func percent(at celsius: Double) -> Double? {
        guard celsius.isFinite, let first = points.first, celsius >= first.celsius else { return nil }
        for (low, high) in zip(points, points.dropFirst()) where celsius < high.celsius {
            let span = high.celsius - low.celsius
            let t = span > 0 ? (celsius - low.celsius) / span : 1
            return low.percent + (high.percent - low.percent) * t
        }
        return points.last?.percent
    }

    /// Where a dragged point may go: between its neighbours (keeping the spacing)
    /// and not below the previous / above the next speed.
    func allowedRange(for index: Int) -> (celsius: ClosedRange<Double>, percent: ClosedRange<Double>)? {
        guard points.indices.contains(index) else { return nil }
        let low = index > 0 ? points[index - 1].celsius + Self.minimumSpacingCelsius : Self.celsiusRange.lowerBound
        let high = index < points.count - 1 ? points[index + 1].celsius - Self.minimumSpacingCelsius : Self.celsiusRange.upperBound
        let floor = index > 0 ? points[index - 1].percent : 0
        let ceiling = index < points.count - 1 ? points[index + 1].percent : 100
        guard low <= high, floor <= ceiling else { return nil }
        return (low...high, floor...ceiling)
    }

    /// Moves one point inside its allowed range.
    mutating func move(_ index: Int, celsius: Double, percent: Double) {
        guard let range = allowedRange(for: index), celsius.isFinite, percent.isFinite else { return }
        points[index].celsius = (min(range.celsius.upperBound, max(range.celsius.lowerBound, celsius)) * 2).rounded() / 2
        points[index].percent = min(range.percent.upperBound, max(range.percent.lowerBound, percent)).rounded()
    }

    /// Adds a point in the widest gap; returns false when the curve is full.
    @discardableResult
    mutating func addPoint() -> Bool {
        guard points.count < Self.maximumPoints else { return false }
        var best: (index: Int, gap: Double)?
        for index in points.indices.dropLast() {
            let gap = points[index + 1].celsius - points[index].celsius
            if gap >= 2 * Self.minimumSpacingCelsius, gap > (best?.gap ?? 0) { best = (index, gap) }
        }
        if let best {
            let low = points[best.index], high = points[best.index + 1]
            points.insert(CoolingCurvePoint(celsius: ((low.celsius + high.celsius) / 2 * 2).rounded() / 2,
                                            percent: ((low.percent + high.percent) / 2).rounded()), at: best.index + 1)
        } else if let last = points.last, last.celsius + Self.minimumSpacingCelsius <= Self.celsiusRange.upperBound {
            points.append(CoolingCurvePoint(celsius: min(Self.celsiusRange.upperBound, last.celsius + 5), percent: last.percent))
        } else {
            return false
        }
        normalize()
        return true
    }

    @discardableResult
    mutating func removePoint(_ index: Int) -> Bool {
        guard points.count > Self.minimumPoints, points.indices.contains(index) else { return false }
        points.remove(at: index)
        normalize()
        return true
    }

    /// One-time migration of customised step rules: each threshold becomes a
    /// point; an Always rule becomes a starting point at 30 °C.
    static func migrated(from profile: CoolingRuleProfile, fallback: CoolingCurve) -> CoolingCurve {
        let enabled = profile.rules.filter(\.enabled)
        var points = enabled.filter { $0.sensor.kind.usesThreshold }
            .map { CoolingCurvePoint(celsius: $0.thresholdCelsius, percent: Double($0.speedPercent)) }
        if let always = enabled.filter({ $0.sensor.kind == .always }).map(\.speedPercent).max() {
            points.append(CoolingCurvePoint(celsius: celsiusRange.lowerBound, percent: Double(always)))
        }
        guard points.count >= minimumPoints else { return fallback }
        let kinds = enabled.map(\.sensor.kind)
        let gpu = kinds.filter { $0 == .gpu }.count
        let cpu = kinds.filter { [.highestCPU, .averageCPU, .performanceCPU, .efficiencyCPU].contains($0) }.count
        let sensor: CoolingCurveSensor = gpu > cpu ? .gpu : (cpu > 0 ? .cpu : .maximumSoC)
        return CoolingCurve(sensor: sensor, points: points)
    }
}

struct CoolingCurves: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var powerAdapter: CoolingCurve
    var battery: CoolingCurve
    /// Auto follows the curve (Helios interface) or the step rules (classic
    /// interface); editing either one selects it.
    var usesCurve: Bool

    static let recommended = CoolingCurves(powerAdapter: .recommendedPowerAdapter, battery: .recommendedBattery,
                                           usesCurve: true)

    func curve(_ power: CoolingPowerProfile) -> CoolingCurve {
        power == .powerAdapter ? powerAdapter : battery
    }

    mutating func setCurve(_ curve: CoolingCurve, for power: CoolingPowerProfile) {
        var curve = curve
        curve.normalize()
        if power == .powerAdapter { powerAdapter = curve } else { battery = curve }
    }

    mutating func normalize() {
        version = Self.currentVersion
        powerAdapter.normalize()
        battery.normalize()
    }

    /// Unchanged default rules become the recommended curves; customised rules
    /// are carried over as points.
    static func migrated(from rules: CoolingRulesConfiguration) -> CoolingCurves {
        var defaults = CoolingRulesConfiguration.safeDefault
        defaults.normalize()
        func same(_ a: CoolingRuleProfile, _ b: CoolingRuleProfile) -> Bool {
            a.rules.map { [$0.enabled ? 1 : 0, Double($0.speedPercent), $0.thresholdCelsius] }
                == b.rules.map { [$0.enabled ? 1 : 0, Double($0.speedPercent), $0.thresholdCelsius] }
                && a.rules.map(\.sensor) == b.rules.map(\.sensor)
        }
        return CoolingCurves(
            powerAdapter: same(rules.powerAdapter, defaults.powerAdapter) ? .recommendedPowerAdapter
                : CoolingCurve.migrated(from: rules.powerAdapter, fallback: .recommendedPowerAdapter),
            battery: same(rules.battery, defaults.battery) ? .recommendedBattery
                : CoolingCurve.migrated(from: rules.battery, fallback: .recommendedBattery),
            usesCurve: true)
    }
}

enum CoolingCurvesPersistence {
    static let defaultsKey = "CoolingCurves.v1"

    static func encode(_ curves: CoolingCurves) throws -> Data {
        var normalized = curves
        normalized.normalize()
        return try JSONEncoder().encode(normalized)
    }

    static func decode(_ data: Data) throws -> CoolingCurves {
        var value = try JSONDecoder().decode(CoolingCurves.self, from: data)
        guard value.version == CoolingCurves.currentVersion else {
            throw TelemetryError.invalidData("Unsupported fan curve version")
        }
        value.normalize()
        return value
    }
}

/// Curve input with hysteresis: a rising temperature counts at once, a falling
/// one only after it dropped by more than the hysteresis (Response).
struct CoolingCurveInput: Sendable {
    private(set) var celsius: Double?

    mutating func reset() { celsius = nil }

    mutating func next(_ reading: Double, hysteresisCelsius: Double) -> Double {
        let hysteresis = hysteresisCelsius.isFinite ? min(10, max(0, hysteresisCelsius)) : 3
        guard let current = celsius, reading.isFinite else {
            celsius = reading
            return reading
        }
        if reading >= current {
            celsius = reading
        } else if reading < current - hysteresis {
            celsius = reading + hysteresis
        }
        return celsius ?? reading
    }
}

// MARK: - Auto presets

/// Starting points for Auto, as a curve or as step rules. Every preset stays on
/// top of the helper's safety floor and the user's speed limit.
enum CoolingPreset: String, CaseIterable, Identifiable, Sendable {
    case cool
    case balanced
    case quiet
    case energySaver

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cool: "Cool"
        case .balanced: "Balanced"
        case .quiet: "Quiet"
        case .energySaver: "Energy Saver"
        }
    }

    var detail: String {
        switch self {
        case .cool: "Fans start early and run faster. Coolest, loudest."
        case .balanced: "Recommended. Fans start when the Mac gets warm."
        case .quiet: "Fans start late and stay slow as long as it is safe."
        case .energySaver: "For battery: fans only when really needed, so they use less power."
        }
    }

    private var pairs: [(Double, Double)] {
        switch self {
        case .cool: [(45, 10), (55, 30), (65, 55), (75, 80), (85, 100)]
        case .balanced: []
        case .quiet: [(65, 0), (75, 25), (83, 55), (90, 100)]
        case .energySaver: [(70, 0), (80, 30), (88, 70), (94, 100)]
        }
    }

    func curve(for power: CoolingPowerProfile) -> CoolingCurve {
        guard self != .balanced else { return CoolingCurve.recommended(power) }
        return CoolingCurve(sensor: .maximumSoC,
                            points: pairs.map { CoolingCurvePoint(celsius: $0.0, percent: $0.1) })
    }

    func rules(for power: CoolingPowerProfile) -> CoolingRuleProfile {
        guard self != .balanced else { return CoolingRulesConfiguration.safeDefault.profile(power) }
        return CoolingRuleProfile(rules: pairs.map {
            CoolingRule(speedPercent: Int($0.1), sensor: .highestCPU, thresholdCelsius: $0.0)
        })
    }
}
