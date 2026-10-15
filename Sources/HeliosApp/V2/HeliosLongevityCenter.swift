import AppKit
import OSLog
import UserNotifications

/// Feeds the longevity history from the live telemetry every 30 seconds and runs the two
/// optional reminders. History stays on this Mac; nothing here changes how the Mac charges.
@MainActor
final class HeliosLongevityCenter: ObservableObject {
  static let shared = HeliosLongevityCenter()

  static let sampleInterval: TimeInterval = 30
  static let adapterInterval: TimeInterval = 300
  private static let unplugKey = "v3.longevity.unplugReminder"
  private static let weeklyKey = "v3.longevity.weeklySummary"
  private static let weeklyLastKey = "v3.longevity.weeklySummaryLast"

  @Published private(set) var days: [LongevityDayRecord] = []
  @Published private(set) var adapter: PowerAdapterDetails?
  @Published var unplugReminder: Bool {
    didSet {
      defaults.set(unplugReminder, forKey: Self.unplugKey)
      if unplugReminder { requestNotificationPermission() }
    }
  }
  @Published var weeklySummary: Bool {
    didSet {
      defaults.set(weeklySummary, forKey: Self.weeklyKey)
      // The first summary comes a week after switching it on, not right away.
      if weeklySummary { defaults.set(Date(), forKey: Self.weeklyLastKey); requestNotificationPermission() }
    }
  }

  private let defaults: UserDefaults
  /// nil until the app starts it, so fixture renders never read the user's history.
  private var store: LongevityHistoryStore?
  private let adapterReader = PowerAdapterReader()
  private var reminders = LongevityReminders()
  private var lastSample = Date.distantPast
  private var lastAdapterRead = Date.distantPast
  private var recording = false
  private let logger = Logger(subsystem: "com.snejda.Helios", category: "Longevity")

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    unplugReminder = defaults.bool(forKey: Self.unplugKey)
    weeklySummary = defaults.bool(forKey: Self.weeklyKey)
  }

  /// Opens the history file. Called once by the app at launch.
  func start(store: LongevityHistoryStore = LongevityHistoryStore()) {
    guard self.store == nil else { return }
    self.store = store
    Task { @MainActor [weak self] in
      let loaded = await store.current()
      if let self, self.days.isEmpty { self.days = loaded }
    }
  }

  /// Fixed history for offline renders and screenshots; never used once `start` has run.
  func preview(days: [LongevityDayRecord], adapter: PowerAdapterDetails?) {
    guard store == nil else { return }
    self.days = days
    self.adapter = adapter
  }

  func observe(_ snapshot: TelemetrySnapshot) {
    guard !snapshot.isSuspended else { return }
    let now = Date()
    if unplugReminder, case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 30, now: now) {
      let onAdapter: Bool? = (try? battery.powerSource.get()).map { $0 == .powerAdapter }
      if reminders.shouldRemindToUnplug(
        chargePercent: try? battery.stateOfChargePercent.get(), charging: try? battery.isCharging.get(),
        onAdapter: onAdapter, now: now)
      {
        notify(
          title: "Battery at 80 %",
          body: "Unplugging now, or letting Optimized Battery Charging finish later, slows battery wear. Helios never changes how your Mac charges.")
      }
    }
    let elapsed = now.timeIntervalSince(lastSample)
    guard let store, !recording, elapsed < 0 || elapsed >= Self.sampleInterval else { return }
    lastSample = now
    let onAdapter = (try? TelemetryFormatting.fresh(snapshot.battery, maxAge: 40, now: now).get())
      .flatMap { try? $0.powerSource.get() } == .powerAdapter
    if onAdapter, now.timeIntervalSince(lastAdapterRead) >= Self.adapterInterval || adapter == nil {
      refreshAdapter(now: now)
    } else if !onAdapter {
      adapter = nil
    }
    let sample = LongevitySample(
      snapshot: snapshot, adapter: adapter, pageSizeBytes: UInt64(getpagesize()), now: now)
    recording = true
    Task { @MainActor [weak self, store] in
      let updated = await store.record(sample)
      guard let self else { return }
      self.recording = false
      if self.days != updated { self.days = updated }
      self.sendWeeklySummaryIfDue(snapshot: snapshot, now: now)
    }
  }

  /// Reads the adapter now (the Longevity page opening, or every five minutes on power).
  func refreshAdapter(now: Date = Date()) {
    guard store != nil else { return }
    lastAdapterRead = now
    let details = adapterReader.read()
    if details != adapter { adapter = details }
  }

  func report(snapshot: TelemetrySnapshot, battery: BatteryHealthSummary, now: Date = Date()) -> LongevityReport {
    let hasBattery = HeliosMacAssessment.battery(snapshot, now: now, configuration: .defaults).status != .notPresent
    let current = LongevityCurrent(snapshot: snapshot, adapter: adapter, hasBattery: hasBattery, now: now)
    return LongevityEngine.report(days: days, battery: battery, current: current, now: now)
  }

  /// Writes the current day before the app exits. Called from applicationWillTerminate,
  /// where a plain Task would never run, so it waits (at most a second) for the store.
  func flush() {
    guard let store else { return }
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
      await store.flush()
      done.signal()
    }
    _ = done.wait(timeout: .now() + 1)
  }

  private func sendWeeklySummaryIfDue(snapshot: TelemetrySnapshot, now: Date) {
    guard weeklySummary else { return }
    let last = defaults.object(forKey: Self.weeklyLastKey) as? Date ?? now
    guard LongevityReminders.weeklySummaryDue(last: last, now: now) else { return }
    defaults.set(now, forKey: Self.weeklyLastKey)
    let report = report(snapshot: snapshot, battery: .empty, now: now)
    notify(title: "Your Mac this week", body: LongevityReportDocument.notificationBody(report))
    logger.notice("Weekly health summary posted")
  }

  private func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  private func notify(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(identifier: "helios-longevity-\(UUID().uuidString)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in }
  }
}

/// Saves the report the user asked for, as HTML or PDF. Never sent anywhere.
@MainActor
enum HeliosLongevityExport {
  enum Format { case html, pdf }

  static func save(_ report: LongevityReport, machine: String, format: Format) {
    let period = DateInterval(start: report.generatedAt.addingTimeInterval(-7 * 86_400), end: report.generatedAt)
    let html = LongevityReportDocument.html(report, machine: machine, period: period)
    let panel = NSSavePanel()
    let stamp = report.generatedAt.formatted(.iso8601.year().month().day())
    panel.nameFieldStringValue = "Helios Health Report \(stamp).\(format == .html ? "html" : "pdf")"
    panel.allowedContentTypes = [format == .html ? .html : .pdf]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    switch format {
    case .html:
      try? Data(html.utf8).write(to: url, options: .atomic)
    case .pdf:
      writePDF(html: html, to: url)
    }
  }

  /// Paginated A4/Letter PDF through the text system: no web view, no network.
  private static func writePDF(html: String, to url: URL) {
    guard let text = NSAttributedString(
      html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    else { return }
    let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
    info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 48; info.rightMargin = 48
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    let width = info.paperSize.width - info.leftMargin - info.rightMargin
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    view.textStorage?.setAttributedString(text)
    view.isVerticallyResizable = true
    view.sizeToFit()
    let operation = NSPrintOperation(view: view, printInfo: info)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    operation.run()
  }
}
