import Foundation

// Pure policy for the cool-only fan layer (docs/FAN_LAYER_DESIGN.md §5–§6).
// Nothing here performs I/O. The privileged daemon is the only authority that
// turns these numbers into hardware writes; the app uses the same types to
// explain what the daemon will do.

/// One user-facing smoothness value: 0 = quickly, 1 = gently. Both the app and
/// the helper derive every rate from it, so only one
/// bounded scalar crosses XPC. Safety and emergency rises bypass all of it.
struct FanLayerResponse: Equatable, Hashable, Sendable {
    let smoothness: Double

    /// nil for anything outside 0…1 (the helper rejects such a request).
    init?(smoothness: Double) {
        guard smoothness.isFinite, (0...1).contains(smoothness) else { return nil }
        self.smoothness = smoothness
    }

    private init(fixed: Double) { smoothness = fixed }

    static let quickly = FanLayerResponse(fixed: 0)
    static let balanced = FanLayerResponse(fixed: 0.5)
    static let gently = FanLayerResponse(fixed: 1)
    static let standard = balanced
    /// Tick marks on the slider (and the fixed points the tests sweep).
    static let presets: [FanLayerResponse] = [.quickly, .balanced, .gently]

    /// Migrates the 0.2 three-way picker (0 Responsive, 1 Balanced, 2 Smooth).
    init(legacyIndex: Int) {
        smoothness = [0.15, 0.5, 0.85][min(2, max(0, legacyIndex))]
    }

    private static func geometric(_ from: Double, _ to: Double, _ t: Double) -> Double {
        from * pow(to / from, t)
    }

    var smoothing: FanLayerSmoothing {
        let t = smoothness
        return FanLayerSmoothing(
            hysteresisCelsius: 2 + 4 * t,
            minimumDwellSeconds: 10 * t,
            riseRPMPerSecond: Self.geometric(4_000, 300, t),
            fallRPMPerSecond: Self.geometric(1_000, 40, t),
            temperatureWindowSeconds: 2 + 8 * t)
    }

    /// Time a fall from `highRPM` to `lowRPM` takes: hold, then the fall rate.
    func secondsToFall(from highRPM: Double, to lowRPM: Double) -> Double {
        let smoothing = smoothing
        return smoothing.minimumDwellSeconds + max(0, highRPM - lowRPM) / smoothing.fallRPMPerSecond
    }

    var label: String {
        switch smoothness {
        case ..<0.25: "Quickly"
        case ..<0.75: "Balanced"
        default: "Gently"
        }
    }
}

struct FanLayerSmoothing: Equatable, Sendable {
    /// Gap between the Auto engage and release temperatures.
    let hysteresisCelsius: Double
    /// Minimum time between two downward target changes.
    let minimumDwellSeconds: Double
    /// Rate limit for a rising user request (floors and urgent targets are
    /// never rate limited).
    let riseRPMPerSecond: Double
    /// Rate limit for every falling target.
    let fallRPMPerSecond: Double
    /// Averaging window for the Auto rule input temperature (app side).
    let temperatureWindowSeconds: Double
}

/// One time budget for the helper and the app. The app
/// must wait for the helper's worst case: a takeover that runs into its hard
/// lease and then restores System, so it never closes the connection while
/// the helper is still releasing the fans correctly.
enum FanLayerTimings {
    /// One Ftst / per-fan mode transition wait (stable readback).
    static let transitionTimeoutSeconds = 4.0
    /// F0Md arbitration after Ftst=1. Measured on Mac16,1 / 26A434: ~6 s after a
    /// pause, 10.1 s shortly after a release.
    static let manualTimeoutSeconds = 10.0
    /// Hard deadline of one takeover (`ControlLease.acquisitionTimeoutSeconds`).
    static let acquisitionLeaseSeconds = 12.0
    /// Steady lease between two calculations (`ControlLease.steadyTimeoutSeconds`).
    static let steadyLeaseSeconds = 5.0
    /// Budget for the per-fan readback is sized for this many fans (the Mac Pro
    /// has three; every other Apple Silicon Mac one or two). More fans still
    /// restore correctly; only the app's wait could end first.
    static let budgetFanCount = 3
    /// SMC write latency and journal persistence across one release.
    static let writeSlackSeconds = 1.0
    /// Reply transport and main-actor scheduling.
    static let replyMarginSeconds = 2.0

    /// Restoring System: Ftst release readback, then each fan's readback.
    static func releaseBudgetSeconds(fanCount: Int = budgetFanCount) -> Double {
        transitionTimeoutSeconds * Double(1 + max(1, fanCount)) + writeSlackSeconds
    }

    /// First calculation that takes the fans from macOS.
    static var clientAcquisitionTimeoutSeconds: Double {
        acquisitionLeaseSeconds + releaseBudgetSeconds() + replyMarginSeconds
    }

    /// A calculation while Helios holds the fans: one target update readback,
    /// then (if macOS took the fans) a full release.
    static var clientSteadyTimeoutSeconds: Double {
        transitionTimeoutSeconds + releaseBudgetSeconds() + replyMarginSeconds
    }

    /// An explicit release back to System.
    static var clientReleaseTimeoutSeconds: Double {
        releaseBudgetSeconds() + replyMarginSeconds
    }

    static func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1_000).rounded(.up)) }
}

/// Fixed, non-removable cooling floor applied while Helios holds the fans.
/// macOS cannot react while Helios owns them, so this curve stands in for it.
/// Data from this Mac (Mac16,1): macOS runs the fan at about 2,500 RPM between
/// 50 and 70 °C, so the curve starts above that band and is deliberately
/// more aggressive than macOS from 70 °C upwards.
enum FanLayerSafetyCurve {
    static let rampStartCelsius = 65.0
    static let halfRangeCelsius = 80.0
    static let fullCelsius = 88.0
    /// Used when Helios has never seen macOS cool at this temperature: the curve
    /// is evaluated this much hotter than the reading.
    static let uncertaintyShiftCelsius = 5.0
    static let emergencyCelsius = CoolingRulesSafetyProfile.emergencyMaximumCelsius

    /// Fraction of the factory range (0 = minimum, 1 = maximum).
    static func fraction(at celsius: Double) -> Double {
        guard celsius.isFinite else { return 1 }
        if celsius <= rampStartCelsius { return 0 }
        if celsius < halfRangeCelsius {
            return 0.5 * (celsius - rampStartCelsius) / (halfRangeCelsius - rampStartCelsius)
        }
        if celsius < fullCelsius {
            return 0.5 + 0.5 * (celsius - halfRangeCelsius) / (fullCelsius - halfRangeCelsius)
        }
        return 1
    }
}

struct FanLayerFanLimits: Equatable, Sendable {
    let id: Int
    let minimumRPM: Double
    let maximumRPM: Double

    func validated() throws -> FanLayerFanLimits {
        guard (0..<FanCodec.maximumFanCount).contains(id), minimumRPM.isFinite, maximumRPM.isFinite,
              minimumRPM >= 0, maximumRPM > minimumRPM, maximumRPM <= 30_000,
              ceil(minimumRPM) <= floor(maximumRPM) else {
            throw TelemetryError.invalidData("Invalid factory fan limits for the fan layer")
        }
        return self
    }

    func rpm(fraction: Double) -> Double {
        minimumRPM + (maximumRPM - minimumRPM) * min(1, max(0, fraction))
    }

    /// Integral RPM inside the factory range, rounded up (towards cooling).
    func integral(_ rpm: Double) -> Double {
        let low = ceil(minimumRPM)
        let high = floor(maximumRPM)
        return min(high, max(low, ceil(rpm.isFinite ? rpm : maximumRPM)))
    }
}

/// The speed limit: Helios itself never commands more
/// than 90 % of the factory maximum unless the user unlocks the full range in
/// Settings. When more cooling is needed than the limit allows (it is very hot,
/// or macOS was already cooling harder), Helios hands the fans back to macOS,
/// which may use the full range as Apple designed it.
enum FanLayerCeiling {
    static let defaultFraction = 0.90
    /// Taking the fans needs this much headroom below a handback, so Helios
    /// does not take and return them repeatedly around the boundary.
    static let engageMarginCelsius = 3.0
    static let handbackPrefix = "More cooling than your fan limit allows is needed"
    static let handbackDetail = "\(handbackPrefix), so macOS manages the fans and may use full speed."

    /// Integral ceiling inside the factory range, rounded down (it is a limit).
    static func rpm(for limits: FanLayerFanLimits, fullMaximum: Bool) -> Double {
        let high = floor(limits.maximumRPM)
        guard !fullMaximum else { return high }
        return min(high, max(ceil(limits.minimumRPM), floor(limits.maximumRPM * defaultFraction)))
    }
}

enum FanLayerTargetSource: String, Sendable {
    case request = "your setting"
    case boost = "Boost"
    case handback = "more than your limit is needed"
    case emergency = "emergency cooling"
    case safetyFloor = "safety floor"
    case systemBaseline = "macOS level at takeover"
    case systemEnvelope = "learned macOS level"
    case factoryMinimum = "factory minimum"
}

struct FanLayerDemand: Sendable {
    /// Hold factory maximum (Boost).
    var boost: Bool
    /// The user's Manual minimum or the Auto rule target, in RPM.
    var requestRPM: Double
    /// Hottest trusted SoC reading available to the daemon.
    var celsius: Double
    /// What macOS was commanding when Helios took the fans (0 when unknown).
    var baselineRPM: Double
    /// Highest level macOS used at this temperature or a cooler one.
    var envelopeRPM: Double
    /// False when Helios never saw macOS cool at (about) this temperature.
    var envelopeInformed: Bool
    /// The user's speed limit in RPM (`FanLayerCeiling`); infinity = factory maximum.
    var ceilingRPM: Double = .infinity
}

struct FanLayerTarget: Equatable, Sendable {
    /// Integral target inside the factory range.
    let rpm: Double
    /// The floor part alone (everything except the user's request). The
    /// smoother never goes below it.
    let floorRPM: Double
    let source: FanLayerTargetSource
    /// The user's limit; the smoother never commands above it, not even
    /// while a fall from an earlier, higher limit is still on hold.
    var ceilingRPM: Double = .infinity

    /// Safety-driven targets bypass smoothing.
    var urgent: Bool { source == .emergency || source == .boost || source == .safetyFloor }
    /// More cooling than the user's limit is needed: return the fans to macOS.
    var handback: Bool { source == .handback }
}

/// effective(fan) = clamp(max(min(request, ceiling), safety, macOS baseline,
/// macOS envelope), min…ceiling), Boost = ceiling. Emergency forces the
/// factory maximum only when the user unlocked it; under a lower ceiling every
/// floor or emergency above it hands the fans back to macOS instead.
enum FanLayerPolicy {
    static func target(for limits: FanLayerFanLimits, demand: FanLayerDemand) throws -> FanLayerTarget {
        let limits = try limits.validated()
        guard demand.celsius.isFinite, demand.celsius > 0, demand.celsius <= 150 else {
            throw TelemetryError.invalidData("Fan layer needs a valid trusted temperature")
        }
        guard demand.requestRPM.isFinite, demand.requestRPM >= 0,
              demand.baselineRPM.isFinite, demand.baselineRPM >= 0,
              demand.envelopeRPM.isFinite, demand.envelopeRPM >= 0,
              !demand.ceilingRPM.isNaN, demand.ceilingRPM > 0 else {
            throw TelemetryError.invalidData("Fan layer demand is not finite")
        }
        let maximum = limits.integral(limits.maximumRPM)
        let ceiling = demand.ceilingRPM.isFinite ? min(maximum, limits.integral(demand.ceilingRPM.rounded(.down))) : maximum
        let limited = ceiling < maximum
        let handback = FanLayerTarget(rpm: ceiling, floorRPM: ceiling, source: .handback, ceilingRPM: ceiling)
        if demand.celsius >= FanLayerSafetyCurve.emergencyCelsius {
            return limited ? handback : FanLayerTarget(rpm: maximum, floorRPM: maximum, source: .emergency)
        }

        let curveCelsius = demand.envelopeInformed
            ? demand.celsius
            : demand.celsius + FanLayerSafetyCurve.uncertaintyShiftCelsius
        let safety = limits.rpm(fraction: FanLayerSafetyCurve.fraction(at: curveCelsius))
        // Order matters only for ties: the more safety-relevant source wins.
        let floors: [(Double, FanLayerTargetSource)] = [
            (safety, .safetyFloor),
            (demand.envelopeRPM, .systemEnvelope),
            (demand.baselineRPM, .systemBaseline),
        ]
        if limited, floors.contains(where: { limits.integral($0.0) > ceiling }) { return handback }
        if demand.boost {
            return FanLayerTarget(rpm: ceiling, floorRPM: ceiling, source: .boost, ceilingRPM: ceiling)
        }
        var best = (rpm: min(demand.requestRPM, ceiling), source: FanLayerTargetSource.request)
        var floor = 0.0
        for (value, source) in floors {
            floor = max(floor, value)
            if value >= best.rpm { best = (value, source) }
        }
        let rpm = min(ceiling, limits.integral(best.rpm))
        // Everything at or below the factory minimum is simply the minimum.
        let source: FanLayerTargetSource = best.rpm <= limits.minimumRPM ? .factoryMinimum : best.source
        return FanLayerTarget(rpm: rpm, floorRPM: min(rpm, limits.integral(floor)), source: source, ceilingRPM: ceiling)
    }

    /// Helios takes the fans only when it would add cooling over what macOS is
    /// doing right now, or for Boost. Floors alone never cause a takeover:
    /// while macOS controls the fans it manages its own temperatures.
    static let engagementMarginRPM = 50.0
    /// Known limitation: during a takeover (6–11 s) the
    /// firmware drives the fan towards its factory minimum before Helios holds
    /// it. While macOS is already spinning the fan, Helios therefore takes over
    /// only for a clearly higher request, so the short dip is worth it.
    static let activeEngagementMarginRPM = 500.0

    static func needsOwnership(requestRPM: Double, boost: Bool, systemTargetRPM: Double,
                               systemActualRPM: Double) -> Bool {
        if boost { return true }
        guard requestRPM.isFinite else { return false }
        let system = max(systemTargetRPM.isFinite ? systemTargetRPM : 0,
                         systemActualRPM.isFinite ? systemActualRPM : 0)
        let margin = system > 0 ? activeEngagementMarginRPM : engagementMarginRPM
        return requestRPM > system + margin
    }
}

/// Rate limits the user-request part of the target. Floors and urgent targets
/// are applied immediately. A fall is one continuous ramp: when the level
/// starts to fall it is held for the dwell once, then it descends at the fall
/// rate for every elapsed second. Further fall steps (a lower target, a floor
/// that held the level, a target reached and lowered again) continue the same
/// ramp without a new hold; only a rise ends it.
struct FanLayerSmoother: Sendable {
    private struct Applied: Sendable {
        /// Commanded integral RPM.
        var rpm: Double
        /// Unrounded ramp level, so rounding up never slows a fall.
        var level: Double
        var ticks: UInt64
        /// Set while a fall is in progress: when it began (the hold starts here).
        var fallStarted: UInt64?
    }

    private var applied: [Int: Applied] = [:]

    mutating func reset() { applied.removeAll() }

    func current(_ fanID: Int) -> Double? { applied[fanID]?.rpm }

    mutating func next(fanID: Int, target: FanLayerTarget, limits: FanLayerFanLimits,
                       smoothing: FanLayerSmoothing, ticks: UInt64) -> Double {
        guard let previous = applied[fanID] else {
            applied[fanID] = Applied(rpm: target.rpm, level: target.rpm, ticks: ticks, fallStarted: nil)
            return target.rpm
        }
        let elapsed = HostClock.seconds(from: previous.ticks, to: ticks)
        var level: Double
        var fallStarted: UInt64?
        if !elapsed.isFinite || elapsed < 0 {
            // Clock regression: never guess, take the policy target directly.
            level = target.rpm
        } else if target.rpm > previous.rpm {
            if target.urgent {
                level = target.rpm
            } else {
                level = min(target.rpm, previous.level + smoothing.riseRPMPerSecond * max(elapsed, 0.5))
            }
        } else if let started = previous.fallStarted {
            // Inside a fall: descend only for the part of this interval that
            // lies after the hold.
            let hold = max(0, smoothing.minimumDwellSeconds)
            let before = HostClock.seconds(from: started, to: previous.ticks)
            let now = HostClock.seconds(from: started, to: ticks)
            let falling = before.isFinite && now.isFinite ? max(0, now - max(before, hold)) : 0
            level = max(target.rpm, previous.level - smoothing.fallRPMPerSecond * falling)
            fallStarted = started
        } else if target.rpm < previous.rpm {
            // A fall begins: hold the current level once.
            level = previous.level
            fallStarted = ticks
        } else {
            level = previous.level
        }
        level = min(max(level, target.floorRPM), target.ceilingRPM)
        let rpm = limits.integral(level)
        applied[fanID] = Applied(rpm: rpm, level: min(level, rpm), ticks: ticks, fallStarted: fallStarted)
        return rpm
    }
}

/// The "shadow" model of macOS: while macOS controls the fans, the highest
/// level it used at each temperature. floor(T) is the highest level used at T
/// or at any cooler temperature, so it is monotone and errs towards cooling.
struct FanSystemEnvelope: Sendable {
    static let binCount = 128
    /// A reading this close to the hottest observation counts as informed.
    static let informedToleranceCelsius = 2

    private var maxima: [Int: [Double]] = [:]
    private var hottest: [Int: Int] = [:]

    mutating func observe(fanID: Int, celsius: Double, systemRPM: Double) {
        guard (0..<FanCodec.maximumFanCount).contains(fanID), celsius.isFinite, celsius > 0, celsius < 150,
              systemRPM.isFinite, systemRPM >= 0, systemRPM <= 30_000 else { return }
        let bin = min(Self.binCount - 1, Int(celsius.rounded(.down)))
        var values = maxima[fanID] ?? [Double](repeating: 0, count: Self.binCount)
        values[bin] = max(values[bin], systemRPM)
        maxima[fanID] = values
        hottest[fanID] = max(hottest[fanID] ?? 0, bin)
    }

    func floor(fanID: Int, celsius: Double) -> (rpm: Double, informed: Bool) {
        guard let values = maxima[fanID], let hottest = hottest[fanID], celsius.isFinite else { return (0, false) }
        let bin = min(Self.binCount - 1, max(0, Int(celsius.rounded(.down))))
        let rpm = values[0...bin].max() ?? 0
        return (rpm, hottest >= bin - Self.informedToleranceCelsius)
    }

    var observedFanIDs: [Int] { maxima.keys.sorted() }
}

/// A takeover shortly after a release is slow or refused by the firmware
/// (measured: 10.1 s and ten 0x82 refusals 4–6 s after a release, ~6 s after a
/// pause). The helper therefore waits a little before it takes
/// the fans again. Emergency cooling never waits.
struct FanLayerReacquireCooldown: Sendable {
    static let defaultSeconds = 15.0
    /// Prefix of the helper's calm reply while it waits.
    static let replyPrefix = "Waiting before taking the fan again"

    /// 0 disables the wait (tests, the legacy validated path).
    let seconds: Double
    /// Repeated refusals double the wait up to this, so Auto does not retry
    /// a doomed takeover every few seconds. A held takeover resets it.
    static let maximumBackoffSeconds = 300.0
    private var releasedAt: UInt64?
    private var refusals = 0

    /// The wait after the last release.
    var currentSeconds: Double {
        guard seconds > 0 else { return 0 }
        return min(Self.maximumBackoffSeconds, seconds * pow(2, Double(min(refusals, 8))))
    }

    init(seconds: Double = FanLayerReacquireCooldown.defaultSeconds) {
        self.seconds = seconds.isFinite ? min(60, max(0, seconds)) : Self.defaultSeconds
    }

    /// `refused`: the takeover that preceded this release never held the fans.
    mutating func recordRelease(at ticks: UInt64, refused: Bool = false) {
        guard seconds > 0 else { return }
        releasedAt = ticks
        refusals = refused ? refusals + 1 : 0
    }

    /// Helios held the fans: the firmware hands over again, reset the backoff.
    mutating func recordHeld() { refusals = 0 }

    /// Seconds left before a new takeover, or nil when one may start now.
    func remaining(at ticks: UInt64) -> Double? {
        guard let releasedAt, seconds > 0 else { return nil }
        let wait = currentSeconds
        let age = HostClock.seconds(from: releasedAt, to: ticks)
        // A clock regression keeps waiting the full time rather than guessing.
        guard age.isFinite, age >= 0 else { return wait }
        return age < wait ? wait - age : nil
    }

    static func reply(remaining: Double) -> String {
        "\(replyPrefix) (about \(max(1, Int(remaining.rounded(.up)))) s); macOS cools meanwhile."
    }
}

/// Invariant 8: if macOS takes the fans back, re-acquire a bounded number of
/// times, then stay on System for a while.
struct FanLayerReclaimGuard: Sendable {
    static let windowSeconds = 600.0
    static let limit = 3
    static let lockoutSeconds = 600.0

    private var losses: [UInt64] = []
    private var lockedUntilLoss: UInt64?

    mutating func recordLoss(at ticks: UInt64) {
        losses = losses.filter { recent($0, now: ticks, within: Self.windowSeconds) }
        losses.append(ticks)
        if losses.count >= Self.limit { lockedUntilLoss = ticks }
    }

    func isLockedOut(at ticks: UInt64) -> Bool {
        guard let lockedUntilLoss else { return false }
        return recent(lockedUntilLoss, now: ticks, within: Self.lockoutSeconds)
    }

    var lossCount: Int { losses.count }

    private func recent(_ event: UInt64, now: UInt64, within seconds: Double) -> Bool {
        let age = HostClock.seconds(from: event, to: now)
        // A clock regression keeps the event (and a lockout) rather than forgetting it.
        return !age.isFinite || age < 0 || age < seconds
    }
}
