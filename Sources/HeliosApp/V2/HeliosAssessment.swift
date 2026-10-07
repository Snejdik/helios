import Foundation

/// The application a process belongs to: its outermost `.app` bundle, so helper
/// processes ("Claude Helper (Renderer)") are attributed to their app ("Claude").
enum HeliosAppIdentity {
  static func of(_ process: ProcessActivity) -> (key: String, name: String) {
    if let path = process.executablePath,
      let range = path.range(of: ".app/", options: .caseInsensitive)
    {
      let bundle = String(path[..<range.lowerBound]) + ".app"
      let name = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
      return ("app:" + bundle, name.isEmpty ? process.name : name)
    }
    return ("proc:" + process.name.lowercased(), process.name)
  }
}

/// One status vocabulary for every Helios surface. Evidence states (waiting,
/// stale, unavailable) are distinct from judgements and never read as "OK".
enum HeliosStatus: Equatable, Sendable {
  case good
  case normal
  case attention
  case critical
  case waiting
  case stale(age: TimeInterval)
  case unavailable
  case notPresent

  var label: String {
    switch self {
    case .good: "Good"
    case .normal: "Normal"
    case .attention: "Needs attention"
    case .critical: "Critical"
    case .waiting: "Waiting…"
    case .stale(let age): "Stale · \(HeliosStatus.ageText(age))"
    case .unavailable: "Unavailable"
    case .notPresent: "Not present"
    }
  }

  /// Narrow surfaces (popover rows) use one word.
  var shortLabel: String {
    switch self {
    case .attention: "Attention"
    case .stale: "Stale"
    case .notPresent: "None"
    default: label
    }
  }

  /// Ordering used to pick the overall answer. Judgements outrank evidence gaps.
  var rank: Int {
    switch self {
    case .critical: 5
    case .attention: 4
    case .unavailable, .stale: 2
    case .waiting: 1
    case .good, .normal, .notPresent: 0
    }
  }

  var isJudgement: Bool {
    switch self {
    case .good, .normal, .attention, .critical: true
    default: false
    }
  }

  var isProblem: Bool { self == .attention || self == .critical }

  static func ageText(_ age: TimeInterval) -> String {
    guard age.isFinite, age >= 0 else { return "—" }
    if age < 90 { return "\(Int(age.rounded()))s" }
    if age < 5_400 { return "\(Int((age / 60).rounded())) min" }
    return "\(Int((age / 3_600).rounded())) h"
  }
}

/// One fact supporting a judgement: what was read, its value and where it came from.
struct HeliosEvidence: Equatable, Sendable, Identifiable {
  let label: String
  let value: String
  var source: String? = nil
  var id: String { label }
}

/// Why an area is a problem. Drives findings and recommended actions.
enum HeliosProblemReason: String, Sendable {
  case memoryPressure, thermalPressure, hotSensor
  case batteryCapacity, batteryTemperature
  case lowDiskSpace, ssdHealth, ssdMediaErrors, ssdTemperature
}

struct HeliosAreaAssessment: Equatable, Sendable, Identifiable {
  let area: HeliosArea
  let status: HeliosStatus
  /// The single key value shown beside the status ("52 °C").
  let value: String?
  /// One sentence (Layer 2).
  let explanation: String
  /// Facts behind the judgement (Layer 3, shown under Why?).
  let evidence: [HeliosEvidence]
  /// Some inputs were missing; the judgement uses only what is known.
  let isPartial: Bool
  let chartMetric: HeliosChartMetric
  /// Set for attention/critical judgements.
  var reason: HeliosProblemReason? = nil
  var id: HeliosArea { area }
}

/// Deterministic, auditable answer to "Is my Mac OK?". Pure: no providers, no
/// hardware, no notification state. Temperature/health limits reuse the
/// notification thresholds so both surfaces agree, but switching a
/// notification off never hides a problem here.
struct HeliosMacAssessment: Equatable, Sendable {
  let areas: [HeliosAreaAssessment]
  let overall: HeliosStatus
  let title: String
  let subtitle: String
  /// The area driving a problem answer, if any.
  let focus: HeliosArea?

  func area(_ area: HeliosArea) -> HeliosAreaAssessment? { areas.first { $0.area == area } }

  /// Storage free-space thresholds.
  static let storageAttentionFreeFraction = 0.10
  static let storageCriticalFreeFraction = 0.05
  static let storageCriticalFreeBytes: UInt64 = 10_000_000_000

  static func evaluate(
    _ snapshot: TelemetrySnapshot, now: Date = Date(),
    configuration: HealthAlertConfiguration = .defaults
  ) -> HeliosMacAssessment {
    let areas = [
      performance(snapshot, now: now),
      thermals(snapshot, now: now, configuration: configuration),
      battery(snapshot, now: now, configuration: configuration),
      storage(snapshot, now: now, configuration: configuration),
    ]
    return summarize(areas)
  }

  static func summarize(_ areas: [HeliosAreaAssessment]) -> HeliosMacAssessment {
    let problems = areas.filter { $0.status.isProblem }
    // Worst rank wins; ties keep the fixed area order (deterministic focus).
    let worst = problems.reduce(nil as HeliosAreaAssessment?) { best, next in
      guard let best else { return next }
      return next.status.rank > best.status.rank ? next : best
    }
    if let worst {
      let title =
        problems.count > 1
        ? "\(problems.count) things need attention" : problemTitle(worst)
      return HeliosMacAssessment(
        areas: areas, overall: worst.status, title: title, subtitle: worst.explanation,
        focus: worst.area)
    }
    // "Doing well" needs evidence for the two areas that always exist.
    let core = areas.filter { $0.area == .performance || $0.area == .thermals }
    if core.allSatisfy({ $0.status.isJudgement }) {
      let gaps = areas.filter { !$0.status.isJudgement && $0.status != .notPresent }
      let subtitle =
        gaps.isEmpty
        ? "Nothing needs your attention."
        : "Nothing needs your attention. Some \(gaps.map { $0.area.title.lowercased() }.joined(separator: " and ")) readings are missing."
      return HeliosMacAssessment(
        areas: areas, overall: .normal, title: "Your Mac is doing well", subtitle: subtitle,
        focus: nil)
    }
    if core.contains(where: { $0.status == .waiting }) {
      return HeliosMacAssessment(
        areas: areas, overall: .waiting, title: "Checking your Mac…",
        subtitle: "Helios is collecting its first readings.", focus: nil)
    }
    let worstGap = core.max { $0.status.rank < $1.status.rank }?.status ?? .unavailable
    return HeliosMacAssessment(
      areas: areas, overall: worstGap, title: "Helios can’t fully check your Mac",
      subtitle: "Some essential readings are unavailable right now.", focus: nil)
  }

  private static func problemTitle(_ area: HeliosAreaAssessment) -> String {
    let critical = area.status == .critical
    switch area.area {
    case .performance: return critical ? "Your Mac is short on memory" : "Memory is under pressure"
    case .thermals: return critical ? "Your Mac is very hot" : "Your Mac is running hot"
    case .battery: return "Your battery needs attention"
    case .storage: return critical ? "Storage needs attention now" : "Storage needs attention"
    }
  }

  // MARK: Performance

  static func performance(_ snapshot: TelemetrySnapshot, now: Date) -> HeliosAreaAssessment {
    let cpu = TelemetryFormatting.observation(snapshot.cpu, maxAge: 5, now: now)
    let memory = TelemetryFormatting.observation(snapshot.memory, maxAge: 5, now: now)
    var evidence: [HeliosEvidence] = []
    var cpuPercent: Double?
    if case .success(let value) = cpu.freshResult {
      cpuPercent = value.usagePercent
      evidence.append(HeliosEvidence(
        label: "CPU usage", value: TelemetryFormatting.percent(value.usagePercent),
        source: "Mach CPU ticks, all cores"))
    }
    var pressure: MemoryPressure?
    if case .success(let value) = memory.freshResult {
      if case .success(let level) = value.pressure {
        pressure = level
        evidence.append(HeliosEvidence(
          label: "Memory pressure", value: level.rawValue, source: "Reported by macOS"))
      }
      evidence.append(HeliosEvidence(
        label: "Memory used",
        value: "\(TelemetryFormatting.gibibytes(value.usedBytes)) of \(TelemetryFormatting.gibibytes(value.physicalBytes))"))
      if case .success(let swap) = value.swapUsedBytes, swap > 0 {
        evidence.append(HeliosEvidence(label: "Swap used", value: TelemetryFormatting.storageBytes(swap)))
      }
    }
    if let leader = mostActiveProcess(snapshot, now: now) {
      evidence.append(HeliosEvidence(label: "Most active", value: leader, source: "Share of total CPU"))
    }
    let value = cpuPercent.map { "CPU \(TelemetryFormatting.percent($0))" }
    switch pressure {
    case .critical?:
      return HeliosAreaAssessment(
        area: .performance, status: .critical, value: value,
        explanation: "macOS reports critical memory pressure. Apps may become unresponsive.",
        evidence: evidence, isPartial: cpuPercent == nil, chartMetric: .memory, reason: .memoryPressure)
    case .warning?:
      return HeliosAreaAssessment(
        area: .performance, status: .attention, value: value,
        explanation: "macOS reports elevated memory pressure. Apps may slow down.",
        evidence: evidence, isPartial: cpuPercent == nil, chartMetric: .memory, reason: .memoryPressure)
    case .normal?:
      let busy = (cpuPercent ?? 0) >= 80
      return HeliosAreaAssessment(
        area: .performance, status: .normal, value: value,
        explanation: busy ? "Busy, and keeping up." : "Running smoothly.",
        evidence: evidence, isPartial: cpuPercent == nil, chartMetric: .cpu)
    case nil:
      // Without macOS pressure Helios does not judge performance from CPU alone.
      let status = gapStatus(snapshot.memory, maxAge: 5, or: snapshot.cpu, maxAge: 5, now: now)
      return HeliosAreaAssessment(
        area: .performance, status: status, value: value,
        explanation: gapExplanation(status, subject: "Memory pressure"),
        evidence: evidence, isPartial: true, chartMetric: .cpu)
    }
  }

  static func mostActiveProcess(_ snapshot: TelemetrySnapshot, now: Date) -> String? {
    guard case .success(let processes) = TelemetryFormatting.fresh(snapshot.processes, maxAge: 12, now: now),
      let top = processes.topByCPU.first(where: { $0.cpuPercent != nil })
    else { return nil }
    let logical: Int
    if case .success(let system) = TelemetryFormatting.fresh(snapshot.system, maxAge: 30, now: now) {
      logical = max(1, system.logicalProcessorCount)
    } else {
      logical = max(1, ProcessInfo.processInfo.processorCount)
    }
    let share = TelemetryFormatting.processCPUShareText(top.cpuPercent, logicalProcessorCount: logical)
    return "\(HeliosAppIdentity.of(top).name) · \(share)"
  }

  // MARK: Thermals

  static func thermals(
    _ snapshot: TelemetrySnapshot, now: Date, configuration: HealthAlertConfiguration
  ) -> HeliosAreaAssessment {
    let system = TelemetryFormatting.observation(snapshot.system, maxAge: 30, now: now)
    let thermals = TelemetryFormatting.observation(snapshot.thermals, maxAge: 6, now: now)
    var evidence: [HeliosEvidence] = []
    var state: SystemThermalState?
    if case .success(let value) = system.freshResult {
      state = value.thermalState
      evidence.append(HeliosEvidence(
        label: "Thermal pressure", value: value.thermalState.rawValue, source: "Reported by macOS"))
    }
    var maximum: Double?
    if case .success(let metrics) = thermals.freshResult,
      case .success(let reading) = metrics.maximumSoCReading
    {
      maximum = reading.celsius
      evidence.append(HeliosEvidence(
        label: "Hottest sensor", value: TelemetryFormatting.temperature(reading.celsius),
        source: "Max SoC · \(reading.displayGroup.rawValue)"))
    }
    if let fan = fanSummary(snapshot, now: now) {
      evidence.append(HeliosEvidence(label: "Fan", value: fan))
    }
    let value = maximum.map { TelemetryFormatting.temperature($0) }
    let hot = configuration[.socHot].threshold ?? HealthAlertRule.socHot.defaultThreshold ?? 90
    let critical =
      configuration[.socCritical].threshold ?? HealthAlertRule.socCritical.defaultThreshold ?? 95
    let partial = state == nil || maximum == nil

    if state == .critical || (maximum ?? -.infinity) >= critical {
      return HeliosAreaAssessment(
        area: .thermals, status: .critical, value: value,
        explanation: state == .critical
          ? "macOS reports critical thermal pressure and is slowing your Mac to cool it."
          : "The hottest sensor is above \(TelemetryFormatting.temperature(critical)).",
        evidence: evidence, isPartial: partial, chartMetric: .temperature,
        reason: state == .critical ? .thermalPressure : .hotSensor)
    }
    if state == .serious || (maximum ?? -.infinity) >= hot {
      return HeliosAreaAssessment(
        area: .thermals, status: .attention, value: value,
        explanation: state == .serious
          ? "macOS reports serious thermal pressure. Performance may be reduced."
          : "The hottest sensor is above \(TelemetryFormatting.temperature(hot)).",
        evidence: evidence, isPartial: partial, chartMetric: .temperature,
        reason: state == .serious ? .thermalPressure : .hotSensor)
    }
    if state != nil || maximum != nil {
      return HeliosAreaAssessment(
        area: .thermals, status: .normal, value: value,
        explanation: state == .fair
          ? "Warm, but within the expected range." : "Operating within the expected range.",
        evidence: evidence, isPartial: partial, chartMetric: .temperature)
    }
    let status = gapStatus(snapshot.thermals, maxAge: 6, or: snapshot.system, maxAge: 30, now: now)
    return HeliosAreaAssessment(
      area: .thermals, status: status, value: nil,
      explanation: gapExplanation(status, subject: "Temperature"),
      evidence: evidence, isPartial: true, chartMetric: .temperature)
  }

  /// Below this a fan counts as stopped (macOS fans idle at 0 RPM).
  static let fanStoppedBelowRPM = 50.0

  /// True when a series has readings and the fan never ran in it.
  static func fanWasIdle(_ rpmSeries: [Double]) -> Bool {
    !rpmSeries.isEmpty && rpmSeries.allSatisfy { $0 < fanStoppedBelowRPM }
  }

  static func fanSummary(_ snapshot: TelemetrySnapshot, now: Date) -> String? {
    guard case .success(let inventory) = TelemetryFormatting.fresh(snapshot.fans, maxAge: 5, now: now)
    else { return nil }
    guard !inventory.fans.isEmpty else { return "None · passive cooling" }
    let speeds = inventory.fans.compactMap { try? $0.actualRPM.get() }
    guard !speeds.isEmpty else { return nil }
    if speeds.allSatisfy({ $0 < fanStoppedBelowRPM }) { return "Off" }
    return speeds.map { TelemetryFormatting.fanRPM($0) }.joined(separator: " · ")
  }

  // MARK: Battery

  /// The frozen battery provider reports a Mac without AppleSmartBattery with
  /// exactly this typed error. Compared as a value, never parsed from text.
  static let batteryAbsentError = TelemetryError.unavailable("AppleSmartBattery unavailable")

  static func battery(
    _ snapshot: TelemetrySnapshot, now: Date, configuration: HealthAlertConfiguration
  ) -> HeliosAreaAssessment {
    let observation = TelemetryFormatting.observation(snapshot.battery, maxAge: 20, now: now)
    guard case .success(let battery) = observation.freshResult else {
      if case .failure(let error) = observation.source, error == batteryAbsentError {
        return HeliosAreaAssessment(
          area: .battery, status: .notPresent, value: nil,
          explanation: "This Mac has no built-in battery.", evidence: [], isPartial: false,
          chartMetric: .power)
      }
      let status = gapStatus(snapshot.battery, maxAge: 20, now: now)
      return HeliosAreaAssessment(
        area: .battery, status: status, value: nil,
        explanation: gapExplanation(status, subject: "Battery information"),
        evidence: [], isPartial: true, chartMetric: .battery)
    }
    var evidence: [HeliosEvidence] = []
    let charge = try? battery.stateOfChargePercent.get()
    if let charge {
      evidence.append(HeliosEvidence(label: "Charge", value: TelemetryFormatting.percent(charge)))
    }
    let health = try? battery.healthPercent.get()
    if let health {
      evidence.append(HeliosEvidence(
        label: "Capacity", value: TelemetryFormatting.percent(health),
        source: "Full charge vs. design capacity"))
    }
    if case .success(let cycles) = battery.cycleCount {
      evidence.append(HeliosEvidence(label: "Cycle count", value: "\(cycles)"))
    }
    let temperature = try? battery.temperatureCelsius.get()
    if let temperature {
      evidence.append(HeliosEvidence(
        label: "Battery temperature", value: TelemetryFormatting.temperature(temperature)))
    }
    let value = charge.map { TelemetryFormatting.percent($0) }
    let lowHealth = configuration[.batteryHealthLow].threshold ?? 80
    let criticalHealth = configuration[.batteryHealthCritical].threshold ?? 70
    let hotTemp = configuration[.batteryTempHot].threshold ?? 45
    let criticalTemp = configuration[.batteryTempCritical].threshold ?? 50
    let partial = health == nil || temperature == nil

    if let temperature, temperature.isFinite, temperature >= criticalTemp {
      return HeliosAreaAssessment(
        area: .battery, status: .critical, value: value,
        explanation: "The battery is very warm (\(TelemetryFormatting.temperature(temperature))).",
        evidence: evidence, isPartial: partial, chartMetric: .battery, reason: .batteryTemperature)
    }
    if let health, health.isFinite, health < criticalHealth {
      return HeliosAreaAssessment(
        area: .battery, status: .critical, value: value,
        explanation: "The battery holds \(TelemetryFormatting.percent(health)) of its original capacity. Consider service.",
        evidence: evidence, isPartial: partial, chartMetric: .battery, reason: .batteryCapacity)
    }
    if let temperature, temperature.isFinite, temperature >= hotTemp {
      return HeliosAreaAssessment(
        area: .battery, status: .attention, value: value,
        explanation: "The battery is warmer than usual (\(TelemetryFormatting.temperature(temperature))).",
        evidence: evidence, isPartial: partial, chartMetric: .battery, reason: .batteryTemperature)
    }
    if let health, health.isFinite, health < lowHealth {
      return HeliosAreaAssessment(
        area: .battery, status: .attention, value: value,
        explanation: "The battery holds \(TelemetryFormatting.percent(health)) of its original capacity.",
        evidence: evidence, isPartial: partial, chartMetric: .battery, reason: .batteryCapacity)
    }
    let explanation: String
    if case .success(true) = battery.isCharging {
      explanation = "Charging."
    } else if case .success(.battery) = battery.powerSource {
      explanation = "On battery power."
    } else if case .success = battery.powerSource {
      explanation = "On power adapter."
    } else {
      explanation = "Battery is working normally."
    }
    return HeliosAreaAssessment(
      area: .battery, status: health == nil ? .normal : .good, value: value,
      explanation: explanation, evidence: evidence, isPartial: partial, chartMetric: .battery)
  }

  // MARK: Storage

  static func storage(
    _ snapshot: TelemetrySnapshot, now: Date, configuration: HealthAlertConfiguration
  ) -> HeliosAreaAssessment {
    let observation = TelemetryFormatting.observation(snapshot.storage, maxAge: 10, now: now)
    guard case .success(let storage) = observation.freshResult else {
      let status = gapStatus(snapshot.storage, maxAge: 10, now: now)
      return HeliosAreaAssessment(
        area: .storage, status: status, value: nil,
        explanation: gapExplanation(status, subject: "Storage information"),
        evidence: [], isPartial: true, chartMetric: .disk)
    }
    var evidence: [HeliosEvidence] = []
    var findings: [(HeliosStatus, String, HeliosProblemReason)] = []
    var value: String?
    if case .success(let root) = storage.rootVolume, root.totalBytes > 0 {
      let fraction = Double(root.freeBytes) / Double(root.totalBytes)
      value = "\(TelemetryFormatting.storageBytes(root.freeBytes)) free"
      evidence.append(HeliosEvidence(
        label: "Free space",
        value: "\(TelemetryFormatting.storageBytes(root.freeBytes)) of \(TelemetryFormatting.storageBytes(root.totalBytes))",
        source: "Startup volume"))
      if fraction < storageCriticalFreeFraction || root.freeBytes < storageCriticalFreeBytes {
        findings.append((.critical, "Your startup disk is almost full. macOS needs free space to update and swap.", .lowDiskSpace))
      } else if fraction < storageAttentionFreeFraction {
        findings.append((.attention, "Less than 10 % of your startup disk is free.", .lowDiskSpace))
      }
    }
    var smartKnown = false
    if case .success(let smart) = storage.smartHealth {
      smartKnown = true
      evidence.append(HeliosEvidence(
        label: "SSD health", value: smart.state.rawValue, source: "NVMe SMART"))
      evidence.append(HeliosEvidence(
        label: "SSD wear", value: "\(smart.percentageUsed) % used", source: "NVMe SMART"))
      switch smart.state {
      case .critical: findings.append((.critical, "The SSD reports a critical health condition. Back up your data.", .ssdHealth))
      case .attention: findings.append((.attention, "The SSD reports a health value outside the normal range.", .ssdHealth))
      case .verified: break
      }
      if smart.mediaErrors.approximateValue > 0 {
        findings.append((.critical, "The SSD reports media errors. Back up your data.", .ssdMediaErrors))
      }
      if let temperature = smart.temperatureCelsius, temperature.isFinite {
        evidence.append(HeliosEvidence(
          label: "SSD temperature", value: TelemetryFormatting.temperature(temperature)))
        let hot = configuration[.ssdTempHot].threshold ?? 70
        let critical = configuration[.ssdTempCritical].threshold ?? 80
        if temperature >= critical {
          findings.append((.critical, "The SSD is very hot (\(TelemetryFormatting.temperature(temperature))).", .ssdTemperature))
        } else if temperature >= hot {
          findings.append((.attention, "The SSD is warmer than usual (\(TelemetryFormatting.temperature(temperature))).", .ssdTemperature))
        }
      }
    }
    if let worst = findings.max(by: { $0.0.rank < $1.0.rank }) {
      return HeliosAreaAssessment(
        area: .storage, status: worst.0, value: value, explanation: worst.1, evidence: evidence,
        isPartial: !smartKnown || value == nil, chartMetric: .disk, reason: worst.2)
    }
    if value == nil && !smartKnown {
      return HeliosAreaAssessment(
        area: .storage, status: .unavailable, value: nil,
        explanation: "Storage capacity and SSD health are unavailable.", evidence: evidence,
        isPartial: true, chartMetric: .disk)
    }
    return HeliosAreaAssessment(
      area: .storage, status: .good, value: value,
      explanation: smartKnown ? "Plenty of space and a healthy SSD." : "Plenty of space.",
      evidence: evidence, isPartial: !smartKnown || value == nil, chartMetric: .disk)
  }

  // MARK: Evidence gaps

  /// Status for missing evidence. A fresh container whose needed field failed
  /// is "unavailable"; an expired container is "stale" with its real age.
  static func gapStatus<V>(_ sample: MetricSample<V>, maxAge: TimeInterval, now: Date) -> HeliosStatus {
    let observation = TelemetryFormatting.observation(sample, maxAge: maxAge, now: now)
    switch observation.state {
    case .available, .unavailable: return .unavailable
    case .waiting: return .waiting
    case .stale: return .stale(age: max(0, now.timeIntervalSince(sample.capturedAt)))
    }
  }

  /// Two inputs: waiting wins (the area is still starting), otherwise the primary gap.
  static func gapStatus<A, B>(
    _ primary: MetricSample<A>, maxAge: TimeInterval, or secondary: MetricSample<B>,
    maxAge secondaryMaxAge: TimeInterval, now: Date
  ) -> HeliosStatus {
    let first = gapStatus(primary, maxAge: maxAge, now: now)
    if gapStatus(secondary, maxAge: secondaryMaxAge, now: now) == .waiting { return .waiting }
    return first
  }

  static func gapExplanation(_ status: HeliosStatus, subject: String) -> String {
    switch status {
    case .waiting: "Waiting for the first reading."
    case .stale: "\(subject) hasn’t updated recently."
    default: "\(subject) is unavailable right now."
    }
  }
}
