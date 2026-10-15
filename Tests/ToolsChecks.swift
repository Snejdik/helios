import Foundation

// Tools (PLAN_0_3_0 M6): Keep Awake policy, the helios:// URL scheme, "if → then" rules
// and "tell me when it's done" watchers. Pure values only.

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CheckFailure(description: message) }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func keepAwakeChecks() throws {
  let timed = HeliosKeepAwakeRequest.forDuration(3_600, from: t0)
  let calm = HeliosKeepAwakeConditions(now: t0.addingTimeInterval(60), onBattery: false, chargePercent: 80, thermalState: .nominal)
  try require(HeliosKeepAwakePolicy.decision(timed, calm) == .hold, "holds within its time")
  var late = calm; late.now = t0.addingTimeInterval(3_601)
  try require(HeliosKeepAwakePolicy.decision(timed, late) != .hold, "ends at its time")
  var low = calm; low.onBattery = true; low.chargePercent = 9
  try require(HeliosKeepAwakePolicy.decision(timed, low) != .hold, "low battery stops it")
  var lowOnAdapter = low; lowOnAdapter.onBattery = false
  try require(HeliosKeepAwakePolicy.decision(timed, lowOnAdapter) == .hold, "low charge on the adapter is fine")
  var hot = calm; hot.thermalState = .critical
  try require(HeliosKeepAwakePolicy.decision(timed, hot) != .hold, "critical heat stops it")
  let app = HeliosKeepAwakeRequest(until: .appQuits(bundleID: "com.example.render", name: "Render"), keepDisplayOn: false, startedAt: t0)
  var running = calm; running.runningBundleIDs = ["com.example.render"]
  try require(HeliosKeepAwakePolicy.decision(app, running) == .hold, "holds while the app runs")
  try require(HeliosKeepAwakePolicy.decision(app, calm) == .release("Keep Awake ended because Render quit."), "ends when it quits")
  let power = HeliosKeepAwakeRequest(until: .onPowerAdapter, keepDisplayOn: true, startedAt: t0)
  var battery = calm; battery.onBattery = true
  try require(HeliosKeepAwakePolicy.decision(power, calm) == .hold && HeliosKeepAwakePolicy.decision(power, battery) != .hold,
              "power-adapter mode follows the power source")
  let forever = HeliosKeepAwakeRequest(until: .stopped, keepDisplayOn: false, startedAt: t0)
  var unknown = HeliosKeepAwakeConditions(now: t0.addingTimeInterval(86_400))
  unknown.thermalState = nil
  try require(HeliosKeepAwakePolicy.decision(forever, unknown) == .hold, "unknown inputs do not stop it")
  try require(HeliosKeepAwakePolicy.remaining(timed, now: t0.addingTimeInterval(600)) == 3_000, "remaining time")
  try require(power.summary.contains("Mac and display"), "summary names the display")
  print("PASS Keep Awake: timer, app, power adapter, until stopped; stops on low battery and critical heat")
}

private func urlChecks() throws {
  func parse(_ text: String) -> HeliosURLCommand? { URL(string: text).flatMap(HeliosURLCommand.parse) }
  try require(parse("helios://open/thermals") == .openPage("thermals"), "open page")
  try require(parse("helios://why/slowMac") == .ask(.slowMac), "ask a lens")
  try require(parse("helios://keep-awake?minutes=30") == .keepAwake(minutes: 30), "keep awake minutes")
  try require(parse("helios://keep-awake") == .keepAwake(minutes: 60), "default hour")
  try require(parse("helios://keep-awake/stop") == .stopKeepAwake, "stop")
  try require(parse("helios://network-check") == .networkCheck, "network check")
  try require(parse("helios://fans/system") == .fansToSystem, "fans back to macOS")
  for bad in ["helios://fans/boost", "helios://fans/manual?rpm=6000", "helios://fans/auto", "helios://open/../../etc",
              "helios://keep-awake?minutes=99999", "https://open/thermals", "helios://quit/1", "helios://open/nope"] {
    try require(parse(bad) == nil, "rejected: \(bad)")
  }
  print("PASS helios:// URL scheme: harmless commands only; a link can never take the fans or quit apps")
}

private func ruleChecks() throws {
  var engine = HeliosRuleEngine()
  let hot = HeliosRule(trigger: .temperatureAbove(85), action: .notify("Hot"))
  let plug = HeliosRule(trigger: .powerSourceIs(battery: true), action: .keepAwake(minutes: 30))
  func inputs(_ seconds: Double, temp: Double? = 60, battery: Bool? = false) -> HeliosRuleInputs {
    HeliosRuleInputs(now: t0.addingTimeInterval(seconds), hottestCelsius: temp, batteryPercent: 50, onBattery: battery)
  }
  try require(engine.evaluate([hot, plug], inputs(0, temp: 90)).isEmpty, "the first observation is never an edge")
  try require(engine.evaluate([hot], inputs(1, temp: 70)).isEmpty, "falling below is not a firing")
  try require(engine.evaluate([hot], inputs(2, temp: 90)) == [hot], "rising above fires")
  try require(engine.evaluate([hot], inputs(3, temp: 92)).isEmpty, "staying above does not fire again")
  _ = engine.evaluate([hot], inputs(4, temp: 70))
  try require(engine.evaluate([hot], inputs(5, temp: 90)).isEmpty, "rate limit: one firing per minute")
  _ = engine.evaluate([hot], inputs(100, temp: 70))
  try require(engine.evaluate([hot], inputs(130, temp: 90)) == [hot], "fires again after the interval")
  try require(engine.evaluate([hot], inputs(140, temp: nil)).isEmpty, "unknown input never fires")
  try require(engine.evaluate([plug], inputs(150, battery: true)) == [plug], "power source change fires")

  // Loop protection: at most 30 firings per hour across all rules.
  var looping = HeliosRuleEngine()
  let rules = (0..<20).map { HeliosRule(trigger: .cpuAbove(Double(10 + $0)), action: .runShortcut("x\($0)")) }
  var fired = 0
  for step in 0..<200 {
    let busy = step % 2 == 0 ? 5.0 : 95.0
    fired += looping.evaluate(rules, HeliosRuleInputs(now: t0.addingTimeInterval(Double(step) * 61), cpuBusyPercent: busy)).count
    if step == 58 { try require(fired <= HeliosRuleEngine.maximumFiringsPerHour, "hourly cap holds: \(fired)") }
  }
  try require(fired > HeliosRuleEngine.maximumFiringsPerHour, "the cap is per hour, not forever")

  // Time of day fires once at that minute.
  var clock = HeliosRuleEngine()
  var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let at = HeliosRule(trigger: .timeOfDay(hour: 8, minute: 0), action: .stopKeepAwake)
  let morning = calendar.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: 7, minute: 59))!
  _ = clock.evaluate([at], HeliosRuleInputs(now: morning, calendar: calendar))
  try require(clock.evaluate([at], HeliosRuleInputs(now: morning.addingTimeInterval(60), calendar: calendar)) == [at], "08:00 fires")

  // Validation and persistence.
  try require(!HeliosRuleStore.valid(HeliosRule(trigger: .temperatureAbove(500), action: .notify("x"))), "absurd threshold rejected")
  try require(!HeliosRuleStore.valid(HeliosRule(trigger: .cpuAbove(50), action: .runShortcut(""))), "empty Shortcut rejected")
  try require(!HeliosRuleStore.valid(HeliosRule(trigger: .cpuAbove(50), action: .keepAwake(minutes: 0))), "zero minutes rejected")
  let defaults = UserDefaults(suiteName: "HeliosToolsChecks-\(UUID().uuidString)")!
  HeliosRuleStore.save([hot, plug, HeliosRule(trigger: .batteryBelow(0), action: .notify("bad"))], defaults)
  try require(HeliosRuleStore.load(defaults) == [hot, plug], "round trip keeps only valid rules")
  defaults.set(Data("{\"version\":99,\"rules\":[]}".utf8), forKey: HeliosRuleStore.defaultsKey)
  try require(HeliosRuleStore.load(defaults).isEmpty, "unknown schema version is ignored")
  print("PASS rules: edge-triggered, per-rule interval, hourly loop cap, unknown inputs never fire, validated and versioned")
}

private func doneChecks() throws {
  var process = HeliosDoneWatch(kind: .processExits(pid: 42, name: "ffmpeg"), startedAt: t0)
  var result = HeliosDoneWatcher.step(process, HeliosDoneInputs(now: t0, runningPIDs: [42]))
  try require(result.1 == nil, "still running")
  result = HeliosDoneWatcher.step(process, HeliosDoneInputs(now: t0, runningPIDs: nil))
  try require(result.1 == nil, "unknown process list is not an exit")
  result = HeliosDoneWatcher.step(process, HeliosDoneInputs(now: t0, runningPIDs: [7]))
  try require(result.1 == "ffmpeg has finished.", "exit noticed")

  var cpu = HeliosDoneWatch(kind: .cpuCalms, startedAt: t0)
  for second in stride(from: 0.0, through: 29, by: 1) {
    (cpu, _) = HeliosDoneWatcher.step(cpu, HeliosDoneInputs(now: t0.addingTimeInterval(second), cpuBusyPercent: 10))
  }
  (cpu, _) = HeliosDoneWatcher.step(cpu, HeliosDoneInputs(now: t0.addingTimeInterval(29.5), cpuBusyPercent: 80))
  try require(cpu.quietSince == nil, "a busy moment restarts the quiet time")
  var message: String?
  for second in stride(from: 30.0, through: 61, by: 1) {
    (cpu, message) = HeliosDoneWatcher.step(cpu, HeliosDoneInputs(now: t0.addingTimeInterval(second), cpuBusyPercent: 10))
    if message != nil { break }
  }
  try require(message == "Your Mac has calmed down.", "30 quiet seconds")

  var download = HeliosDoneWatch(kind: .downloadFinishes, startedAt: t0)
  (download, message) = HeliosDoneWatcher.step(download, HeliosDoneInputs(now: t0, downloadBytesPerSecond: 10))
  try require(message == nil && !download.sawTraffic, "quiet before any download is not a finish")
  (download, _) = HeliosDoneWatcher.step(download, HeliosDoneInputs(now: t0.addingTimeInterval(1), downloadBytesPerSecond: 5_000_000))
  (download, _) = HeliosDoneWatcher.step(download, HeliosDoneInputs(now: t0.addingTimeInterval(2), downloadBytesPerSecond: 1_000))
  (download, message) = HeliosDoneWatcher.step(download, HeliosDoneInputs(now: t0.addingTimeInterval(23), downloadBytesPerSecond: 1_000))
  try require(message == "The download has finished.", "finish after 20 quiet seconds")

  process = HeliosDoneWatch(kind: .processExits(pid: 42, name: "x"), startedAt: t0)
  result = HeliosDoneWatcher.step(process, HeliosDoneInputs(now: t0.addingTimeInterval(90_000), runningPIDs: [42]))
  try require(result.1?.contains("after a day") == true, "watches expire")
  print("PASS tell-me-when-done: process exit, CPU calm, download finished, unknown inputs ignored, one-day expiry")
}

private func mouseChecks() throws {
  let wheel = HeliosMouseScroll.Deltas(lines: (3, 0), points: (30, 0), fixed: (3, 0))
  var settings = HeliosMouseScrollSettings()
  let reversed = HeliosMouseScroll.transform(wheel, continuous: false, settings: settings)
  try require(reversed == HeliosMouseScroll.Deltas(lines: (-3, 0), points: (-30, 0), fixed: (-3, 0)),
              "a wheel notch is reversed")
  try require(HeliosMouseScroll.transform(wheel, continuous: true, settings: settings) == nil,
              "trackpad and Magic Mouse (continuous) pass untouched")
  settings.wheelSpeed = 3
  try require(HeliosMouseScroll.transform(wheel, continuous: false, settings: settings)
                == HeliosMouseScroll.Deltas(lines: (-9, 0), points: (-90, 0), fixed: (-9, 0)), "speed scales every field")
  settings.reverseWheel = false
  settings.wheelSpeed = 1
  try require(HeliosMouseScroll.transform(wheel, continuous: false, settings: settings) == nil, "neutral passes untouched")
  settings.wheelSpeed = 99
  try require(HeliosMouseScroll.transform(wheel, continuous: false, settings: settings)?.lines.vertical == 15,
              "speed is clamped to 5×")
  let sideways = HeliosMouseScroll.Deltas(lines: (0, -2), points: (0, -20), fixed: (0, -2))
  try require(HeliosMouseScroll.transform(sideways, continuous: false, settings: HeliosMouseScrollSettings())?.lines.horizontal == 2,
              "horizontal wheels reverse too")
  print("PASS mouse tools: wheel-only reverse and speed, continuous devices untouched, neutral passes, clamped")
}

private func latencyHistoryChecks() throws {
  func sample(_ offset: TimeInterval, internet: Double? = 20, loss: Double = 0, routerLoss: Double = 0) -> HeliosLatencySample {
    HeliosLatencySample(at: t0.addingTimeInterval(offset),
      router: HeliosNetworkCheck.Ping(averageMilliseconds: 4, lossPercent: routerLoss),
      internet: HeliosNetworkCheck.Ping(averageMilliseconds: internet, lossPercent: loss))
  }
  var samples: [HeliosLatencySample] = []
  for index in 0..<10 { samples = HeliosLatencyHistory.appended(samples, sample(Double(index) * 300), now: t0.addingTimeInterval(3_000)) }
  try require(samples.count == 10 && samples.first!.at < samples.last!.at, "appends in order")
  let later = HeliosLatencyHistory.appended(samples, sample(8 * 86_400), now: t0.addingTimeInterval(8 * 86_400))
  try require(later.count == 1, "older than seven days is dropped")
  try require(HeliosLatencyHistory.appended([], sample(3_600), now: t0).isEmpty, "the future is dropped")
  try require(HeliosLatencyHistory.sanitized([sample(0, internet: .nan)], now: t0).isEmpty, "non-finite values are dropped")
  let mixed = [sample(0, internet: 10), sample(300, internet: 20), sample(600, internet: 30, loss: 33),
               sample(900, internet: nil, loss: 100, routerLoss: 100)]
  let summary = HeliosLatencyHistory.summary(mixed, since: t0)
  try require(summary.count == 4 && summary.internetMedian == 20 && summary.routerMedian == 4,
              "medians: \(summary)")
  try require(summary.lossBeyondRouter == 1 && summary.lossAtRouter == 1, "loss split at the router")
  try require(HeliosLatencyHistory.trend(mixed, now: t0.addingTimeInterval(900)) == nil, "no trend from a few looks")
  print("PASS latency history: order, seven-day retention, future and invalid dropped, medians, loss split, trend needs history")
}

@main
private enum ToolsChecks {
  static func main() {
    do {
      try keepAwakeChecks()
      try urlChecks()
      try ruleChecks()
      try doneChecks()
      try mouseChecks()
      try latencyHistoryChecks()
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
