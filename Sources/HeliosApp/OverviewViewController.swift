import AppKit
import SwiftUI

@MainActor
final class OverviewViewModel: ObservableObject {
  @Published var snapshot = TelemetrySnapshot()
  // `snapshot` is the single 1 Hz live invalidation. History is appended in the
  // same synchronous accept() call, so publishing it separately would make every
  // open SwiftUI telemetry surface recompute twice for one sample.
  var history = TelemetryHistory()
  @Published var persistentHistory = PersistentHistorySummary.empty
  @Published var ioAudit = IOActivitySummary.empty
  @Published var appEnergy = AppEnergySummary.empty
  let healthCenter: HealthAlertCenter
  private let historyStore: PersistentHistoryStore?
  private let ioAuditStore: IOActivityAuditStore?
  private let appEnergyStore: AppEnergyHistoryStore?
  private var lastPersistenceAttempt = Date.distantPast
  private var lastAppEnergyProcessTicks: UInt64?

  /// The live app uses persistent/history/notification services by default.
  /// Presentation fixtures can disable them so native SwiftUI rendering remains
  /// deterministic and never depends on being hosted inside a .app bundle.
  init(runtimeServicesEnabled: Bool = true) {
    healthCenter = HealthAlertCenter(runtimeServicesEnabled: runtimeServicesEnabled)
    guard runtimeServicesEnabled else {
      historyStore = nil
      ioAuditStore = nil
      appEnergyStore = nil
      return
    }

    let historyStore = PersistentHistoryStore()
    let ioAuditStore = IOActivityAuditStore()
    let appEnergyStore = AppEnergyHistoryStore()
    self.historyStore = historyStore
    self.ioAuditStore = ioAuditStore
    self.appEnergyStore = appEnergyStore
    Task { @MainActor [weak self, historyStore, ioAuditStore, appEnergyStore] in
      async let historySummary = historyStore.current()
      async let ioSummary = ioAuditStore.current()
      async let energySummary = appEnergyStore.current()
      let (history, io, energy) = await (historySummary, ioSummary, energySummary)
      guard let self else { return }
      self.persistentHistory = history
      self.ioAudit = io
      self.appEnergy = energy
    }
  }

  func accept(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    self.snapshot = snapshot
    history.append(snapshot, now: now)
    healthCenter.accept(snapshot, now: now)
    if let appEnergyStore, lastAppEnergyProcessTicks != snapshot.processes.capturedTicks {
      lastAppEnergyProcessTicks = snapshot.processes.capturedTicks
      Task { @MainActor [weak self, appEnergyStore] in
        let summary = await appEnergyStore.consume(snapshot: snapshot, now: now)
        guard let self, self.appEnergy != summary else { return }
        self.appEnergy = summary
      }
    }
    guard let historyStore, let ioAuditStore else { return }
    let persistenceElapsed = now.timeIntervalSince(lastPersistenceAttempt)
    guard persistenceElapsed < 0 || persistenceElapsed >= PersistentHistoryEngine.minimumInterval
    else { return }
    lastPersistenceAttempt = now
    Task { @MainActor [weak self, historyStore, ioAuditStore] in
      let historySummary = await historyStore.append(snapshot: snapshot, now: now)
      let ioSummary = await ioAuditStore.append(snapshot: snapshot, now: now)
      guard let self else { return }
      self.persistentHistory = historySummary
      self.ioAudit = ioSummary
    }
  }
}

@MainActor
private final class MaintenanceViewModel: ObservableObject {
  @Published var cleanup: CleanupMetrics?
  @Published var applications: ApplicationsMetrics?
  @Published var cleanupError: String?
  @Published var applicationsError: String?
  @Published var scanningCleanup = false
  @Published var scanningApplications = false

  private let cleanupProvider = CleanupProvider()
  private let applicationsProvider = ApplicationsProvider()

  func scanCleanup() {
    guard !scanningCleanup else { return }
    scanningCleanup = true
    cleanupError = nil
    Task { @MainActor [weak self, cleanupProvider] in
      let sample = await cleanupProvider.sample()
      guard let self else { return }
      switch sample.result {
      case .success(let value): self.cleanup = value
      case .failure(let error): self.cleanupError = error.localizedDescription
      }
      self.scanningCleanup = false
    }
  }

  func scanApplications() {
    guard !scanningApplications else { return }
    scanningApplications = true
    applicationsError = nil
    Task { @MainActor [weak self, applicationsProvider] in
      let sample = await applicationsProvider.sample()
      guard let self else { return }
      switch sample.result {
      case .success(let value): self.applications = value
      case .failure(let error): self.applicationsError = error.localizedDescription
      }
      self.scanningApplications = false
    }
  }
}

@MainActor
final class OverviewViewController: NSViewController {
  private let model: OverviewViewModel
  private let acceptsSnapshotUpdates: Bool
  private let service: DaemonService?
  private let preferences: HeliosPreferences?
  private let openMonitor: () -> Void
  private let openCooling: () -> Void
  private let openSettings: () -> Void
  private let openRoute: (HeliosMonitorRoute) -> Void

  init(
    model: OverviewViewModel? = nil,
    service: DaemonService? = nil,
    preferences: HeliosPreferences? = nil,
    openMonitor: @escaping () -> Void = {},
    openCooling: @escaping () -> Void = {},
    openSettings: @escaping () -> Void = {},
    openRoute: @escaping (HeliosMonitorRoute) -> Void = { _ in }
  ) {
    if let model {
      self.model = model
      acceptsSnapshotUpdates = false
    } else {
      self.model = OverviewViewModel()
      acceptsSnapshotUpdates = true
    }
    self.service = service
    self.preferences = preferences
    self.openMonitor = openMonitor
    self.openCooling = openCooling
    self.openSettings = openSettings
    self.openRoute = openRoute
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    if let service, let preferences {
      view = NSHostingView(
        rootView: HeliosPopoverView(
          model: model,
          service: service,
          preferences: preferences,
          openMonitor: openMonitor,
          openCooling: openCooling,
          openSettings: openSettings,
          openRoute: openRoute
        ))
      preferredContentSize = NSSize(width: 420, height: 600)
    } else {
      // Deterministic presentation fixtures and non-live callers retain the
      // complete diagnostic surface without coupling it to app windows.
      view = NSHostingView(
        rootView: ScrollView {
          OverviewCards(
            presentation: OverviewPresentation(model.snapshot),
            service: service,
            history: model.history,
            persistentHistory: model.persistentHistory,
            ioAudit: model.ioAudit,
            appEnergy: model.appEnergy,
            capabilityReport: CapabilityEvaluator.evaluate(model.snapshot),
            healthCenter: model.healthCenter
          )
        })
      preferredContentSize = NSSize(width: 380, height: 700)
    }
  }

  func update(_ snapshot: TelemetrySnapshot) {
    if acceptsSnapshotUpdates { model.accept(snapshot) }
  }
}

/// Shared by the live popover and deterministic native presentation renders.
struct OverviewCards: View {
  let presentation: OverviewPresentation
  var service: DaemonService? = nil
  var history = TelemetryHistory()
  var persistentHistory = PersistentHistorySummary.empty
  var ioAudit = IOActivitySummary.empty
  var appEnergy = AppEnergySummary.empty
  var capabilityReport = CapabilityReport(items: [])
  var healthCenter: HealthAlertCenter? = nil

  var body: some View {
    VStack(spacing: 8) {
      thermalCard
      Divider().opacity(0.4)
      cpuCard
      Divider().opacity(0.4)
      memoryCard
      Divider().opacity(0.4)
      gpuCard
      Divider().opacity(0.4)
      batteryCard
      Divider().opacity(0.4)
      networkCard
      Divider().opacity(0.4)
      processCard
      Divider().opacity(0.4)
      storageCard
      Divider().opacity(0.4)
      systemCard
      Divider().opacity(0.4)
      devicesCard
      Divider().opacity(0.4)
      MaintenanceCard()
      Divider().opacity(0.4)
      historyCard
      if let healthCenter {
        Divider().opacity(0.4)
        HealthCard(center: healthCenter)
      }
      if let service {
        Divider().opacity(0.4)
        DaemonServiceCard(service: service, client: service.client)
      }
      HStack {
        Text("Helios").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        Spacer()
        Button("Copy Diagnostics") { copyDiagnostics() }
          .font(.system(size: 11))
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
        Button("Quit Helios") { NSApplication.shared.terminate(nil) }
          .font(.system(size: 11))
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 4)
    }
    .padding(14)
    .frame(maxWidth: .infinity)
  }

  private var thermalCard: some View {
    MonitorCard(title: "Thermals & Cooling", symbol: "thermometer.medium", tint: .orange) {
      HStack(alignment: .firstTextBaseline) {
        Text("Max SoC").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        MetricText(
          value: DisplayValue(
            presentation.thermals.flatMap(\.maximumSoCCelsius), format: temperature), size: 26)
      }
      if case .success(let thermals) = presentation.thermals,
        case .success(let hottest) = thermals.maximumSoCReading
      {
        HStack(spacing: 6) {
          Text("Hottest zone")
          Spacer()
          Text(thermalGroupLabel(hottest.group))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .help(
          "Trusted raw SMC source: \(hottest.key). Fan safety uses the raw trusted maximum; the display is not smoothed."
        )
      }
      Divider().opacity(0.55)
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
        GridRow {
          Text("Sensor group").frame(maxWidth: .infinity, alignment: .leading)
          Text("Average").frame(width: 62, alignment: .trailing)
          Text("Max").frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        thermalRow("P-Cores", group: .performanceCPU)
        thermalRow("E-Cores", group: .efficiencyCPU)
        thermalRow("GPU clusters", group: .gpu)
      }
      .help("Averages and maxima summarize the available temperature sensors in each group.")
      if case .failure = presentation.thermals {
        notice("Temperature readings unavailable")
      } else if case .success(let thermals) = presentation.thermals, !thermals.failures.isEmpty {
        notice("Some temperature readings are unavailable")
      }
      if case .success(let thermals) = presentation.thermals {
        DisclosureGroup("Sensor browser") {
          VStack(spacing: 4) {
            ForEach(thermals.readings.sorted(by: { $0.key < $1.key }), id: \.key) { reading in
              HStack(spacing: 8) {
                Text(reading.key).font(.system(size: 10, design: .monospaced))
                Text(thermalGroupLabel(reading.group)).font(.system(size: 9)).foregroundStyle(
                  .secondary)
                Spacer()
                Text(temperature(reading.celsius)).font(
                  .system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
              }
            }
          }
          .padding(.top, 4)
        }
        .font(.system(size: 10, weight: .medium))
        .help(
          "Read-only raw SMC temperature inventory. Unclassified sensors are display-only and never enter fan safety."
        )
      }
      if let service {
        Divider().opacity(0.55)
        FanControlView(
          model: service.fanControl, client: service.client,
          preflight: presentation.fanOwnershipPreflight)
      }
    }
  }

  private func thermalGroupLabel(_ group: ThermalGroup) -> String {
    switch group {
    case .performanceCPU: return "P-Cores"
    case .efficiencyCPU: return "E-Cores"
    case .gpu: return "GPU"
    case .unclassified: return "Unknown"
    }
  }

  private func thermalRow(_ title: String, group: ThermalGroup) -> some View {
    let summary = presentation.temperatures(group)
    return GridRow {
      Text(title).font(.system(size: 12, weight: .medium))
      MetricText(value: DisplayValue(summary.map(\.average), format: temperature))
        .frame(width: 62, alignment: .trailing)
      MetricText(value: DisplayValue(summary.map(\.maximum), format: temperature))
        .frame(width: 62, alignment: .trailing)
    }
  }

  private var cpuCard: some View {
    MonitorCard(title: "CPU", symbol: "cpu", tint: .blue) {
      HStack(alignment: .firstTextBaseline) {
        Text("CPU usage").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        MetricText(
          value: DisplayValue(presentation.cpu.map(\.usagePercent), format: percent), size: 24)
      }
      HStack(spacing: 0) {
        cpuDetail("User", value: presentation.cpu.map(\.userPercent))
        cpuDetail("System", value: presentation.cpu.map(\.systemPercent))
        cpuDetail("Nice", value: presentation.cpu.map(\.nicePercent))
        cpuDetail("Idle", value: presentation.cpu.map(\.idlePercent))
      }
      if case .success(let cpu) = presentation.cpu {
        Divider().opacity(0.55)
        Grid(horizontalSpacing: 18, verticalSpacing: 6) {
          GridRow {
            detail(
              "Logical cores",
              value: DisplayValue(MetricResult<Int>.success(cpu.perCoreUsagePercent.count)) {
                String($0)
              })
            detail("Physical cores", value: DisplayValue(cpu.physicalCoreCount) { String($0) })
          }
          GridRow {
            detail("P-cores", value: DisplayValue(cpu.performanceCoreCount) { String($0) })
            detail("E-cores", value: DisplayValue(cpu.efficiencyCoreCount) { String($0) })
          }
        }
        if !cpu.perCoreUsagePercent.isEmpty {
          DisclosureGroup("Per-core activity") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
              ForEach(Array(cpu.perCoreUsagePercent.enumerated()), id: \.offset) { index, usage in
                HStack {
                  Text("CPU \(index + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                  Spacer()
                  Text(String(format: "%.0f%%", usage)).font(
                    .system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                }
              }
            }.padding(.top, 4)
          }
          .font(.system(size: 10, weight: .medium))
        }
      }
    }
  }

  private var memoryCard: some View {
    MonitorCard(title: "Memory", symbol: "memorychip", tint: .indigo) {
      HStack(alignment: .firstTextBaseline) {
        Text("Memory usage").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        MetricText(
          value: DisplayValue(presentation.memory.map(\.usagePercent), format: percent), size: 24)
      }
      HStack {
        Text("Memory pressure").font(.system(size: 12, weight: .medium))
        Spacer()
        pressureBadge
      }
      Divider().opacity(0.55)
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          memoryDetail("Used", bytes: presentation.memory.map(\.usedBytes))
          memoryDetail("Available", bytes: presentation.memory.map(\.availableBytes))
        }
        GridRow {
          memoryDetail("App", bytes: presentation.memory.map(\.appBytes))
          memoryDetail("Wired", bytes: presentation.memory.map(\.wiredBytes))
        }
        GridRow {
          memoryDetail("Compressed", bytes: presentation.memory.map(\.compressedBytes))
          memoryDetail("Cache", bytes: presentation.memory.map(\.cacheBytes))
        }
        GridRow {
          memoryDetail("Active", bytes: presentation.memory.map(\.activeBytes))
          memoryDetail("Inactive", bytes: presentation.memory.map(\.inactiveBytes))
        }
        GridRow {
          memoryDetail("Free", bytes: presentation.memory.map(\.freeBytes))
          memoryDetail("Physical", bytes: presentation.memory.map(\.physicalBytes))
        }
        GridRow {
          memoryDetail("Swap used", bytes: presentation.memory.flatMap(\.swapUsedBytes))
          memoryDetail("Swap total", bytes: presentation.memory.flatMap(\.swapTotalBytes))
        }
      }
      if case .success(let memory) = presentation.memory {
        DisclosureGroup("VM details") {
          Grid(horizontalSpacing: 18, verticalSpacing: 5) {
            GridRow {
              memoryDetail("Speculative", bytes: .success(memory.speculativeBytes))
              memoryDetail("Purgeable", bytes: .success(memory.purgeableBytes))
            }
            GridRow {
              memoryDetail("External", bytes: .success(memory.externalBytes))
              memoryDetail("Swap free", bytes: memory.swapFreeBytes)
            }
            GridRow {
              detail(
                "Swap-ins",
                value: DisplayValue(
                  MetricResult<UInt64>.success(memory.swapIns), format: TelemetryFormatting.count))
              detail(
                "Swap-outs",
                value: DisplayValue(
                  MetricResult<UInt64>.success(memory.swapOuts), format: TelemetryFormatting.count))
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      }
    }
  }

  private var gpuCard: some View {
    let gpu = presentation.gpu
    return MonitorCard(title: "GPU & Graphics", symbol: "display", tint: .cyan) {
      HStack(alignment: .firstTextBaseline) {
        Text("GPU usage").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        MetricText(
          value: DisplayValue(gpu.flatMap(\.deviceUtilizationPercent), format: percent), size: 24)
      }
      HStack(spacing: 8) {
        MetricText(value: DisplayValue(gpu.flatMap(\.model)) { $0 }, size: 11)
        Spacer()
        detail("Cores", value: DisplayValue(gpu.flatMap(\.coreCount)) { String($0) })
          .frame(maxWidth: 95)
      }
      Divider().opacity(0.55)
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail(
            "Renderer",
            value: DisplayValue(gpu.flatMap(\.rendererUtilizationPercent), format: percent))
          detail(
            "Tiler", value: DisplayValue(gpu.flatMap(\.tilerUtilizationPercent), format: percent))
        }
        GridRow {
          memoryDetail("Mapped", bytes: gpu.flatMap(\.allocatedSystemMemoryBytes))
          memoryDetail("In use", bytes: gpu.flatMap(\.inUseSystemMemoryBytes))
        }
      }
      switch gpu {
      case .failure(let error):
        notice("GPU telemetry unavailable — \(error.localizedDescription)")
      case .success(let metrics):
        if case .failure(let error) = metrics.deviceUtilizationPercent {
          notice("GPU utilization unavailable — \(error.localizedDescription)")
        }
      }
    }
  }

  private func cpuDetail(_ title: String, value: MetricResult<Double>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
      MetricText(value: DisplayValue(value, format: percent))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func memoryDetail(_ title: String, bytes: MetricResult<UInt64>) -> some View {
    detail(title, value: DisplayValue(bytes, format: TelemetryFormatting.gibibytes))
  }

  private var pressureBadge: some View {
    let result = presentation.memory.flatMap(\.pressure)
    let text = DisplayValue(result) { $0.rawValue }
    let color: Color =
      switch result {
      case .success(.normal): .green
      case .success(.warning): .orange
      case .success(.critical): .red
      case .failure: .secondary
      }
    return HStack(spacing: 5) {
      Circle().fill(color).frame(width: 5, height: 5)
      Text(text.failure == nil ? text.text : "Unavailable")
        .font(.system(size: 10, weight: .medium))
    }
    .padding(.horizontal, 8).padding(.vertical, 3)
    .background(color.opacity(0.09), in: Capsule())
    .help(text.failure ?? "Kernel-reported memory pressure")
  }

  private var batteryCard: some View {
    let battery = presentation.battery
    let power = battery.flatMap(\.power)
    return MonitorCard(title: "Battery & Power", symbol: "battery.100percent", tint: .green) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(powerTitle(power)).font(.system(size: 12)).foregroundStyle(.secondary)
          MetricText(
            value: DisplayValue(power) { String(format: "%.2f W", abs($0.signedWatts)) }, size: 24)
          Text(powerBasis(power)).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          Text("Battery health").font(.system(size: 10)).foregroundStyle(.secondary)
          MetricText(
            value: DisplayValue(battery.flatMap(\.healthPercent), format: percent), size: 17)
        }
      }
      Divider().opacity(0.55)
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail(
            "Design", value: DisplayValue(battery.flatMap(\.designCapacityMAh)) { "\($0) mAh" })
          detail(
            "Full charge",
            value: DisplayValue(battery.flatMap(\.maximumCapacityMAh)) { "\($0) mAh" })
        }
        GridRow {
          detail(
            "Current", value: DisplayValue(battery.flatMap(\.currentCapacityMAh)) { "\($0) mAh" })
          detail(
            "Charge", value: DisplayValue(battery.flatMap(\.stateOfChargePercent), format: percent))
        }
        GridRow {
          detail(
            "Voltage",
            value: DisplayValue(battery.flatMap(\.voltageVolts)) { String(format: "%.2f V", $0) })
          detail(
            "Current",
            value: DisplayValue(battery.flatMap(\.currentAmps)) { String(format: "%+.2f A", $0) })
        }
        GridRow {
          detail("Cycles", value: DisplayValue(battery.flatMap(\.cycleCount)) { String($0) })
          detail(
            "Cell temp",
            value: DisplayValue(battery.flatMap(\.temperatureCelsius), format: temperature))
        }
        GridRow {
          detail("Source", value: DisplayValue(battery.flatMap(\.powerSource)) { $0.rawValue })
          detail("Adapter", value: DisplayValue(battery.flatMap(\.adapterWatts)) { "\($0) W" })
        }
      }
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail(
            "Charging", value: DisplayValue(battery.flatMap(\.isCharging)) { $0 ? "Yes" : "No" })
          detail(
            "Time remaining",
            value: DisplayValue(
              battery.flatMap(\.timeRemaining), format: TelemetryFormatting.batteryTimeRemaining))
        }
      }
      DisclosureGroup("Battery diagnostics") {
        Grid(horizontalSpacing: 18, verticalSpacing: 6) {
          GridRow {
            detail(
              "System SoC",
              value: DisplayValue(battery.flatMap(\.systemChargePercent), format: percent))
            detail(
              "Raw capacity SoC",
              value: DisplayValue(battery.flatMap(\.rawStateOfChargePercent), format: percent))
          }
          GridRow {
            detail(
              "Charged", value: DisplayValue(battery.flatMap(\.isCharged)) { $0 ? "Yes" : "No" })
            detail(
              "Optimized charging",
              value: DisplayValue(battery.flatMap(\.optimizedChargingEngaged)) {
                $0 ? "Engaged" : "Not engaged"
              })
          }
          GridRow {
            detail(
              "Manufactured",
              value: DisplayValue(battery.flatMap(\.manufactureDate)) { date in
                DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
              })
            detail(
              "Adapter voltage",
              value: DisplayValue(battery.flatMap(\.adapterVoltageVolts)) {
                String(format: "%.2f V", $0)
              })
          }
          GridRow {
            detail(
              "Charging current",
              value: DisplayValue(battery.flatMap(\.chargingCurrentAmps)) {
                String(format: "%.2f A", $0)
              })
            detail(
              "Charging voltage",
              value: DisplayValue(battery.flatMap(\.chargingVoltageVolts)) {
                String(format: "%.2f V", $0)
              })
          }
          GridRow {
            detail(
              "Cell balance",
              value: DisplayValue(battery.flatMap(\.cellBalanceMillivolts)) {
                String(format: "%.0f mV", $0)
              })
            detail(
              "Not-charging raw",
              value: DisplayValue(battery.flatMap(\.notChargingReasonRaw)) {
                String(format: "0x%llX", $0)
              })
          }
          GridRow {
            detail(
              "Cell voltages",
              value: DisplayValue(battery.flatMap(\.cellVoltagesVolts), format: batteryCells))
            detail(
              "Policy", value: DisplayValue(MetricResult<String>.success("macOS-managed")) { $0 })
          }
        }.padding(.top, 4)
        Text(
          "System SoC follows macOS. Raw mAh/cell/charger values are read-only expert diagnostics and never change charging policy."
        )
        .font(.system(size: 9)).foregroundStyle(.secondary)
      }.font(.system(size: 10, weight: .medium))
      Divider().opacity(0.55)
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Total System Power")
          Text("AppleSMC PSTR · read-only")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        Spacer()
        MetricText(
          value: DisplayValue(presentation.systemPower.flatMap(\.totalSystemWatts)) {
            String(format: "%.2f W", $0)
          }, size: 13)
      }
      .font(.system(size: 11))
      .help(
        "Board/system power is read independently from the AppleSMC PSTR rail; battery charge/discharge power is not substituted for it."
      )
      if !persistentHistory.points.isEmpty {
        Divider().opacity(0.55)
        DisclosureGroup("24h battery trend") {
          Grid(horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
              detail(
                "Minimum",
                value: DisplayValue(
                  optionalMetric(
                    persistentHistory.batteryMinimumPercent,
                    unavailable: "No persisted battery samples"), format: percent))
              detail(
                "Maximum",
                value: DisplayValue(
                  optionalMetric(
                    persistentHistory.batteryMaximumPercent,
                    unavailable: "No persisted battery samples"), format: percent))
            }
            GridRow {
              detail(
                "Charge change",
                value: DisplayValue(
                  optionalMetric(
                    persistentHistory.batteryChargeDeltaPercent,
                    unavailable: "Battery trend unavailable")
                ) { String(format: "%+.1f%%", $0) })
              detail(
                "Battery energy",
                value: DisplayValue(
                  MetricResult<Double>.success(persistentHistory.batteryEnergyWattHours)
                ) { String(format: "%+.3f Wh", $0) })
            }
            GridRow {
              detail(
                "Temp minimum",
                value: DisplayValue(
                  optionalMetric(
                    persistentHistory.batteryMinimumTemperatureCelsius,
                    unavailable: "Battery temperature history unavailable"), format: temperature))
              detail(
                "Temp maximum",
                value: DisplayValue(
                  optionalMetric(
                    persistentHistory.batteryMaximumTemperatureCelsius,
                    unavailable: "Battery temperature history unavailable"), format: temperature))
            }
            GridRow {
              detail(
                "Health minimum",
                value: DisplayValue(
                  optionalMetric(
                    persistentHistory.batteryMinimumHealthPercent,
                    unavailable: "Battery health history unavailable"), format: percent))
              detail(
                "Latest cycles",
                value: DisplayValue(
                  optionalMetric(
                    persistentHistory.latestBatteryCycleCount,
                    unavailable: "Battery cycle history unavailable")
                ) { String($0) })
            }
            GridRow {
              detail(
                "Power coverage",
                value: DisplayValue(
                  MetricResult<TimeInterval>.success(
                    persistentHistory.measuredBatteryPowerCoverageSeconds),
                  format: TelemetryFormatting.duration))
              detail(
                "Trend window",
                value: DisplayValue(
                  MetricResult<TimeInterval>.success(persistentHistory.durationSeconds),
                  format: TelemetryFormatting.duration))
            }
          }
          notice(
            "Battery energy is signed: positive means net charge into the battery, negative means discharge. Long gaps are not interpolated."
          )
        }
        .font(.system(size: 10, weight: .medium))
      }
    }
  }

  private var networkCard: some View {
    let network = presentation.network
    return MonitorCard(title: "Network", symbol: "network", tint: .teal) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Primary interface").font(.system(size: 10)).foregroundStyle(.secondary)
          MetricText(value: DisplayValue(network.flatMap(\.primaryInterface)) { $0 }, size: 14)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("Active interfaces").font(.system(size: 10)).foregroundStyle(.secondary)
          MetricText(
            value: DisplayValue(network.map(\.activeInterfaceCount)) { String($0) }, size: 14)
        }
      }
      Divider().opacity(0.55)
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail(
            "Download",
            value: DisplayValue(
              network.flatMap(\.throughput).map(\.downloadBytesPerSecond),
              format: TelemetryFormatting.bytesPerSecond))
          detail(
            "Upload",
            value: DisplayValue(
              network.flatMap(\.throughput).map(\.uploadBytesPerSecond),
              format: TelemetryFormatting.bytesPerSecond))
        }
        GridRow {
          detail(
            "RX packets/s",
            value: DisplayValue(
              network.flatMap(\.throughput).map(\.receivePacketsPerSecond),
              format: TelemetryFormatting.iops))
          detail(
            "TX packets/s",
            value: DisplayValue(
              network.flatMap(\.throughput).map(\.transmitPacketsPerSecond),
              format: TelemetryFormatting.iops))
        }
        GridRow {
          detail(
            "Link",
            value: DisplayValue(
              network.flatMap(\.linkSpeedBitsPerSecond), format: TelemetryFormatting.bitsPerSecond))
          detail("MTU", value: DisplayValue(network.flatMap(\.mtu)) { String($0) })
        }
        GridRow {
          detail("RX errors", value: DisplayValue(network.flatMap(\.receiveErrors)) { String($0) })
          detail("TX errors", value: DisplayValue(network.flatMap(\.transmitErrors)) { String($0) })
        }
      }
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail(
            "Session download",
            value: DisplayValue(
              network.flatMap(\.sessionDownloadedBytes), format: TelemetryFormatting.storageBytes))
          detail(
            "Session upload",
            value: DisplayValue(
              network.flatMap(\.sessionUploadedBytes), format: TelemetryFormatting.storageBytes))
        }
      }
      addressDetail("IPv4", value: network.flatMap(\.ipv4Address))
      addressDetail("IPv6", value: network.flatMap(\.ipv6Address))
      if case .success(let value) = network {
        DisclosureGroup("Network path & DNS") {
          VStack(alignment: .leading, spacing: 5) {
            addressDetail("GW", value: value.gatewayIPv4)
            addressDetail(
              "DNS",
              value: value.dnsServers.isEmpty
                ? .failure(.unavailable("DNS servers unavailable"))
                : .success(value.dnsServers.joined(separator: ", ")))
            addressDetail(
              "IF",
              value: value.activeInterfaces.isEmpty
                ? .failure(.unavailable("Active interface list unavailable"))
                : .success(value.activeInterfaces.joined(separator: ", ")))
            if !value.searchDomains.isEmpty {
              addressDetail("SRCH", value: .success(value.searchDomains.joined(separator: ", ")))
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      }
      Divider().opacity(0.55)
      if case .success(let wifi) = presentation.wifi {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Wi-Fi").font(.system(size: 10)).foregroundStyle(.secondary)
            MetricText(value: DisplayValue(wifi.ssid) { $0 }, size: 11)
          }
          Spacer()
          Text(wifi.powerOn ? (wifi.serviceActive ? "Connected" : "On") : "Off")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(wifi.serviceActive ? .green : .secondary)
        }
        Grid(horizontalSpacing: 18, verticalSpacing: 6) {
          GridRow {
            detail("RSSI", value: DisplayValue(wifi.rssiDBm) { "\($0) dBm" })
            detail("SNR", value: DisplayValue(wifi.signalToNoiseDB) { "\($0) dB" })
          }
          GridRow {
            detail(
              "TX rate",
              value: DisplayValue(wifi.transmitRateMbps) { String(format: "%.0f Mb/s", $0) })
            detail("TX power", value: DisplayValue(wifi.transmitPowerMilliwatts) { "\($0) mW" })
          }
          GridRow {
            detail("Channel", value: DisplayValue(wifi.channelNumber) { String($0) })
            detail("Band", value: DisplayValue(wifi.channelBand) { $0 })
          }
          GridRow {
            detail("Width", value: DisplayValue(wifi.channelWidth) { $0 })
            detail("PHY", value: DisplayValue(wifi.phyMode) { $0 })
          }
        }
        detail("Security", value: DisplayValue(wifi.security) { $0 })
      } else if case .failure(let error) = presentation.wifi {
        notice("Wi-Fi radio telemetry unavailable — \(error.localizedDescription)")
      }
      if case .success(let value) = network, case .success(false) = value.isRunning {
        notice("Primary interface is not currently running")
      } else if case .failure(let error) = network {
        notice("Network telemetry unavailable — \(error.localizedDescription)")
      }
    }
  }

  private var processCard: some View {
    MonitorCard(title: "Processes", symbol: "list.bullet.rectangle", tint: .mint) {
      switch presentation.processes {
      case .success(let processes):
        HStack {
          Text("Accessible processes").font(.system(size: 10)).foregroundStyle(.secondary)
          Spacer()
          Text(String(processes.accessibleProcessCount)).font(
            .system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        }
        Divider().opacity(0.55)
        Text("Top CPU").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        ForEach(processes.topByCPU.prefix(5)) { process in
          processRow(process)
        }
        DisclosureGroup("Top energy") {
          VStack(spacing: 5) {
            ForEach(processes.topByEnergy.prefix(5)) { process in processRow(process) }
          }.padding(.top, 4)
        }
        .font(.system(size: 10, weight: .medium))
        DisclosureGroup("Top memory") {
          VStack(spacing: 5) {
            ForEach(processes.topByMemory.prefix(5)) { process in processRow(process) }
          }.padding(.top, 4)
        }
        .font(.system(size: 10, weight: .medium))
        DisclosureGroup("Disk I/O attribution") {
          VStack(alignment: .leading, spacing: 7) {
            Grid(horizontalSpacing: 18, verticalSpacing: 5) {
              GridRow {
                detail(
                  "Accounted read",
                  value: DisplayValue(
                    MetricResult<Double>.success(processes.accountedDiskReadBytesPerSecond),
                    format: TelemetryFormatting.bytesPerSecond))
                detail(
                  "Accounted write",
                  value: DisplayValue(
                    MetricResult<Double>.success(processes.accountedDiskWriteBytesPerSecond),
                    format: TelemetryFormatting.bytesPerSecond))
              }
              GridRow {
                detail(
                  "Session read",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(processes.sessionAccountedReadBytes),
                    format: TelemetryFormatting.storageBytes))
                detail(
                  "Session write",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(processes.sessionAccountedWriteBytes),
                    format: TelemetryFormatting.storageBytes))
              }
            }
            Text("Current readers").font(.system(size: 9, weight: .medium)).foregroundStyle(
              .secondary)
            ForEach(processes.topByDiskRead.prefix(4)) { process in
              processIORow(process, read: true)
            }
            Text("Current writers").font(.system(size: 9, weight: .medium)).foregroundStyle(
              .secondary)
            ForEach(processes.topByDiskWrite.prefix(4)) { process in
              processIORow(process, read: false)
            }
            Text("Session leaders").font(.system(size: 9, weight: .medium)).foregroundStyle(
              .secondary)
            ForEach(processes.topSessionWriters.prefix(4)) { process in processSessionIORow(process)
            }
          }.padding(.top, 4)
        }
        .font(.system(size: 10, weight: .medium))
        if let own = processes.heliosActivity {
          DisclosureGroup("Helios footprint") {
            Grid(horizontalSpacing: 18, verticalSpacing: 5) {
              GridRow {
                detail(
                  "CPU",
                  value: DisplayValue(
                    optionalMetric(own.cpuPercent, unavailable: "Helios CPU rate warming up"),
                    format: percent))
                detail(
                  "Memory",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(own.physicalFootprintBytes),
                    format: TelemetryFormatting.storageBytes))
              }
              GridRow {
                detail(
                  "Power",
                  value: DisplayValue(
                    optionalMetric(own.powerWatts, unavailable: "Helios energy rate warming up")
                  ) { String(format: "%.3f W", $0) })
                detail(
                  "Wakeups/s",
                  value: DisplayValue(
                    optionalMetric(
                      own.wakeupsPerSecond, unavailable: "Helios wakeup rate warming up")
                  ) { String(format: "%.1f", $0) })
              }
              GridRow {
                detail(
                  "Disk read",
                  value: DisplayValue(
                    optionalMetric(
                      own.diskReadBytesPerSecond, unavailable: "Helios disk rate warming up"),
                    format: TelemetryFormatting.bytesPerSecond))
                detail(
                  "Disk write",
                  value: DisplayValue(
                    optionalMetric(
                      own.diskWriteBytesPerSecond, unavailable: "Helios disk rate warming up"),
                    format: TelemetryFormatting.bytesPerSecond))
              }
              GridRow {
                detail(
                  "Session read",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(own.sessionDiskReadBytes),
                    format: TelemetryFormatting.storageBytes))
                detail(
                  "Session write",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(own.sessionDiskWriteBytes),
                    format: TelemetryFormatting.storageBytes))
              }
            }
            if !persistentHistory.points.isEmpty {
              Divider().opacity(0.45)
              Text("24h self-overhead").font(.system(size: 9, weight: .medium)).foregroundStyle(
                .secondary)
              Grid(horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                  detail(
                    "Avg CPU",
                    value: DisplayValue(
                      optionalMetric(
                        persistentHistory.heliosAverageCPUPercent,
                        unavailable: "No persisted Helios CPU samples"), format: percent))
                  detail(
                    "Peak CPU",
                    value: DisplayValue(
                      optionalMetric(
                        persistentHistory.heliosPeakCPUPercent,
                        unavailable: "No persisted Helios CPU samples"), format: percent))
                }
                GridRow {
                  detail(
                    "Avg power",
                    value: DisplayValue(
                      optionalMetric(
                        persistentHistory.heliosAveragePowerWatts,
                        unavailable: "No persisted Helios power samples")
                    ) { String(format: "%.3f W", $0) })
                  detail(
                    "Peak power",
                    value: DisplayValue(
                      optionalMetric(
                        persistentHistory.heliosPeakPowerWatts,
                        unavailable: "No persisted Helios power samples")
                    ) { String(format: "%.3f W", $0) })
                }
                GridRow {
                  detail(
                    "Peak memory",
                    value: DisplayValue(
                      optionalMetric(
                        persistentHistory.heliosPeakMemoryBytes,
                        unavailable: "No persisted Helios memory samples"),
                      format: TelemetryFormatting.storageBytes))
                  detail(
                    "Avg wakeups/s",
                    value: DisplayValue(
                      optionalMetric(
                        persistentHistory.heliosAverageWakeupsPerSecond,
                        unavailable: "No persisted Helios wakeup samples")
                    ) { String(format: "%.1f", $0) })
                }
              }
            }
          }.font(.system(size: 10, weight: .medium))
        }
        if !appEnergy.buckets.isEmpty {
          DisclosureGroup("Per-app energy history") {
            VStack(alignment: .leading, spacing: 6) {
              Grid(horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                  detail(
                    "Coverage",
                    value: DisplayValue(
                      MetricResult<TimeInterval>.success(appEnergy.coverageSeconds),
                      format: TelemetryFormatting.duration))
                  detail(
                    "On battery",
                    value: DisplayValue(
                      MetricResult<TimeInterval>.success(appEnergy.onBatteryCoverageSeconds),
                      format: TelemetryFormatting.duration))
                }
              }
              Text("Top sampled apps")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
              ForEach(appEnergy.topAll.prefix(6)) { entry in
                HStack {
                  Text(entry.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                  Spacer()
                  Text(String(format: "%.3f Wh", entry.energyWattHours))
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                }
              }
              Button("Export per-app CSV…") { exportAppEnergyCSV() }
                .buttonStyle(.bordered).controlSize(.small)
              if !appEnergy.recentHourTrends.isEmpty {
                Divider().opacity(0.4)
                HStack {
                  Text("Recent 1h vs previous 1h")
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                  Spacer()
                  if let delta = appEnergy.recentHourOnBatteryChargeDeltaPercent {
                    Text(String(format: "battery %+.1f%%", delta))
                      .font(.system(size: 8, design: .rounded)).foregroundStyle(.secondary)
                  }
                }
                ForEach(appEnergy.recentHourTrends.prefix(5)) { trend in
                  HStack {
                    Text(trend.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%+.3f Wh", trend.changeWattHours))
                      .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    if let percent = trend.changePercent {
                      Text(String(format: "%+.0f%%", percent))
                        .font(.system(size: 8, design: .rounded)).foregroundStyle(.secondary)
                    } else {
                      Text("new")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                  }
                }
              }
            }.padding(.top, 4)
          }.font(.system(size: 10, weight: .medium))
        }
        notice(
          "Per-app history integrates the bounded native energy-leader set and is intended for attribution/trends, not billing-grade joule measurement. One compact aggregate is persisted about once per minute."
        )
        notice(
          "Process I/O is libproc task accounting. Physical device I/O can be higher because APFS, VM paging, cache writeback and kernel work are not attributed one-to-one to user processes."
        )
        notice(
          "Per-process power uses native RUSAGE_INFO_V6 kernel energy counters when available. Missing processes are not estimated or elevated through the helper."
        )
      case .failure(let error):
        notice("Process telemetry unavailable — \(error.localizedDescription)")
      }
    }
  }

  private func processRow(_ process: ProcessActivity) -> some View {
    HStack(spacing: 7) {
      VStack(alignment: .leading, spacing: 1) {
        Text(process.name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(
          .middle)
        Text(
          "PID \(process.pid) · \(TelemetryFormatting.storageBytes(process.physicalFootprintBytes))"
        )
        .font(.system(size: 8)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 1) {
        Text(process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
          .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        Text(process.powerWatts.map { String(format: "%.2f W", $0) } ?? "—")
          .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .frame(width: 58, alignment: .trailing)
    }
    .help(process.executablePath ?? process.name)
  }

  private func processIORow(_ process: ProcessActivity, read: Bool) -> some View {
    let rate = read ? process.diskReadBytesPerSecond : process.diskWriteBytesPerSecond
    let total = read ? process.sessionDiskReadBytes : process.sessionDiskWriteBytes
    return HStack(spacing: 7) {
      VStack(alignment: .leading, spacing: 1) {
        Text(process.name).font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(
          .middle)
        Text("PID \(process.pid) · session \(TelemetryFormatting.storageBytes(total))")
          .font(.system(size: 8)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Text(rate.map(TelemetryFormatting.bytesPerSecond) ?? "—")
        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
    }
    .help(process.executablePath ?? process.name)
  }

  private func processSessionIORow(_ process: ProcessActivity) -> some View {
    HStack(spacing: 7) {
      Text(process.name).font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(
        .middle)
      Spacer(minLength: 4)
      Text(
        "R \(TelemetryFormatting.storageBytes(process.sessionDiskReadBytes)) · W \(TelemetryFormatting.storageBytes(process.sessionDiskWriteBytes))"
      )
      .font(.system(size: 8, weight: .semibold, design: .rounded).monospacedDigit())
    }
    .help(process.executablePath ?? process.name)
  }

  private var devicesCard: some View {
    MonitorCard(
      title: "Hardware & Devices", symbol: "externaldrive.connected.to.line.below", tint: .teal
    ) {
      switch presentation.displays {
      case .success(let value):
        DisclosureGroup("Displays (\(value.displays.count))") {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(value.displays) { display in
              HStack {
                Text(display.label).font(.system(size: 9, weight: .medium))
                Spacer()
                Text(
                  "\(display.pixelWidth)×\(display.pixelHeight)"
                    + (display.refreshRateHz.map { String(format: " · %.0f Hz", $0) } ?? "")
                )
                .font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary)
              }
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      case .failure(let error):
        notice("Display inventory unavailable — \(error.localizedDescription)")
      }

      switch presentation.volumes {
      case .success(let value):
        DisclosureGroup("Mounted volumes (\(value.volumes.count))") {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(value.volumes.prefix(12)) { volume in
              HStack {
                Text(volume.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer()
                if let available = volume.availableBytes, let total = volume.totalBytes {
                  Text(
                    "\(TelemetryFormatting.storageBytes(available)) free / \(TelemetryFormatting.storageBytes(total))"
                  )
                  .font(.system(size: 8, design: .rounded)).foregroundStyle(.secondary)
                }
              }.help(
                [volume.path, volume.localizedFormatDescription, volume.uuid].compactMap { $0 }
                  .joined(separator: " · "))
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      case .failure(let error):
        notice("Volume inventory unavailable — \(error.localizedDescription)")
      }

      switch presentation.usb {
      case .success(let value):
        DisclosureGroup("USB devices (\(value.devices.count))") {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(value.devices.prefix(12)) { device in
              HStack {
                Text(device.product).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer()
                Text(device.vendor ?? "USB").font(.system(size: 8)).foregroundStyle(.secondary)
              }
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      case .failure(let error): notice("USB inventory unavailable — \(error.localizedDescription)")
      }

      switch presentation.bluetooth {
      case .success(let value):
        DisclosureGroup("Bluetooth (\(value.devices.count))") {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(value.devices.prefix(12)) { device in
              HStack {
                Text(device.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer()
                if let battery = device.battery.mainPercent {
                  Text("\(battery)%").font(.system(size: 8, weight: .semibold))
                }
                Text(device.connected ? "Connected" : "Paired").font(.system(size: 8))
                  .foregroundStyle(device.connected ? .green : .secondary)
              }
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      case .failure(let error):
        notice("Bluetooth inventory unavailable — \(error.localizedDescription)")
      }

      switch presentation.audio {
      case .success(let value):
        DisclosureGroup("Audio devices (\(value.devices.count))") {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(value.devices.prefix(12)) { device in
              HStack {
                Text(device.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer()
                if !value.inputTelemetrySuppressedForPrivacy,
                  value.defaultInputDeviceID == device.objectID
                {
                  Text("IN").font(.system(size: 7, weight: .bold)).foregroundStyle(.blue)
                }
                if value.defaultOutputDeviceID == device.objectID {
                  Text("OUT").font(.system(size: 7, weight: .bold)).foregroundStyle(.green)
                }
                if value.inputTelemetrySuppressedForPrivacy {
                  if device.outputChannels > 0 {
                    Text("\(device.outputChannels)o")
                      .font(.system(size: 8, design: .rounded)).foregroundStyle(.secondary)
                  }
                } else if device.inputChannels > 0 || device.outputChannels > 0 {
                  Text("\(device.inputChannels)i/\(device.outputChannels)o")
                    .font(.system(size: 8, design: .rounded)).foregroundStyle(.secondary)
                }
                if let rate = device.nominalSampleRateHz {
                  Text(String(format: "%.1f kHz", rate / 1000)).font(.system(size: 8))
                    .foregroundStyle(.secondary)
                }
              }
            }
            if value.inputTelemetrySuppressedForPrivacy {
              Text(
                "Input details are intentionally not probed; Helios does not request microphone access for device inventory."
              )
              .font(.system(size: 8)).foregroundStyle(.secondary)
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      case .failure(let error):
        notice("Audio inventory unavailable — \(error.localizedDescription)")
      }

      switch presentation.powerAssertions {
      case .success(let value):
        DisclosureGroup("Sleep blockers (\(value.assertions.count))") {
          VStack(alignment: .leading, spacing: 5) {
            Text(
              "Display blockers: \(value.displaySleepBlockers.count) · System blockers: \(value.systemSleepBlockers.count)"
            )
            .font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(value.assertions.prefix(12)) { assertion in
              HStack {
                Text(assertion.processName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer()
                Text(assertion.assertionType).font(.system(size: 8)).foregroundStyle(.secondary)
                  .lineLimit(1)
              }.help(assertion.reason ?? assertion.assertionType)
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      case .failure(let error):
        notice("Sleep assertion inventory unavailable — \(error.localizedDescription)")
      }

      if case .success(let clock) = presentation.clock {
        DisclosureGroup("Clock & Calendar") {
          Grid(horizontalSpacing: 18, verticalSpacing: 5) {
            GridRow {
              detail(
                "Time zone",
                value: DisplayValue(MetricResult<String>.success(clock.localTimeZoneIdentifier)) {
                  $0
                })
              detail(
                "ISO week",
                value: DisplayValue(MetricResult<Int>.success(clock.isoWeekOfYear)) { String($0) })
            }
            GridRow {
              detail(
                "Day of year",
                value: DisplayValue(MetricResult<Int>.success(clock.dayOfYear)) { String($0) })
              detail(
                "Extra zones",
                value: DisplayValue(MetricResult<Int>.success(clock.zones.count)) { String($0) })
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      }
      notice(
        "Peripheral inventories are read-only. Bluetooth uses paired/HID state only; Helios does not actively scan or connect to nearby devices."
      )
    }
  }

  private var systemCard: some View {
    let system = presentation.system
    return MonitorCard(title: "System", symbol: "macbook", tint: .indigo) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Mac").font(.system(size: 10)).foregroundStyle(.secondary)
          MetricText(value: DisplayValue(system.flatMap(\.modelIdentifier)) { $0 }, size: 13)
        }
        Spacer()
        MetricText(value: DisplayValue(system.flatMap(\.chipName)) { $0 }, size: 13)
      }
      Divider().opacity(0.55)
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail("macOS", value: DisplayValue(system.map(\.osVersion)) { shortOSVersion($0) })
          detail(
            "Uptime",
            value: DisplayValue(system.map(\.uptimeSeconds), format: TelemetryFormatting.duration))
        }
        GridRow {
          detail(
            "Logical CPUs", value: DisplayValue(system.map(\.logicalProcessorCount)) { String($0) })
          memoryDetail("Memory", bytes: system.map(\.physicalMemoryBytes))
        }
        GridRow {
          detail("Thermal state", value: DisplayValue(system.map(\.thermalState)) { $0.rawValue })
          detail(
            "Low Power Mode",
            value: DisplayValue(system.map(\.lowPowerModeEnabled)) { $0 ? "On" : "Off" })
        }
        GridRow {
          detail(
            "Load 1m",
            value: DisplayValue(system.flatMap(\.loadAverage1)) { String(format: "%.2f", $0) })
          detail(
            "Load 5m",
            value: DisplayValue(system.flatMap(\.loadAverage5)) { String(format: "%.2f", $0) })
        }
      }
      detail(
        "Load 15m",
        value: DisplayValue(system.flatMap(\.loadAverage15)) { String(format: "%.2f", $0) })
      if !capabilityReport.items.isEmpty {
        Divider().opacity(0.55)
        DisclosureGroup(
          "Hardware capabilities \(capabilityReport.availableCount)/\(capabilityReport.totalCount)"
        ) {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(capabilityReport.items) { item in
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                  .fill(
                    item.state == .available
                      ? Color.green : item.state == .warming ? Color.orange : Color.secondary
                  )
                  .frame(width: 5, height: 5)
                Text(item.title).font(.system(size: 9, weight: .medium))
                Spacer()
                Text(item.state.rawValue).font(.system(size: 9)).foregroundStyle(.secondary)
              }
              .help(item.detail)
            }
            Button("Copy Capability Report") { copyCapabilityReport() }
              .buttonStyle(.bordered).controlSize(.small)
          }.padding(.top, 4)
        }
        .font(.system(size: 10, weight: .medium))
        notice(
          "Capabilities are discovered read-only. Fan writes remain separately restricted to the physically validated production profile."
        )
      }
    }
  }

  private var historyCard: some View {
    MonitorCard(title: "Live History", symbol: "chart.xyaxis.line", tint: .pink) {
      if history.points.count < 2 {
        notice("Collecting one-second samples. Helios keeps up to 60 minutes in memory.")
      }
      historyRow(
        "CPU", values: history.points.map(\.cpuPercent), current: history.points.last?.cpuPercent,
        fixedRange: 0...100
      ) { String(format: "%.0f%%", $0) }
      historyRow(
        "GPU", values: history.points.map(\.gpuPercent), current: history.points.last?.gpuPercent,
        fixedRange: 0...100
      ) { String(format: "%.0f%%", $0) }
      historyRow(
        "Max SoC", values: history.points.map(\.maxSoCCelsius),
        current: history.points.last?.maxSoCCelsius, fixedRange: 20...100
      ) { String(format: "%.0f°C", $0) }
      historyRow(
        "System Power", values: history.points.map(\.systemPowerWatts),
        current: history.points.last?.systemPowerWatts, fixedRange: nil
      ) { String(format: "%.1f W", $0) }
      historyRow(
        "Fan 1", values: history.points.map(\.fanRPM), current: history.points.last?.fanRPM,
        fixedRange: nil
      ) { String(format: "%.0f RPM", $0) }
      historyRow(
        "Download", values: history.points.map(\.networkDownloadBytesPerSecond),
        current: history.points.last?.networkDownloadBytesPerSecond, fixedRange: nil,
        format: TelemetryFormatting.bytesPerSecond)
      historyRow(
        "Upload", values: history.points.map(\.networkUploadBytesPerSecond),
        current: history.points.last?.networkUploadBytesPerSecond, fixedRange: nil,
        format: TelemetryFormatting.bytesPerSecond)
      Divider().opacity(0.55)
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail(
            "History window",
            value: DisplayValue(
              MetricResult<TimeInterval>.success(history.durationSeconds),
              format: TelemetryFormatting.duration))
          detail(
            "Power coverage",
            value: DisplayValue(
              MetricResult<TimeInterval>.success(history.measuredPowerCoverageSeconds),
              format: TelemetryFormatting.duration))
        }
        GridRow {
          detail(
            "Session energy",
            value: DisplayValue(MetricResult<Double>.success(history.sessionEnergyWattHours)) {
              String(format: "%.3f Wh", $0)
            })
          detail(
            "Samples",
            value: DisplayValue(MetricResult<Int>.success(history.points.count)) { String($0) })
        }
      }
      Divider().opacity(0.55)
      Grid(horizontalSpacing: 18, verticalSpacing: 6) {
        GridRow {
          detail(
            "24h history",
            value: DisplayValue(
              MetricResult<TimeInterval>.success(persistentHistory.durationSeconds),
              format: TelemetryFormatting.duration))
          detail(
            "Persisted samples",
            value: DisplayValue(MetricResult<Int>.success(persistentHistory.points.count)) {
              String($0)
            })
        }
        GridRow {
          detail(
            "24h energy",
            value: DisplayValue(MetricResult<Double>.success(persistentHistory.energyWattHours)) {
              String(format: "%.3f Wh", $0)
            })
          detail(
            "PSTR coverage",
            value: DisplayValue(
              MetricResult<TimeInterval>.success(persistentHistory.measuredPowerCoverageSeconds),
              format: TelemetryFormatting.duration))
        }
      }
      HStack {
        Button("Export 24h History CSV…") { exportHistoryCSV() }
          .buttonStyle(.bordered).controlSize(.small)
        Spacer()
      }
      notice(
        "Session and persisted energy integrate only successful PSTR samples; gaps, sleep, and clock jumps are never guessed."
      )
    }
  }

  private func historyRow(
    _ title: String, values: [Double?], current: Double?, fixedRange: ClosedRange<Double>?,
    format: @escaping (Double) -> String
  ) -> some View {
    HStack(spacing: 8) {
      Text(title).font(.system(size: 10, weight: .medium)).frame(width: 72, alignment: .leading)
      SparklineView(values: values, fixedRange: fixedRange)
        .frame(height: 28)
      Text(current.map(format) ?? "—")
        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundStyle(current == nil ? .secondary : .primary)
        .frame(width: 66, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
  }

  private func addressDetail(_ title: String, value: MetricResult<String>) -> some View {
    let display = DisplayValue(value) { $0 }
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).font(.system(size: 10)).foregroundStyle(.secondary).frame(
        width: 32, alignment: .leading)
      Spacer(minLength: 4)
      Text(display.text)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(display.failure == nil ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(display.failure ?? display.text)
    }
  }

  private func shortOSVersion(_ text: String) -> String {
    text.replacingOccurrences(of: "Version ", with: "")
  }

  private var storageCard: some View {
    MonitorCard(title: "Storage", symbol: "internaldrive", tint: .purple) {
      switch presentation.storage {
      case .success(let storage):
        if let device = storage.primaryDevice {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(device.model)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
              Text("\(device.bsdName) · \(device.transport)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(TelemetryFormatting.storageBytes(device.capacityBytes))
              .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
          }
        } else {
          notice("Primary internal storage unavailable")
        }

        Divider().opacity(0.55)
        Grid(horizontalSpacing: 18, verticalSpacing: 6) {
          GridRow {
            detail(
              "Used",
              value: DisplayValue(
                storage.rootVolume.map(\.usedBytes), format: TelemetryFormatting.storageBytes))
            detail(
              "Available",
              value: DisplayValue(
                storage.rootVolume.map(\.freeBytes), format: TelemetryFormatting.storageBytes))
          }
          GridRow {
            detail(
              "Read",
              value: DisplayValue(
                storage.throughput.map(\.readBytesPerSecond),
                format: TelemetryFormatting.bytesPerSecond))
            detail(
              "Write",
              value: DisplayValue(
                storage.throughput.map(\.writeBytesPerSecond),
                format: TelemetryFormatting.bytesPerSecond))
          }
          GridRow {
            detail(
              "Read IOPS",
              value: DisplayValue(
                storage.throughput.map(\.readIOPS), format: TelemetryFormatting.iops))
            detail(
              "Write IOPS",
              value: DisplayValue(
                storage.throughput.map(\.writeIOPS), format: TelemetryFormatting.iops))
          }
        }

        if let device = storage.primaryDevice {
          Divider().opacity(0.55)
          switch device.counters {
          case .success(let counters):
            Grid(horizontalSpacing: 18, verticalSpacing: 6) {
              GridRow {
                detail(
                  "Read since boot",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(counters.bytesRead),
                    format: TelemetryFormatting.storageBytes))
                detail(
                  "Written since boot",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(counters.bytesWritten),
                    format: TelemetryFormatting.storageBytes))
              }
              GridRow {
                detail(
                  "Read ops",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(counters.readOperations),
                    format: TelemetryFormatting.count))
                detail(
                  "Write ops",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(counters.writeOperations),
                    format: TelemetryFormatting.count))
              }
              GridRow {
                detail(
                  "Read errors",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(counters.readErrors),
                    format: TelemetryFormatting.count))
                detail(
                  "Write errors",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(counters.writeErrors),
                    format: TelemetryFormatting.count))
              }
            }
          case .failure(let error):
            notice("Disk I/O counters unavailable — \(error.localizedDescription)")
          }
          HStack(alignment: .firstTextBaseline) {
            Text("SMART capability").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(device.smartCapability.rawValue)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(device.smartCapability == .notAdvertised ? .secondary : .primary)
          }
        }

        Divider().opacity(0.55)
        DisclosureGroup("I/O attribution & 24h audit") {
          VStack(alignment: .leading, spacing: 7) {
            Grid(horizontalSpacing: 18, verticalSpacing: 6) {
              GridRow {
                detail(
                  "Since Helios read",
                  value: DisplayValue(
                    storage.monitoringReadBytes, format: TelemetryFormatting.storageBytes))
                detail(
                  "Since Helios write",
                  value: DisplayValue(
                    storage.monitoringWrittenBytes, format: TelemetryFormatting.storageBytes))
              }
              if case .success(let system) = presentation.system, system.uptimeSeconds > 0,
                let primary = storage.primaryDevice, case .success(let counters) = primary.counters
              {
                GridRow {
                  detail(
                    "Boot avg read",
                    value: DisplayValue(
                      MetricResult<Double>.success(
                        Double(counters.bytesRead) / system.uptimeSeconds),
                      format: TelemetryFormatting.bytesPerSecond))
                  detail(
                    "Boot avg write",
                    value: DisplayValue(
                      MetricResult<Double>.success(
                        Double(counters.bytesWritten) / system.uptimeSeconds),
                      format: TelemetryFormatting.bytesPerSecond))
                }
              }
              if case .success(let processes) = presentation.processes {
                GridRow {
                  detail(
                    "Process read",
                    value: DisplayValue(
                      MetricResult<Double>.success(processes.accountedDiskReadBytesPerSecond),
                      format: TelemetryFormatting.bytesPerSecond))
                  detail(
                    "Process write",
                    value: DisplayValue(
                      MetricResult<Double>.success(processes.accountedDiskWriteBytesPerSecond),
                      format: TelemetryFormatting.bytesPerSecond))
                }
              }
              GridRow {
                detail(
                  "24h observed read",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(ioAudit.observedDeviceReadBytes),
                    format: TelemetryFormatting.storageBytes))
                detail(
                  "24h observed write",
                  value: DisplayValue(
                    MetricResult<UInt64>.success(ioAudit.observedDeviceWrittenBytes),
                    format: TelemetryFormatting.storageBytes))
              }
              GridRow {
                detail(
                  "SMART Δ read",
                  value: DisplayValue(
                    optionalMetric(
                      persistentHistory.storageLifetimeReadDeltaBytes,
                      unavailable: "NVMe lifetime-read history unavailable"),
                    format: TelemetryFormatting.decimalBytes))
                detail(
                  "SMART Δ written",
                  value: DisplayValue(
                    optionalMetric(
                      persistentHistory.storageLifetimeWrittenDeltaBytes,
                      unavailable: "NVMe lifetime-write history unavailable"),
                    format: TelemetryFormatting.decimalBytes))
              }
              GridRow {
                detail(
                  "Audit coverage",
                  value: DisplayValue(
                    MetricResult<TimeInterval>.success(ioAudit.observedCoverageSeconds),
                    format: TelemetryFormatting.duration))
                detail(
                  "Audit records",
                  value: DisplayValue(MetricResult<Int>.success(ioAudit.records.count)) {
                    String($0)
                  })
              }
            }
            if case .success(let processes) = presentation.processes {
              if let reader = processes.topByDiskRead.first(where: {
                ($0.diskReadBytesPerSecond ?? 0) > 0
              }) {
                ioLeaderRow("Top reader now", process: reader, read: true)
              }
              if let writer = processes.topByDiskWrite.first(where: {
                ($0.diskWriteBytesPerSecond ?? 0) > 0
              }) {
                ioLeaderRow("Top writer now", process: writer, read: false)
              }
              if let writer = processes.topSessionWriters.first, writer.sessionDiskWriteBytes > 0 {
                HStack {
                  Text("Session writer").font(.system(size: 9)).foregroundStyle(.secondary)
                  Spacer()
                  Text(writer.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                  Text(TelemetryFormatting.storageBytes(writer.sessionDiskWriteBytes)).font(
                    .system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                }
              }
            }
            if let latest = ioAudit.latest {
              HStack {
                Text("Last audit").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text(latest.capturedAt, style: .time).font(.system(size: 9, design: .rounded))
                if let writer = latest.topWriterName, let rate = latest.topWriterBytesPerSecond {
                  Text("· \(writer) W \(TelemetryFormatting.bytesPerSecond(rate))")
                    .font(.system(size: 9, weight: .medium)).lineLimit(1)
                }
              }
            }
            HStack {
              Button("Copy I/O Audit") { copyIOAudit() }
                .buttonStyle(.bordered).controlSize(.small)
              Button("Export I/O CSV…") { exportIOAuditCSV() }
                .buttonStyle(.bordered).controlSize(.small)
            }
            notice(
              "Since-boot counters are physical device traffic for the whole OS, not Helios. APFS metadata, VM/swap, cache writeback, Spotlight, browser caches, Xcode builds and kernel I/O can all contribute. Process-accounted I/O is intentionally shown separately and is not expected to sum exactly to device traffic. SMART Δ uses persistent NVMe lifetime counters, so it can continue across Helios restarts when the controller exposes them."
            )
          }.padding(.top, 4)
        }
        .font(.system(size: 10, weight: .medium))

        let externalDevices = storage.externalPhysicalDevices
        if !externalDevices.isEmpty {
          Divider().opacity(0.55)
          DisclosureGroup("External storage (\(externalDevices.count))") {
            VStack(spacing: 5) {
              ForEach(externalDevices, id: \.registryID) { external in
                HStack {
                  VStack(alignment: .leading, spacing: 1) {
                    Text(external.model).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Text("\(external.bsdName) · \(external.transport)").font(.system(size: 8))
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text(TelemetryFormatting.storageBytes(external.capacityBytes)).font(
                    .system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                }
              }
            }.padding(.top, 4)
          }
          .font(.system(size: 10, weight: .medium))
        }

        Divider().opacity(0.55)
        switch storage.smartHealth {
        case .success(let smart):
          HStack(alignment: .firstTextBaseline) {
            Text("SSD health").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(smart.state.rawValue)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(
                smart.state == .verified ? .green : smart.state == .attention ? .orange : .red)
          }
          Grid(horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
              detail(
                "Life remaining",
                value: DisplayValue(MetricResult<Int>.success(smart.lifeRemainingPercent)) {
                  "\($0)%"
                })
              detail(
                "Wear used",
                value: DisplayValue(MetricResult<UInt8>.success(smart.percentageUsed)) { "\($0)%" })
            }
            GridRow {
              detail(
                "Lifetime written",
                value: DisplayValue(
                  MetricResult<Double>.success(smart.lifetimeWrittenBytes),
                  format: TelemetryFormatting.decimalBytes))
              detail(
                "Lifetime read",
                value: DisplayValue(
                  MetricResult<Double>.success(smart.lifetimeReadBytes),
                  format: TelemetryFormatting.decimalBytes))
            }
            GridRow {
              detail(
                "SSD temperature",
                value: DisplayValue(
                  smart.temperatureCelsius.map { MetricResult<Double>.success($0) }
                    ?? .failure(.unavailable("NVMe SMART temperature unavailable"))
                ) { String(format: "%.1f°C", $0) })
              detail(
                "Available spare",
                value: DisplayValue(MetricResult<UInt8>.success(smart.availableSparePercent)) {
                  "\($0)%"
                })
            }
            GridRow {
              detail(
                "Power-on hours",
                value: DisplayValue(
                  smart.powerOnHours.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Power-on hours exceed display range"))
                ) { "\($0) h" })
              detail(
                "Power cycles",
                value: DisplayValue(
                  smart.powerCycles.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Power-cycle count exceeds display range"))
                ) { String($0) })
            }
            GridRow {
              detail(
                "Unsafe shutdowns",
                value: DisplayValue(
                  smart.unsafeShutdowns.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Unsafe-shutdown count exceeds display range")),
                  format: TelemetryFormatting.count))
              detail(
                "Media errors",
                value: DisplayValue(
                  smart.mediaErrors.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Media-error count exceeds display range")),
                  format: TelemetryFormatting.count))
            }
            GridRow {
              detail(
                "Spare threshold",
                value: DisplayValue(
                  MetricResult<UInt8>.success(smart.availableSpareThresholdPercent)
                ) { "\($0)%" })
              detail(
                "Error log entries",
                value: DisplayValue(
                  smart.errorLogEntries.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Error-log count exceeds display range")),
                  format: TelemetryFormatting.count))
            }
            GridRow {
              detail(
                "Host read cmds",
                value: DisplayValue(
                  smart.hostReadCommands.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Host-read count exceeds display range")),
                  format: TelemetryFormatting.count))
              detail(
                "Host write cmds",
                value: DisplayValue(
                  smart.hostWriteCommands.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Host-write count exceeds display range")),
                  format: TelemetryFormatting.count))
            }
            GridRow {
              detail(
                "Controller busy",
                value: DisplayValue(
                  smart.controllerBusyMinutes.uint64Value.map { MetricResult<UInt64>.success($0) }
                    ?? .failure(.unavailable("Controller-busy time exceeds display range"))
                ) { "\($0) min" })
              detail(
                "Critical warning",
                value: DisplayValue(MetricResult<UInt8>.success(smart.criticalWarning)) {
                  "0x" + String($0, radix: 16)
                })
            }
          }
          if smart.criticalWarning != 0 {
            notice("NVMe SMART critical warning: 0x\(String(smart.criticalWarning, radix: 16))")
          }
        case .failure(let error):
          notice("Native NVMe SMART unavailable — \(error.localizedDescription)")
          notice("Helios never substitutes since-boot I/O counters for lifetime TBW or wear.")
        }
      case .failure(let error):
        notice("Storage telemetry unavailable — \(error.localizedDescription)")
      }
    }
  }

  private func ioLeaderRow(_ title: String, process: ProcessActivity, read: Bool) -> some View {
    let rate = read ? process.diskReadBytesPerSecond : process.diskWriteBytesPerSecond
    return HStack(spacing: 6) {
      Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
      Spacer()
      Text(process.name).font(.system(size: 9, weight: .medium)).lineLimit(1).truncationMode(
        .middle)
      Text(rate.map(TelemetryFormatting.bytesPerSecond) ?? "—")
        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
    }
    .help(process.executablePath ?? process.name)
  }

  private func detail(_ title: String, value: DisplayValue) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
      Spacer(minLength: 2)
      MetricText(value: value, size: 11)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  private func notice(_ text: String) -> some View {
    Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func temperature(_ value: Double) -> String { String(format: "%.1f°C", value) }
  private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

  private func batteryCells(_ cells: [Double]) -> String {
    guard !cells.isEmpty else { return "—" }
    return cells.enumerated().map { index, value in
      String(format: "C%d %.3fV", index + 1, value)
    }.joined(separator: " · ")
  }

  private func powerTitle(_ result: MetricResult<BatteryPower>) -> String {
    guard case .success(let power) = result else { return "Battery power" }
    return power.signedWatts > 0
      ? "Battery Charge" : power.signedWatts < 0 ? "Battery Discharge" : "Battery Idle"
  }

  private func powerBasis(_ result: MetricResult<BatteryPower>) -> String {
    guard case .success(let power) = result else { return "Reading unavailable" }
    return power.usesInstantaneousCurrent ? "Instantaneous" : "Averaged current"
  }

  private func optionalMetric<T>(_ value: T?, unavailable: String) -> MetricResult<T> {
    value.map(MetricResult<T>.success) ?? .failure(.unavailable(unavailable))
  }

  private func copyCapabilityReport() {
    var lines = [
      "Helios hardware capability report",
      "Generated: \(ISO8601DateFormatter().string(from: Date()))",
      "Available: \(capabilityReport.availableCount)/\(capabilityReport.totalCount)",
    ]
    lines.append(
      contentsOf: capabilityReport.items.map { "[\($0.state.rawValue)] \($0.title): \($0.detail)" })
    lines.append(
      "Fan-control surface matching is read-only evidence. It never authorizes or widens privileged fan writes."
    )
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
  }

  private func copyIOAudit() {
    var lines = [
      "Helios I/O audit",
      "Generated: \(ISO8601DateFormatter().string(from: Date()))",
      "Records: \(ioAudit.records.count); coverage=\(TelemetryFormatting.duration(ioAudit.observedCoverageSeconds))",
      "Observed physical I/O: read=\(TelemetryFormatting.storageBytes(ioAudit.observedDeviceReadBytes)) write=\(TelemetryFormatting.storageBytes(ioAudit.observedDeviceWrittenBytes))",
    ]
    for record in ioAudit.records.suffix(20) {
      let time = ISO8601DateFormatter().string(from: record.capturedAt)
      let physicalRead =
        record.deviceReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
      let physicalWrite =
        record.deviceWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
      let processRead =
        record.processAccountedReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
      let processWrite =
        record.processAccountedWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"
      let reader =
        record.topReaderName.map {
          "\($0) \(record.topReaderBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")"
        } ?? "—"
      let writer =
        record.topWriterName.map {
          "\($0) \(record.topWriterBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")"
        } ?? "—"
      lines.append(
        "\(time) device R \(physicalRead) W \(physicalWrite); process R \(processRead) W \(processWrite); topReader=\(reader); topWriter=\(writer)"
      )
    }
    lines.append(
      "Note: physical device counters and per-process libproc accounting are different layers and are not expected to match exactly."
    )
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
  }

  private func exportHistoryCSV() {
    exportCSV(
      PersistentHistoryEngine.csv(persistentHistory.points), suggestedName: "Helios-history-24h.csv"
    )
  }

  private func exportIOAuditCSV() {
    exportCSV(IOActivityAuditEngine.csv(ioAudit.records), suggestedName: "Helios-io-audit-24h.csv")
  }

  private func exportAppEnergyCSV() {
    exportCSV(
      AppEnergyHistoryEngine.csv(appEnergy.buckets), suggestedName: "Helios-app-energy-7d.csv")
  }

  private func exportCSV(_ csv: String, suggestedName: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    panel.title = "Export Helios data"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? csv.write(to: url, atomically: true, encoding: .utf8)
  }

  private func copyDiagnostics() {
    var lines = [
      "Helios diagnostics",
      "Generated: \(ISO8601DateFormatter().string(from: Date()))",
    ]
    if case .success(let system) = presentation.system {
      let model = TelemetryFormatting.text(system.modelIdentifier, format: { $0 })
      let chip = TelemetryFormatting.text(system.chipName, format: { $0 })
      lines.append("System: \(model) / \(chip)")
      lines.append(
        "OS: \(system.osVersion); uptime=\(TelemetryFormatting.duration(system.uptimeSeconds)); thermal=\(system.thermalState.rawValue); lowPower=\(system.lowPowerModeEnabled)"
      )
    }
    if case .success(let cpu) = presentation.cpu {
      lines.append(String(format: "CPU: %.1f%%", cpu.usagePercent))
    }
    if case .success(let gpu) = presentation.gpu {
      let usage = TelemetryFormatting.text(
        gpu.deviceUtilizationPercent, format: { String(format: "%.1f%%", $0) })
      let model = TelemetryFormatting.text(gpu.model, format: { $0 })
      lines.append("GPU: \(usage) / \(model)")
    }
    if case .success(let thermals) = presentation.thermals {
      let maximum = TelemetryFormatting.text(
        thermals.maximumSoCCelsius, format: { String(format: "%.1f C", $0) })
      lines.append("Max SoC: \(maximum); sensorFailures=\(thermals.failures.count)")
    }
    if case .success(let power) = presentation.systemPower {
      lines.append(
        "PSTR: "
          + TelemetryFormatting.text(
            power.totalSystemWatts, format: { String(format: "%.2f W", $0) }))
    }
    if case .success(let battery) = presentation.battery {
      let health = TelemetryFormatting.text(
        battery.healthPercent, format: { String(format: "%.1f%%", $0) })
      let charge = TelemetryFormatting.text(
        battery.stateOfChargePercent, format: { String(format: "%.1f%%", $0) })
      let cycles = TelemetryFormatting.text(battery.cycleCount, format: { String($0) })
      lines.append("Battery: health=\(health); charge=\(charge); cycles=\(cycles)")
    }
    if case .success(let network) = presentation.network {
      let primary = TelemetryFormatting.text(network.primaryInterface, format: { $0 })
      let down = TelemetryFormatting.text(
        network.throughput.map(\.downloadBytesPerSecond), format: TelemetryFormatting.bytesPerSecond
      )
      let up = TelemetryFormatting.text(
        network.throughput.map(\.uploadBytesPerSecond), format: TelemetryFormatting.bytesPerSecond)
      lines.append(
        "Network: primary=\(primary); active=\(network.activeInterfaceCount); down=\(down); up=\(up)"
      )
    }
    if case .success(let wifi) = presentation.wifi {
      let ssid = TelemetryFormatting.text(wifi.ssid, format: { $0 })
      let rssi = TelemetryFormatting.text(wifi.rssiDBm, format: { "\($0) dBm" })
      let rate = TelemetryFormatting.text(
        wifi.transmitRateMbps, format: { String(format: "%.0f Mb/s", $0) })
      lines.append("Wi-Fi: ssid=\(ssid); rssi=\(rssi); tx=\(rate); active=\(wifi.serviceActive)")
    }
    if case .success(let processes) = presentation.processes {
      let top =
        processes.topByCPU.first.map {
          "\($0.name) \($0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")"
        } ?? "—"
      let reader =
        processes.topByDiskRead.first.map {
          "\($0.name) \($0.diskReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")"
        } ?? "—"
      let writer =
        processes.topByDiskWrite.first.map {
          "\($0.name) \($0.diskWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—")"
        } ?? "—"
      lines.append(
        "Processes: accessible=\(processes.accessibleProcessCount); topCPU=\(top); accountedIO=R \(TelemetryFormatting.bytesPerSecond(processes.accountedDiskReadBytesPerSecond)) W \(TelemetryFormatting.bytesPerSecond(processes.accountedDiskWriteBytesPerSecond)); topReader=\(reader); topWriter=\(writer)"
      )
      if let own = processes.heliosActivity {
        lines.append(
          "Helios footprint: CPU=\(own.cpuPercent.map { String(format: "%.2f%%", $0) } ?? "—"); power=\(own.powerWatts.map { String(format: "%.3f W", $0) } ?? "—"); memory=\(TelemetryFormatting.storageBytes(own.physicalFootprintBytes)); IO=R \(own.diskReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—") W \(own.diskWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "—"); sessionIO=R \(TelemetryFormatting.storageBytes(own.sessionDiskReadBytes)) W \(TelemetryFormatting.storageBytes(own.sessionDiskWriteBytes))"
        )
      }
    }
    if case .success(let storage) = presentation.storage, let device = storage.primaryDevice {
      let smart = TelemetryFormatting.text(
        storage.smartHealth.map(\.state), format: { $0.rawValue })
      let monitorRead = TelemetryFormatting.text(
        storage.monitoringReadBytes, format: TelemetryFormatting.storageBytes)
      let monitorWrite = TelemetryFormatting.text(
        storage.monitoringWrittenBytes, format: TelemetryFormatting.storageBytes)
      lines.append(
        "Storage: \(device.bsdName) / \(device.model); capacity=\(TelemetryFormatting.storageBytes(device.capacityBytes)); SMART=\(smart); sinceHelios=R \(monitorRead) W \(monitorWrite)"
      )
    }
    lines.append(
      String(
        format:
          "History: sessionSamples=%d; sessionWindow=%@; sessionEnergy=%.4f Wh; persistedSamples=%d; persistedWindow=%@; persistedEnergy=%.4f Wh; batteryEnergy=%+.4f Wh",
        history.points.count, TelemetryFormatting.duration(history.durationSeconds),
        history.sessionEnergyWattHours, persistentHistory.points.count,
        TelemetryFormatting.duration(persistentHistory.durationSeconds),
        persistentHistory.energyWattHours, persistentHistory.batteryEnergyWattHours))
    lines.append(
      "I/O audit: records=\(ioAudit.records.count); coverage=\(TelemetryFormatting.duration(ioAudit.observedCoverageSeconds)); observedRead=\(TelemetryFormatting.storageBytes(ioAudit.observedDeviceReadBytes)); observedWrite=\(TelemetryFormatting.storageBytes(ioAudit.observedDeviceWrittenBytes))"
    )
    if let healthCenter {
      lines.append(
        "Health: issues=\(healthCenter.issues.count); notifications=\(healthCenter.authorization.rawValue)"
      )
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
  }
}

struct HealthCard: View {
  @ObservedObject var center: HealthAlertCenter
  var showEventLog = false

  var body: some View {
    MonitorCard(title: "Health & Alerts", symbol: "heart.text.square", tint: .red) {
      HStack {
        Text(
          center.issues.isEmpty
            ? "All monitored signals normal"
            : "\(center.issues.count) active issue\(center.issues.count == 1 ? "" : "s")"
        )
        .font(.system(size: 11, weight: .medium))
        Spacer()
        Text(center.authorization.rawValue)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(center.authorization == .enabled ? .green : .secondary)
      }
      if !center.issues.isEmpty {
        Divider().opacity(0.55)
        ForEach(center.issues) { issue in
          HStack(alignment: .top, spacing: 7) {
            Circle().fill(issue.severity == .critical ? Color.red : Color.orange).frame(
              width: 6, height: 6
            ).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
              Text(issue.title).font(.system(size: 10, weight: .semibold))
              Text(issue.detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
          }
        }
      }
      if !center.events.isEmpty {
        if showEventLog {
          Divider().opacity(0.55)
          HStack {
            Label("Alert log", systemImage: "list.bullet.rectangle")
              .font(.system(size: 10.5, weight: .semibold))
            Spacer()
            Text("Local · 7 days")
              .font(.system(size: 8.5, weight: .medium))
              .foregroundStyle(.tertiary)
          }
          VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(center.events.suffix(20).reversed())) { event in
              eventLogRow(event, showDetail: true)
            }
          }
        } else {
          DisclosureGroup("Recent health events (\(center.events.count))") {
            VStack(alignment: .leading, spacing: 5) {
              ForEach(Array(center.events.suffix(8).reversed())) { event in
                eventLogRow(event, showDetail: false)
              }
            }.padding(.top, 4)
          }
          .font(.system(size: 10, weight: .medium))
        }
      }
      if center.authorization != .enabled {
        Button(
          center.authorization == .denied ? "Notifications denied in macOS" : "Enable Notifications"
        ) {
          if center.authorization != .denied { center.requestAuthorization() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(center.authorization == .denied)
      }
      Text(
        "Attention alerts must remain continuously active for 15 seconds and the same alert is then suppressed for 30 minutes. Critical alerts are immediate with a 10-minute repeat cooldown. Every activation, resolution and delivered notification is logged locally; alerts never change fan-control decisions."
      )
      .font(.system(size: 9)).foregroundStyle(.secondary)
    }
    .task { await center.refreshAuthorization() }
  }

  @ViewBuilder
  private func eventLogRow(_ event: HealthEventRecord, showDetail: Bool) -> some View {
    let presentation = eventPresentation(event.change)
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: presentation.symbol)
        .font(.system(size: 9))
        .foregroundStyle(presentation.tint)
        .frame(width: 12)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(event.capturedAt, style: .time)
            .font(.system(size: 8.5, design: .rounded))
            .foregroundStyle(.secondary)
          Text(event.title)
            .font(.system(size: 9.5, weight: .medium))
            .lineLimit(showDetail ? 2 : 1)
          Spacer(minLength: 2)
          Text(presentation.label)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(presentation.tint)
        }
        if showDetail {
          Text(event.detail)
            .font(.system(size: 8.75))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .help(event.detail)
  }

  private func eventPresentation(_ change: HealthEventRecord.Change) -> (
    symbol: String, label: String, tint: Color
  ) {
    switch change {
    case .activated:
      return ("exclamationmark.circle.fill", "Active", .orange)
    case .resolved:
      return ("checkmark.circle.fill", "Resolved", .green)
    case .notified:
      return ("bell.badge.fill", "Notified", .blue)
    }
  }
}

private struct SparklineView: View {
  let values: [Double?]
  let fixedRange: ClosedRange<Double>?

  var body: some View {
    GeometryReader { geometry in
      let valid = values.compactMap { value -> Double? in
        guard let value, value.isFinite else { return nil }
        return value
      }
      let derivedMin = valid.min() ?? 0
      let derivedMax = valid.max() ?? 1
      let padding = max(0.5, (derivedMax - derivedMin) * 0.08)
      let range =
        fixedRange ?? ((max(0, derivedMin - padding))...(max(derivedMin + 1, derivedMax + padding)))
      Path { path in
        guard values.count > 1, range.upperBound > range.lowerBound else { return }
        let width = geometry.size.width
        let height = geometry.size.height
        var drawing = false
        for (index, raw) in values.enumerated() {
          guard let raw, raw.isFinite else {
            drawing = false
            continue
          }
          let value = min(range.upperBound, max(range.lowerBound, raw))
          let x = width * CGFloat(index) / CGFloat(max(1, values.count - 1))
          let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
          let y = height * CGFloat(1 - normalized)
          let point = CGPoint(x: x, y: y)
          if drawing {
            path.addLine(to: point)
          } else {
            path.move(to: point)
            drawing = true
          }
        }
      }
      .stroke(
        Color.secondary.opacity(0.8),
        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }
    .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
    .accessibilityHidden(true)
  }
}

@MainActor
struct MaintenanceCard: View {
  @StateObject private var model = MaintenanceViewModel()

  init() {}

  var body: some View {
    MonitorCard(title: "Maintenance Scout", symbol: "wrench.and.screwdriver", tint: .mint) {
      Text(
        "Explicit read-only scans. Helios estimates space and inventories apps; it never deletes, uninstalls, modifies, or executes discovered content."
      )
      .font(.system(size: 9)).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button(model.scanningCleanup ? "Scanning caches…" : "Scan cleanup candidates") {
          model.scanCleanup()
        }
        .buttonStyle(.bordered).controlSize(.small).disabled(model.scanningCleanup)
        Button(model.scanningApplications ? "Scanning apps…" : "Scan applications") {
          model.scanApplications()
        }
        .buttonStyle(.bordered).controlSize(.small).disabled(model.scanningApplications)
      }
      if model.scanningCleanup || model.scanningApplications { ProgressView().controlSize(.small) }
      if let error = model.cleanupError {
        Text("Cleanup scan unavailable — \(error)").font(.system(size: 9)).foregroundStyle(
          .secondary)
      }
      if let cleanup = model.cleanup {
        DisclosureGroup(
          "Cleanup candidates · \(TelemetryFormatting.storageBytes(cleanup.estimatedBytes))"
        ) {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(cleanup.candidates) { item in
              DisclosureGroup(item.label) {
                VStack(spacing: 3) {
                  maintenanceRow("ID", item.id)
                  maintenanceRow("Path", item.path)
                  maintenanceRow(
                    "Estimated size", TelemetryFormatting.storageBytes(item.estimatedBytes))
                  maintenanceRow("Scanned entries", String(item.scannedEntries))
                  maintenanceRow("Scan truncated", item.truncated ? "Yes" : "No")
                }
                .padding(.top, 3)
              }
              .font(.system(size: 9, weight: .medium))
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      }
      if let error = model.applicationsError {
        Text("Application inventory unavailable — \(error)").font(.system(size: 9)).foregroundStyle(
          .secondary)
      }
      if let applications = model.applications {
        let arm = applications.applications.filter { $0.architecture == .appleSilicon }.count
        let universal = applications.applications.filter { $0.architecture == .universal }.count
        let intel = applications.applications.filter { $0.architecture == .intel }.count
        DisclosureGroup("Applications (\(applications.applications.count))") {
          LazyVStack(alignment: .leading, spacing: 5) {
            Text("Apple Silicon \(arm) · Universal \(universal) · Intel \(intel)")
              .font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(
              applications.applications.sorted {
                ($0.estimatedSizeBytes ?? 0) > ($1.estimatedSizeBytes ?? 0)
              }
            ) { app in
              DisclosureGroup(app.name) {
                VStack(spacing: 3) {
                  maintenanceRow("Path", app.path)
                  maintenanceRow("Bundle identifier", app.bundleIdentifier ?? "—")
                  maintenanceRow("Version", app.version ?? "—")
                  maintenanceRow("Architecture", app.architecture.rawValue)
                  maintenanceRow(
                    "Estimated size",
                    app.estimatedSizeBytes.map(TelemetryFormatting.storageBytes) ?? "—")
                  maintenanceRow("Size scan truncated", app.sizeTruncated ? "Yes" : "No")
                }
                .padding(.top, 3)
              }
              .font(.system(size: 9, weight: .medium))
            }
          }.padding(.top, 4)
        }.font(.system(size: 10, weight: .medium))
      }
    }
  }

  private func maintenanceRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 12)
      Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
    }
    .font(.system(size: 8.5))
  }
}

private struct MonitorCard<Content: View>: View {
  let title: String
  let symbol: String
  let tint: Color
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(title, systemImage: symbol)
        .font(.system(size: 13, weight: .bold))
        .labelStyle(CardLabelStyle(tint: tint))
        .padding(.bottom, 2)
      content
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10).strokeBorder(
        Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5))
  }
}

private struct CardLabelStyle: LabelStyle {
  let tint: Color
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 7) {
      configuration.icon.foregroundStyle(tint).frame(width: 14)
      configuration.title.foregroundStyle(.primary)
    }
  }
}

private struct MetricText: View {
  let value: DisplayValue
  var size: CGFloat = 12

  var body: some View {
    Text(value.text)
      .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
      .foregroundStyle(value.failure == nil ? .primary : .secondary)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .help(value.failure ?? "")
      .accessibilityLabel(value.failure.map { "Unavailable: \($0)" } ?? value.text)
  }
}
