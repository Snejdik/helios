import Foundation

// Longevity assessment (PLAN_0_3_0 M5, decision 5): a word grade per area with the facts
// behind it, never a bare score. Projections are always called estimates, and an area
// without enough history says so instead of guessing. Pure: day records in, text out.

enum LongevityGrade: Int, Sendable, Comparable, CaseIterable {
  case excellent, good, attention

  var title: String {
    switch self {
    case .excellent: "Excellent"
    case .good: "Good"
    case .attention: "Needs attention"
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum LongevityAreaKind: String, Sendable, CaseIterable, Identifiable {
  case battery, charger, storage, cooling, memory
  var id: String { rawValue }

  var title: String {
    switch self {
    case .battery: "Battery"
    case .charger: "Power adapter"
    case .storage: "SSD"
    case .cooling: "Cooling"
    case .memory: "Memory"
    }
  }

  /// Name inside a sentence.
  var phrase: String {
    switch self {
    case .battery: "the battery"
    case .charger: "the power adapter"
    case .storage: "the SSD"
    case .cooling: "cooling"
    case .memory: "memory"
    }
  }

  var symbol: String {
    switch self {
    case .battery: "battery.75percent"
    case .charger: "powerplug"
    case .storage: "internaldrive"
    case .cooling: "fan"
    case .memory: "memorychip"
    }
  }
}

struct LongevityFact: Sendable, Equatable, Identifiable {
  let label: String
  let value: String
  var detail: String? = nil
  var id: String { label }
}

struct LongevityArea: Sendable, Equatable, Identifiable {
  let kind: LongevityAreaKind
  /// nil = not enough data yet (or nothing to judge, such as no battery).
  let grade: LongevityGrade?
  /// One sentence: what Helios sees.
  let summary: String
  var facts: [LongevityFact] = []
  /// A projection, always worded as an estimate with its basis.
  var estimate: String? = nil
  /// What would help, when something would.
  var advice: String? = nil
  var id: String { kind.rawValue }
}

/// Live values the day records do not hold.
struct LongevityCurrent: Sendable, Equatable {
  var hasBattery = true
  var batteryHealthPercent: Double?
  var cycleCount: Int?
  var optimizedChargingEngaged: Bool?
  var adapter: PowerAdapterDetails?
  var ssdPercentageUsed: Int?
  var ssdAvailableSparePercent: Int?
  var ssdAvailableSpareThresholdPercent: Int?
  var ssdCriticalWarning = false
  var ssdLifetimeWrittenBytes: Double?
  var physicalMemoryBytes: UInt64?
  /// The SoC temperature map is trusted on this Mac (validated or confirmed).
  var thermalMapTrusted = false
  var hasFans = true

  init() {}
}

struct LongevityReport: Sendable, Equatable {
  let generatedAt: Date
  let areas: [LongevityArea]
  /// Worst grade among the areas that have one; nil while every area is still learning.
  let overall: LongevityGrade?
  let overallSummary: String
  /// Days of history behind the report.
  let recordedDays: Int

  func area(_ kind: LongevityAreaKind) -> LongevityArea? { areas.first { $0.kind == kind } }
}

enum LongevityEngine {
  /// Apple's published service life for current MacBook batteries.
  static let ratedCycles = 1_000
  /// Apple recommends service below this health.
  static let serviceHealthPercent = 80.0
  /// First four weeks are this Mac's own cooling baseline.
  static let coolingBaselineDays = 28
  /// A day counts toward averages once Helios watched it this long.
  static let usefulDaySeconds: Double = 2 * 3_600

  static func report(
    days: [LongevityDayRecord], battery: BatteryHealthSummary, current: LongevityCurrent, now: Date,
    calendar: Calendar = .current
  ) -> LongevityReport {
    var areas: [LongevityArea] = []
    if current.hasBattery {
      areas.append(batteryArea(days: days, battery: battery, current: current, now: now))
      areas.append(chargerArea(days: days, current: current))
    }
    areas.append(storageArea(days: days, current: current))
    if current.hasFans || current.thermalMapTrusted {
      areas.append(coolingArea(days: days, current: current, calendar: calendar))
    }
    areas.append(memoryArea(days: days, current: current))
    let graded = areas.compactMap { area in area.grade.map { (area, $0) } }
    let overall = graded.map(\.1).max()
    let summary: String
    if let overall {
      let worst = graded.filter { $0.1 == overall }.map { $0.0.kind.phrase }
      switch overall {
      case .excellent:
        summary = "Everything Helios can judge looks healthy."
      case .good:
        summary = "Healthy, with normal wear. Worth a look: \(list(worst))."
      case .attention:
        summary = "\(list(worst).capitalizedFirst) \(worst.count == 1 ? "needs" : "need") attention."
      }
    } else {
      summary = "Helios is still learning this Mac. Grades appear after a few days of use."
    }
    return LongevityReport(
      generatedAt: now, areas: areas, overall: overall, overallSummary: summary,
      recordedDays: days.filter { $0.observedSeconds > 0 }.count)
  }

  // MARK: - Battery

  static func batteryArea(
    days: [LongevityDayRecord], battery: BatteryHealthSummary, current: LongevityCurrent, now: Date
  ) -> LongevityArea {
    let health = current.batteryHealthPercent ?? battery.latest?.healthPercent
    let cycles = current.cycleCount ?? battery.latest?.cycleCount
    var facts: [LongevityFact] = []
    if let health { facts.append(.init(label: "Health", value: percent(health), detail: "Capacity compared with new")) }
    if let cycles {
      facts.append(.init(label: "Cycles", value: "\(cycles) of \(ratedCycles.formatted()) rated"))
    }
    let recent = lastUseful(days, count: 7)
    var advice: String?
    if !recent.isEmpty {
      let adapter = recent.reduce(0) { $0 + $1.adapterSeconds }
      let high = recent.reduce(0) { $0 + $1.highChargeSeconds }
      let perDay = high / Double(recent.count)
      facts.append(.init(
        label: "At full charge on the adapter", value: "\(hours(perDay)) a day",
        detail: "95 % or more, average of the last \(recent.count) day\(recent.count == 1 ? "" : "s")"))
      let charging = recent.reduce(0) { $0 + $1.chargingSeconds }
      let hot = recent.reduce(0) { $0 + $1.hotChargingSeconds }
      if charging >= 1_800 {
        facts.append(.init(
          label: "Charging while warm", value: share(hot, of: charging),
          detail: "Share of charging time with the battery at 40 °C or more"))
      }
      if charging >= 1_800, hot / charging >= 0.25 {
        advice = "The battery is often warm while it charges. Heat while full or charging ages it fastest; charging in a cooler spot or with lighter work helps."
      } else if adapter > 0, perDay >= 10 * 3_600, current.optimizedChargingEngaged != true {
        advice = "The Mac spends most of the day full on the adapter. Optimized Battery Charging (System Settings › Battery) or unplugging around 80 % slows wear."
      }
    }
    if let limited = current.adapter?.thermallyLimitedSeconds, limited > 0 {
      facts.append(.init(label: "Charging slowed by heat", value: duration(Double(limited)),
        detail: "As counted by macOS since the battery was installed"))
    }

    var estimate: String?
    if let trend = healthTrend(battery), let health {
      facts.append(.init(
        label: "Wear trend", value: String(format: "%+.1f points a year", trend.pointsPerYear),
        detail: "Over \(trend.spanDays) days of daily readings"))
      if trend.pointsPerYear < -0.2, health > serviceHealthPercent {
        let years = (health - serviceHealthPercent) / -trend.pointsPerYear
        estimate = "At this pace the battery reaches 80 % in about \(yearsText(years)). Estimate: macOS refines its health reading over time, so the trend can move."
      } else if trend.pointsPerYear >= -0.2 {
        estimate = "No measurable wear over \(trend.spanDays) days."
      }
    }
    if let pace = cyclesPerDay(battery), let cycles, cycles < ratedCycles, pace > 0.05 {
      let years = Double(ratedCycles - cycles) / pace / 365
      let text = "At \(String(format: "%.1f", pace)) cycles a day, \(ratedCycles.formatted()) cycles is about \(yearsText(years)) away (estimate)."
      estimate = estimate.map { "\($0) \(text)" } ?? text
    }

    guard let health else {
      return LongevityArea(kind: .battery, grade: nil, summary: "Battery health is not available yet.", facts: facts)
    }
    let grade: LongevityGrade = health >= 90 ? .excellent : health >= serviceHealthPercent ? .good : .attention
    let summary: String
    switch grade {
    case .excellent: summary = "The battery holds \(percent(health)) of its original capacity."
    case .good: summary = "The battery holds \(percent(health)) of its original capacity: normal wear."
    case .attention: summary = "The battery holds \(percent(health)) of its original capacity, below the 80 % at which Apple suggests service."
    }
    if estimate == nil, battery.days.count < 30 {
      estimate = "A wear trend needs about a month of daily readings (\(battery.days.count) so far)."
    }
    return LongevityArea(kind: .battery, grade: grade, summary: summary, facts: facts, estimate: estimate, advice: advice)
  }

  struct HealthTrend: Equatable { let pointsPerYear: Double; let spanDays: Int }

  /// Least-squares slope of daily health. Needs a month and five readings, because macOS
  /// recalibrates the reading by a point or two in either direction.
  static func healthTrend(_ battery: BatteryHealthSummary) -> HealthTrend? {
    let points = battery.days.compactMap { day in day.healthPercent.map { (day.day.timeIntervalSince1970 / 86_400, $0) } }
    guard points.count >= 5, let first = points.first?.0, let last = points.last?.0, last - first >= 30 else { return nil }
    guard let slope = slope(points) else { return nil }
    return HealthTrend(pointsPerYear: slope * 365, spanDays: Int((last - first).rounded()))
  }

  static func cyclesPerDay(_ battery: BatteryHealthSummary) -> Double? {
    let points = battery.days.compactMap { day in day.cycleCount.map { (day.day, $0) } }
    guard let first = points.first, let last = points.last else { return nil }
    let span = last.0.timeIntervalSince(first.0) / 86_400
    guard span >= 14, last.1 >= first.1 else { return nil }
    return Double(last.1 - first.1) / span
  }

  // MARK: - Power adapter

  static func chargerArea(days: [LongevityDayRecord], current: LongevityCurrent) -> LongevityArea {
    let lastSeen = days.last(where: { $0.adapterNegotiatedWatts != nil || $0.adapterName != nil })
    let adapter = current.adapter ?? lastSeen.map { day -> PowerAdapterDetails in
      var details = PowerAdapterDetails()
      details.name = day.adapterName
      details.ratedWatts = day.adapterRatedWatts
      details.offeredWatts = day.adapterOfferedWatts
      details.negotiatedWatts = day.adapterNegotiatedWatts
      return details
    }
    guard let adapter else {
      return LongevityArea(kind: .charger, grade: nil, summary: "Connect the power adapter and Helios checks it and its cable.")
    }
    var facts: [LongevityFact] = []
    if let name = adapter.name { facts.append(.init(label: "Adapter", value: name)) }
    if let rated = adapter.ratedWatts { facts.append(.init(label: "Rated", value: "\(rated) W")) }
    if let offered = adapter.offeredWatts {
      facts.append(.init(label: "Offered over this cable", value: "\(offered) W", detail: "Highest USB-C power offer"))
    }
    if let negotiated = adapter.negotiatedWatts {
      facts.append(.init(label: "Agreed with the Mac", value: "\(negotiated) W"))
    }
    let connected = current.adapter != nil
    let when = connected ? "" : " (last time it was connected)"
    if adapter.limitedByCable, let rated = adapter.ratedWatts, let offered = adapter.offeredWatts {
      return LongevityArea(
        kind: .charger, grade: .attention,
        summary: "The \(rated) W adapter offers only \(offered) W\(when). The cable, a hub or a dock is limiting it.",
        facts: facts,
        advice: "Use a cable rated for the adapter's full power (for over 60 W, a 5 A or 240 W USB-C cable) and connect it directly.")
    }
    if adapter.isWireless || adapter.ratedWatts == nil && adapter.offeredWatts == nil {
      return LongevityArea(kind: .charger, grade: nil,
        summary: "Helios cannot read this adapter's rating\(when).", facts: facts)
    }
    let watts = adapter.negotiatedWatts ?? adapter.offeredWatts ?? adapter.ratedWatts ?? 0
    return LongevityArea(
      kind: .charger, grade: .excellent,
      summary: "The adapter and cable deliver what the adapter is rated for\(when): \(watts) W.", facts: facts)
  }

  // MARK: - SSD

  static func storageArea(days: [LongevityDayRecord], current: LongevityCurrent) -> LongevityArea {
    var facts: [LongevityFact] = []
    let used = current.ssdPercentageUsed ?? days.last(where: { $0.ssdPercentageUsed != nil })?.ssdPercentageUsed
    let lifetime = current.ssdLifetimeWrittenBytes ?? days.last(where: { $0.ssdLifetimeWrittenBytes != nil })?.ssdLifetimeWrittenBytes
    if let used { facts.append(.init(label: "Endurance used", value: "\(used) %", detail: "The drive's own estimate of its rated write endurance")) }
    if let lifetime { facts.append(.init(label: "Written so far", value: bytes(lifetime))) }
    let pace = writesPerDay(days)
    if let pace {
      facts.append(.init(label: "Writes a day", value: bytes(pace.bytes), detail: "Average over \(pace.spanDays) days"))
      let swap = days.suffix(pace.spanDays + 1).reduce(0) { $0 + $1.swapWrittenBytes }
      if swap > 0, pace.bytes > 0 {
        facts.append(.init(label: "Of that, memory swap", value: share(swap / Double(pace.spanDays), of: pace.bytes)))
      }
    }

    var estimate: String?
    if let used, let lifetime, let pace, pace.bytes > 0 {
      if used >= 1, used < 100 {
        let perPercent = lifetime / Double(used)
        let years = Double(100 - used) * perPercent / pace.bytes / 365
        estimate = "At this pace the drive reaches its rated endurance in about \(yearsText(years)). Rough estimate: it scales from the drive's whole-percent counter, and SSDs often outlast their rating."
      } else if used == 0 {
        estimate = "Less than 1 % of the rated endurance is used, so there is no basis for a projection yet; at \(bytes(pace.bytes)) a day that is not a concern."
      }
    } else if pace == nil {
      estimate = "Daily writes need a few days of history."
    }

    guard used != nil || current.ssdCriticalWarning else {
      return LongevityArea(kind: .storage, grade: nil,
        summary: "This drive does not report its wear, so Helios can only count what is written.",
        facts: facts, estimate: estimate)
    }
    let spareLow: Bool = {
      guard let spare = current.ssdAvailableSparePercent, let threshold = current.ssdAvailableSpareThresholdPercent else { return false }
      return spare < threshold
    }()
    if current.ssdCriticalWarning || spareLow || (used ?? 0) >= 80 {
      return LongevityArea(kind: .storage, grade: .attention,
        summary: current.ssdCriticalWarning || spareLow
          ? "The drive reports a health warning. Back up now."
          : "The drive has used most of its rated write endurance. Keep backups current.",
        facts: facts, estimate: estimate, advice: "Time Machine or another backup protects you whatever the drive does next.")
    }
    let heavy = (pace?.bytes ?? 0) >= 100e9
    let grade: LongevityGrade = (used ?? 0) < 10 && !heavy ? .excellent : .good
    let summary = heavy
      ? "Healthy, but the Mac writes a lot every day (\(bytes(pace?.bytes ?? 0)))."
      : "Healthy: \(used ?? 0) % of the rated write endurance used."
    return LongevityArea(kind: .storage, grade: grade, summary: summary, facts: facts, estimate: estimate,
      advice: heavy ? "Large daily writes usually come from swap, caches or a sync app. Storage › Why? shows which." : nil)
  }

  struct WritePace: Equatable { let bytes: Double; let spanDays: Int }

  /// From the SMART lifetime counter at the end of recorded days: counts writes while
  /// Helios was closed too. Needs three days; uses the last thirty.
  static func writesPerDay(_ days: [LongevityDayRecord]) -> WritePace? {
    let points = days.suffix(31).compactMap { day in day.ssdLifetimeWrittenBytes.map { (day.day, $0) } }
    guard let first = points.first, let last = points.last else { return nil }
    let span = last.0.timeIntervalSince(first.0) / 86_400
    guard span >= 3, last.1 >= first.1 else { return nil }
    return WritePace(bytes: (last.1 - first.1) / span, spanDays: Int(span.rounded()))
  }

  // MARK: - Cooling

  struct CoolingComparison: Equatable {
    let baselineBusyCelsius: Double
    let recentBusyCelsius: Double
    let baselineIdleCelsius: Double?
    let recentIdleCelsius: Double?
    let baselineFanRPM: Double?
    let recentFanRPM: Double?
    let baselineLoad: Double
    let recentLoad: Double
  }

  static func coolingArea(days: [LongevityDayRecord], current: LongevityCurrent, calendar: Calendar) -> LongevityArea {
    guard current.thermalMapTrusted else {
      return LongevityArea(kind: .cooling, grade: nil,
        summary: "Helios compares temperatures only from sensors confirmed on this Mac. It is still confirming them.")
    }
    guard let first = days.first?.day else {
      return LongevityArea(kind: .cooling, grade: nil, summary: learningText(days: 0))
    }
    let elapsed = calendar.dateComponents([.day], from: first, to: days.last?.day ?? first).day ?? 0
    guard let comparison = coolingComparison(days, calendar: calendar) else {
      return LongevityArea(kind: .cooling, grade: nil, summary: learningText(days: elapsed + 1))
    }
    let rise = comparison.recentBusyCelsius - comparison.baselineBusyCelsius
    var facts: [LongevityFact] = [
      .init(label: "Under load, first four weeks", value: celsius(comparison.baselineBusyCelsius)),
      .init(label: "Under load, last two weeks", value: celsius(comparison.recentBusyCelsius),
        detail: String(format: "CPU %.0f %% vs %.0f %% on average", comparison.recentLoad, comparison.baselineLoad)),
    ]
    if let base = comparison.baselineIdleCelsius, let recent = comparison.recentIdleCelsius {
      facts.append(.init(label: "At rest", value: "\(celsius(recent)) (was \(celsius(base)))"))
    }
    var fanRise = 0.0
    if let base = comparison.baselineFanRPM, let recent = comparison.recentFanRPM, base > 300 {
      fanRise = (recent - base) / base
      facts.append(.init(label: "Fan under load", value: "\(Int(recent.rounded())) RPM (was \(Int(base.rounded())))"))
    }
    let caveat = "Helios cannot measure the room, so a warm season raises this too."
    if rise >= 6 || (rise >= 4 && fanRise >= 0.25) {
      return LongevityArea(kind: .cooling, grade: .attention,
        summary: String(format: "Under similar load the Mac runs %.0f °C warmer than in its first weeks.", rise),
        facts: facts, estimate: caveat,
        advice: "If the room is not warmer, dust in the vents or an obstructed airflow path is the usual cause. Keep the vents clear; a service check can clean them.")
    }
    if rise >= 3 {
      return LongevityArea(kind: .cooling, grade: .good,
        summary: String(format: "Slightly warmer under load than in its first weeks (+%.0f °C).", rise),
        facts: facts, estimate: caveat)
    }
    return LongevityArea(kind: .cooling, grade: .excellent,
      summary: "Cooling works as well as in the Mac's first weeks.", facts: facts, estimate: caveat)
  }

  /// First four weeks against the last two, both only from time under comparable load.
  static func coolingComparison(_ days: [LongevityDayRecord], calendar: Calendar) -> CoolingComparison? {
    guard let first = days.first?.day,
      let baselineEnd = calendar.date(byAdding: .day, value: coolingBaselineDays, to: first),
      let last = days.last?.day, last >= baselineEnd,
      let recentStart = calendar.date(byAdding: .day, value: -13, to: last)
    else { return nil }
    let baseline = days.filter { $0.day < baselineEnd }
    let recent = days.filter { $0.day >= max(recentStart, baselineEnd) }
    func busy(_ set: [LongevityDayRecord]) -> (celsius: Double, load: Double, seconds: Double)? {
      let seconds = set.reduce(0) { $0 + $1.busySeconds }
      guard seconds >= 3_600 else { return nil }
      return (set.reduce(0) { $0 + $1.busyCelsiusSeconds } / seconds, set.reduce(0) { $0 + $1.busyLoadSeconds } / seconds, seconds)
    }
    func idle(_ set: [LongevityDayRecord]) -> Double? {
      let seconds = set.reduce(0) { $0 + $1.idleSeconds }
      return seconds >= 3_600 ? set.reduce(0) { $0 + $1.idleCelsiusSeconds } / seconds : nil
    }
    func fan(_ set: [LongevityDayRecord]) -> Double? {
      let seconds = set.reduce(0) { $0 + $1.busyFanSeconds }
      return seconds >= 1_800 ? set.reduce(0) { $0 + $1.busyFanRPMSeconds } / seconds : nil
    }
    guard let base = busy(baseline), let now = busy(recent) else { return nil }
    // Much heavier recent load is not "the same work"; do not compare it.
    guard abs(now.load - base.load) <= 20 else { return nil }
    return CoolingComparison(
      baselineBusyCelsius: base.celsius, recentBusyCelsius: now.celsius,
      baselineIdleCelsius: idle(baseline), recentIdleCelsius: idle(recent),
      baselineFanRPM: fan(baseline), recentFanRPM: fan(recent),
      baselineLoad: base.load, recentLoad: now.load)
  }

  private static func learningText(days: Int) -> String {
    let left = max(1, coolingBaselineDays + 1 - days)
    return "Learning: Helios compares temperatures under load with this Mac's first four weeks. A first comparison in about \(left) day\(left == 1 ? "" : "s"), once it has seen the Mac busy for an hour in each period."
  }

  // MARK: - Memory

  static func memoryArea(days: [LongevityDayRecord], current: LongevityCurrent) -> LongevityArea {
    let recent = lastUseful(days, count: 7)
    guard !recent.isEmpty else {
      return LongevityArea(kind: .memory, grade: nil, summary: "Memory pressure needs a couple of hours of history.")
    }
    let count = Double(recent.count)
    let warning = recent.reduce(0) { $0 + $1.pressureWarningSeconds } / count
    let critical = recent.reduce(0) { $0 + $1.pressureCriticalSeconds } / count
    let swap = recent.reduce(0) { $0 + $1.swapWrittenBytes } / count
    var facts: [LongevityFact] = [
      .init(label: "Under memory pressure", value: "\(hours(warning + critical)) a day",
        detail: "Average of the last \(recent.count) day\(recent.count == 1 ? "" : "s")"),
      .init(label: "Swap written to the SSD", value: "\(bytes(swap)) a day"),
    ]
    if let peak = recent.compactMap(\.maximumSwapUsedBytes).max() {
      facts.append(.init(label: "Largest swap", value: bytes(Double(peak))))
    }
    let advice = "Closing apps you are not using, or fewer browser tabs, keeps more in memory. If this is your normal work, the Mac would benefit from more memory next time."
    if critical >= 900 || warning >= 2 * 3_600 || swap >= 20e9 {
      return LongevityArea(kind: .memory, grade: .attention,
        summary: "The Mac often runs short of memory and moves it to the SSD instead.", facts: facts,
        estimate: swap >= 20e9 ? "Swap adds \(bytes(swap)) of SSD writes a day." : nil, advice: advice)
    }
    if warning >= 1_200 || swap >= 5e9 {
      return LongevityArea(kind: .memory, grade: .good,
        summary: "Memory is sometimes tight; macOS handles it with some swap.", facts: facts)
    }
    return LongevityArea(kind: .memory, grade: .excellent,
      summary: "Memory is rarely tight, so the SSD sees little swap.", facts: facts)
  }

  // MARK: - Helpers

  static func lastUseful(_ days: [LongevityDayRecord], count: Int) -> [LongevityDayRecord] {
    Array(days.filter { $0.observedSeconds >= usefulDaySeconds }.suffix(count))
  }

  private static func slope(_ points: [(Double, Double)]) -> Double? {
    let n = Double(points.count)
    let meanX = points.reduce(0) { $0 + $1.0 } / n
    let meanY = points.reduce(0) { $0 + $1.1 } / n
    let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
    let denominator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
    guard denominator > 0 else { return nil }
    return numerator / denominator
  }

  static func yearsText(_ years: Double) -> String {
    guard years.isFinite else { return "many years" }
    if years >= 10 { return "more than 10 years" }
    if years >= 1.5 { return "\(Int(years.rounded())) years" }
    let months = max(1, Int((years * 12).rounded()))
    return months == 1 ? "a month" : "\(months) months"
  }

  static func percent(_ value: Double) -> String { String(format: "%.0f %%", value) }

  static func celsius(_ value: Double) -> String { TelemetryFormatting.temperature(value) }

  static func hours(_ seconds: Double) -> String {
    if seconds < 60 { return "none" }
    if seconds < 3_600 { return "\(Int((seconds / 60).rounded())) min" }
    return String(format: "%.1f h", seconds / 3_600)
  }

  static func duration(_ seconds: Double) -> String {
    seconds >= 3_600 ? String(format: "%.0f h", seconds / 3_600) : "\(max(1, Int((seconds / 60).rounded()))) min"
  }

  static func share(_ part: Double, of whole: Double) -> String {
    guard whole > 0 else { return "—" }
    return String(format: "%.0f %%", min(100, max(0, part / whole * 100)))
  }

  static func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(0, min(value, 9e18))), countStyle: .decimal)
  }

  private static func list(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
  }
}

private extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
