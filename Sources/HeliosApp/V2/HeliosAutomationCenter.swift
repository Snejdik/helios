import AppKit
import OSLog
import SwiftUI
import UserNotifications

/// Runs the user's "if → then" rules and "tell me when it's done" watches against the
/// live telemetry, and executes `helios://` links. Does nothing (no work per sample) while
/// there are no rules and no watches. Fan actions go only through FanControlModel.setMode
/// and its gates; Shortcuts run by name through the shortcuts:// URL, no process is started.
@MainActor
final class HeliosAutomationCenter: ObservableObject {
  static let shared = HeliosAutomationCenter()

  @Published private(set) var rules: [HeliosRule] = HeliosRuleStore.load()
  @Published private(set) var watches: [HeliosDoneWatch] = []
  @Published private(set) var lastEvent: String?
  private var engine = HeliosRuleEngine()
  private let logger = Logger(subsystem: "com.snejda.Helios", category: "Automation")

  /// Set by the app: open a page, change the fan mode through FanControlModel.
  var openPage: (HeliosPage) -> Void = { _ in }
  var setFanMode: (FanControlSelection) -> Void = { _ in }

  // MARK: Rules

  func setRules(_ rules: [HeliosRule]) {
    let valid = Array(rules.prefix(HeliosRule.maximumCount)).filter(HeliosRuleStore.valid)
    self.rules = valid
    HeliosRuleStore.save(valid)
  }

  func add(_ rule: HeliosRule) { setRules(rules + [rule]) }
  func remove(_ id: UUID) { setRules(rules.filter { $0.id != id }) }
  func toggle(_ id: UUID) {
    setRules(rules.map { rule in
      var rule = rule
      if rule.id == id { rule.enabled.toggle() }
      return rule
    })
  }

  // MARK: Watches

  func watch(_ kind: HeliosDoneWatch.Kind) {
    guard watches.count < 10 else { return }
    watches.append(HeliosDoneWatch(kind: kind, startedAt: Date()))
    requestNotificationPermissionIfNeeded()
  }

  func cancelWatch(_ id: UUID) { watches.removeAll { $0.id == id } }

  // MARK: Telemetry

  func observe(_ snapshot: TelemetrySnapshot) {
    guard !rules.isEmpty || !watches.isEmpty else { return }
    let now = Date()
    let cpuBusy = (try? TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now).get())
      .map { max(0, 100 - $0.idlePercent) }
    if rules.contains(where: \.enabled) {
      var inputs = HeliosRuleInputs(now: now, cpuBusyPercent: cpuBusy)
      if case .success(let thermals) = TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now) {
        inputs.hottestCelsius = try? thermals.maximumSoCCelsius.get()
      }
      if case .success(let battery) = TelemetryFormatting.fresh(snapshot.battery, maxAge: 30, now: now) {
        inputs.batteryPercent = try? battery.stateOfChargePercent.get()
        if case .success(let source) = battery.powerSource { inputs.onBattery = source == .battery }
      }
      if rules.contains(where: { if case .appRunning = $0.trigger { return true }; return false }) {
        inputs.runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
      }
      for rule in engine.evaluate(rules, inputs) { perform(rule) }
    }
    guard !watches.isEmpty else { return }
    var inputs = HeliosDoneInputs(now: now, cpuBusyPercent: cpuBusy)
    if watches.contains(where: { if case .processExits = $0.kind { return true }; return false }) {
      inputs.runningPIDs = Self.runningPIDs()
    }
    if case .success(let network) = TelemetryFormatting.fresh(snapshot.network, maxAge: 5, now: now),
      case .success(let throughput) = network.throughput
    {
      inputs.downloadBytesPerSecond = throughput.downloadBytesPerSecond
    }
    var remaining: [HeliosDoneWatch] = []
    for watch in watches {
      let (next, message) = HeliosDoneWatcher.step(watch, inputs)
      if let message { notify(title: "Helios", body: message) } else { remaining.append(next) }
    }
    watches = remaining
  }

  private static func runningPIDs() -> Set<Int32>? {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) + 32)
    let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard filled > 0 else { return nil }
    return Set(pids.prefix(Int(filled)).filter { $0 > 0 })
  }

  private func perform(_ rule: HeliosRule) {
    logger.notice("Rule fired: \(rule.trigger.title, privacy: .public) → \(rule.action.title, privacy: .public)")
    lastEvent = "\(rule.trigger.title) → \(rule.action.title)"
    switch rule.action {
    case .notify(let text): notify(title: rule.trigger.title, body: text)
    case .keepAwake(let minutes): HeliosKeepAwake.shared.start(minutes: minutes)
    case .stopKeepAwake: HeliosKeepAwake.shared.stop(reason: "Stopped by a rule.")
    case .fansToSystem: setFanMode(.system)
    case .fansAuto: setFanMode(.auto)
    case .runShortcut(let name): Self.runShortcut(name)
    }
  }

  /// Through the Shortcuts URL scheme; Helios starts no process of its own.
  static func runShortcut(_ name: String) {
    guard !name.isEmpty, name.count <= HeliosRule.maximumShortcutNameLength,
      let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)")
    else { return }
    NSWorkspace.shared.open(url)
  }

  // MARK: Notifications

  private func requestNotificationPermissionIfNeeded() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func notify(title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: "helios-automation-\(UUID().uuidString)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in }
  }

  // MARK: helios:// links

  func handle(_ url: URL) {
    guard let command = HeliosURLCommand.parse(url) else {
      logger.notice("Ignored an unknown helios:// link")
      return
    }
    switch command {
    case .openPage(let name):
      if let page = HeliosPage(rawValue: name) { openPage(page) }
    case .ask(let lens):
      HeliosDiagnosisCenter.shared.requestedLens = lens
      openPage(.overview)
    case .keepAwake(let minutes): HeliosKeepAwake.shared.start(minutes: minutes)
    case .stopKeepAwake: HeliosKeepAwake.shared.stop(reason: "Stopped by a link.")
    case .networkCheck:
      HeliosDiagnosisCenter.shared.runNetworkCheck()
      openPage(.network)
    case .fansToSystem: setFanMode(.system)
    }
  }
}

/// Overview: start a "tell me when it's done" watch and see the running ones.
struct HeliosDoneWatchRow: View {
  @ObservedObject var model: OverviewViewModel
  @ObservedObject private var automation = HeliosAutomationCenter.shared

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Label(automation.watches.first?.title ?? "Tell me when it's done", systemImage: "bell")
        .foregroundStyle(automation.watches.isEmpty ? .secondary : .primary)
      if automation.watches.count > 1 { Text("+\(automation.watches.count - 1)").foregroundStyle(.secondary) }
      Spacer(minLength: 8)
      if let first = automation.watches.first {
        Button("Cancel") { automation.cancelWatch(first.id) }
      }
      Menu("Notify Me") {
        if let top = (try? model.snapshot.processes.result.get())?.topByCPU.first(where: { ($0.cpuPercent ?? 0) > 5 }) {
          Button("When \(HeliosDiagnosisNames.app(top)) Finishes") {
            automation.watch(.processExits(pid: top.pid, name: HeliosDiagnosisNames.app(top)))
          }
        }
        Button("When the Mac Calms Down") { automation.watch(.cpuCalms) }
        Button("When the Download Finishes") { automation.watch(.downloadFinishes) }
      }
      .fixedSize()
    }
  }
}

/// Settings › Automation: rules ("if → then"), the command palette shortcut and the
/// command-line status file. Every tool here can be switched off completely.
struct HeliosAutomationSettings: View {
  @ObservedObject private var automation = HeliosAutomationCenter.shared
  @ObservedObject private var palette = HeliosCommandPalette.shared
  @ObservedObject private var status = HeliosStatusFile.shared
  @State private var trigger = TriggerChoice.temperature
  @State private var triggerValue = 85.0
  @State private var action = ActionChoice.notify
  @State private var actionText = "Your Mac is hot"
  @State private var actionMinutes = 30

  enum TriggerChoice: String, CaseIterable, Identifiable {
    case temperature = "Hottest sensor above (°C)"
    case battery = "Battery below (%)"
    case cpu = "CPU busier than (%)"
    case onBattery = "Mac switches to battery"
    case onAdapter = "Mac is plugged in"
    var id: String { rawValue }
    var needsValue: Bool { self == .temperature || self == .battery || self == .cpu }
    /// A sensible starting value whenever the trigger changes.
    var defaultValue: Double {
      switch self {
      case .temperature: 85
      case .battery: 20
      case .cpu: 80
      case .onBattery, .onAdapter: 0
      }
    }
  }

  enum ActionChoice: String, CaseIterable, Identifiable {
    case notify = "Notify me"
    case keepAwake = "Keep the Mac awake"
    case stopKeepAwake = "Stop Keep Awake"
    case fansToSystem = "Return the fans to macOS"
    case fansAuto = "Turn on Auto fan control"
    case shortcut = "Run a Shortcut"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Rules") {
        VStack(alignment: .leading, spacing: 8) {
          if automation.rules.isEmpty {
            Text("No rules yet. A rule does one safe thing when something happens, for example notify you when the Mac gets hot.")
              .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          ForEach(automation.rules) { rule in
            HStack {
              Toggle("", isOn: Binding(get: { rule.enabled }, set: { _ in automation.toggle(rule.id) }))
                .labelsHidden()
              Text("\(rule.trigger.title) → \(rule.action.title)")
              Spacer()
              Button(role: .destructive) { automation.remove(rule.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete rule")
            }
          }
          Divider()
          newRule
          Text("Rules fire once when their condition becomes true, at most once a minute each and 30 times an hour in total. Fan rules use the same safety checks as the Thermals page; no rule can run a script.")
            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      GroupBox("Command palette") {
        VStack(alignment: .leading, spacing: 6) {
          Toggle("Open with \(HeliosCommandPalette.shortcutLabel) from anywhere", isOn: Binding(
            get: { palette.enabled }, set: { palette.setEnabled($0) }))
          Text("Jump to a page, ask a question or run an action by typing. The shortcut needs no Accessibility permission.")
            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if palette.enabled, palette.registrationFailed {
            Label("Another app already uses \(HeliosCommandPalette.shortcutLabel), so the palette cannot open with it.",
                  systemImage: "exclamationmark.triangle")
              .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      GroupBox("Links and command line") {
        VStack(alignment: .leading, spacing: 6) {
          Toggle("Write a status file for the command line", isOn: Binding(
            get: { status.enabled }, set: { status.setEnabled($0) }))
          Text("`helios status` reads it (the script is inside Helios.app/Contents/Resources). Links such as helios://keep-awake?minutes=30 or helios://open/thermals work in Shortcuts and other apps; a link can never take the fans from macOS or quit an app.")
            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var newRule: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("When", selection: $trigger) { ForEach(TriggerChoice.allCases) { Text($0.rawValue).tag($0) } }
          .fixedSize()
        if trigger.needsValue {
          TextField("", value: $triggerValue, format: .number).frame(width: 60)
        }
      }
      .onChange(of: trigger) { triggerValue = $0.defaultValue }
      HStack {
        Picker("Then", selection: $action) { ForEach(ActionChoice.allCases) { Text($0.rawValue).tag($0) } }
          .fixedSize()
        switch action {
        case .notify, .shortcut: TextField(action == .notify ? "Message" : "Shortcut name", text: $actionText).frame(width: 200)
        case .keepAwake: Stepper("\(actionMinutes) min", value: $actionMinutes, in: 5...600, step: 5)
        default: EmptyView()
        }
        Button("Add Rule") { automation.add(candidate) }
          .disabled(automation.rules.count >= HeliosRule.maximumCount || !HeliosRuleStore.valid(candidate))
      }
      if !HeliosRuleStore.valid(candidate) {
        Text(trigger == .temperature ? "Use a temperature from 30 to 110 °C." : trigger.needsValue
          ? "Use a value from 1 to 99 %." : action == .keepAwake ? "Use 1 to 1,440 minutes."
          : action == .notify ? "Enter a message of up to 200 characters." : "Enter a Shortcut name of up to 100 characters.")
          .font(.subheadline).foregroundStyle(.secondary)
      }
    }
  }

  private var candidate: HeliosRule {
    let ruleTrigger: HeliosRule.Trigger
    switch trigger {
    case .temperature: ruleTrigger = .temperatureAbove(triggerValue)
    case .battery: ruleTrigger = .batteryBelow(triggerValue)
    case .cpu: ruleTrigger = .cpuAbove(triggerValue)
    case .onBattery: ruleTrigger = .powerSourceIs(battery: true)
    case .onAdapter: ruleTrigger = .powerSourceIs(battery: false)
    }
    let ruleAction: HeliosRule.Action
    switch action {
    case .notify: ruleAction = .notify(actionText)
    case .keepAwake: ruleAction = .keepAwake(minutes: actionMinutes)
    case .stopKeepAwake: ruleAction = .stopKeepAwake
    case .fansToSystem: ruleAction = .fansToSystem
    case .fansAuto: ruleAction = .fansAuto
    case .shortcut: ruleAction = .runShortcut(actionText)
    }
    return HeliosRule(trigger: ruleTrigger, action: ruleAction)
  }
}
