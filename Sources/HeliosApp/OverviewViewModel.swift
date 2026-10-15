import AppKit
import SwiftUI

@MainActor
final class OverviewViewModel: ObservableObject {
  @Published var snapshot = TelemetrySnapshot() {
    didSet { presentation = OverviewPresentation(snapshot) }
  }
  /// Freshness-evaluated view of `snapshot`, derived once per publication. Views
  /// read it as a stored value rather than rebuilding it on every property access.
  private(set) var presentation = OverviewPresentation(TelemetrySnapshot())
  // `snapshot` is the single 1 Hz live invalidation. History is appended in the
  // same synchronous accept() call, so publishing it separately would make every
  // open SwiftUI telemetry surface recompute twice for one sample.
  var history = TelemetryHistory()
  @Published var persistentHistory = PersistentHistorySummary.empty
  @Published var ioAudit = IOActivitySummary.empty
  @Published var appEnergy = AppEnergySummary.empty
  /// One record a day: the long-term battery trend (Battery page).
  @Published var batteryHealth = BatteryHealthSummary.empty
  @Published private(set) var smcNumericSample: MetricSample<SMCNumericMetrics>?
  @Published private(set) var smcNumericLoading = false
  typealias SMCNumericSampler = @Sendable (Int) async -> MetricSample<SMCNumericMetrics>
  private let smcNumericSampler: SMCNumericSampler?
  private var smcNumericTask: Task<Void, Never>?
  private var smcNumericRequestID: UUID?
  let healthCenter: HealthAlertCenter
  private let historyStore: PersistentHistoryStore?
  private let ioAuditStore: IOActivityAuditStore?
  private let appEnergyStore: AppEnergyHistoryStore?
  private let batteryHealthStore: BatteryHealthHistoryStore?
  private var appEnergyTask: Task<Void, Never>?
  private var stopped = false
  var onDetailDemandChange: ((TelemetryDetailDemand) -> Void)?
  private(set) var detailDemand: TelemetryDetailDemand = []
  private var surfaceDemands = TelemetryDetailDemandRegistry()

  func setDetailDemand(_ demand: TelemetryDetailDemand, owner: String) {
    guard !stopped else { return }
    guard surfaceDemands.set(demand, owner: owner) else { return }
    detailDemand = surfaceDemands.demand
    onDetailDemandChange?(detailDemand)
  }
  private var pendingAppEnergyHasGap = false
  private var pendingAppEnergy: (snapshot: TelemetrySnapshot, capturedAt: Date)?
  private var persistenceInFlight = false
  private var lastPersistenceAttempt = Date.distantPast
  private var lastAppEnergyProcessTicks: UInt64?

  /// The live app uses persistent/history/notification services by default.
  /// Presentation fixtures can disable them so native SwiftUI rendering remains
  /// deterministic and never depends on being hosted inside a .app bundle.
  init(runtimeServicesEnabled: Bool = true,
    alertConfiguration: @escaping @MainActor () -> HealthAlertConfiguration = { .defaults },
    smcNumericSampler: SMCNumericSampler? = nil) {
    if let smcNumericSampler {
      self.smcNumericSampler = smcNumericSampler
    } else if runtimeServicesEnabled {
      self.smcNumericSampler = { maximumReadings in
        await SMCNumericProvider().sample(maximumReadings: maximumReadings)
      }
    } else {
      self.smcNumericSampler = nil
    }
    healthCenter = HealthAlertCenter(runtimeServicesEnabled: runtimeServicesEnabled,
      configuration: alertConfiguration)
    guard runtimeServicesEnabled else {
      historyStore = nil
      ioAuditStore = nil
      appEnergyStore = nil
      batteryHealthStore = nil
      return
    }

    let historyStore = PersistentHistoryStore()
    let ioAuditStore = IOActivityAuditStore()
    let appEnergyStore = AppEnergyHistoryStore()
    self.historyStore = historyStore
    self.ioAuditStore = ioAuditStore
    self.appEnergyStore = appEnergyStore
    let batteryHealthStore = BatteryHealthHistoryStore()
    self.batteryHealthStore = batteryHealthStore
    Task { @MainActor [weak self, historyStore, ioAuditStore, appEnergyStore, batteryHealthStore] in
      async let historySummary = historyStore.current()
      async let ioSummary = ioAuditStore.current()
      async let energySummary = appEnergyStore.current()
      async let healthSummary = batteryHealthStore.current()
      let (history, io, energy, health) = await (historySummary, ioSummary, energySummary, healthSummary)
      guard let self, !self.stopped else { return }
      self.persistentHistory = history
      self.ioAudit = io
      self.appEnergy = energy
      self.batteryHealth = health
    }
  }

  deinit { smcNumericTask?.cancel() }

  /// Explicit Expert action only; no provider is constructed by init or rendering.
  @discardableResult
  func loadSMCNumericInventory() -> Task<Void, Never>? {
    guard !stopped, !smcNumericLoading, smcNumericTask == nil, smcNumericRequestID == nil,
      let sampler = smcNumericSampler else { return nil }
    let requestID = UUID()
    smcNumericRequestID = requestID
    smcNumericLoading = true
    smcNumericTask = Task { @MainActor [weak self] in
      // Cancellation before this task's first turn must not open a transport.
      guard !Task.isCancelled else {
        self?.finishSMCNumericRequest()
        return
      }
      let sample = await sampler(512)
      guard let self else { return }
      if !Task.isCancelled, !self.stopped, self.smcNumericRequestID == requestID {
        self.smcNumericSample = sample
      }
      self.finishSMCNumericRequest()
    }
    return smcNumericTask
  }

  func cancelSMCNumericInventory(clearCachedSample: Bool = false) {
    smcNumericRequestID = nil
    smcNumericTask?.cancel()
    if clearCachedSample { smcNumericSample = nil }
    // Keep the slot occupied until cooperative work actually drains. Reopening
    // a window cannot queue more reads behind an outstanding blocking IOKit call.
  }

  private func finishSMCNumericRequest() {
    smcNumericTask = nil
    smcNumericRequestID = nil
    smcNumericLoading = false
  }

  func shutdown() {
    stopped = true
    cancelSMCNumericInventory(clearCachedSample: true)
    surfaceDemands = TelemetryDetailDemandRegistry()
    detailDemand = []
    onDetailDemandChange?([])
    onDetailDemandChange = nil
    healthCenter.shutdown()
    appEnergyTask?.cancel()
    appEnergyTask = nil
    pendingAppEnergy = nil
  }

  func accept(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    guard !stopped else { return }
    self.snapshot = snapshot
    history.append(snapshot, now: now)
    healthCenter.accept(snapshot, now: now)
    if let appEnergyStore, lastAppEnergyProcessTicks != snapshot.processes.capturedTicks {
      lastAppEnergyProcessTicks = snapshot.processes.capturedTicks
      if pendingAppEnergy != nil { pendingAppEnergyHasGap = true }
      pendingAppEnergy = (snapshot, now)
      if appEnergyTask == nil {
        appEnergyTask = Task { @MainActor [weak self, appEnergyStore] in
          while !Task.isCancelled {
            guard let self, !self.stopped else { return }
            guard let pending = self.pendingAppEnergy else {
              self.appEnergyTask = nil
              return
            }
            self.pendingAppEnergy = nil
            let hasGap = self.pendingAppEnergyHasGap
            self.pendingAppEnergyHasGap = false
            if hasGap { await appEnergyStore.resetSamplingBaseline() }
            guard !Task.isCancelled else { return }
            let summary = await appEnergyStore.consume(snapshot: pending.snapshot, now: pending.capturedAt)
            guard !Task.isCancelled else { return }
            if self.appEnergy != summary { self.appEnergy = summary }
          }
        }
      }
    }
    guard let historyStore, let ioAuditStore, !persistenceInFlight else { return }
    let persistenceElapsed = now.timeIntervalSince(lastPersistenceAttempt)
    guard persistenceElapsed < 0 || persistenceElapsed >= PersistentHistoryEngine.minimumInterval
    else { return }
    lastPersistenceAttempt = now
    persistenceInFlight = true
    let batteryHealthStore = self.batteryHealthStore
    Task { @MainActor [weak self, historyStore, ioAuditStore, batteryHealthStore] in
      let historySummary = await historyStore.append(snapshot: snapshot, now: now)
      let ioSummary = await ioAuditStore.append(snapshot: snapshot, now: now)
      let healthSummary = await batteryHealthStore?.record(snapshot: snapshot, now: now)
      guard let self, !self.stopped else { return }
      self.persistentHistory = historySummary
      self.ioAudit = ioSummary
      if let healthSummary, self.batteryHealth != healthSummary { self.batteryHealth = healthSummary }
      self.persistenceInFlight = false
    }
  }
}

@MainActor
final class MaintenanceViewModel: ObservableObject {
  @Published private(set) var cleanup: CleanupMetrics?
  @Published private(set) var applications: ApplicationsMetrics?
  private(set) var applicationsPresentation: ApplicationsInventoryPresentation?
  @Published private(set) var cleanupError: String?
  @Published private(set) var applicationsError: String?
  @Published private(set) var scanningCleanup = false
  @Published private(set) var scanningApplications = false

  typealias CleanupSampler = @Sendable () async -> MetricSample<CleanupMetrics>
  typealias ApplicationsSampler = @Sendable () async -> MetricSample<ApplicationsMetrics>
  private let cleanupSampler: CleanupSampler?
  private let applicationsSampler: ApplicationsSampler?
  private lazy var cleanupProvider = CleanupProvider()
  private lazy var applicationsProvider = ApplicationsProvider()
  private var cleanupTask: Task<Void, Never>?
  private var applicationsTask: Task<Void, Never>?

  init(cleanupSampler: CleanupSampler? = nil,
    applicationsSampler: ApplicationsSampler? = nil) {
    self.cleanupSampler = cleanupSampler
    self.applicationsSampler = applicationsSampler
  }

  deinit {
    cleanupTask?.cancel()
    applicationsTask?.cancel()
  }

  func cancelScans() {
    cleanupTask?.cancel()
    applicationsTask?.cancel()
    // Do not release slots until the filesystem operation actually drains.
  }

  @discardableResult
  func scanCleanup() -> Task<Void, Never>? {
    guard !scanningCleanup, cleanupTask == nil else { return nil }
    let sampler: CleanupSampler
    if let injected = cleanupSampler { sampler = injected }
    else {
      let provider = cleanupProvider
      sampler = { await provider.sample() }
    }
    cleanupTask = Task { @MainActor [weak self] in
      if !Task.isCancelled {
        let sample = await sampler()
        if let self, !Task.isCancelled {
          switch sample.result {
          case .success(let value): self.cleanup = value
          case .failure(let error): self.cleanupError = error.localizedDescription
          }
        }
      }
      self?.cleanupTask = nil
      self?.scanningCleanup = false
    }
    scanningCleanup = true
    cleanupError = nil
    return cleanupTask
  }

  @discardableResult
  func scanApplications() -> Task<Void, Never>? {
    guard !scanningApplications, applicationsTask == nil else { return nil }
    let sampler: ApplicationsSampler
    if let injected = applicationsSampler { sampler = injected }
    else {
      let provider = applicationsProvider
      sampler = { await provider.sample() }
    }
    applicationsTask = Task { @MainActor [weak self] in
      if !Task.isCancelled {
        let sample = await sampler()
        if let self, !Task.isCancelled {
          switch sample.result {
          case .success(let value):
            self.applicationsPresentation = ApplicationsInventoryPresentation(value)
            self.applications = value
          case .failure(let error): self.applicationsError = error.localizedDescription
          }
        }
      }
      self?.applicationsTask = nil
      self?.scanningApplications = false
    }
    scanningApplications = true
    applicationsError = nil
    return applicationsTask
  }
}
