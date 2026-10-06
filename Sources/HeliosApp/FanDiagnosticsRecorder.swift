import Combine
import Foundation

/// Watches the fan model and the helper connection and keeps what happened in
/// memory. Nothing is stored on disk and nothing is recorded unless the user
/// turned on fan-control statistics; the data leaves the Mac only inside a
/// diagnostics report the user can read first.
@MainActor
final class FanDiagnosticsRecorder {
  private let model: FanControlModel
  private let client: DaemonClient
  private let isEnabled: () -> Bool
  private let now: () -> Date
  private let lowPowerMode: () -> Bool
  private var data = FanDiagnosticsData()
  private var subscriptions: Set<AnyCancellable> = []
  private var handoverStartedAt: Date?
  private var fanHeld = false
  private var lastRecorded: [FanDiagnosticEvent: Date] = [:]
  private var onBattery: Bool?

  /// The same event is not counted twice within this time: helper messages repeat
  /// on every poll while a condition lasts.
  static let repeatInterval: TimeInterval = 60

  init(
    model: FanControlModel, client: DaemonClient, isEnabled: @escaping () -> Bool,
    now: @escaping () -> Date = Date.init,
    lowPowerMode: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
  ) {
    self.model = model
    self.client = client
    self.isEnabled = isEnabled
    self.now = now
    self.lowPowerMode = lowPowerMode
    fanHeld = client.fanState == .boost || client.fanState == .override

    // The start is kept until the helper answers: the model clears its own
    // `handingOver` flag in the same update that reports the held state, so
    // reading the flag at that point would always find the takeover over.
    model.$handingOver.removeDuplicates().sink { [weak self] handingOver in
      guard let self, handingOver, self.handoverStartedAt == nil else { return }
      self.handoverStartedAt = self.now()
    }.store(in: &subscriptions)
    model.$selection.removeDuplicates().dropFirst().sink { [weak self] selection in
      switch selection {
      case .auto: self?.record(.mode(.auto))
      case .override: self?.record(.mode(.manual))
      case .boost: self?.record(.mode(.boost))
      case .system: break
      }
    }.store(in: &subscriptions)
    client.$fanState.removeDuplicates().sink { [weak self] state in
      guard let self else { return }
      let wasHeld = self.fanHeld
      self.fanHeld = state == .boost || state == .override
      guard self.fanHeld else {
        self.handoverStartedAt = nil
        return
      }
      // Switching between Boost and Manual while the fans are held is not a takeover.
      guard !wasHeld else { return }
      let seconds = self.handoverStartedAt.map { max(0, self.now().timeIntervalSince($0)) }
      self.handoverStartedAt = nil
      self.record(.takeoverHeld, seconds: seconds)
    }.store(in: &subscriptions)
    client.$fanControlFaultRevision.dropFirst().sink { [weak self] _ in
      guard let self else { return }
      self.record(FanDiagnosticsSummary.failureEvent(forDetail: self.client.fanDetail))
    }.store(in: &subscriptions)
    client.$fanDetail.removeDuplicates().sink { [weak self] detail in
      if detail.hasPrefix(FanLayerCeiling.handbackPrefix) {
        self?.record(.handbackOverLimit)
      } else if detail.hasPrefix(FanControlModel.macOSAlreadyCoolingPrefix) {
        self?.record(.handbackMacOSCooling)
      } else if detail.hasPrefix(FanLayerReacquireCooldown.replyPrefix) {
        self?.record(.cooldownWait)
      }
    }.store(in: &subscriptions)
  }

  /// Called with every telemetry snapshot: power source for the refusal context
  /// and the highest temperature and fan speed seen.
  func observe(_ snapshot: TelemetrySnapshot) {
    guard isEnabled() else { return }
    if case .success(let battery) = snapshot.battery.result,
      case .success(let source) = battery.powerSource
    {
      onBattery = source == .battery
    }
    var temperature: Double?
    if case .success(let thermals) = snapshot.thermals.result,
      case .success(let hottest) = thermals.maximumSoCCelsius
    {
      temperature = hottest
    }
    var share: Double?
    if case .success(let inventory) = snapshot.fans.result, let fan = inventory.fans.first,
      case .success(let actual) = fan.actualRPM, case .success(let maximum) = fan.maximumRPM, maximum > 0
    {
      share = actual / maximum * 100
    }
    data.observe(temperatureCelsius: temperature, fanSharePercent: share)
  }

  /// The section for a report, or nil while the helper has not reported the layer.
  func report() -> DiagnosticsFanLayer? {
    guard isEnabled(), let layer = client.fanLayer else { return nil }
    let tier: DiagnosticsFanTier = switch layer.tier {
    case .unsupported: .unsupported
    case .experimental: .experimental
    case .validated: .validated
    }
    let settings = FanDiagnosticsSettings(
      tier: tier, controlEnabled: layer.consented && layer.available,
      speedLimitUnlocked: layer.fullMaximumAllowed, autoUsesCurve: model.curves.usesCurve,
      restoreAuto: model.restoresAutoOnStart)
    return FanDiagnosticsSummary.report(data: data, settings: settings)
  }

  /// Turning the statistics off discards what was recorded.
  func clear() {
    data = FanDiagnosticsData()
    lastRecorded = [:]
  }

  private func record(_ event: FanDiagnosticEvent, seconds: Double? = nil) {
    guard isEnabled() else { return }
    let moment = now()
    switch event {
    case .handbackOverLimit, .handbackMacOSCooling, .cooldownWait, .mode:
      if let last = lastRecorded[event], moment.timeIntervalSince(last) < Self.repeatInterval { return }
      lastRecorded[event] = moment
    default: break
    }
    data.append(FanDiagnosticRecord(
      event: event, seconds: seconds, onBattery: onBattery, lowPowerMode: lowPowerMode()))
  }
}
