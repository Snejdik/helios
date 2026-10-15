import Foundation

// "Why?" engine (PLAN_0_3_0 M3/M4): every lens against ≥ 5 fixture scenarios with the
// expected leading cause, plus honesty rules: missing data never yields "Likely", gaps
// are said, nothing is invented on a calm Mac. Pure values; no hardware, files or network
// (the report reader is checked against a temporary folder it creates).

private struct CheckFailure: Error, CustomStringConvertible { let description: String }

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CheckFailure(description: message) }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func sample<V: Sendable>(_ value: V, age: TimeInterval = 0) -> MetricSample<V> {
  MetricSample(.success(value), capturedAt: now.addingTimeInterval(-age), capturedTicks: 1)
}

private func missing<V: Sendable>() -> MetricSample<V> {
  MetricSample(.failure(.unavailable("not collected")), capturedAt: now, capturedTicks: 1)
}

private func process(_ name: String, pid: Int32 = 900, cpu: Double = 2, watts: Double = 0.1,
                     memory: UInt64 = 200 << 20, wakeups: Double = 5, write: Double = 0,
                     sessionWrite: UInt64 = 0, path: String? = nil) -> ProcessActivity {
  ProcessActivity(pid: pid, name: name, executablePath: path, physicalFootprintBytes: memory,
    neuralFootprintBytes: 0, cpuPercent: cpu, powerWatts: watts, performanceCorePowerWatts: nil,
    diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: write, wakeupsPerSecond: wakeups,
    instructionsPerSecond: nil, cyclesPerSecond: nil, instructionsPerCycle: nil,
    sessionDiskReadBytes: 0, sessionDiskWriteBytes: sessionWrite)
}

private func cpu(busy: Double) -> CPUMetrics {
  CPUMetrics(userPercent: busy * 0.7, systemPercent: busy * 0.3, nicePercent: 0, idlePercent: 100 - busy,
             performanceCoreCount: .success(4), efficiencyCoreCount: .success(6))
}

private func memory(_ pressure: MemoryPressure = .normal, swap: UInt64 = 0) -> MemoryMetrics {
  MemoryMetrics(physicalBytes: 16 << 30, activeBytes: 8 << 30, inactiveBytes: 1 << 30,
    wiredBytes: 2 << 30, compressedBytes: 2 << 30, freeBytes: 3 << 30,
    pressure: .success(pressure), swapUsedBytes: .success(swap), swapTotalBytes: .success(swap * 2))
}

private func gpu(_ busy: Double) -> GPUMetrics {
  GPUMetrics(model: .success("Apple M4"), coreCount: .success(10), deviceUtilizationPercent: .success(busy),
    rendererUtilizationPercent: .success(busy), tilerUtilizationPercent: .success(busy),
    allocatedSystemMemoryBytes: .success(1 << 30), inUseSystemMemoryBytes: .success(1 << 28))
}

private func system(_ state: SystemThermalState = .nominal, lowPower: Bool = false) -> SystemMetrics {
  SystemMetrics(modelIdentifier: .success("Mac16,1"), chipName: .success("Apple M4"), osVersion: "27.0",
    osBuild: .success("26A434"), uptimeSeconds: 3_600, logicalProcessorCount: 10, physicalMemoryBytes: 16 << 30,
    loadAverage1: .success(1), loadAverage5: .success(1), loadAverage15: .success(1),
    thermalState: state, lowPowerModeEnabled: lowPower)
}

private func battery(watts: Double = -8, source: MacPowerSource = .battery, maximum: Int = 5_700,
                     temperature: Double = 30) -> BatteryMetrics {
  BatteryMetrics(designCapacityMAh: .success(6_000), maximumCapacityMAh: .success(maximum),
    currentCapacityMAh: .success(4_000), systemChargePercent: .success(70), cycleCount: .success(100),
    temperatureCelsius: .success(temperature),
    power: .success(BatteryPower(signedWatts: watts, usesInstantaneousCurrent: true)),
    powerSource: .success(source), voltageVolts: .success(12.3), currentAmps: .success(-1),
    isCharging: .success(watts > 0), timeRemaining: .success(.seconds(14_400)))
}

private func storage(free: UInt64, total: UInt64 = 1_000_000_000_000) -> StorageMetrics {
  StorageMetrics(rootVolume: .success(RootVolumeMetrics(totalBytes: total, freeBytes: free)), devices: [],
    primaryDeviceBSDName: nil, throughput: .failure(.unavailable("n/a")), smartHealth: .failure(.unavailable("n/a")),
    smartHealthCapturedTicks: nil, monitoringReadBytes: .failure(.unavailable("n/a")),
    monitoringWrittenBytes: .failure(.unavailable("n/a")))
}

private func processes(cpu: [ProcessActivity] = [process("Mail")], energy: [ProcessActivity]? = nil,
                       memory: [ProcessActivity]? = nil, writers: [ProcessActivity] = [],
                       diskRead: Double = 0, diskWrite: Double = 0) -> ProcessMetrics {
  ProcessMetrics(accessibleProcessCount: 300, topByCPU: cpu, topByEnergy: energy ?? cpu,
    topByMemory: memory ?? cpu, topByDiskWrite: writers, topSessionWriters: writers,
    accountedDiskReadBytesPerSecond: diskRead, accountedDiskWriteBytesPerSecond: diskWrite)
}

private func thermals(_ celsius: Double, trusted: Bool = true) -> ThermalMetrics {
  ThermalMetrics(readings: [ThermalReading(key: "Tp01", group: trusted ? .performanceCPU : .unclassified,
                                           celsius: celsius, displayGroup: .performanceCPU)], failures: [:])
}

private func fans(_ rpm: Double) -> FanInventory {
  FanInventory(fans: [FanReading(id: 0, actualRPM: .success(rpm), targetRPM: .success(rpm),
    minimumRPM: .success(2_317), maximumRPM: .success(6_550), automatic: .success(true))])
}

private func assertion(_ name: String, pid: Int32 = 700, system: Bool = true, display: Bool = false,
                       reason: String? = nil) -> PowerAssertionMetrics {
  PowerAssertionMetrics(pid: pid, processName: name, assertionType: system ? "PreventUserIdleSystemSleep" : "PreventUserIdleDisplaySleep",
    reason: reason, preventsDisplaySleep: display, preventsSystemSleep: system)
}

private func wifi(rssi: Int = -50, noise: Int = -92, rate: Double = 866) -> WiFiMetrics {
  WiFiMetrics(interfaceName: "en0", powerOn: true, serviceActive: true, ssid: .failure(.unavailable("private")),
    rssiDBm: .success(rssi), noiseDBm: .success(noise), transmitRateMbps: .success(rate),
    transmitPowerMilliwatts: .success(30), channelNumber: .success(36), channelBand: .success("5 GHz"),
    channelWidth: .success("80 MHz"), phyMode: .success("802.11ax"), security: .success("WPA3"))
}

/// A calm Mac: everything fresh and unremarkable.
private func calm() -> HeliosDiagnosisInput {
  var snapshot = TelemetrySnapshot(capturedAt: now, capturedTicks: 1)
  snapshot.cpu = sample(cpu(busy: 8))
  snapshot.memory = sample(memory())
  snapshot.gpu = sample(gpu(5))
  snapshot.system = sample(system())
  snapshot.processes = sample(processes())
  snapshot.battery = sample(battery())
  snapshot.storage = sample(storage(free: 600_000_000_000))
  snapshot.thermals = sample(thermals(45))
  snapshot.fans = sample(fans(0))
  snapshot.powerAssertions = sample(PowerAssertionsMetrics(assertions: []))
  snapshot.wifi = sample(wifi())
  return HeliosDiagnosisInput(snapshot: snapshot, now: now)
}

private func top(_ lens: HeliosLens, _ input: HeliosDiagnosisInput) -> HeliosCause? {
  HeliosDiagnose.run(lens, input).causes.first
}

private func expect(_ lens: HeliosLens, _ name: String, _ input: HeliosDiagnosisInput, id: String,
                    confidence: HeliosConfidence? = nil) throws {
  let diagnosis = HeliosDiagnose.run(lens, input)
  guard let first = diagnosis.causes.first else {
    throw CheckFailure(description: "\(lens) / \(name): no cause, expected \(id)")
  }
  try require(first.id == id, "\(lens) / \(name): expected \(id), got \(first.id) (\(first.observation))")
  if let confidence { try require(first.confidence == confidence, "\(lens) / \(name): confidence \(first.confidence)") }
  try require(!first.observation.isEmpty && !first.reasoning.isEmpty, "\(lens) / \(name): says what and why")
}

private func expectNothing(_ lens: HeliosLens, _ name: String, _ input: HeliosDiagnosisInput) throws {
  let diagnosis = HeliosDiagnose.run(lens, input)
  try require(diagnosis.causes.isEmpty, "\(lens) / \(name): invented \(diagnosis.causes.map(\.id))")
  try require(diagnosis.summary == "Nothing in the current readings explains this.", "\(lens) / \(name): honest summary")
}

private func slowMacChecks() throws {
  var busy = calm()
  busy.snapshot.cpu = sample(cpu(busy: 95))
  busy.snapshot.processes = sample(processes(cpu: [process("Xcode", cpu: 720, path: "/Applications/Xcode.app/Contents/MacOS/Xcode")]))
  try expect(.slowMac, "one app saturates the CPU", busy, id: "cpu.app", confidence: .likely)
  try require(top(.slowMac, busy)?.action == .quitProcess(pid: 900, name: "Xcode"), "offers to quit the app")

  var memoryFull = calm()
  memoryFull.snapshot.memory = sample(memory(.critical, swap: 6 << 30))
  try expect(.slowMac, "memory critical", memoryFull, id: "memory.pressure", confidence: .likely)

  var throttled = calm()
  throttled.snapshot.system = sample(system(.critical))
  try expect(.slowMac, "thermal throttling", throttled, id: "thermal.pressure", confidence: .likely)

  var full = calm()
  full.snapshot.storage = sample(storage(free: 8_000_000_000))
  try expect(.slowMac, "disk nearly full", full, id: "disk.full", confidence: .likely)

  var lowPower = calm()
  lowPower.snapshot.system = sample(system(lowPower: true))
  try expect(.slowMac, "Low Power Mode", lowPower, id: "power.lowPowerMode", confidence: .possible)

  var kills = calm()
  kills.reports = [DiagnosticReportSummary(kind: .memoryKill, process: nil, date: now.addingTimeInterval(-3_600))]
  try expect(.slowMac, "recent Jetsam kills", kills, id: "memory.kills", confidence: .possible)

  // Throttling outranks a busy app (both likely; macOS slows everything).
  var both = busy
  both.snapshot.system = sample(system(.critical))
  try expect(.slowMac, "throttling over busy app", both, id: "thermal.pressure")

  try expectNothing(.slowMac, "calm Mac", calm())

  // Honesty: busy CPU without per-app data never names an app or says "Likely".
  var anonymous = calm()
  anonymous.snapshot.cpu = sample(cpu(busy: 97))
  anonymous.snapshot.processes = missing()
  let diagnosis = HeliosDiagnose.run(.slowMac, anonymous)
  try require(diagnosis.causes.first?.id == "cpu.busy" && diagnosis.causes.first?.confidence == .possible,
              "no app data → no app name and no Likely")
  try require(diagnosis.gaps.contains { $0.contains("Per-app activity") }, "the gap is said")

  // Stale CPU data is not used at all.
  var stale = busy
  stale.snapshot.cpu = sample(cpu(busy: 99), age: 60)
  try require(HeliosDiagnose.run(.slowMac, stale).causes.allSatisfy { $0.id != "cpu.app" }, "stale CPU is ignored")
}

private func hotChecks() throws {
  var helios = calm()
  helios.heliosFanRPM = 3_400
  try expect(.hotOrNoisy, "Helios holds the fan", helios, id: "fan.helios", confidence: .likely)

  var load = calm()
  load.snapshot.cpu = sample(cpu(busy: 80))
  load.snapshot.processes = sample(processes(cpu: [process("ffmpeg", cpu: 650)]))
  try expect(.hotOrNoisy, "heavy CPU work", load, id: "load.heavy", confidence: .likely)

  var gpuLoad = calm()
  gpuLoad.snapshot.gpu = sample(gpu(92))
  try expect(.hotOrNoisy, "heavy GPU work", gpuLoad, id: "load.heavy", confidence: .likely)

  var idleHot = calm()
  idleHot.snapshot.thermals = sample(thermals(78))
  try expect(.hotOrNoisy, "hot while idle", idleHot, id: "heat.idle", confidence: .possible)
  var idleHotCatalogue = calm()
  idleHotCatalogue.snapshot.thermals = sample(thermals(78, trusted: false))
  try require(top(.hotOrNoisy, idleHotCatalogue)?.reasoning.contains("not confirmed") == true,
              "an unconfirmed map is admitted in the reasoning")

  var charging = calm()
  charging.snapshot.battery = sample(battery(watts: 40, source: .powerAdapter, temperature: 38))
  try expect(.hotOrNoisy, "fast charging", charging, id: "heat.charging", confidence: .possible)

  var fanIdle = calm()
  fanIdle.snapshot.fans = sample(fans(4_800))
  try expect(.hotOrNoisy, "fast fan without load", fanIdle, id: "fan.fastIdle", confidence: .possible)

  var pressure = calm()
  pressure.snapshot.system = sample(system(.serious))
  try expect(.hotOrNoisy, "thermal pressure", pressure, id: "thermal.pressure")

  try expectNothing(.hotOrNoisy, "calm Mac", calm())
}

private func batteryChecks() throws {
  var app = calm()
  app.snapshot.processes = sample(processes(energy: [process("Chrome", cpu: 140, watts: 7.5)]))
  try expect(.batteryDrain, "energy-hungry app", app, id: "energy.app", confidence: .likely)

  var discharge = calm()
  discharge.snapshot.battery = sample(battery(watts: -22))
  try expect(.batteryDrain, "high discharge", discharge, id: "energy.discharge", confidence: .possible)

  var awake = calm()
  awake.snapshot.powerAssertions = sample(PowerAssertionsMetrics(assertions: [assertion("Music", reason: "Playing")]))
  try expect(.batteryDrain, "sleep blocker", awake, id: "sleep.blocked", confidence: .possible)

  var worn = calm()
  worn.snapshot.battery = sample(battery(maximum: 4_200))
  try expect(.batteryDrain, "worn battery", worn, id: "battery.wear", confidence: .possible)

  var wake = calm()
  wake.snapshot.processes = sample(processes(energy: [process("Spotlight", watts: 0.5, wakeups: 1_200)]))
  try expect(.batteryDrain, "frequent wake-ups", wake, id: "energy.wakeups", confidence: .possible)

  var reports = calm()
  reports.reports = (0..<3).map { DiagnosticReportSummary(kind: .wakeupsResource, process: "Dropbox", date: now.addingTimeInterval(-Double($0) * 86_400)) }
  try expect(.batteryDrain, "wake-up reports", reports, id: "reports.wakeupsResource")

  var adapter = calm()
  adapter.snapshot.battery = sample(battery(watts: 20, source: .powerAdapter))
  let onAdapter = HeliosDiagnose.run(.batteryDrain, adapter)
  try require(onAdapter.gaps.contains { $0.contains("power adapter") }, "on the adapter it says so")

  try expectNothing(.batteryDrain, "calm Mac", calm())
}

private func sleepChecks() throws {
  var keep = calm()
  keep.keepAwakeActive = true
  try expect(.cannotSleep, "Helios Keep Awake", keep, id: "sleep.keepAwake", confidence: .likely)
  try require(top(.cannotSleep, keep)?.action == .stopKeepAwake, "offers to stop it")

  var blocker = calm()
  blocker.snapshot.powerAssertions = sample(PowerAssertionsMetrics(assertions: [assertion("Zoom", reason: "In a call")]))
  try expect(.cannotSleep, "app prevents sleep", blocker, id: "sleep.blocked", confidence: .likely)

  var several = calm()
  several.snapshot.powerAssertions = sample(PowerAssertionsMetrics(assertions: [
    assertion("backupd", pid: 1), assertion("Transmission", pid: 2), assertion("Zoom", pid: 3)]))
  try require(top(.cannotSleep, several)?.observation.contains("are keeping") == true, "several blockers are listed")

  var display = calm()
  display.snapshot.powerAssertions = sample(PowerAssertionsMetrics(assertions: [
    assertion("QuickTime Player", system: false, display: true, reason: "Video playback")]))
  try expect(.cannotSleep, "display kept on", display, id: "sleep.display", confidence: .possible)

  var own = calm()
  own.snapshot.powerAssertions = sample(PowerAssertionsMetrics(assertions: [
    assertion("Helios", pid: ProcessInfo.processInfo.processIdentifier)]))
  try expectNothing(.cannotSleep, "Helios's own assertion is not blamed", own)

  var unknown = calm()
  unknown.snapshot.powerAssertions = missing()
  let diagnosis = HeliosDiagnose.run(.cannotSleep, unknown)
  try require(diagnosis.causes.isEmpty && diagnosis.gaps.contains { $0.contains("keeping the Mac awake") },
              "missing assertion data is a gap, not a verdict")

  try expectNothing(.cannotSleep, "calm Mac", calm())
}

private func restartChecks() throws {
  var panic = calm()
  panic.reports = [DiagnosticReportSummary(kind: .kernelPanic, process: nil, date: now.addingTimeInterval(-7_200), panicCause: .sleepWake)]
  try expect(.unexpectedRestart, "kernel panic", panic, id: "restart.panic", confidence: .likely)
  try require(top(.unexpectedRestart, panic)?.reasoning.contains("sleep or wake") == true, "panic cause explained")

  var repeated = calm()
  repeated.reports = (0..<3).map { DiagnosticReportSummary(kind: .kernelPanic, process: nil, date: now.addingTimeInterval(-Double($0 + 1) * 86_400), panicCause: .watchdog) }
  try require(top(.unexpectedRestart, repeated)?.observation.contains("3 in the last two weeks") == true, "count shown")

  var unclean = calm()
  unclean.previousSessionEndedUncleanly = true
  try expect(.unexpectedRestart, "unclean exit without panic", unclean, id: "restart.unclean", confidence: .possible)

  var old = calm()
  old.reports = [DiagnosticReportSummary(kind: .kernelPanic, process: nil, date: now.addingTimeInterval(-30 * 86_400))]
  try expectNothing(.unexpectedRestart, "panic older than two weeks", old)

  var both = unclean
  both.reports = panic.reports
  try expect(.unexpectedRestart, "panic outranks unclean exit", both, id: "restart.panic")

  try expectNothing(.unexpectedRestart, "calm Mac", calm())
}

private func diskChecks() throws {
  var full = calm()
  full.snapshot.storage = sample(storage(free: 40_000_000_000))
  try expect(.fillingDisk, "low space", full, id: "disk.full", confidence: .likely)

  var writer = calm()
  writer.snapshot.processes = sample(processes(writers: [process("Docker", sessionWrite: 40_000_000_000)]))
  try expect(.fillingDisk, "big writer", writer, id: "disk.writer", confidence: .possible)

  var swap = calm()
  swap.snapshot.memory = sample(memory(swap: 9_000_000_000))
  try expect(.fillingDisk, "large swap", swap, id: "disk.swap", confidence: .possible)

  var reports = calm()
  reports.reports = [DiagnosticReportSummary(kind: .diskWritesResource, process: "photoanalysisd", date: now)]
  try expect(.fillingDisk, "disk-write reports", reports, id: "reports.diskWritesResource")

  var tight = calm()
  tight.snapshot.storage = sample(storage(free: 120_000_000_000))
  try expect(.fillingDisk, "under 15 % free", tight, id: "disk.full", confidence: .possible)

  try expectNothing(.fillingDisk, "calm Mac", calm())
}

private func networkChecks() throws {
  func check(gateway: Double? = 4, gatewayLoss: Double = 0, internet: Double? = 20, internetLoss: Double = 0,
             dns: Double? = 30, dnsFailed: Bool = false, vpn: Bool = false, expensive: Bool = false,
             traffic: [HeliosNetworkCheck.AppTraffic] = [], connected: Bool = true) -> HeliosNetworkCheck {
    HeliosNetworkCheck(checkedAt: now, connected: connected, vpnActive: vpn, expensivePath: expensive,
      gateway: gateway.map { HeliosNetworkCheck.Ping(averageMilliseconds: $0, lossPercent: gatewayLoss) },
      internet: internet.map { HeliosNetworkCheck.Ping(averageMilliseconds: $0, lossPercent: internetLoss) },
      dnsMilliseconds: dns, dnsFailed: dnsFailed, topTraffic: traffic)
  }
  var provider = calm()
  provider.network = check(gateway: 4, internet: 180)
  try expect(.slowNetwork, "slow provider", provider, id: "net.provider", confidence: .likely)
  try require(top(.slowNetwork, provider)?.observation == "Your router answers in 4 ms, the internet in 180 ms.",
              "the plan's example sentence")

  var weak = calm()
  weak.snapshot.wifi = sample(wifi(rssi: -80, noise: -90, rate: 24))
  weak.network = check(gateway: 35)
  try expect(.slowNetwork, "weak Wi-Fi", weak, id: "net.wifi", confidence: .likely)

  var router = calm()
  router.network = check(gateway: 120, gatewayLoss: 10, internet: 160)
  try expect(.slowNetwork, "slow router", router, id: "net.router", confidence: .likely)
  try require(HeliosDiagnose.run(.slowNetwork, router).causes.first { $0.id == "net.provider" }?.confidence == .possible,
              "a slow router lowers the confidence in blaming the provider")

  var oneLost = calm()
  oneLost.network = check(gateway: 4, gatewayLoss: 20, internet: 20, internetLoss: 20)
  try expectNothing(.slowNetwork, "one lost echo of five is not a problem", oneLost)
  var twoLost = calm()
  twoLost.network = check(gateway: 4, gatewayLoss: 40)
  try expect(.slowNetwork, "two lost echoes at the router", twoLost, id: "net.router", confidence: .likely)

  var dns = calm()
  dns.network = check(dns: 900)
  try expect(.slowNetwork, "slow DNS", dns, id: "net.dns", confidence: .likely)

  var dnsDown = calm()
  dnsDown.network = check(dns: nil, dnsFailed: true)
  try expect(.slowNetwork, "DNS fails", dnsDown, id: "net.dns", confidence: .likely)

  var vpn = calm()
  vpn.network = check(vpn: true)
  try expect(.slowNetwork, "VPN", vpn, id: "net.vpn", confidence: .possible)

  var download = calm()
  download.network = check(traffic: [HeliosNetworkCheck.AppTraffic(name: "Steam", bytesPerSecond: 40_000_000)])
  try expect(.slowNetwork, "own download", download, id: "net.app", confidence: .possible)

  var offline = calm()
  offline.network = check(connected: false)
  try expect(.slowNetwork, "offline", offline, id: "net.offline", confidence: .likely)

  let unchecked = HeliosDiagnose.run(.slowNetwork, calm())
  try require(unchecked.causes.isEmpty && unchecked.gaps.contains { $0.contains("Run a network check") },
              "without a check it asks for one instead of guessing")
  var fine = calm()
  fine.network = check()
  try expectNothing(.slowNetwork, "healthy network", fine)

  // Background history: the last hour against this Mac's own week.
  func history(usual: Double, recent: Double, recentInternetLoss: Double = 0) -> [HeliosLatencySample] {
    let week = (1...200).map { index in
      HeliosLatencySample(at: now.addingTimeInterval(-3_600 - Double(index) * 300),
        router: HeliosNetworkCheck.Ping(averageMilliseconds: 4, lossPercent: 0),
        internet: HeliosNetworkCheck.Ping(averageMilliseconds: usual, lossPercent: 0))
    }
    let hour = (0..<12).map { index in
      HeliosLatencySample(at: now.addingTimeInterval(-Double(index) * 300),
        router: HeliosNetworkCheck.Ping(averageMilliseconds: 4, lossPercent: 0),
        internet: HeliosNetworkCheck.Ping(averageMilliseconds: recent, lossPercent: recentInternetLoss))
    }
    return (week + hour).sorted { $0.at < $1.at }
  }
  var worse = calm()
  worse.latencyHistory = history(usual: 18, recent: 120)
  try expect(.slowNetwork, "worse than this Mac's usual", worse, id: "net.history", confidence: .possible)
  try require(top(.slowNetwork, worse)?.observation
                == "In the last hour the internet answered in 120 ms, against 18 ms usually on this Mac.",
              "history sentence")
  var worseAndLossy = calm()
  worseAndLossy.latencyHistory = history(usual: 18, recent: 120, recentInternetLoss: 33)
  try expect(.slowNetwork, "slower and losing packets", worseAndLossy, id: "net.history", confidence: .likely)
  var usual = calm()
  usual.latencyHistory = history(usual: 18, recent: 22)
  try require(!HeliosDiagnose.run(.slowNetwork, usual).causes.contains { $0.id == "net.history" },
              "an ordinary hour is not a cause")
  var short = calm()
  short.latencyHistory = Array(history(usual: 18, recent: 120).suffix(20))
  try require(!HeliosDiagnose.run(.slowNetwork, short).causes.contains { $0.id == "net.history" },
              "no verdict without a day of history")
}

private func networkParserChecks() throws {
  // ICMP echo request: type 8, our identifier/sequence, a checksum that verifies to zero.
  let echo = HeliosNetworkProbe.icmpEcho(identifier: 0x1234, sequence: 7)
  try require(echo[0] == 8 && echo[4] == 0x12 && echo[5] == 0x34 && echo[7] == 7, "echo header")
  try require(HeliosNetworkProbe.checksum(echo) == 0, "checksum over the whole packet is zero")
  var reply = echo; reply[0] = 0
  try require(HeliosNetworkProbe.isEchoReply(reply, sequence: 7), "bare ICMP reply")
  try require(HeliosNetworkProbe.isEchoReply([0x45] + [UInt8](repeating: 0, count: 19) + reply, sequence: 7),
              "reply behind an IPv4 header")
  try require(!HeliosNetworkProbe.isEchoReply(reply, sequence: 8), "another sequence is not ours")
  try require(!HeliosNetworkProbe.isEchoReply(echo, sequence: 7), "a request is not a reply")
  let nettop = """
  ,bytes_in,bytes_out,
  Safari.812,1000,200,
  Steam.900,50000,100,
  ,bytes_in,bytes_out,
  Safari.812,1500,300,
  Steam.900,4050000,100,
  kernel_task.0,10,0,
  """
  let traffic = HeliosNetworkProbe.parseNettop(nettop)
  try require(traffic.first?.name == "Steam" && traffic.first?.bytesPerSecond == 4_000_000, "busiest app first: \(traffic)")
  try require(traffic.contains { $0.name == "Safari" && $0.bytesPerSecond == 600 }, "rate from the two samples")
  try require(HeliosNetworkProbe.parseNettop(",bytes_in,bytes_out,\nA.1,5,5,\n").isEmpty, "one sample gives no rate")
  try require(HeliosNetworkProbe.isTunnel("utun4") && !HeliosNetworkProbe.isTunnel("en0"), "VPN interfaces")
  try require(HeliosNetworkProbe.isIPv4("192.168.1.1") && !HeliosNetworkProbe.isIPv4("fe80::1"), "IPv4 only for ping")
}

private func networkHealthChecks() throws {
  // Congestion: 5 GHz counts the exact channel; 2.4 GHz counts overlapping neighbours.
  let neighbors = (0..<6).map { HeliosWiFiNeighbor(channel: 36, band: "5 GHz", rssi: -60 - $0) }
    + [HeliosWiFiNeighbor(channel: 149, band: "5 GHz", rssi: -70), HeliosWiFiNeighbor(channel: 6, band: "2.4 GHz", rssi: -50)]
  let crowded = HeliosWiFiCongestion.analyze(neighbors, currentChannel: 36, band: "5 GHz")
  try require(crowded.sameChannel == 6 && crowded.strongSameChannel == 6 && crowded.crowded, "crowded 5 GHz channel")
  try require(crowded.quieterChannels.first == 149, "suggests a quieter channel: \(crowded.quieterChannels)")
  let overlapping = HeliosWiFiCongestion.analyze(
    [3, 4, 5, 8, 11, 11].map { HeliosWiFiNeighbor(channel: $0, band: "2.4 GHz", rssi: -65) }, currentChannel: 6, band: "2.4 GHz")
  try require(overlapping.sameChannel == 4, "2.4 GHz overlap within ±4 channels: \(overlapping.sameChannel)")
  try require(overlapping.quieterChannels.first == 1, "1/6/11 suggestions: \(overlapping.quieterChannels)")
  try require(!HeliosWiFiCongestion.analyze([], currentChannel: 40, band: "5 GHz").crowded, "empty air is not crowded")

  var drops = HeliosWiFiDropTracker()
  let on = wifi(), off = WiFiMetrics(interfaceName: "en0", powerOn: true, serviceActive: false, ssid: .failure(.unavailable("x")),
    rssiDBm: .failure(.unavailable("x")), noiseDBm: .failure(.unavailable("x")), transmitRateMbps: .failure(.unavailable("x")),
    transmitPowerMilliwatts: .failure(.unavailable("x")), channelNumber: .failure(.unavailable("x")),
    channelBand: .failure(.unavailable("x")), channelWidth: .failure(.unavailable("x")), phyMode: .failure(.unavailable("x")),
    security: .failure(.unavailable("x")))
  for minute in 0..<6 { drops.observe(minute % 2 == 0 ? on : off, now: now.addingTimeInterval(Double(minute) * 60)) }
  try require(drops.drops.count == 3, "three drops counted: \(drops.drops.count)")
  drops.observe(on, now: now.addingTimeInterval(4_000))
  try require(drops.drops.isEmpty, "drops older than an hour expire")

  var flaky = calm()
  flaky.wifiDropsLastHour = 4
  try expect(.slowNetwork, "Wi-Fi drops", flaky, id: "net.drops", confidence: .likely)
  var busyChannel = calm()
  busyChannel.network = HeliosNetworkCheck(checkedAt: now, connected: true, vpnActive: false, expensivePath: false,
    gateway: .init(averageMilliseconds: 4, lossPercent: 0), internet: .init(averageMilliseconds: 20, lossPercent: 0),
    dnsMilliseconds: 30, dnsFailed: false, topTraffic: [], congestion: crowded)
  try expect(.slowNetwork, "crowded channel", busyChannel, id: "net.channel", confidence: .possible)
  try require(top(.slowNetwork, busyChannel)?.reasoning.contains("Channel 149 is quieter") == true, "names the quieter channel")

  // Data usage.
  var tracker = HeliosDataUsageTracker()
  try require(tracker.deltas(["Safari.1": 1_000, "Mail.2": 500]).isEmpty, "the first sample is the baseline")
  let delta = tracker.deltas(["Safari.1": 4_000, "Mail.2": 500, "Steam.9": 9_000, "Safari.3": 100])
  try require(delta == ["Safari": 3_100, "Steam": 9_000], "deltas per app, new processes count fully: \(delta)")
  try require(tracker.deltas(["Safari.1": 10]).isEmpty, "a counter that went backwards counts nothing")
  try require(HeliosDataUsageTracker.parseTotals("Safari.812,1000,200,\nkernel_task.0,5,5,\n,bytes_in,bytes_out,\n")
              == ["Safari.812": 1_200, "kernel_task.0": 10], "nettop totals parsed")
  var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  var days = HeliosDataUsageStore.merge([], deltas: ["Safari": 100], metered: false, now: now, calendar: calendar)
  days = HeliosDataUsageStore.merge(days, deltas: ["Safari": 50, "Steam": 1_000], metered: true, now: now, calendar: calendar)
  try require(days.count == 1 && days[0].apps["Safari"] == 150 && days[0].metered == 1_050, "same day merges; metered counted")
  let many = Dictionary(uniqueKeysWithValues: (0..<40).map { ("App\($0)", UInt64($0 + 1)) })
  let folded = HeliosDataUsageStore.merge([], deltas: many, metered: false, now: now, calendar: calendar)
  try require(folded[0].apps.count == HeliosDataUsageStore.appsPerDay && folded[0].apps["Other"] != nil
              && folded[0].total == many.values.reduce(0, +), "top apps kept, the rest folded into Other")
  let old = HeliosDataUsageStore.merge([HeliosDataUsageDay(day: "2020-01-01", apps: ["x": 1], metered: 0)], deltas: ["y": 1],
                                       metered: false, now: now, calendar: calendar)
  try require(old.count == 1, "days past retention are dropped")
  try require(HeliosDataUsageStore.top(days, last: 7, now: now, calendar: calendar).first?.app == "Steam", "top app")
  try require(HeliosDataUsageStore.crossed(previous: 200_000_000, current: 300_000_000) == 250_000_000
              && HeliosDataUsageStore.crossed(previous: 300_000_000, current: 400_000_000) == nil
              && HeliosDataUsageStore.crossed(previous: 0, current: 2_000_000_000) == 1_000_000_000, "hotspot thresholds once each")
  print("PASS network health: channel congestion (5 GHz exact, 2.4 GHz overlap), Wi-Fi drops, data usage per day/app, hotspot thresholds")
}

private func reportReaderChecks() throws {
  let date = now
  try require(DiagnosticReportsReader.classify(fileName: "panic-full-2026-10-01-101010.0002.panic", date: date)?.kind == .kernelPanic, "panic file")
  try require(DiagnosticReportsReader.classify(fileName: "JetsamEvent-2026-10-13-134210.ips", date: date)?.kind == .memoryKill, "jetsam")
  let cpuReport = DiagnosticReportsReader.classify(
    fileName: "com.apple.WebKit.WebContent_2026-10-13-150741_Host-MacBook-Pro.cpu_resource.diag", date: date)
  try require(cpuReport?.kind == .cpuResource && cpuReport?.process == "com.apple.WebKit.WebContent", "cpu resource + name")
  try require(DiagnosticReportsReader.classify(fileName: "Brave Browser_2026-10-09-110249_Host.diag", date: date) == nil,
              "plain hang/spin diags are not interpreted")
  try require(DiagnosticReportsReader.classify(fileName: "Safari-2026-10-09-114031.ips", date: date)?.process == "Safari", "crash")
  try require(DiagnosticReportsReader.classify(fileName: "ExcUserFault_Safari-2026-10-09-114031.ips", date: date) == nil, "user faults skipped")
  try require(DiagnosticReportsReader.panicCause(text: "panic(cpu 4 caller): watchdog timeout: no checkins") == .watchdog, "watchdog")
  try require(DiagnosticReportsReader.panicCause(text: "Sleep Wake failure in EFI") == .sleepWake, "sleep wake")
  try require(DiagnosticReportsReader.panicCause(text: "AGX firmware fault") == .gpu, "gpu")

  // Real folder round trip in a private temporary directory; the host name never leaves.
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("helios-reports-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let panic = folder.appendingPathComponent("panic-full-2026-10-14-120000.0001.panic")
  try Data("{\"panicString\":\"watchdog timeout\"}".utf8).write(to: panic)
  try Data("x".utf8).write(to: folder.appendingPathComponent("Music_2026-10-14-230332_Secret-Host-Name.wakeups_resource.diag"))
  try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
  let read = DiagnosticReportsReader.read(folders: [folder.path], since: Date().addingTimeInterval(-3_600))
  try require(read.count == 2, "two interpreted reports, got \(read.count)")
  try require(read.contains { $0.kind == .kernelPanic && $0.panicCause == .watchdog }, "panic cause read from file")
  try require(!String(describing: read).contains("Secret-Host-Name"), "host names are never kept")
  try require(DiagnosticReportsReader.read(folders: ["/nonexistent/helios"], since: .distantPast).isEmpty, "missing folder is empty")
}

@main
private enum DiagnoseChecks {
  static func main() {
    do {
      try slowMacChecks()
      try hotChecks()
      try batteryChecks()
      try sleepChecks()
      try restartChecks()
      try diskChecks()
      print("PASS Why? engine: slow Mac, hot/noisy, battery drain, cannot sleep, restart and disk lenses (≥ 5 scenarios each) with honest confidence and stated gaps")
      try networkChecks()
      try networkParserChecks()
      try networkHealthChecks()
      print("PASS Why? network lens: Wi-Fi → router → DNS → provider → VPN → own traffic, offline and unchecked")
      try reportReaderChecks()
      print("PASS macOS diagnostic reports: panic/Jetsam/resource classification, panic causes, local-only names")
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
}
