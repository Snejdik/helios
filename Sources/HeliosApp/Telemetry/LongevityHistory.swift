import Foundation

// Longevity (PLAN_0_3_0 M5): one record a day of the habits and conditions that wear a
// Mac out over months, so a single reading is never mistaken for a trend. Everything is
// kept on this Mac and never sent.

/// What one 30-second look at the telemetry contributes to the day. Pure input, built from
/// a snapshot by `LongevitySample.init(snapshot:…)` and directly by the checks.
struct LongevitySample: Sendable, Equatable {
  var at: Date
  var cpuBusyPercent: Double?
  var gpuBusyPercent: Double?
  /// Hottest reading whose sensor map is trusted on this Mac; nil when none is.
  var trustedSoCCelsius: Double?
  var averageFanRPM: Double?
  var onAdapter: Bool?
  var charging: Bool?
  var chargePercent: Double?
  var batteryCelsius: Double?
  var memoryPressure: MemoryPressure?
  var swapUsedBytes: UInt64?
  /// Cumulative pages swapped out since boot.
  var swapOutPages: UInt64?
  var pageSizeBytes: UInt64 = 16_384
  /// SSD lifetime host writes (SMART); survives reboots.
  var ssdLifetimeWrittenBytes: Double?
  var ssdPercentageUsed: Int?
  var ssdAvailableSparePercent: Int?
  var adapter: PowerAdapterDetails?

  init(at: Date) { self.at = at }
}

/// One local day. Durations are seconds Helios actually observed, so a day the Mac spent
/// asleep or with Helios closed is short rather than wrong.
struct LongevityDayRecord: Codable, Sendable, Equatable, Identifiable {
  let day: Date
  var observedSeconds: Double = 0

  // Battery habits
  var adapterSeconds: Double = 0
  /// On the adapter at 95 % or more: the state that ages a lithium battery fastest.
  var highChargeSeconds: Double = 0
  var chargingSeconds: Double = 0
  /// Charging while the battery was at 40 °C or warmer.
  var hotChargingSeconds: Double = 0
  var maximumBatteryCelsius: Double?

  // Power adapter, last seen this day
  var adapterName: String?
  var adapterRatedWatts: Int?
  var adapterOfferedWatts: Int?
  var adapterNegotiatedWatts: Int?

  // SSD
  /// Lifetime counter at the last sample of the day.
  var ssdLifetimeWrittenBytes: Double?
  var ssdPercentageUsed: Int?
  var ssdAvailableSparePercent: Int?

  // Memory
  var pressureWarningSeconds: Double = 0
  var pressureCriticalSeconds: Double = 0
  var swapWrittenBytes: Double = 0
  var maximumSwapUsedBytes: UInt64?

  // Cooling: temperature in two load bands, so days compare like with like.
  var idleSeconds: Double = 0
  var idleCelsiusSeconds: Double = 0
  var busySeconds: Double = 0
  var busyCelsiusSeconds: Double = 0
  var busyLoadSeconds: Double = 0
  var busyFanSeconds: Double = 0
  var busyFanRPMSeconds: Double = 0

  var id: Date { day }

  init(day: Date) { self.day = day }

  var idleMeanCelsius: Double? { idleSeconds > 0 ? idleCelsiusSeconds / idleSeconds : nil }
  var busyMeanCelsius: Double? { busySeconds > 0 ? busyCelsiusSeconds / busySeconds : nil }
  var busyMeanFanRPM: Double? { busyFanSeconds > 0 ? busyFanRPMSeconds / busyFanSeconds : nil }
}

/// Folds samples into day records. Keeps the previous sample only in memory, so the first
/// sample after a launch, a sleep or a gap sets a new baseline and adds no time.
struct LongevityAccumulator: Sendable {
  /// Two missed 30-second looks: anything longer was sleep or Helios not running.
  static let maximumStep: TimeInterval = 90
  static let busyLoadPercent = 50.0
  static let idleLoadPercent = 10.0
  static let highChargePercent = 95.0
  static let hotChargingCelsius = 40.0

  private var previous: LongevitySample?

  init() {}

  /// Adds `sample` to `day` (the record for the sample's own day). Returns the seconds counted.
  @discardableResult
  mutating func fold(_ sample: LongevitySample, into day: inout LongevityDayRecord) -> TimeInterval {
    defer { previous = sample }
    // Readings that do not depend on elapsed time.
    if let adapter = sample.adapter, sample.onAdapter == true {
      day.adapterName = adapter.name
      day.adapterRatedWatts = adapter.ratedWatts
      day.adapterOfferedWatts = adapter.offeredWatts
      day.adapterNegotiatedWatts = adapter.negotiatedWatts
    }
    if let written = sample.ssdLifetimeWrittenBytes, written.isFinite, written >= 0 {
      day.ssdLifetimeWrittenBytes = written
    }
    if let used = sample.ssdPercentageUsed { day.ssdPercentageUsed = used }
    if let spare = sample.ssdAvailableSparePercent { day.ssdAvailableSparePercent = spare }
    if let swap = sample.swapUsedBytes { day.maximumSwapUsedBytes = max(day.maximumSwapUsedBytes ?? 0, swap) }
    if let celsius = sample.batteryCelsius, celsius.isFinite, (-20...90).contains(celsius) {
      day.maximumBatteryCelsius = max(day.maximumBatteryCelsius ?? celsius, celsius)
    }

    guard let previous else { return 0 }
    // Swap counters reset at boot; a smaller value is a new baseline, not negative writes.
    if let now = sample.swapOutPages, let before = previous.swapOutPages, now > before {
      day.swapWrittenBytes += Double(now - before) * Double(sample.pageSizeBytes)
    }
    let step = sample.at.timeIntervalSince(previous.at)
    guard step > 0, step <= Self.maximumStep else { return 0 }
    // The state held since the previous look is the one that look saw.
    let state = previous
    day.observedSeconds += step
    if state.onAdapter == true {
      day.adapterSeconds += step
      if let charge = state.chargePercent, charge >= Self.highChargePercent { day.highChargeSeconds += step }
    }
    if state.charging == true {
      day.chargingSeconds += step
      if let celsius = state.batteryCelsius, celsius >= Self.hotChargingCelsius { day.hotChargingSeconds += step }
    }
    switch state.memoryPressure {
    case .warning: day.pressureWarningSeconds += step
    case .critical: day.pressureCriticalSeconds += step
    default: break
    }
    if let celsius = state.trustedSoCCelsius, celsius.isFinite, (10...120).contains(celsius),
      let cpu = state.cpuBusyPercent
    {
      let gpu = state.gpuBusyPercent ?? 0
      if cpu >= Self.busyLoadPercent {
        day.busySeconds += step
        day.busyCelsiusSeconds += celsius * step
        day.busyLoadSeconds += cpu * step
        if let rpm = state.averageFanRPM, rpm.isFinite, rpm >= 0 {
          day.busyFanSeconds += step
          day.busyFanRPMSeconds += rpm * step
        }
      } else if cpu < Self.idleLoadPercent, gpu < Self.idleLoadPercent {
        day.idleSeconds += step
        day.idleCelsiusSeconds += celsius * step
      }
    }
    return step
  }
}

enum LongevityHistory {
  /// More than a year, so a battery or SSD trend spans the seasons. ~1 KB a day.
  static let retentionDays = 400

  /// Folds a new day record into the list: the same day replaces, a later day appends,
  /// an earlier one (clock rollback) is ignored.
  static func merged(_ days: [LongevityDayRecord], with record: LongevityDayRecord) -> [LongevityDayRecord] {
    var result = days
    if let last = result.last {
      if record.day < last.day { return result }
      if record.day == last.day { result[result.count - 1] = record } else { result.append(record) }
    } else {
      result.append(record)
    }
    if result.count > retentionDays { result.removeFirst(result.count - retentionDays) }
    return result
  }

  /// Loaded lines: later lines for the same day win; order, bounds and the future are enforced.
  static func sanitized(_ days: [LongevityDayRecord], now: Date) -> [LongevityDayRecord] {
    var byDay: [Date: LongevityDayRecord] = [:]
    for day in days where day.day <= now.addingTimeInterval(86_400) && day.observedSeconds >= 0
      && day.observedSeconds <= 90_000
    {
      byDay[day.day] = day
    }
    return Array(byDay.values.sorted { $0.day < $1.day }.suffix(retentionDays))
  }
}

/// Append-only daily longevity record, like the battery-health file: the current day is
/// written again at most every ten minutes (later lines win) and compacted now and then.
actor LongevityHistoryStore {
  static let persistInterval: TimeInterval = 600

  private let url: URL
  private let calendar: Calendar
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var days: [LongevityDayRecord]?
  private var accumulator = LongevityAccumulator()
  private var lastPersisted = Date.distantPast
  private var dirty = false
  private var rawLineCount = 0

  init(url: URL = LongevityHistoryStore.defaultURL(), calendar: Calendar = .current) {
    self.url = url
    self.calendar = calendar
    encoder = JSONEncoder(); decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    decoder.dateDecodingStrategy = .millisecondsSince1970
  }

  static func defaultURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("longevity-v1.ndjson")
  }

  func current(now: Date = Date()) -> [LongevityDayRecord] { loadIfNeeded(now: now) }

  func record(_ sample: LongevitySample) -> [LongevityDayRecord] {
    var loaded = loadIfNeeded(now: sample.at)
    let dayStart = calendar.startOfDay(for: sample.at)
    var today: LongevityDayRecord
    if let last = loaded.last, last.day == dayStart {
      today = last
    } else if let last = loaded.last, last.day > dayStart {
      return loaded  // clock moved back past a stored day
    } else {
      if dirty, let last = loaded.last { appendLine(last) }  // finish yesterday on disk
      today = LongevityDayRecord(day: dayStart)
    }
    accumulator.fold(sample, into: &today)
    loaded = LongevityHistory.merged(loaded, with: today)
    days = loaded
    dirty = true
    let elapsed = sample.at.timeIntervalSince(lastPersisted)
    if elapsed < 0 || elapsed >= Self.persistInterval {
      appendLine(today)
      lastPersisted = sample.at
    }
    return loaded
  }

  /// Writes the current day now (on quit).
  func flush() {
    guard dirty, let last = days?.last else { return }
    appendLine(last)
  }

  private func loadIfNeeded(now: Date) -> [LongevityDayRecord] {
    if let days { return days }
    let data = HistoryCompactionPolicy.read(url)
    var decoded: [LongevityDayRecord] = []
    for line in data.split(separator: 0x0A) where !line.isEmpty {
      if let record = try? decoder.decode(LongevityDayRecord.self, from: Data(line)) { decoded.append(record) }
    }
    rawLineCount = decoded.count
    let clean = LongevityHistory.sanitized(decoded, now: now)
    days = clean
    if decoded.count > clean.count + 200 || (!data.isEmpty && data.last != 0x0A) { rewrite(clean) }
    return clean
  }

  private func appendLine(_ record: LongevityDayRecord) {
    dirty = false
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      var data = try encoder.encode(record); data.append(0x0A)
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } else {
        try data.write(to: url, options: .atomic)
      }
      rawLineCount += 1
      if rawLineCount > (days?.count ?? 0) + 200, let days { rewrite(days) }
    } catch {
      // Observability only: a write failure never affects telemetry.
    }
  }

  private func rewrite(_ records: [LongevityDayRecord]) {
    if (try? HistoryCompactionPolicy.writeLines(records, encoder: encoder, to: url)) != nil {
      rawLineCount = records.count
    }
  }
}

extension LongevitySample {
  /// The parts of a live snapshot longevity cares about. Stale readings are left out.
  init(snapshot: TelemetrySnapshot, adapter: PowerAdapterDetails?, pageSizeBytes: UInt64, now: Date) {
    self.init(at: now)
    self.pageSizeBytes = pageSizeBytes
    if case .success(let cpu) = TelemetryFormatting.fresh(snapshot.cpu, maxAge: 10, now: now) {
      cpuBusyPercent = max(0, min(100, cpu.usagePercent))
    }
    if case .success(let gpu) = TelemetryFormatting.fresh(snapshot.gpu, maxAge: 10, now: now) {
      gpuBusyPercent = try? gpu.deviceUtilizationPercent.get()
    }
    if case .success(let thermals) = TelemetryFormatting.fresh(snapshot.thermals, maxAge: 10, now: now) {
      trustedSoCCelsius = try? thermals.alertMaximumSoCCelsius.get()
    }
    if case .success(let fans) = TelemetryFormatting.fresh(snapshot.fans, maxAge: 10, now: now) {
      let rpms = fans.fans.compactMap { try? $0.actualRPM.get() }.filter { $0.isFinite && $0 >= 0 }
      if !rpms.isEmpty { averageFanRPM = rpms.reduce(0, +) / Double(rpms.count) }
    }
    if case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 40, now: now) {
      if case .success(let source) = battery.powerSource { onAdapter = source == .powerAdapter }
      charging = try? battery.isCharging.get()
      chargePercent = try? battery.stateOfChargePercent.get()
      batteryCelsius = try? battery.temperatureCelsius.get()
    }
    if case .success(let memory) = TelemetryFormatting.fresh(snapshot.memory, maxAge: 10, now: now) {
      memoryPressure = try? memory.pressure.get()
      swapUsedBytes = try? memory.swapUsedBytes.get()
      swapOutPages = memory.swapOuts
    }
    if case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 120, now: now),
      case .success(let smart) = storage.smartHealth
    {
      ssdLifetimeWrittenBytes = smart.lifetimeWrittenBytes
      ssdPercentageUsed = Int(smart.percentageUsed)
      ssdAvailableSparePercent = Int(smart.availableSparePercent)
    }
    self.adapter = onAdapter == true ? adapter : nil
  }
}

/// Optional, off-by-default nudges. Advice only: Helios never changes how the Mac charges.
struct LongevityReminders: Sendable {
  static let unplugPercent = 80.0
  static let unplugCooldown: TimeInterval = 6 * 3_600
  static let weeklyInterval: TimeInterval = 7 * 86_400

  private var previousCharge: Double?
  private(set) var lastUnplugReminder: Date?

  init(lastUnplugReminder: Date? = nil) { self.lastUnplugReminder = lastUnplugReminder }

  /// True once when a charge on the adapter crosses 80 % from below, at most every six hours.
  mutating func shouldRemindToUnplug(chargePercent: Double?, charging: Bool?, onAdapter: Bool?, now: Date) -> Bool {
    let before = previousCharge
    previousCharge = onAdapter == true && charging == true ? chargePercent : nil
    guard onAdapter == true, charging == true, let charge = chargePercent, let before,
      before < Self.unplugPercent, charge >= Self.unplugPercent
    else { return false }
    if let last = lastUnplugReminder, now >= last, now.timeIntervalSince(last) < Self.unplugCooldown { return false }
    lastUnplugReminder = now
    return true
  }

  /// The weekly summary is due a week after the last one (or after it was switched on).
  static func weeklySummaryDue(last: Date, now: Date) -> Bool {
    now.timeIntervalSince(last) >= weeklyInterval
  }
}

extension LongevityCurrent {
  /// Live values for the assessment. `hasBattery` comes from the caller, which knows
  /// whether the Mac has no battery or the reading is merely missing.
  init(snapshot: TelemetrySnapshot, adapter: PowerAdapterDetails?, hasBattery: Bool, now: Date) {
    self.init()
    self.hasBattery = hasBattery
    self.adapter = adapter
    if case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 60, now: now) {
      batteryHealthPercent = try? battery.healthPercent.get()
      cycleCount = try? battery.cycleCount.get()
      optimizedChargingEngaged = try? battery.optimizedChargingEngaged.get()
      if case .success(.battery) = battery.powerSource { self.adapter = nil }
    }
    if case .success(let storage) = TelemetryFormatting.fresh(snapshot.storage, maxAge: 300, now: now),
      case .success(let smart) = storage.smartHealth
    {
      ssdPercentageUsed = Int(smart.percentageUsed)
      ssdAvailableSparePercent = Int(smart.availableSparePercent)
      ssdAvailableSpareThresholdPercent = Int(smart.availableSpareThresholdPercent)
      ssdCriticalWarning = smart.criticalWarning != 0
      ssdLifetimeWrittenBytes = smart.lifetimeWrittenBytes
    }
    if case .success(let memory) = snapshot.memory.result { physicalMemoryBytes = memory.physicalBytes }
    if case .success(let thermals) = TelemetryFormatting.fresh(snapshot.thermals, maxAge: 30, now: now) {
      thermalMapTrusted = (try? thermals.alertMaximumSoCCelsius.get()) != nil
    }
    if case .success(let fans) = snapshot.fans.result { hasFans = !fans.fans.isEmpty }
  }
}
