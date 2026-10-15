import Foundation

// "Why?" engine (PLAN_0_3_0 M3): a question (lens) → pure checks over one telemetry
// snapshot plus macOS's own diagnostic reports → causes with evidence, an honest
// confidence and an action. No hardware access, no side effects; fixtures drive it fully.
// Every answer reads "what I see → why I think so → what you can do".

/// The questions Helios answers.
enum HeliosLens: String, CaseIterable, Sendable, Identifiable {
  case slowMac
  case hotOrNoisy
  case batteryDrain
  case cannotSleep
  case unexpectedRestart
  case fillingDisk
  case slowNetwork

  var id: String { rawValue }

  var question: String {
    switch self {
    case .slowMac: "Why is my Mac slow?"
    case .hotOrNoisy: "Why is my Mac hot or loud?"
    case .batteryDrain: "Why is the battery draining?"
    case .cannotSleep: "Why doesn't my Mac sleep?"
    case .unexpectedRestart: "Why did my Mac restart?"
    case .fillingDisk: "Why is my disk filling up?"
    case .slowNetwork: "Why is the internet slow?"
    }
  }
}

/// How sure Helios is. Shown in words next to every cause; a cause never claims more
/// than its inputs support (missing or stale data caps it at `.possible`).
enum HeliosConfidence: Int, Comparable, Sendable {
  case possible = 1
  case likely = 2

  var label: String {
    switch self {
    case .likely: "Likely"
    case .possible: "Possible"
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Actions a cause can offer. The app maps each to a handler in one registry
/// (`HeliosActionRegistry`), shared with the command palette, URL scheme and rules.
enum HeliosActionID: Hashable, Sendable {
  case openActivityMonitor
  case openPage(String)
  case openSystemSettings(String)
  case revealDiagnosticReports
  case quitProcess(pid: Int32, name: String)
  case startKeepAwake
  case stopKeepAwake
  case runNetworkCheck

  var title: String {
    switch self {
    case .openActivityMonitor: "Open Activity Monitor"
    case .openPage(let page): "Open \(page.prefix(1).uppercased() + page.dropFirst())"
    case .openSystemSettings(let pane): "Open \(pane) Settings"
    case .revealDiagnosticReports: "Show Reports in Finder"
    case .quitProcess(_, let name): "Quit \(name)…"
    case .startKeepAwake: "Keep Awake"
    case .stopKeepAwake: "Stop Keep Awake"
    case .runNetworkCheck: "Check Network"
    }
  }
}

struct HeliosCauseEvidence: Equatable, Sendable {
  let label: String
  let value: String
}

struct HeliosCause: Equatable, Sendable, Identifiable {
  /// Stable kind ("cpu.app"), for tests and de-duplication.
  let id: String
  /// What Helios sees, as one sentence.
  let observation: String
  /// Why that explains the question.
  let reasoning: String
  let confidence: HeliosConfidence
  /// Orders causes of equal confidence (bigger first).
  let weight: Double
  var evidence: [HeliosCauseEvidence] = []
  var action: HeliosActionID? = nil
}

struct HeliosDiagnosis: Equatable, Sendable {
  let lens: HeliosLens
  /// Most likely first.
  let causes: [HeliosCause]
  /// Inputs Helios did not have, said plainly.
  let gaps: [String]

  var summary: String {
    causes.first?.observation ?? "Nothing in the current readings explains this."
  }
}

/// Everything a check may look at. Built by the app; fixtures build it by hand.
struct HeliosDiagnosisInput: Sendable {
  var snapshot: TelemetrySnapshot
  var now: Date
  /// macOS diagnostic reports from the last 14 days (newest first).
  var reports: [DiagnosticReportSummary] = []
  /// Helios's previous run did not end cleanly (power loss, forced restart, crash).
  var previousSessionEndedUncleanly: Bool? = nil
  /// Helios itself holds the fans (Manual, Auto takeover or Boost) at this RPM.
  var heliosFanRPM: Double? = nil
  /// Helios Keep Awake is holding a power assertion.
  var keepAwakeActive = false
  /// Latest on-demand network check (M4), if any.
  var network: HeliosNetworkCheck? = nil
  /// Wi-Fi disconnections in the last hour.
  var wifiDropsLastHour = 0
  /// Opt-in background latency history (empty while that module is off).
  var latencyHistory: [HeliosLatencySample] = []
}

enum HeliosDiagnose {
  static let reportWindow: TimeInterval = 14 * 24 * 3_600

  static func run(_ lens: HeliosLens, _ input: HeliosDiagnosisInput) -> HeliosDiagnosis {
    var context = Context(input: input)
    let causes: [HeliosCause?]
    switch lens {
    case .slowMac:
      causes = [cpuSaturated(&context), memoryPressure(&context), thermalThrottling(&context),
                diskNearlyFull(&context, likelyAt: 0.05), lowPowerMode(&context), heavyDiskIO(&context),
                gpuBusy(&context), recentMemoryKills(&context)]
    case .hotOrNoisy:
      causes = [heliosHoldsFans(&context), heavyLoad(&context), thermalThrottling(&context),
                hotWhileIdle(&context), chargingHeat(&context), fanFastWithoutLoad(&context)]
    case .batteryDrain:
      causes = [onAdapter(&context), topEnergyApp(&context), highDischarge(&context),
                sleepBlockers(&context, forDrain: true), batteryWear(&context),
                busyInBackground(&context), wakeups(&context), resourceReports(&context, .wakeupsResource)]
    case .cannotSleep:
      causes = [keepAwake(&context), sleepBlockers(&context, forDrain: false), displayBlockers(&context)]
    case .unexpectedRestart:
      causes = [kernelPanics(&context), uncleanExit(&context)]
    case .fillingDisk:
      causes = [diskNearlyFull(&context, likelyAt: 0.10), topWriters(&context), largeSwap(&context),
                resourceReports(&context, .diskWritesResource)]
    case .slowNetwork:
      causes = HeliosNetworkDiagnosis.causes(&context)
    }
    let sorted = causes.compactMap { $0 }.sorted {
      $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.weight > $1.weight
    }
    return HeliosDiagnosis(lens: lens, causes: sorted, gaps: context.gaps)
  }

  // MARK: Context

  struct Context {
    let input: HeliosDiagnosisInput
    var gaps: [String] = []

    var now: Date { input.now }

    private mutating func fresh<T>(_ sample: MetricSample<T>, _ maxAge: TimeInterval, gap: String) -> T? {
      if case .success(let value) = TelemetryFormatting.fresh(sample, maxAge: maxAge, now: now) { return value }
      if !gaps.contains(gap) { gaps.append(gap) }
      return nil
    }

    mutating func cpu() -> CPUMetrics? { fresh(input.snapshot.cpu, 5, gap: "CPU load is not available.") }
    mutating func memory() -> MemoryMetrics? { fresh(input.snapshot.memory, 5, gap: "Memory readings are not available.") }
    mutating func gpu() -> GPUMetrics? { fresh(input.snapshot.gpu, 5, gap: "GPU load is not available.") }
    mutating func system() -> SystemMetrics? { fresh(input.snapshot.system, 30, gap: "System state is not available.") }
    mutating func processes() -> ProcessMetrics? {
      fresh(input.snapshot.processes, 15, gap: "Per-app activity is not available, so Helios cannot name an app.")
    }
    mutating func battery() -> BatteryMetrics? { fresh(input.snapshot.battery, 30, gap: "Battery readings are not available.") }
    mutating func storage() -> StorageMetrics? { fresh(input.snapshot.storage, 30, gap: "Storage readings are not available.") }
    mutating func thermals() -> ThermalMetrics? { fresh(input.snapshot.thermals, 6, gap: "Temperatures are not available.") }
    mutating func fans() -> FanInventory? { fresh(input.snapshot.fans, 6, gap: "Fan speed is not available.") }
    mutating func assertions() -> PowerAssertionsMetrics? {
      fresh(input.snapshot.powerAssertions, 60, gap: "The list of apps keeping the Mac awake is not available.")
    }

    var recentReports: [DiagnosticReportSummary] {
      input.reports.filter { now.timeIntervalSince($0.date) <= HeliosDiagnose.reportWindow && $0.date <= now }
    }
  }

  // MARK: Shared readings

  static func busyPercent(_ cpu: CPUMetrics) -> Double { max(0, min(100, 100 - cpu.idlePercent)) }

  static func gpuPercent(_ gpu: GPUMetrics) -> Double? {
    guard case .success(let value) = gpu.deviceUtilizationPercent, value.isFinite else { return nil }
    return value
  }

  static func topCPU(_ processes: ProcessMetrics?) -> ProcessActivity? {
    processes?.topByCPU.first { ($0.cpuPercent ?? 0) > 0 && $0.pid != ProcessInfo.processInfo.processIdentifier }
  }

  static func appName(_ process: ProcessActivity) -> String { HeliosDiagnosisNames.app(process) }

  static func quit(_ process: ProcessActivity) -> HeliosActionID {
    .quitProcess(pid: process.pid, name: appName(process))
  }

  static func date(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  // MARK: Slow Mac

  static func cpuSaturated(_ c: inout Context) -> HeliosCause? {
    guard let cpu = c.cpu() else { return nil }
    let busy = busyPercent(cpu)
    let top = topCPU(c.processes())
    let topPercent = top?.cpuPercent ?? 0
    guard busy >= 60 || topPercent >= 100 else { return nil }
    let saturated = busy >= 85
    var evidence = [HeliosCauseEvidence(label: "CPU busy", value: TelemetryFormatting.percent(busy))]
    if let top {
      evidence.append(HeliosCauseEvidence(label: appName(top), value: TelemetryFormatting.percent(topPercent)))
      return HeliosCause(
        id: "cpu.app",
        observation: "\(appName(top)) is using \(TelemetryFormatting.percent(topPercent)) CPU, and the processor is \(TelemetryFormatting.percent(busy)) busy.",
        reasoning: "When one app keeps the cores busy, everything else has to wait for its turn.",
        confidence: saturated && topPercent >= 50 ? .likely : .possible, weight: busy,
        evidence: evidence, action: quit(top))
    }
    return HeliosCause(
      id: "cpu.busy", observation: "The processor is \(TelemetryFormatting.percent(busy)) busy.",
      reasoning: "With every core busy, new work waits. Helios cannot see which app, so it does not name one.",
      confidence: .possible, weight: busy, evidence: evidence, action: .openActivityMonitor)
  }

  static func memoryPressure(_ c: inout Context) -> HeliosCause? {
    guard let memory = c.memory(), case .success(let pressure) = memory.pressure, pressure != .normal else {
      return nil
    }
    var evidence = [HeliosCauseEvidence(label: "Memory pressure", value: pressure.rawValue)]
    if case .success(let swap) = memory.swapUsedBytes, swap > 0 {
      evidence.append(HeliosCauseEvidence(label: "Swap used", value: TelemetryFormatting.storageBytes(swap)))
    }
    if let top = c.processes()?.topByMemory.first {
      evidence.append(HeliosCauseEvidence(label: appName(top), value: TelemetryFormatting.storageBytes(top.physicalFootprintBytes)))
    }
    return HeliosCause(
      id: "memory.pressure",
      observation: "Memory is \(pressure == .critical ? "full" : "tight") (macOS reports \(pressure.rawValue.lowercased()) pressure).",
      reasoning: "When apps need more memory than the Mac has, macOS compresses memory and swaps to the SSD, which is much slower than RAM.",
      confidence: pressure == .critical ? .likely : .possible, weight: pressure == .critical ? 95 : 70,
      evidence: evidence, action: .openPage("memory"))
  }

  static func thermalThrottling(_ c: inout Context) -> HeliosCause? {
    guard let system = c.system(), system.thermalState == .serious || system.thermalState == .critical else {
      return nil
    }
    return HeliosCause(
      id: "thermal.pressure",
      observation: "macOS reports \(system.thermalState.rawValue.lowercased()) thermal pressure.",
      reasoning: "To cool down, macOS lowers the processor's speed, so the Mac feels slower and the fans run harder.",
      confidence: .likely, weight: system.thermalState == .critical ? 99 : 90,
      evidence: [HeliosCauseEvidence(label: "Thermal pressure", value: system.thermalState.rawValue)],
      action: .openPage("thermals"))
  }

  static func diskNearlyFull(_ c: inout Context, likelyAt fraction: Double) -> HeliosCause? {
    guard let storage = c.storage(), case .success(let root) = storage.rootVolume, root.totalBytes > 0 else {
      return nil
    }
    let free = Double(root.freeBytes) / Double(root.totalBytes)
    let gigabytes = Double(root.freeBytes) / 1_000_000_000
    guard free < 0.15 || gigabytes < 20 else { return nil }
    let likely = free < fraction || gigabytes < 10
    return HeliosCause(
      id: "disk.full",
      observation: "Only \(TelemetryFormatting.storageBytes(root.freeBytes)) is free on the startup disk (\(TelemetryFormatting.percent(free * 100)) of it).",
      reasoning: "macOS needs free space for memory swap, updates and caches; with little left it slows down and apps may fail to save.",
      confidence: likely ? .likely : .possible, weight: 100 - free * 100,
      evidence: [HeliosCauseEvidence(label: "Free", value: TelemetryFormatting.storageBytes(root.freeBytes))],
      action: .openPage("storage"))
  }

  static func lowPowerMode(_ c: inout Context) -> HeliosCause? {
    guard let system = c.system(), system.lowPowerModeEnabled else { return nil }
    return HeliosCause(
      id: "power.lowPowerMode", observation: "Low Power Mode is on.",
      reasoning: "It lowers processor speed and background work to save energy, so heavy tasks take longer.",
      confidence: .possible, weight: 40, action: .openSystemSettings("Battery"))
  }

  static func heavyDiskIO(_ c: inout Context) -> HeliosCause? {
    guard let processes = c.processes() else { return nil }
    let total = processes.accountedDiskReadBytesPerSecond + processes.accountedDiskWriteBytesPerSecond
    guard total >= 200_000_000 else { return nil }
    let top = processes.topByDiskWrite.first ?? processes.topByDiskRead.first
    return HeliosCause(
      id: "disk.io",
      observation: "Apps are reading and writing \(TelemetryFormatting.storageBytes(UInt64(total)))/s\(top.map { ", mostly \(appName($0))" } ?? "").",
      reasoning: "Heavy disk traffic delays every app that needs the disk, even on a fast SSD.",
      confidence: .possible, weight: min(80, total / 10_000_000),
      action: top.map(quit) ?? .openActivityMonitor)
  }

  static func gpuBusy(_ c: inout Context) -> HeliosCause? {
    guard let gpu = c.gpu(), let percent = gpuPercent(gpu), percent >= 90 else { return nil }
    return HeliosCause(
      id: "gpu.busy", observation: "The graphics processor is \(TelemetryFormatting.percent(percent)) busy.",
      reasoning: "A busy GPU makes animations, video and windows stutter.",
      confidence: .possible, weight: percent, action: .openPage("gpu"))
  }

  static func recentMemoryKills(_ c: inout Context) -> HeliosCause? {
    let kills = c.recentReports.filter { $0.kind == .memoryKill }
    guard let latest = kills.first else { return nil }
    return HeliosCause(
      id: "memory.kills",
      observation: "macOS had to close apps for memory \(kills.count == 1 ? "once" : "\(kills.count) times") in the last two weeks (latest \(date(latest.date))).",
      reasoning: "That only happens when memory runs out, which also makes the Mac slow before it.",
      confidence: .possible, weight: 50 + Double(min(kills.count, 10)),
      action: .revealDiagnosticReports)
  }

  // MARK: Hot or noisy

  static func heliosHoldsFans(_ c: inout Context) -> HeliosCause? {
    guard let rpm = c.input.heliosFanRPM, rpm > 0 else { return nil }
    return HeliosCause(
      id: "fan.helios", observation: "Helios is holding the fan at \(TelemetryFormatting.fanRPM(rpm)).",
      reasoning: "Manual, Auto or Boost in Helios adds cooling on top of macOS, and you hear it.",
      confidence: .likely, weight: 100, action: .openPage("thermals"))
  }

  static func heavyLoad(_ c: inout Context) -> HeliosCause? {
    let busy = c.cpu().map(busyPercent)
    let gpu = c.gpu().flatMap(gpuPercent)
    let cpuHeavy = (busy ?? 0) >= 60
    let gpuHeavy = (gpu ?? 0) >= 70
    guard cpuHeavy || gpuHeavy else { return nil }
    let top = topCPU(c.processes())
    var evidence: [HeliosCauseEvidence] = []
    if let busy { evidence.append(HeliosCauseEvidence(label: "CPU busy", value: TelemetryFormatting.percent(busy))) }
    if let gpu { evidence.append(HeliosCauseEvidence(label: "GPU busy", value: TelemetryFormatting.percent(gpu))) }
    let what = cpuHeavy ? "The processor is \(TelemetryFormatting.percent(busy ?? 0)) busy" : "The GPU is \(TelemetryFormatting.percent(gpu ?? 0)) busy"
    return HeliosCause(
      id: "load.heavy",
      observation: what + (top.map { ", mostly \(appName($0)) (\(TelemetryFormatting.percent($0.cpuPercent ?? 0)) CPU)." } ?? "."),
      reasoning: "Heat follows work: the chip turns load into heat and macOS spins the fans to move it out.",
      confidence: .likely, weight: max(busy ?? 0, gpu ?? 0), evidence: evidence,
      action: top.map(quit) ?? .openActivityMonitor)
  }

  static func hotWhileIdle(_ c: inout Context) -> HeliosCause? {
    guard let thermals = c.thermals(), let cpu = c.cpu() else { return nil }
    let busy = busyPercent(cpu)
    let gpu = c.gpu().flatMap(gpuPercent) ?? 0
    guard busy < 15, gpu < 15, case .success(let hottest) = thermals.maximumSoCCelsius, hottest >= 70 else {
      return nil
    }
    let trusted = (try? thermals.alertMaximumSoCCelsius.get()) != nil
    return HeliosCause(
      id: "heat.idle",
      observation: "The chip reads \(TelemetryFormatting.temperature(hottest)) while it is almost idle.",
      reasoning: trusted
        ? "Without load this is unusual: the vents may be covered, the room hot, or dust may have built up inside."
        : "Without load this is unusual, but this Mac's sensor map is not confirmed yet, so the reading itself may be off.",
      confidence: .possible, weight: hottest,
      evidence: [HeliosCauseEvidence(label: "Hottest sensor", value: TelemetryFormatting.temperature(hottest))],
      action: .openPage("thermals"))
  }

  static func chargingHeat(_ c: inout Context) -> HeliosCause? {
    guard let battery = c.battery(), case .success(let source) = battery.powerSource, source == .powerAdapter,
      case .success(let power) = battery.power, power.signedWatts > 5,
      case .success(let temperature) = battery.temperatureCelsius, temperature >= 35
    else { return nil }
    return HeliosCause(
      id: "heat.charging",
      observation: "The battery is charging at \(TelemetryFormatting.watts(power.signedWatts)) and is \(TelemetryFormatting.temperature(temperature)).",
      reasoning: "Fast charging warms the battery and the case around it.",
      confidence: .possible, weight: temperature, action: .openPage("battery"))
  }

  static func fanFastWithoutLoad(_ c: inout Context) -> HeliosCause? {
    guard c.input.heliosFanRPM == nil, let fans = c.fans(), let cpu = c.cpu(), busyPercent(cpu) < 20 else {
      return nil
    }
    let shares = fans.fans.compactMap { fan -> Double? in
      guard case .success(let actual) = fan.actualRPM, case .success(let maximum) = fan.maximumRPM, maximum > 0
      else { return nil }
      return actual / maximum
    }
    guard let share = shares.max(), share >= 0.6 else { return nil }
    return HeliosCause(
      id: "fan.fastIdle",
      observation: "A fan runs at \(TelemetryFormatting.percent(share * 100)) of its maximum while the processor is nearly idle.",
      reasoning: "macOS may still be cooling after a burst of work, or a hot component other than the CPU (charger, display, SSD) needs air.",
      confidence: .possible, weight: share * 100, action: .openPage("thermals"))
  }

  // MARK: Battery drain

  static func onAdapter(_ c: inout Context) -> HeliosCause? {
    guard let battery = c.battery(), case .success(let source) = battery.powerSource, source == .powerAdapter else {
      return nil
    }
    c.gaps.append("The Mac is on the power adapter right now; the readings below show what would drain the battery.")
    return nil
  }

  static func topEnergyApp(_ c: inout Context) -> HeliosCause? {
    guard let top = c.processes()?.topByEnergy.first(where: { ($0.powerWatts ?? 0) > 0 }),
      let watts = top.powerWatts, watts >= 2
    else { return nil }
    return HeliosCause(
      id: "energy.app",
      observation: "\(appName(top)) uses about \(TelemetryFormatting.watts(watts)).",
      reasoning: "The app using the most energy empties the battery fastest; quitting or pausing it helps the most.",
      confidence: watts >= 5 ? .likely : .possible, weight: watts * 10,
      evidence: [HeliosCauseEvidence(label: appName(top), value: TelemetryFormatting.watts(watts))],
      action: quit(top))
  }

  static func highDischarge(_ c: inout Context) -> HeliosCause? {
    guard let battery = c.battery(), case .success(let power) = battery.power, power.signedWatts <= -15 else {
      return nil
    }
    return HeliosCause(
      id: "energy.discharge",
      observation: "The Mac draws \(TelemetryFormatting.watts(-power.signedWatts)) from the battery.",
      reasoning: "At this rate a full battery lasts only a few hours; screen brightness and busy apps add up.",
      confidence: .possible, weight: -power.signedWatts, action: .openPage("energy"))
  }

  static func sleepBlockers(_ c: inout Context, forDrain: Bool) -> HeliosCause? {
    guard let assertions = c.assertions() else { return nil }
    let blockers = assertions.systemSleepBlockers.filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
    guard let first = blockers.first else { return nil }
    let names = Array(Set(blockers.map(\.processName))).sorted()
    return HeliosCause(
      id: "sleep.blocked",
      observation: "\(names.prefix(3).joined(separator: ", ")) \(names.count == 1 ? "is" : "are") keeping the Mac awake\(first.reason.map { " (\($0))" } ?? "").",
      reasoning: forDrain
        ? "A Mac that cannot sleep keeps using the battery while you are away."
        : "Apps can ask macOS not to sleep, for example while playing, downloading or syncing.",
      confidence: forDrain ? .possible : .likely, weight: Double(80 + blockers.count),
      evidence: blockers.prefix(5).map { HeliosCauseEvidence(label: $0.processName, value: $0.assertionType) },
      action: .quitProcess(pid: first.pid, name: first.processName))
  }

  static func displayBlockers(_ c: inout Context) -> HeliosCause? {
    guard let assertions = c.assertions() else { return nil }
    let blockers = assertions.displaySleepBlockers.filter { !$0.preventsSystemSleep }
    guard let first = blockers.first else { return nil }
    return HeliosCause(
      id: "sleep.display",
      observation: "\(first.processName) keeps the display on\(first.reason.map { " (\($0))" } ?? "").",
      reasoning: "Video, presentations and calls hold the display awake; the Mac usually cannot sleep while they do.",
      confidence: .possible, weight: 60, action: .quitProcess(pid: first.pid, name: first.processName))
  }

  static func keepAwake(_ c: inout Context) -> HeliosCause? {
    guard c.input.keepAwakeActive else { return nil }
    return HeliosCause(
      id: "sleep.keepAwake", observation: "Helios Keep Awake is on.",
      reasoning: "You asked Helios to keep the Mac awake; it lets go when its timer or condition ends.",
      confidence: .likely, weight: 100, action: .stopKeepAwake)
  }

  static func batteryWear(_ c: inout Context) -> HeliosCause? {
    guard let battery = c.battery(), case .success(let health) = battery.healthPercent, health < 80 else {
      return nil
    }
    return HeliosCause(
      id: "battery.wear",
      observation: "The battery holds \(TelemetryFormatting.percent(health)) of its original capacity.",
      reasoning: "A worn battery stores less energy, so it empties sooner even with the same use.",
      confidence: .possible, weight: 100 - health, action: .openPage("battery"))
  }

  static func busyInBackground(_ c: inout Context) -> HeliosCause? {
    guard let cpu = c.cpu(), busyPercent(cpu) >= 50 else { return nil }
    let top = topCPU(c.processes())
    return HeliosCause(
      id: "energy.cpu",
      observation: "The processor is \(TelemetryFormatting.percent(busyPercent(cpu))) busy\(top.map { ", mostly \(appName($0))" } ?? "").",
      reasoning: "Sustained CPU work is the biggest battery cost after the display.",
      confidence: .possible, weight: busyPercent(cpu), action: top.map(quit) ?? .openActivityMonitor)
  }

  static func wakeups(_ c: inout Context) -> HeliosCause? {
    guard let top = c.processes()?.topByEnergy.max(by: { ($0.wakeupsPerSecond ?? 0) < ($1.wakeupsPerSecond ?? 0) }),
      let rate = top.wakeupsPerSecond, rate >= 300
    else { return nil }
    return HeliosCause(
      id: "energy.wakeups",
      observation: "\(appName(top)) wakes the processor \(Int(rate.rounded())) times a second.",
      reasoning: "Frequent wake-ups stop the chip from resting in its low-power states.",
      confidence: .possible, weight: min(60, rate / 20), action: quit(top))
  }

  static func resourceReports(_ c: inout Context, _ kind: DiagnosticReportSummary.Kind) -> HeliosCause? {
    let reports = c.recentReports.filter { $0.kind == kind && $0.process != nil }
    let counts = Dictionary(grouping: reports, by: { $0.process ?? "" })
    guard let (name, items) = counts.max(by: { $0.value.count < $1.value.count }) else { return nil }
    let what: String
    switch kind {
    case .wakeupsResource: what = "woke the Mac too often"
    case .diskWritesResource: what = "wrote unusually much to the disk"
    case .cpuResource: what = "used unusually much CPU"
    default: return nil
    }
    return HeliosCause(
      id: "reports.\(kind.rawValue)",
      observation: "macOS noted that \(name) \(what) (\(items.count)× in the last two weeks).",
      reasoning: "macOS files these reports only when an app goes well beyond normal use.",
      confidence: .possible, weight: 30 + Double(min(items.count, 20)), action: .revealDiagnosticReports)
  }

  // MARK: Restart

  static func kernelPanics(_ c: inout Context) -> HeliosCause? {
    let panics = c.recentReports.filter { $0.kind == .kernelPanic }
    guard let latest = panics.first else { return nil }
    let cause = latest.panicCause ?? .other
    return HeliosCause(
      id: "restart.panic",
      observation: "macOS restarted after a kernel panic on \(date(latest.date))\(panics.count > 1 ? " (\(panics.count) in the last two weeks)" : "").",
      reasoning: "The report points to \(cause.text). Repeated panics with the same cause usually mean one driver, accessory or piece of hardware.",
      confidence: .likely, weight: 100 + Double(panics.count),
      evidence: [HeliosCauseEvidence(label: "Panic cause", value: cause.rawValue)],
      action: .revealDiagnosticReports)
  }

  static func uncleanExit(_ c: inout Context) -> HeliosCause? {
    guard c.input.previousSessionEndedUncleanly == true else { return nil }
    var evidence: [HeliosCauseEvidence] = []
    if let system = c.system() {
      evidence.append(HeliosCauseEvidence(label: "Up since", value: date(c.now.addingTimeInterval(-system.uptimeSeconds))))
    }
    return HeliosCause(
      id: "restart.unclean",
      observation: "Helios did not shut down cleanly last time, and macOS left no panic report.",
      reasoning: "That fits a power loss, a battery that ran empty, a forced restart (holding the power button) or Helios itself quitting unexpectedly.",
      confidence: .possible, weight: 50, evidence: evidence)
  }

  // MARK: Filling disk

  static func topWriters(_ c: inout Context) -> HeliosCause? {
    guard let top = c.processes()?.topSessionWriters.first, top.sessionDiskWriteBytes >= 5_000_000_000 else {
      return nil
    }
    return HeliosCause(
      id: "disk.writer",
      observation: "\(appName(top)) has written \(TelemetryFormatting.storageBytes(top.sessionDiskWriteBytes)) since Helios started.",
      reasoning: "Apps that write a lot (caches, downloads, logs, virtual machines) are where space goes.",
      confidence: .possible, weight: Double(top.sessionDiskWriteBytes) / 1_000_000_000, action: quit(top))
  }

  static func largeSwap(_ c: inout Context) -> HeliosCause? {
    guard let memory = c.memory(), case .success(let swap) = memory.swapUsedBytes, swap >= 4_000_000_000 else {
      return nil
    }
    return HeliosCause(
      id: "disk.swap",
      observation: "macOS is using \(TelemetryFormatting.storageBytes(swap)) of disk as swap.",
      reasoning: "Swap files live on the startup disk and grow when memory runs short; they shrink after a restart.",
      confidence: .possible, weight: Double(swap) / 1_000_000_000, action: .openPage("memory"))
  }
}

/// App names for processes, shared by the engine and its tests.
enum HeliosDiagnosisNames {
  /// The outermost `.app` bundle name ("Claude Helper (Renderer)" → "Claude"), or a plain
  /// name for a known macOS background process; the same names as everywhere else.
  static func app(_ process: ProcessActivity) -> String { HeliosAppIdentity.of(process).name }
}

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
    if let system = systemName(process.name) { return ("sys:" + system.lowercased(), system) }
    return ("proc:" + process.name.lowercased(), process.name)
  }

  /// Plain names for macOS background processes people see in "Right now" without
  /// knowing what they are. Related helpers share a name so they group into one row.
  static func systemName(_ process: String) -> String? {
    if let exact = systemNames[process] { return exact }
    for (prefix, name) in systemPrefixes where process.hasPrefix(prefix) { return name }
    return nil
  }

  private static let systemNames: [String: String] = [
    "kernel_task": "macOS kernel",
    "WindowServer": "WindowServer (drawing the screen)",
    "launchd": "macOS system",
    "mds": "Spotlight indexing", "mds_stores": "Spotlight indexing", "corespotlightd": "Spotlight indexing",
    "photoanalysisd": "Photos analysis", "mediaanalysisd": "Photos analysis", "photolibraryd": "Photos library",
    "bird": "iCloud Drive sync", "cloudd": "iCloud sync", "fileproviderd": "File sync (File Provider)",
    "backupd": "Time Machine backup", "backupd-helper": "Time Machine backup",
    "softwareupdated": "Software Update", "nsurlsessiond": "Background downloads",
    "coreaudiod": "Audio (Core Audio)", "logd": "System logging",
    "trustd": "Security checks", "syspolicyd": "Security checks",
    "XprotectService": "XProtect malware scan", "XProtect": "XProtect malware scan",
    "suggestd": "Siri Suggestions", "siriknowledged": "Siri Suggestions",
    "triald": "macOS feature updates", "lsd": "macOS app database",
  ]

  private static let systemPrefixes: [(String, String)] = [
    ("com.apple.WebKit.WebContent", "Web pages (WebKit)"),
    ("com.apple.WebKit.GPU", "Web graphics (WebKit)"),
    ("com.apple.WebKit.Networking", "Web networking (WebKit)"),
    ("mdworker", "Spotlight indexing"),
    ("spotlightknowledged", "Spotlight indexing"),
    ("com.apple.Safari", "Safari helper"),
  ]
}

