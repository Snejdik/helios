import Foundation

/// Passive, read-only check that each catalogue sensor group follows its own load on this
/// Mac (PLAN_0_3_0 M1). It only watches telemetry Helios already collects: the mean
/// temperature of each group while the Mac is idle, and while one kind of load (P-cores,
/// E-cores or GPU) dominates. A group is confirmed when its own sensors warm clearly with
/// its own load and more than the other groups do. No stress is generated, nothing is
/// written to hardware, and the result never feeds fan control or the helper.
///
/// M0 spike on Mac16,1 (3 CPU threads, 25 s): P keys +10 °C, E keys +2 °C, GPU keys +1 °C,
/// so groups separate by response even when their names are unknown.
struct SensorMapVerifier {
  enum Channel: String, Codable, CaseIterable, Sendable {
    case performance
    case efficiency
    case gpu

    var group: ThermalGroup {
      switch self {
      case .performance: .performanceCPU
      case .efficiency: .efficiencyCPU
      case .gpu: .gpu
      }
    }

    var loadName: String {
      switch self {
      case .performance: "busy P-cores"
      case .efficiency: "busy E-cores while P-cores rest"
      case .gpu: "busy GPU while the CPU rests"
      }
    }
  }

  /// Busy percent of each kind of load. nil = not known right now.
  struct Load: Sendable, Equatable {
    var performance: Double?
    var efficiency: Double?
    var gpu: Double?
  }

  struct Thresholds: Sendable {
    /// Consecutive samples a condition must hold before it counts (temperatures lag load).
    var idleSettleSamples = 5
    var activeSettleSamples = 3
    var minimumIdleSamples = 30
    var minimumActiveSamples = 15
    /// Minimum warming of a group under its own load. E-cores warm the least.
    var minimumRise: [Channel: Double] = [.performance: 3, .efficiency: 1, .gpu: 2]
    /// Own group must warm at least this much more than any other group.
    var specificityMargin = 0.5
    /// Another group warming this much more than the expected one disputes the map.
    var disputeMargin = 3.0
    var minimumDisputeSamples = 30
    /// Older evidence is halved past this many samples so a changing room or season
    /// does not freeze the baseline.
    var decayAfterSamples = 3_600
    /// A key of a confirmed group must warm at least this much, and at least this fraction
    /// of its group's rise, or it is hidden from the group on this Mac.
    var minimumKeyRise = 0.5
    var keyRiseFraction = 0.25

    static let standard = Thresholds()
  }

  struct Accumulator: Codable, Equatable, Sendable {
    var count = 0
    var sum = 0.0

    var mean: Double? { count > 0 ? sum / Double(count) : nil }

    mutating func add(_ value: Double, decayAfter limit: Int) {
      count += 1
      sum += value
      if count > limit {
        // Halve the weight but keep the mean exactly (integer halving rounds down).
        let kept = count / 2
        sum *= Double(kept) / Double(count)
        count = kept
      }
    }
  }

  /// Persisted per Mac (`MacProfile.evidenceKey`).
  struct Evidence: Codable, Equatable, Sendable {
    var key: String
    /// Mean temperature of each group while the whole Mac idles.
    var idle: [String: Accumulator] = [:]
    /// load channel → group → mean temperature while that load dominates.
    var active: [String: [String: Accumulator]] = [:]
    /// Channels confirmed on this Mac. Sticky: confirmation is not undone by a quiet week.
    var confirmed: Set<String> = []
    /// Per key: idle temperature, and temperature while its own group's load dominates.
    /// One family map covers several variants, so a key can belong to another group here.
    var keyIdle: [String: Accumulator] = [:]
    var keyActive: [String: Accumulator] = [:]
  }

  private enum Condition: Equatable {
    case idle
    case active(Channel)
  }

  let profile: MacProfile
  let thresholds: Thresholds
  private(set) var evidence: Evidence
  private var condition: Condition?
  private var streak = 0

  init(profile: MacProfile, stored: Evidence? = nil, thresholds: Thresholds = .standard) {
    self.profile = profile
    self.thresholds = thresholds
    if let stored, stored.key == profile.evidenceKey {
      evidence = stored
    } else {
      evidence = Evidence(key: profile.evidenceKey)
    }
  }

  /// Channels that have a catalogue map to verify on this chip.
  var verifiableChannels: [Channel] {
    Channel.allCases.filter { profile.baselineStatus(for: $0.group) != .unknown }
  }

  /// Feeds one thermal sample with the load at the same moment. Returns true when a
  /// channel was newly confirmed (callers persist then).
  @discardableResult
  mutating func observe(_ thermals: ThermalMetrics, load: Load) -> Bool {
    guard !verifiableChannels.isEmpty else { return false }
    let temperatures = groupTemperatures(thermals)
    guard !temperatures.isEmpty else {
      condition = nil
      streak = 0
      return false
    }
    let current = classify(load)
    if current == condition {
      streak += 1
    } else {
      condition = current
      streak = current == nil ? 0 : 1
    }
    guard let current else { return false }
    switch current {
    case .idle:
      guard streak >= thresholds.idleSettleSamples else { return false }
      for (channel, celsius) in temperatures {
        evidence.idle[channel.rawValue, default: Accumulator()]
          .add(celsius, decayAfter: thresholds.decayAfterSamples)
      }
      for reading in groupReadings(thermals) {
        evidence.keyIdle[reading.key, default: Accumulator()]
          .add(reading.celsius, decayAfter: thresholds.decayAfterSamples)
      }
    case .active(let channel):
      guard streak >= thresholds.activeSettleSamples else { return false }
      for (group, celsius) in temperatures {
        evidence.active[channel.rawValue, default: [:]][group.rawValue, default: Accumulator()]
          .add(celsius, decayAfter: thresholds.decayAfterSamples)
      }
      for reading in groupReadings(thermals) where reading.displayGroup == channel.group {
        evidence.keyActive[reading.key, default: Accumulator()]
          .add(reading.celsius, decayAfter: thresholds.decayAfterSamples)
      }
    }
    var newlyConfirmed = false
    for channel in verifiableChannels where !evidence.confirmed.contains(channel.rawValue) {
      if verdict(for: channel) == .confirmed {
        evidence.confirmed.insert(channel.rawValue)
        newlyConfirmed = true
      }
    }
    return newlyConfirmed
  }

  /// Status per display group, ready for `ThermalMetrics.mapStatus`.
  var statuses: [ThermalGroup: SensorMapStatus] {
    var result: [ThermalGroup: SensorMapStatus] = [:]
    for channel in Channel.allCases {
      let baseline = profile.baselineStatus(for: channel.group)
      guard baseline != .unknown else { continue }
      if evidence.confirmed.contains(channel.rawValue) {
        result[channel.group] = .confirmed
      } else if verdict(for: channel) == .disputed {
        result[channel.group] = .disputed
      } else {
        result[channel.group] = baseline
      }
    }
    if profile.chip?.isM4Family == true { result[.validatedHotspot] = .validated }
    return result
  }

  /// Warming of `group` while `channel` load dominates, against the idle baseline.
  func rise(of group: Channel, under channel: Channel) -> Double? {
    guard let idle = evidence.idle[group.rawValue], idle.count >= thresholds.minimumIdleSamples,
      let active = evidence.active[channel.rawValue]?[group.rawValue],
      active.count >= thresholds.minimumActiveSamples,
      let idleMean = idle.mean, let activeMean = active.mean
    else { return nil }
    return activeMean - idleMean
  }

  /// Keys of a confirmed group that did not warm with that group's load on this Mac. They
  /// stay in the raw inventory but no longer count as the group (display only; the
  /// validated M4 identity used by fan control is never changed by this).
  var excludedKeys: Set<String> {
    var result = Set<String>()
    guard let map = profile.sensorMap else { return result }
    for channel in verifiableChannels where evidence.confirmed.contains(channel.rawValue) {
      guard let groupRise = rise(of: channel, under: channel) else { continue }
      let minimum = max(thresholds.minimumKeyRise, groupRise * thresholds.keyRiseFraction)
      for key in map.keys(in: channel.group) {
        guard let idle = evidence.keyIdle[key], idle.count >= thresholds.minimumIdleSamples,
          let active = evidence.keyActive[key], active.count >= thresholds.minimumActiveSamples,
          let idleMean = idle.mean, let activeMean = active.mean
        else { continue }
        if activeMean - idleMean < minimum { result.insert(key) }
      }
    }
    return result
  }

  /// One line for the UI: what was seen, or what is still missing.
  func detail(for channel: Channel) -> String {
    if evidence.confirmed.contains(channel.rawValue) {
      let hidden = excludedKeys.intersection(profile.sensorMap?.keys(in: channel.group) ?? []).count
      let base = "Its sensors warmed with \(channel.loadName)."
      return hidden == 0
        ? base
        : base + " \(hidden) sensor\(hidden == 1 ? "" : "s") did not follow and \(hidden == 1 ? "is" : "are") hidden."
    }
    switch verdict(for: channel) {
    case .disputed:
      return "Under \(channel.loadName), other sensors warmed more than these."
    case .confirmed:
      return "Its sensors warmed with \(channel.loadName)."
    case .undecided:
      let idle = evidence.idle[channel.rawValue]?.count ?? 0
      if idle < thresholds.minimumIdleSamples {
        return "Waiting for a quiet minute to learn the idle temperature."
      }
      let active = evidence.active[channel.rawValue]?[channel.rawValue]?.count ?? 0
      if active < thresholds.minimumActiveSamples {
        return "Waiting for a while of \(channel.loadName). Normal use is enough."
      }
      return "Its sensors have not yet warmed clearly with \(channel.loadName)."
    }
  }

  enum Verdict: Equatable {
    case confirmed
    case disputed
    case undecided
  }

  func verdict(for channel: Channel) -> Verdict {
    guard let own = rise(of: channel, under: channel) else { return .undecided }
    let others = Channel.allCases.filter { $0 != channel }.compactMap { rise(of: $0, under: channel) }
    let activeCount = evidence.active[channel.rawValue]?[channel.rawValue]?.count ?? 0
    if activeCount >= thresholds.minimumDisputeSamples,
      others.contains(where: { $0 >= own + thresholds.disputeMargin })
    {
      return .disputed
    }
    let minimum = thresholds.minimumRise[channel] ?? 3
    if own >= minimum, others.allSatisfy({ own >= $0 + thresholds.specificityMargin }) {
      return .confirmed
    }
    return .undecided
  }

  private func classify(_ load: Load) -> Condition? {
    guard let performance = load.performance, let efficiency = load.efficiency else { return nil }
    let gpuQuiet = load.gpu.map { $0 < 20 } ?? true
    if performance >= 50 { return .active(.performance) }
    if let gpu = load.gpu, gpu >= 50, performance < 20, efficiency < 50 { return .active(.gpu) }
    if efficiency >= 60, performance < 15, gpuQuiet { return .active(.efficiency) }
    if performance < 10, efficiency < 30, load.gpu.map({ $0 < 10 }) ?? true { return .idle }
    return nil
  }

  private func groupReadings(_ thermals: ThermalMetrics) -> [ThermalReading] {
    let groups = Set(verifiableChannels.map(\.group))
    return thermals.readings.filter { groups.contains($0.displayGroup) && $0.celsius.isFinite }
  }

  /// Mean of each verifiable group's live readings. Raw/unclassified keys never count.
  private func groupTemperatures(_ thermals: ThermalMetrics) -> [Channel: Double] {
    var result: [Channel: Double] = [:]
    for channel in verifiableChannels {
      let values = thermals.readings.filter { $0.displayGroup == channel.group }.map(\.celsius)
        .filter { $0.isFinite }
      guard !values.isEmpty else { continue }
      result[channel] = values.reduce(0, +) / Double(values.count)
    }
    return result
  }
}

/// Keeps verification evidence across launches, one small JSON value per Mac.
enum SensorMapEvidenceStore {
  static let defaultsKey = "HeliosSensorMapEvidence.v1"

  static func load(from defaults: UserDefaults = .standard) -> SensorMapVerifier.Evidence? {
    guard let data = defaults.data(forKey: defaultsKey), data.count <= 64 * 1024 else { return nil }
    return try? JSONDecoder().decode(SensorMapVerifier.Evidence.self, from: data)
  }

  static func save(_ evidence: SensorMapVerifier.Evidence, to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(evidence), data.count <= 64 * 1024 else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}
