import AppIntents
import Foundation

// Shortcuts actions (PLAN_0_3_0 M6.5). Each one goes through the same paths as the app:
// Keep Awake, the "Why?" engine, the status summary, and FanControlModel only to return
// the fans to macOS. No intent can take the fans or quit apps.

@available(macOS 13.0, *)
enum HeliosQuestion: String, AppEnum {
  case slowMac, hotOrNoisy, batteryDrain, cannotSleep, unexpectedRestart, fillingDisk, slowNetwork

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Question"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .slowMac: "Why is my Mac slow?", .hotOrNoisy: "Why is my Mac hot or loud?",
    .batteryDrain: "Why is the battery draining?", .cannotSleep: "Why doesn't my Mac sleep?",
    .unexpectedRestart: "Why did my Mac restart?", .fillingDisk: "Why is my disk filling up?",
    .slowNetwork: "Why is the internet slow?",
  ]
}

@available(macOS 13.0, *)
struct HeliosKeepAwakeIntent: AppIntent {
  static let title: LocalizedStringResource = "Keep Mac Awake"
  static let description = IntentDescription("Keeps the Mac awake for a number of minutes. It stops by itself on low battery or critical heat.")
  @Parameter(title: "Minutes", default: 60, inclusiveRange: (1, 1_440)) var minutes: Int

  @MainActor func perform() async throws -> some IntentResult {
    HeliosKeepAwake.shared.start(minutes: minutes)
    return .result()
  }
}

@available(macOS 13.0, *)
struct HeliosStopKeepAwakeIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop Keeping Mac Awake"

  @MainActor func perform() async throws -> some IntentResult {
    HeliosKeepAwake.shared.stop(reason: "Stopped by a Shortcut.")
    return .result()
  }
}

@available(macOS 13.0, *)
struct HeliosStatusIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Mac Status"
  static let description = IntentDescription("CPU, memory pressure, the hottest sensor, battery and free disk space as text.")

  @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
    let summary = HeliosStatusSummary.make(HeliosAppState.latestSnapshot, now: Date(),
                                           keepAwake: HeliosKeepAwake.shared.isActive)
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    return .result(value: String(decoding: data, as: UTF8.self))
  }
}

@available(macOS 13.0, *)
struct HeliosAskIntent: AppIntent {
  static let title: LocalizedStringResource = "Ask Helios"
  static let description = IntentDescription("Answers a question about this Mac from its current readings.")
  @Parameter(title: "Question") var question: HeliosQuestion

  @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
    guard let lens = HeliosLens(rawValue: question.rawValue) else { return .result(value: "") }
    let diagnosis = HeliosDiagnose.run(
      lens, HeliosDiagnosisCenter.shared.input(snapshot: HeliosAppState.latestSnapshot))
    let lines = diagnosis.causes.prefix(3).map { "\($0.confidence.label): \($0.observation) \($0.reasoning)" }
    return .result(value: lines.isEmpty ? diagnosis.summary : lines.joined(separator: "\n"))
  }
}

@available(macOS 13.0, *)
struct HeliosReturnFansIntent: AppIntent {
  static let title: LocalizedStringResource = "Return Fans to macOS"
  static let description = IntentDescription("Ends Manual, Auto or Boost fan control; macOS manages the fans again.")

  @MainActor func perform() async throws -> some IntentResult {
    if let url = URL(string: "helios://fans/system") { HeliosAutomationCenter.shared.handle(url) }
    return .result()
  }
}

@available(macOS 13.0, *)
struct HeliosShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: HeliosKeepAwakeIntent(), phrases: ["Keep my Mac awake with \(.applicationName)"],
                shortTitle: "Keep Awake", systemImageName: "cup.and.saucer")
    AppShortcut(intent: HeliosStatusIntent(), phrases: ["Get Mac status from \(.applicationName)"],
                shortTitle: "Mac Status", systemImageName: "sun.max")
    AppShortcut(intent: HeliosAskIntent(), phrases: ["Ask \(.applicationName) about my Mac"],
                shortTitle: "Ask Helios", systemImageName: "questionmark.circle")
  }
}
