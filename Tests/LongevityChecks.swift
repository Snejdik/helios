import Foundation

// Longevity (PLAN_0_3_0 M5) on synthetic history: rising battery wear, a stable Mac,
// worsening cooling, a cable-limited adapter, SSD and swap projections, the store on disk,
// the report document and the reminders. Projections must call themselves estimates and
// an area without enough data must say so instead of grading.

private struct CheckFailure: Error, CustomStringConvertible { let description: String }

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CheckFailure(description: message) }
}

private let calendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
  return calendar
}()

private let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 9))!

private func day(_ offset: Int) -> Date {
  calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: start)!)
}

private func batteryDays(_ count: Int, from health: Double, to end: Double, cycles: (Int, Int) = (100, 160))
  -> BatteryHealthSummary
{
  BatteryHealthSummary(days: (0..<count).map { index in
    let fraction = count > 1 ? Double(index) / Double(count - 1) : 0
    return BatteryDayRecord(
      day: day(index), healthPercent: health + (end - health) * fraction, maximumCapacityMAh: nil,
      designCapacityMAh: nil, cycleCount: cycles.0 + Int(Double(cycles.1 - cycles.0) * fraction))
  })
}

private func usefulDay(_ offset: Int, configure: (inout LongevityDayRecord) -> Void = { _ in }) -> LongevityDayRecord {
  var record = LongevityDayRecord(day: day(offset))
  record.observedSeconds = 8 * 3_600
  configure(&record)
  return record
}

private func coolingHistory(baselineBusy: Double, recentBusy: Double, recentLoad: Double = 70, days: Int = 45)
  -> [LongevityDayRecord]
{
  (0..<days).map { index in
    usefulDay(index) { record in
      let recent = index >= days - 14
      let celsius = recent ? recentBusy : baselineBusy
      let load = recent ? recentLoad : 70
      record.busySeconds = 1_200
      record.busyCelsiusSeconds = celsius * 1_200
      record.busyLoadSeconds = load * 1_200
      record.busyFanSeconds = 1_200
      record.busyFanRPMSeconds = (recent ? 3_200 : 2_400) * 1_200
      record.idleSeconds = 3_000
      record.idleCelsiusSeconds = 42 * 3_000
    }
  }
}

private func trusted() -> LongevityCurrent {
  var current = LongevityCurrent()
  current.thermalMapTrusted = true
  current.batteryHealthPercent = 96
  current.cycleCount = 120
  return current
}

private func checkAccumulator() throws {
  var accumulator = LongevityAccumulator()
  var record = LongevityDayRecord(day: day(0))
  var sample = LongevitySample(at: start)
  sample.onAdapter = true
  sample.charging = true
  sample.chargePercent = 96
  sample.batteryCelsius = 41
  sample.memoryPressure = .warning
  sample.cpuBusyPercent = 75
  sample.trustedSoCCelsius = 80
  sample.averageFanRPM = 2_500
  sample.swapOutPages = 1_000
  sample.ssdLifetimeWrittenBytes = 1e12
  try require(accumulator.fold(sample, into: &record) == 0, "the first sample sets a baseline and adds no time")
  var next = sample
  next.at = start.addingTimeInterval(30)
  next.swapOutPages = 1_100
  try require(accumulator.fold(next, into: &record) == 30, "a 30 s step counts")
  try require(record.highChargeSeconds == 30 && record.hotChargingSeconds == 30 && record.adapterSeconds == 30,
    "full charge on the adapter and warm charging are counted")
  try require(record.pressureWarningSeconds == 30, "memory pressure time is counted")
  try require(record.swapWrittenBytes == 100 * 16_384, "swap writes come from the page counter delta")
  try require(record.busySeconds == 30 && record.busyMeanCelsius == 80 && record.busyMeanFanRPM == 2_500,
    "busy-band temperature and fan are averaged")
  var gap = next
  gap.at = next.at.addingTimeInterval(600)
  gap.swapOutPages = 50  // reboot: counter restarted
  try require(accumulator.fold(gap, into: &record) == 0, "a gap longer than 90 s (sleep, Helios closed) adds no time")
  try require(record.swapWrittenBytes == 100 * 16_384, "a restarted swap counter is a new baseline, not negative writes")
  var idle = gap
  idle.at = gap.at.addingTimeInterval(30)
  idle.cpuBusyPercent = 5
  idle.gpuBusyPercent = 2
  idle.trustedSoCCelsius = 45
  _ = accumulator.fold(idle, into: &record)
  var after = idle
  after.at = idle.at.addingTimeInterval(30)
  _ = accumulator.fold(after, into: &record)
  try require(record.idleSeconds == 30 && record.idleMeanCelsius == 45, "idle-band temperature is kept apart from busy")
  var untrusted = after
  untrusted.at = after.at.addingTimeInterval(30)
  untrusted.trustedSoCCelsius = nil
  let busyBefore = record.busySeconds + record.idleSeconds
  var next2 = untrusted
  next2.at = untrusted.at.addingTimeInterval(30)
  _ = accumulator.fold(untrusted, into: &record)
  _ = accumulator.fold(next2, into: &record)
  try require(record.busySeconds + record.idleSeconds == busyBefore + 30, "only the step that began trusted counts")
}

private func checkBattery() throws {
  // Rising wear: 100 → 94 % over 120 days.
  let wearing = batteryDays(120, from: 100, to: 94)
  var current = trusted()
  current.batteryHealthPercent = 94
  current.cycleCount = 160
  let area = LongevityEngine.batteryArea(days: [], battery: wearing, current: current, now: day(120))
  guard let trend = LongevityEngine.healthTrend(wearing) else { throw CheckFailure(description: "a 120-day trend exists") }
  try require(abs(trend.pointsPerYear - (-6 / 119 * 365)) < 0.5, "slope is points per year (\(trend.pointsPerYear))")
  try require(area.grade == .excellent, "94 % is excellent")
  try require(area.estimate?.contains("reaches 80 %") == true && area.estimate?.contains("Estimate") == true,
    "a wear projection is worded as an estimate")
  // Stable battery.
  let stable = LongevityEngine.batteryArea(days: [], battery: batteryDays(60, from: 97, to: 97), current: trusted(), now: day(60))
  try require(stable.estimate?.contains("No measurable wear") == true, "a flat trend says no measurable wear")
  // Too little history.
  let young = LongevityEngine.batteryArea(days: [], battery: batteryDays(6, from: 97, to: 96.8), current: trusted(), now: day(6))
  try require(LongevityEngine.healthTrend(batteryDays(6, from: 97, to: 96.8)) == nil, "six days are not a trend")
  try require(young.estimate?.contains("about a month") == true, "short history says how much is needed")
  // Below service level.
  var worn = trusted()
  worn.batteryHealthPercent = 76
  let old = LongevityEngine.batteryArea(days: [], battery: .empty, current: worn, now: day(0))
  try require(old.grade == .attention && old.summary.contains("80 %"), "below 80 % needs attention")
  // Habits: full on the adapter most of the day.
  let habits = (0..<7).map { index in usefulDay(index) { $0.adapterSeconds = 20 * 3_600; $0.highChargeSeconds = 14 * 3_600 } }
  var notOptimized = trusted()
  notOptimized.optimizedChargingEngaged = false
  let full = LongevityEngine.batteryArea(days: habits, battery: .empty, current: notOptimized, now: day(7))
  try require(full.advice?.contains("Optimized Battery Charging") == true, "long full-charge time suggests optimized charging")
  var optimized = notOptimized
  optimized.optimizedChargingEngaged = true
  try require(LongevityEngine.batteryArea(days: habits, battery: .empty, current: optimized, now: day(7)).advice == nil,
    "no advice when optimized charging already works")
  let warm = (0..<7).map { index in usefulDay(index) { $0.chargingSeconds = 3_600; $0.hotChargingSeconds = 1_800 } }
  try require(LongevityEngine.batteryArea(days: warm, battery: .empty, current: notOptimized, now: day(7)).advice?
    .contains("warm") == true, "charging while warm is pointed out")
  var unknown = LongevityCurrent()
  unknown.batteryHealthPercent = nil
  try require(LongevityEngine.batteryArea(days: [], battery: .empty, current: unknown, now: day(0)).grade == nil,
    "no health reading, no grade")
}

private func checkAdapter() throws {
  // The owner's M4 MacBook Pro with Apple's 70 W adapter (ioreg, 2026-10-14).
  let m4: [String: Any] = [
    "Watts": NSNumber(value: 68), "Name": "70W USB-C Power Adapter ", "IsWireless": false,
    "SerialString": "F16H91009KF000000P",
    "UsbHvcMenu": [
      ["Index": 0, "MaxCurrent": 2_960, "MaxVoltage": 5_000], ["Index": 1, "MaxCurrent": 2_970, "MaxVoltage": 9_000],
      ["Index": 2, "MaxCurrent": 2_980, "MaxVoltage": 15_000], ["Index": 3, "MaxCurrent": 3_390, "MaxVoltage": 20_000],
    ],
  ]
  guard let details = PowerAdapterParser.parse(adapterDetails: m4, chargerData: ["TimeChargingThermallyLimited": 0])
  else { throw CheckFailure(description: "the M4 adapter parses") }
  try require(details.name == "70W USB-C Power Adapter" && details.ratedWatts == 70, "name and rating from the name")
  try require(details.offeredWatts == 68 && details.negotiatedWatts == 68 && !details.limitedByCable,
    "70 W adapter offering 68 W over its cable is not cable-limited")
  try require(!String(describing: details).contains("F16H91009"), "the adapter serial is never kept")
  let area = LongevityEngine.chargerArea(days: [], current: { var c = LongevityCurrent(); c.adapter = details; return c }())
  try require(area.grade == .excellent, "a full-power adapter is excellent")
  // A 96 W adapter through a 3 A cable offers 60 W.
  let limited: [String: Any] = [
    "Watts": 60, "Name": "96W USB-C Power Adapter",
    "UsbHvcMenu": [["MaxCurrent": 3_000, "MaxVoltage": 5_000], ["MaxCurrent": 3_000, "MaxVoltage": 20_000]],
  ]
  let cable = PowerAdapterParser.parse(adapterDetails: limited, chargerData: [:])
  try require(cable?.limitedByCable == true, "96 W adapter offering 60 W is cable-limited")
  let cableArea = LongevityEngine.chargerArea(days: [], current: { var c = LongevityCurrent(); c.adapter = cable; return c }())
  try require(cableArea.grade == .attention && cableArea.advice?.contains("5 A") == true, "a limiting cable needs attention")
  try require(PowerAdapterParser.parse(adapterDetails: [:], chargerData: [:]) == nil, "no adapter, no details")
  try require(PowerAdapterParser.ratedWatts(fromName: "USB-C Power Adapter") == nil
    && PowerAdapterParser.ratedWatts(fromName: "140W USB-C") == 140, "rating only from a leading number with W")
  // Last seen on an earlier day when on battery now.
  let seen = usefulDay(3) { $0.adapterName = "30W USB-C Power Adapter"; $0.adapterRatedWatts = 30; $0.adapterOfferedWatts = 30; $0.adapterNegotiatedWatts = 30 }
  let remembered = LongevityEngine.chargerArea(days: [seen], current: LongevityCurrent())
  try require(remembered.summary.contains("last time"), "an adapter seen earlier is reported as such")
  try require(LongevityEngine.chargerArea(days: [], current: LongevityCurrent()).grade == nil, "never seen, no grade")
}

private func checkStorage() throws {
  let days = (0..<31).map { index in
    usefulDay(index) { $0.ssdLifetimeWrittenBytes = 20e12 + Double(index) * 50e9; $0.ssdPercentageUsed = 2; $0.swapWrittenBytes = 5e9 }
  }
  var current = LongevityCurrent()
  current.ssdPercentageUsed = 2
  current.ssdLifetimeWrittenBytes = 21.5e12
  let pace = LongevityEngine.writesPerDay(days)
  try require(pace.map { abs($0.bytes - 50e9) < 1 } == true && pace?.spanDays == 30, "writes a day from the lifetime counter")
  let area = LongevityEngine.storageArea(days: days, current: current)
  try require(area.grade == .excellent, "2 % used at 50 GB a day is excellent")
  try require(area.estimate?.contains("Rough estimate") == true, "the endurance projection is a rough estimate")
  try require(area.facts.contains { $0.label == "Of that, memory swap" }, "swap's share of the writes is shown")
  current.ssdPercentageUsed = 0
  try require(LongevityEngine.storageArea(days: days, current: current).estimate?.contains("no basis for a projection") == true,
    "0 % used gives no projection")
  current.ssdPercentageUsed = 85
  try require(LongevityEngine.storageArea(days: days, current: current).grade == .attention, "85 % used needs attention")
  current.ssdPercentageUsed = 3
  current.ssdCriticalWarning = true
  try require(LongevityEngine.storageArea(days: days, current: current).summary.contains("Back up"), "a SMART warning says back up")
  let heavy = (0..<10).map { index in usefulDay(index) { $0.ssdLifetimeWrittenBytes = Double(index) * 150e9 } }
  var heavyCurrent = LongevityCurrent()
  heavyCurrent.ssdPercentageUsed = 1
  let heavyArea = LongevityEngine.storageArea(days: heavy, current: heavyCurrent)
  try require(heavyArea.grade == .good && heavyArea.advice != nil, "150 GB a day is good with advice")
  let noWear = LongevityEngine.storageArea(days: [usefulDay(0)], current: LongevityCurrent())
  try require(noWear.grade == nil && noWear.estimate?.contains("few days") == true, "no SMART and no history: no grade")
}

private func checkCooling() throws {
  let healthy = LongevityEngine.coolingArea(days: coolingHistory(baselineBusy: 72, recentBusy: 73), current: trusted(), calendar: calendar)
  try require(healthy.grade == .excellent, "same temperature under the same load is excellent")
  try require(healthy.estimate?.contains("cannot measure the room") == true, "cooling always says the room is unknown")
  let worse = LongevityEngine.coolingArea(days: coolingHistory(baselineBusy: 72, recentBusy: 80), current: trusted(), calendar: calendar)
  try require(worse.grade == .attention && worse.advice?.contains("dust") == true, "+8 °C under similar load needs attention")
  let slight = LongevityEngine.coolingArea(days: coolingHistory(baselineBusy: 72, recentBusy: 75.5), current: trusted(), calendar: calendar)
  try require(slight.grade == .good, "+3.5 °C is good")
  let fanAssisted = LongevityEngine.coolingArea(days: coolingHistory(baselineBusy: 72, recentBusy: 76.5), current: trusted(), calendar: calendar)
  try require(fanAssisted.grade == .attention, "+4.5 °C with the fan 33 % faster needs attention")
  let heavier = LongevityEngine.coolingArea(
    days: coolingHistory(baselineBusy: 72, recentBusy: 85, recentLoad: 98), current: trusted(), calendar: calendar)
  try require(heavier.grade == nil, "much heavier recent load is not compared")
  let learning = LongevityEngine.coolingArea(days: coolingHistory(baselineBusy: 72, recentBusy: 72, days: 10), current: trusted(), calendar: calendar)
  try require(learning.grade == nil && learning.summary.hasPrefix("Learning"), "under four weeks is learning")
  var untrusted = trusted()
  untrusted.thermalMapTrusted = false
  try require(LongevityEngine.coolingArea(days: coolingHistory(baselineBusy: 72, recentBusy: 90), current: untrusted, calendar: calendar)
    .grade == nil, "an unconfirmed sensor map is never graded")
}

private func checkMemory() throws {
  let calm = (0..<7).map { index in usefulDay(index) { $0.swapWrittenBytes = 0.2e9 } }
  try require(LongevityEngine.memoryArea(days: calm, current: LongevityCurrent()).grade == .excellent, "calm memory is excellent")
  let tight = (0..<7).map { index in usefulDay(index) { $0.pressureWarningSeconds = 3 * 3_600; $0.swapWrittenBytes = 25e9 } }
  let area = LongevityEngine.memoryArea(days: tight, current: LongevityCurrent())
  try require(area.grade == .attention && area.estimate?.contains("SSD writes") == true, "swap-heavy days need attention")
  try require(LongevityEngine.memoryArea(days: [], current: LongevityCurrent()).grade == nil, "no history, no grade")
  let short = [LongevityDayRecord(day: day(0))]
  try require(LongevityEngine.memoryArea(days: short, current: LongevityCurrent()).grade == nil, "a barely watched day is not used")
}

private func checkReport() throws {
  var current = trusted()
  current.ssdPercentageUsed = 1
  var history = coolingHistory(baselineBusy: 72, recentBusy: 81)
  history[history.count - 1].ssdLifetimeWrittenBytes = 1e12
  let report = LongevityEngine.report(days: history, battery: batteryDays(45, from: 99, to: 98), current: current, now: day(45), calendar: calendar)
  try require(report.overall == .attention && report.overallSummary.contains("Cooling needs attention"), "overall is the worst area")
  try require(report.areas.allSatisfy { $0.grade != nil || !$0.summary.isEmpty }, "every area says something")
  var noBattery = LongevityCurrent()
  noBattery.hasBattery = false
  let desktop = LongevityEngine.report(days: [], battery: .empty, current: noBattery, now: day(0), calendar: calendar)
  try require(desktop.area(.battery) == nil && desktop.area(.charger) == nil, "a Mac without a battery has no battery areas")
  try require(desktop.overall == nil && desktop.overallSummary.contains("still learning"), "no data says Helios is learning")
  // The document escapes everything it did not write.
  var hostile = LongevityCurrent()
  var adapter = PowerAdapterDetails()
  adapter.name = "<script>alert(1)</script>"
  adapter.ratedWatts = 96
  adapter.offeredWatts = 60
  hostile.adapter = adapter
  let html = LongevityReportDocument.html(
    LongevityEngine.report(days: [], battery: .empty, current: hostile, now: day(0), calendar: calendar),
    machine: "Mac16,1 & co", period: DateInterval(start: day(0), end: day(7)))
  try require(!html.contains("<script>") && html.contains("&lt;script&gt;") && html.contains("Mac16,1 &amp; co"),
    "the report escapes adapter names and the machine line")
  try require(html.contains("Projections are estimates"), "the report says projections are estimates")
}

private func checkReminders() throws {
  var reminders = LongevityReminders()
  let t = start
  try require(!reminders.shouldRemindToUnplug(chargePercent: 78, charging: true, onAdapter: true, now: t), "below 80 %: nothing")
  try require(reminders.shouldRemindToUnplug(chargePercent: 80, charging: true, onAdapter: true, now: t.addingTimeInterval(60)),
    "crossing 80 % while charging reminds once")
  try require(!reminders.shouldRemindToUnplug(chargePercent: 81, charging: true, onAdapter: true, now: t.addingTimeInterval(120)),
    "staying above 80 % does not repeat")
  _ = reminders.shouldRemindToUnplug(chargePercent: 70, charging: false, onAdapter: false, now: t.addingTimeInterval(3_600))
  _ = reminders.shouldRemindToUnplug(chargePercent: 79, charging: true, onAdapter: true, now: t.addingTimeInterval(3_700))
  try require(!reminders.shouldRemindToUnplug(chargePercent: 80, charging: true, onAdapter: true, now: t.addingTimeInterval(3_760)),
    "a second crossing within six hours is quiet")
  var fresh = LongevityReminders()
  try require(!fresh.shouldRemindToUnplug(chargePercent: 85, charging: true, onAdapter: true, now: t),
    "plugging in above 80 % is not a crossing")
  try require(LongevityReminders.weeklySummaryDue(last: t, now: t.addingTimeInterval(7 * 86_400))
    && !LongevityReminders.weeklySummaryDue(last: t, now: t.addingTimeInterval(6 * 86_400)), "weekly means seven days")
}

private func checkStore() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("helios-longevity-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("longevity-v1.ndjson")
  let store = LongevityHistoryStore(url: url, calendar: calendar)
  var sample = LongevitySample(at: start)
  sample.onAdapter = true
  sample.chargePercent = 99
  for step in 0..<40 {
    sample.at = start.addingTimeInterval(Double(step) * 30)
    _ = await store.record(sample)
  }
  // Next day.
  sample.at = calendar.date(byAdding: .day, value: 1, to: start)!
  let days = await store.record(sample)
  try require(days.count == 2 && abs(days[0].highChargeSeconds - 39 * 30) < 0.001, "two days, the first with 19.5 min at full charge")
  await store.flush()
  let reloaded = await LongevityHistoryStore(url: url, calendar: calendar).current(now: sample.at)
  try require(reloaded.count == 2 && reloaded[0].highChargeSeconds == days[0].highChargeSeconds,
    "a reloaded store keeps the finished day (later lines win)")
  let raw = try String(contentsOf: url, encoding: .utf8)
  try require(!raw.contains("Serial") && raw.split(separator: "\n").count <= 4, "few lines, nothing identifying")
  let future = LongevityHistory.sanitized([LongevityDayRecord(day: day(400))], now: day(0))
  try require(future.isEmpty, "records from the future are dropped")
}

@main
struct LongevityChecks {
  static func main() async {
    do {
      try checkAccumulator()
      try checkBattery()
      try checkAdapter()
      try checkStorage()
      try checkCooling()
      try checkMemory()
      try checkReport()
      try checkReminders()
      try await checkStore()
      print("PASS longevity: accumulator, battery wear trend and habits, adapter and cable, SSD endurance, cooling vs. own baseline, memory/swap, word grades, report document, reminders, store")
    } catch {
      print("FAIL \(error)")
      exit(1)
    }
  }
}
