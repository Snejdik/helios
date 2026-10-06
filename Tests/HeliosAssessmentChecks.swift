import Foundation

/// Pure checks for the Helios 0.2 assessment and Activity derivation across the
/// deterministic fixture catalog. No UI, services, defaults or clocks.
@MainActor
enum HeliosAssessmentChecks {
  private static func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
  }

  static func run() {
    let now = UIFixtureCatalog.now
    func assess(_ scenario: UIFixtureCatalog.Scenario,
      configuration: HealthAlertConfiguration = .defaults) -> HeliosMacAssessment {
      HeliosMacAssessment.evaluate(UIFixtureCatalog.make(scenario).snapshot, now: now,
        configuration: configuration)
    }

    let healthy = assess(.healthy)
    require(healthy.overall == .normal && healthy.title == "Your Mac is doing well", "Healthy answer")
    require(healthy.focus == nil, "Healthy has no focus area")
    require(healthy.area(.performance)?.status == .normal, "Healthy performance")
    require(healthy.area(.thermals)?.status == .normal, "Healthy thermals")
    require(healthy.area(.battery)?.status == .good, "Healthy battery")
    require(healthy.area(.storage)?.status == .good, "Healthy storage")
    require(healthy.area(.thermals)?.value == "56°C", "Thermal key value is the trusted maximum")

    // Desktop: absence of a battery is not a failure and never blocks "doing well".
    let desktop = assess(.desktop)
    require(desktop.area(.battery)?.status == .notPresent, "Desktop battery is not present")
    require(desktop.overall == .normal, "Desktop is judged without a battery")

    let memory = assess(.memoryWarning)
    require(memory.overall == .attention && memory.focus == .performance, "Memory pressure focus")
    require(memory.area(.performance)?.reason == .memoryPressure, "Memory reason")
    require(memory.area(.performance)?.chartMetric == .memory, "Automatic chart follows the problem")

    let storage = assess(.storageWarning)
    require(storage.area(.storage)?.status == .critical, "SMART critical / media errors are critical")
    let battery = assess(.batteryWarning)
    require(battery.area(.battery)?.status == .critical, "51 °C battery is critical")
    require(battery.area(.battery)?.reason == .batteryTemperature, "Temperature outranks capacity")
    let both = HeliosMacAssessment.summarize([
      memory.area(.performance)!, healthy.area(.thermals)!, battery.area(.battery)!,
      healthy.area(.storage)!,
    ])
    require(both.title == "2 things need attention" && both.overall == .critical,
      "Multiple problems are counted; the worst sets the level")

    // Raw/unclassified 110 °C must never be judged; missing trusted max is partial.
    let raw = assess(.rawThermals)
    require(raw.area(.thermals)?.status == .normal && raw.area(.thermals)?.value == nil,
      "Raw-only thermals are judged from macOS pressure only")
    require(raw.area(.thermals)?.isPartial == true, "Raw-only thermals are partial")
    let noData = assess(.thermalNoData)
    require(noData.area(.thermals)?.isPartial == true, "Empty thermals are partial")

    // Notification switches never hide a problem in the assessment.
    var silenced = HealthAlertConfiguration.defaults
    silenced[.memoryWarning] = HealthAlertSetting(enabled: false, threshold: nil)
    require(assess(.memoryWarning, configuration: silenced).area(.performance)?.status == .attention,
      "Assessment is independent of notification enablement")
    // Thresholds are shared with notifications.
    var strict = HealthAlertConfiguration.defaults
    strict[.socHot] = HealthAlertSetting(enabled: false, threshold: 50)
    require(assess(.healthy, configuration: strict).area(.thermals)?.status == .attention,
      "SoC limit follows the configured notification threshold")

    // Evidence gaps are never "OK".
    let waiting = assess(.waitingForFirstSample)
    require(waiting.overall == .waiting && waiting.title == "Checking your Mac…", "Waiting answer")
    require(waiting.area(.performance)?.status == .waiting, "CPU warm-up is waiting")
    let staleSample = MetricSample<StorageMetrics>(
      UIFixtureCatalog.make(.healthy).snapshot.storage.result,
      capturedAt: now.addingTimeInterval(-40), capturedTicks: UIFixtureCatalog.ticks)
    var staleSnapshot = UIFixtureCatalog.make(.healthy).snapshot
    staleSnapshot.storage = staleSample
    let staleStorage = HeliosMacAssessment.storage(staleSnapshot, now: now, configuration: .defaults)
    require(staleStorage.status == .stale(age: 40), "Stale keeps its real age")
    require(HeliosStatus.stale(age: 40).label == "Stale · 40s", "Stale label")

    // Storage space thresholds.
    var lowSpace = UIFixtureCatalog.make(.healthy).snapshot
    if case .success(let metrics) = lowSpace.storage.result {
      for (free, expected) in [(80_000_000_000 as UInt64, HeliosStatus.attention),
        (40_000_000_000, .critical), (200_000_000_000, .good)]
      {
        lowSpace.storage = MetricSample(.success(StorageMetrics(
          rootVolume: .success(RootVolumeMetrics(totalBytes: 1_000_000_000_000, freeBytes: free)),
          devices: metrics.devices, primaryDeviceBSDName: metrics.primaryDeviceBSDName,
          throughput: metrics.throughput, smartHealth: metrics.smartHealth,
          smartHealthCapturedTicks: metrics.smartHealthCapturedTicks)),
          capturedAt: now, capturedTicks: UIFixtureCatalog.ticks)
        require(HeliosMacAssessment.storage(lowSpace, now: now, configuration: .defaults).status == expected,
          "Free-space threshold \(free)")
      }
    }

    func process(_ path: String?, name: String) -> ProcessActivity {
      ProcessActivity(pid: 1, name: name, executablePath: path, physicalFootprintBytes: 0,
        neuralFootprintBytes: 0, cpuPercent: nil, powerWatts: nil, performanceCorePowerWatts: nil,
        diskReadBytesPerSecond: nil, diskWriteBytesPerSecond: nil, wakeupsPerSecond: nil,
        instructionsPerSecond: nil, cyclesPerSecond: nil, instructionsPerCycle: nil)
    }
    let helper = HeliosAppIdentity.of(process(
      "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
      name: "Claude Helper (Renderer)"))
    require(helper.name == "Claude" && helper.key == "app:/Applications/Claude.app",
      "Helper processes belong to their outermost app")
    require(HeliosAppIdentity.of(process("/usr/libexec/siriactionsd", name: "siriactionsd")).name
      == "siriactionsd", "Non-bundle processes keep their name")
    require(HeliosAppIdentity.of(process(nil, name: "kernel_task")).key == "proc:kernel_task",
      "Unknown paths fall back to the process name")

    func event(_ kind: HeliosActivityEvent.Kind, _ metric: HeliosChartMetric?) -> HeliosActivityEvent {
      HeliosActivityEvent(id: "t", date: now, kind: kind, tone: .neutral, title: "t", source: .history, metric: metric)
    }
    require(event(.issueStarted, .memory).area == .performance, "Memory issues belong to Performance")
    require(event(.peak, .cpu).area == .performance, "CPU peaks belong to Performance")
    require(event(.issueStarted, .temperature).area == .thermals, "Temperature events belong to Thermals")
    require(event(.powerConnected, .battery).area == .battery
      && event(.powerDisconnected, nil).area == .battery, "Power changes belong to Battery")
    require(event(.issueResolved, .disk).area == .storage, "Disk issues belong to Storage")
    require(event(.issueStarted, nil).area == nil, "Unknown metrics have no area")
    require(HeliosActivityFilter.allCases.count == 1 + HeliosArea.allCases.count, "One filter per area plus All")
    require(HeliosActivityFilter.area(.storage).includes(event(.issueStarted, .disk))
      && !HeliosActivityFilter.area(.storage).includes(event(.issueStarted, .memory)), "Area filter matches by area")
    require(!HeliosActivityFilter.all.includes(event(.peak, .cpu), problemsOnly: true)
      && HeliosActivityFilter.all.includes(event(.issueStarted, .cpu), problemsOnly: true), "Problems only drops peaks and power changes")
    require(HeliosMacAssessment.fanWasIdle([0, 0, 10]), "A fan that never ran is idle")
    require(!HeliosMacAssessment.fanWasIdle([0, 2_400]), "A fan that ran is not idle")
    require(!HeliosMacAssessment.fanWasIdle([]), "No readings is not idle (no data is not 'off')")

    activity(now: now)
    print("PASS Helios 0.2 assessment and Activity derivation across fixtures")
  }

  private static func activity(now: Date) {
    func record(_ offset: TimeInterval, _ change: HealthEventRecord.Change, _ id: String,
      severity: Int = 1) -> HealthEventRecord {
      HealthEventRecord(capturedAt: now.addingTimeInterval(offset), change: change, issueID: id,
        severity: severity, title: id, detail: "")
    }
    let records = [
      record(-3_000, .activated, "soc-hot"), record(-2_940, .notified, "soc-hot"),
      record(-2_400, .resolved, "soc-hot"),
      record(-1_800, .activated, "memory-warning"),
      record(-1_200, .activated, "battery-temp-critical", severity: 2),
      record(-600, .activated, "battery-temp-critical", severity: 2),
    ]
    let events = HeliosActivityTimeline.healthEvents(records, activeIssueIDs: ["memory-warning"])
    let soc = events.first { $0.kind == .issueStarted && $0.title == "soc-hot" }
    require(soc?.duration == 600 && soc?.metric == .temperature, "Episode duration and metric")
    require(events.contains { $0.kind == .issueResolved && $0.title == "soc-hot — resolved" },
      "Resolution event")
    require(!events.contains { $0.title.contains("notified") }, "Notified records are not events")
    require(events.first { $0.title == "memory-warning" }?.detail == "Ongoing", "Active issue is ongoing")
    let battery = events.filter { $0.title == "battery-temp-critical" }
    require(battery.count == 2 && battery.allSatisfy { $0.tone == .critical }, "Critical tone")
    require(battery.contains { $0.detail == "End not recorded" }, "Unpaired activation is honest")

    // A reading hovering at its threshold is one episode; a return after a real pause is another.
    let flapping = [
      record(-5_000, .activated, "memory-critical"), record(-4_950, .resolved, "memory-critical"),
      record(-4_900, .activated, "memory-critical"), record(-4_850, .resolved, "memory-critical"),
      record(-4_800, .activated, "memory-critical"), record(-4_700, .resolved, "memory-critical"),
      record(-2_000, .activated, "memory-critical"), record(-1_900, .resolved, "memory-critical"),
    ]
    let flapEvents = HeliosActivityTimeline.healthEvents(flapping, activeIssueIDs: [])
    let flapStarts = flapEvents.filter { $0.kind == .issueStarted }.sorted { $0.date < $1.date }
    require(flapStarts.count == 2, "Three quick flaps and one later return are two episodes")
    require(flapStarts[0].duration == 300 && flapStarts[0].detail?.contains("3 times") == true,
      "The merged episode spans first start to last end and says how often it came back")
    require(flapStarts[1].duration == 100 && flapStarts[1].detail?.contains("times") != true,
      "A separate episode is not labelled as repeated")
    require(flapEvents.filter { $0.kind == .issueResolved }.count == 2, "One resolution per episode")
    let openFlap = HeliosActivityTimeline.healthEvents(
      [record(-300, .activated, "memory-critical"), record(-250, .resolved, "memory-critical"),
       record(-200, .activated, "memory-critical")], activeIssueIDs: ["memory-critical"])
    require(openFlap.count == 1 && openFlap[0].detail?.contains("Happened 2 times") == true,
      "A flap that is still active stays one ongoing episode")
    require(HeliosActivityTimeline.mergingFlaps(flapping).records.count == 4,
      "The stored log is not rewritten; only the derived records are merged")

    // Brief spikes spread over a day collapse into one line; a longer episode stays its own.
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let dayStart = utcCalendar.startOfDay(for: now)
    func at(_ hour: Double, _ change: HealthEventRecord.Change, _ id: String) -> HealthEventRecord {
      HealthEventRecord(capturedAt: dayStart.addingTimeInterval(hour * 3_600), change: change,
        issueID: id, severity: 1, title: id, detail: "")
    }
    var spikes: [HealthEventRecord] = []
    for hour in [1.0, 3.0, 5.0, 7.0] {
      spikes.append(at(hour, .activated, "memory-warning"))
      spikes.append(HealthEventRecord(capturedAt: dayStart.addingTimeInterval(hour * 3_600 + 40),
        change: .resolved, issueID: "memory-warning", severity: 1, title: "memory-warning", detail: ""))
    }
    spikes.append(at(9, .activated, "memory-warning"))
    spikes.append(HealthEventRecord(capturedAt: dayStart.addingTimeInterval(9 * 3_600 + 300),
      change: .resolved, issueID: "memory-warning", severity: 1, title: "memory-warning", detail: ""))
    let spikeEvents = HeliosActivityTimeline.healthEvents(spikes, activeIssueIDs: [], calendar: utcCalendar)
    let brief = spikeEvents.filter { $0.detail?.contains("Brief spikes: 4 times") == true }
    require(brief.count == 1 && brief[0].kind == .issueStarted && brief[0].duration == nil,
      "Four brief episodes on one day are one summary line")
    require(spikeEvents.filter { $0.kind == .issueResolved }.count == 1
      && spikeEvents.filter { $0.kind == .issueStarted }.count == 2,
      "Their start/resolved pairs are gone; the five-minute episode keeps its own pair")
    let twoSpikes = HeliosActivityTimeline.healthEvents(Array(spikes.prefix(4)), activeIssueIDs: [],
      calendar: utcCalendar)
    require(twoSpikes.filter { $0.kind == .issueStarted }.count == 2,
      "Fewer than three brief episodes are not collapsed")
    let orphan = HeliosActivityTimeline.healthEvents(
      [record(-100, .resolved, "memory-warning")], activeIssueIDs: [])
    require(orphan.count == 1 && orphan[0].kind == .issueResolved,
      "A resolution whose start is older than the log is still shown")

    func point(_ offset: TimeInterval, ac: Bool?, cpu: Double? = 10, soc: Double? = 50)
      -> PersistedTelemetryPoint {
      PersistedTelemetryPoint(capturedAt: now.addingTimeInterval(offset), cpuPercent: cpu,
        gpuPercent: nil, maxSoCCelsius: soc, systemPowerWatts: nil, batteryPercent: nil,
        batteryOnAC: ac, storageTemperatureCelsius: nil, fanRPM: nil,
        networkDownloadBytesPerSecond: nil, networkUploadBytesPerSecond: nil)
    }
    let history = [
      point(-600, ac: true), point(-570, ac: false, cpu: 92), point(-540, ac: nil, soc: 88),
      point(-300, ac: true),
    ]
    let power = HeliosActivityTimeline.powerEvents(history)
    require(power.count == 2, "Two observed power transitions; nil is not a transition")
    require(power[0].kind == .powerDisconnected && power[0].detail == nil, "Precise transition")
    require(power[1].kind == .powerConnected && power[1].detail != nil, "Transition across a gap is qualified")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let peaks = HeliosActivityTimeline.peakEvents(history, calendar: utc)
    require(peaks.contains { $0.metric == .temperature && $0.title.contains("88") }, "Temperature peak")
    require(peaks.contains { $0.metric == .cpu && $0.title.contains("92") }, "Substantial CPU peak")
    require(HeliosActivityTimeline.peakEvents([point(-60, ac: nil, cpu: 30)], calendar: utc)
      .allSatisfy { $0.metric != .cpu }, "Small CPU peaks are not events")

    let all = HeliosActivityTimeline.events(health: records, history: history,
      activeIssueIDs: [], calendar: utc)
    require(zip(all, all.dropFirst()).allSatisfy { $0.date >= $1.date }, "Newest first")
    let markers = HeliosActivityTimeline.markers(all, metric: .temperature,
      from: now.addingTimeInterval(-2_700), to: now)
    require(markers.allSatisfy { $0.date >= now.addingTimeInterval(-2_700) }, "Markers stay in range")
    require(markers.contains { $0.label == "soc-hot — resolved" }, "Relevant markers included")
    require(!markers.contains { $0.label.contains("memory") }, "Unrelated metric excluded")
    require(markers.contains { $0.label == "Power adapter connected" }, "Power markers on every chart")
  }
}
