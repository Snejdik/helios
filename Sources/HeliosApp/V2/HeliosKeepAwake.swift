import AppKit
import IOKit.pwr_mgt
import OSLog
import SwiftUI

/// Keep Awake controller: one or two IOPMAssertions named "Helios Keep Awake", evaluated
/// against `HeliosKeepAwakePolicy` every 15 seconds and on every telemetry update. Nothing
/// runs and nothing is held while it is off. Ends itself on low battery or critical heat.
@MainActor
final class HeliosKeepAwake: ObservableObject {
  static let shared = HeliosKeepAwake()
  static let assertionName = "Helios Keep Awake"

  @Published private(set) var request: HeliosKeepAwakeRequest?
  /// Why it ended last time (shown once).
  @Published private(set) var lastEndReason: String?

  private var systemAssertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
  private var displayAssertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
  private var timer: Timer?
  private var latestConditions = HeliosKeepAwakeConditions(now: Date())
  private let logger = Logger(subsystem: "com.snejda.Helios", category: "KeepAwake")

  var isActive: Bool { request != nil }

  func start(_ request: HeliosKeepAwakeRequest) {
    stopAssertions()
    guard createAssertion(kIOPMAssertPreventUserIdleSystemSleep, into: &systemAssertion) else {
      lastEndReason = "macOS did not accept the Keep Awake request."
      return
    }
    if request.keepDisplayOn {
      _ = createAssertion(kIOPMAssertPreventUserIdleDisplaySleep, into: &displayAssertion)
    }
    self.request = request
    lastEndReason = nil
    logger.notice("Keep Awake started: \(request.summary, privacy: .public)")
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
      Task { @MainActor in HeliosKeepAwake.shared.evaluate() }
    }
    evaluate()
  }

  /// Convenience for menus, the palette and the URL scheme.
  func start(minutes: Int, display: Bool = false) {
    start(.forDuration(TimeInterval(max(1, min(minutes, 24 * 60)) * 60), from: Date(), display: display))
  }

  func stop(reason: String? = nil) {
    guard request != nil else { return }
    stopAssertions()
    request = nil
    timer?.invalidate()
    timer = nil
    lastEndReason = reason
    logger.notice("Keep Awake stopped\(reason.map { ": \($0)" } ?? "", privacy: .public)")
  }

  /// Feeds the latest power and thermal state (from the telemetry snapshot).
  func observe(_ snapshot: TelemetrySnapshot) {
    guard request != nil else { return }
    var conditions = HeliosKeepAwakeConditions(now: Date())
    if case .success(let battery) = snapshot.battery.result {
      if case .success(let source) = battery.powerSource { conditions.onBattery = source == .battery }
      conditions.chargePercent = try? battery.stateOfChargePercent.get()
    }
    if case .success(let system) = snapshot.system.result { conditions.thermalState = system.thermalState }
    latestConditions = conditions
    evaluate()
  }

  private func evaluate() {
    guard let request else { return }
    var conditions = latestConditions
    conditions.now = Date()
    if case .appQuits = request.until {
      conditions.runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
    if case .release(let reason) = HeliosKeepAwakePolicy.decision(request, conditions) {
      stop(reason: reason)
    }
  }

  private func createAssertion(_ type: String, into id: inout IOPMAssertionID) -> Bool {
    IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                Self.assertionName as CFString, &id) == kIOReturnSuccess
  }

  private func stopAssertions() {
    for id in [systemAssertion, displayAssertion] where id != IOPMAssertionID(kIOPMNullAssertionID) {
      IOPMAssertionRelease(id)
    }
    systemAssertion = IOPMAssertionID(kIOPMNullAssertionID)
    displayAssertion = IOPMAssertionID(kIOPMNullAssertionID)
  }
}

/// Keep Awake on the Overview and in the menu-bar popover: state, a menu to start, Stop.
struct HeliosKeepAwakeRow: View {
  var compact = false
  @ObservedObject private var keepAwake = HeliosKeepAwake.shared

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Label(keepAwake.request?.summary ?? "Keep Awake is off", systemImage: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
        .foregroundStyle(keepAwake.isActive ? .primary : .secondary)
        .help(HeliosKeepAwakePolicy.closedLidNote)
      Spacer(minLength: 8)
      if keepAwake.isActive {
        Button("Stop") { keepAwake.stop(reason: nil) }
      } else {
        Menu("Keep Awake") {
          Button("15 Minutes") { keepAwake.start(minutes: 15) }
          Button("1 Hour") { keepAwake.start(minutes: 60) }
          Button("2 Hours") { keepAwake.start(minutes: 120) }
          Divider()
          Button("While on Power Adapter") {
            keepAwake.start(HeliosKeepAwakeRequest(until: .onPowerAdapter, keepDisplayOn: false, startedAt: Date()))
          }
          Button("Until I Stop It") {
            keepAwake.start(HeliosKeepAwakeRequest(until: .stopped, keepDisplayOn: false, startedAt: Date()))
          }
          Button("1 Hour, Display On Too") { keepAwake.start(minutes: 60, display: true) }
          if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier,
            id != Bundle.main.bundleIdentifier, let name = front.localizedName
          {
            Divider()
            Button("While \(name) Runs") {
              keepAwake.start(HeliosKeepAwakeRequest(
                until: .appQuits(bundleID: id, name: name), keepDisplayOn: false, startedAt: Date()))
            }
          }
        }
        .fixedSize()
      }
    }
    .font(compact ? .subheadline : .body)
    .accessibilityElement(children: .contain)
    if let reason = keepAwake.lastEndReason, !compact {
      Text(reason).font(.subheadline).foregroundStyle(.secondary)
    }
  }
}
