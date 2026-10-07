import SwiftUI

/// Helios popover for one menu-bar metric: what it is now, a short chart,
/// the few facts that explain it and a way into the matching page. It reads the
/// shared model; opening it samples nothing.
struct HeliosMetricStatusPopover: View {
  let metric: HeliosMenuBarMetric
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel

  static let width: CGFloat = 340

  init(metric: HeliosMenuBarMetric, context: HeliosContext) {
    self.metric = metric
    self.context = context
    model = context.model
  }

  var body: some View {
    let presentation = model.presentation
    VStack(alignment: .leading, spacing: 12) {
      header(presentation)
      if metric == .cooling || metric == .temperature {
        fanLine(presentation)
        fanModes(presentation)
      }
      if metric == .memory, case .success(let memory) = presentation.memory {
        HeliosMemoryGaugeBlock(memory: memory, preferences: context.preferences)
      } else {
        if let chart = Self.chartMetric(metric) {
          HeliosChartPanel(
            metric: chart, model: model, preferences: context.preferences, scope: .overview,
            height: 70, showsRange: false)
        }
        // Cooling: fan speed next to the temperature.
        if metric == .cooling || metric == .temperature, HeliosCooling.hasFans(presentation) {
          HeliosChartPanel(
            metric: .fan, model: model, preferences: context.preferences, scope: .overview,
            height: 56, showsRange: false)
        }
        // Network: upload gets its own line under download.
        if metric == .network {
          HeliosChartPanel(
            metric: .networkUpload, model: model, preferences: context.preferences,
            scope: .overview, height: 56, showsRange: false)
        }
        extraBlock(presentation)
        HeliosFactList(rows: Self.rows(metric, presentation))
      }
      if metric == .cpu || metric == .memory { topProcesses(presentation) }
      Divider()
      HStack {
        Button("Open \(Self.page(metric).title)") { context.actions.openPage(Self.page(metric)) }
          .keyboardShortcut(.defaultAction)
        Spacer()
        Button("Settings…", action: context.actions.openSettings)
      }
      .controlSize(.small)
    }
    .padding(16)
    .frame(width: Self.width)
  }

  // MARK: Header

  @ViewBuilder
  private func header(_ presentation: OverviewPresentation) -> some View {
    let area = Self.area(metric).map {
      HeliosMacAssessment.area($0, snapshot: model.snapshot, configuration: context.preferences.healthAlerts)
    }
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: Self.symbol(metric)).foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(Self.title(metric)).font(.headline)
      Spacer(minLength: 8)
      Text(Self.headline(metric, presentation))
        .font(.title2.weight(.semibold)).monospacedDigit()
    }
    if let area {
      HeliosStatusLabel(status: area.status, compact: true)
      if area.status.isProblem {
        Text(area.explanation).font(.subheadline).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// What a compact popover adds to the chart and facts: the same cluster and
  /// meter views the pages use, in their small form.
  @ViewBuilder
  private func extraBlock(_ presentation: OverviewPresentation) -> some View {
    switch metric {
    case .cpu:
      if case .success(let cpu) = presentation.cpu, !cpu.perCoreUsagePercent.isEmpty {
        HeliosGroup { HeliosCoreStrips(cpu: cpu) }
      }
    case .gpu:
      if case .success(let gpu) = presentation.gpu {
        HeliosGroup {
          VStack(alignment: .leading, spacing: 8) {
            HeliosMeterRow(label: "Device", value: try? gpu.deviceUtilizationPercent.get())
            HeliosMeterRow(label: "Renderer", value: try? gpu.rendererUtilizationPercent.get())
            HeliosMeterRow(label: "Tiler", value: try? gpu.tilerUtilizationPercent.get())
          }
          .padding(.vertical, 6)
        }
      }
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func topProcesses(_ presentation: OverviewPresentation) -> some View {
    if metric == .cpu {
      HeliosRightNowSection(context: context, presentation: presentation, limit: 3)
    } else if case .success(let processes) = presentation.processes {
      let leaders = Self.memoryLeaders(processes.topByMemory, limit: 3)
      if !leaders.isEmpty {
        HeliosSection("Most memory") {
          VStack(spacing: 6) {
            ForEach(leaders) { leader in
              HStack(spacing: 8) {
                HeliosAppIdentityIcon(appKey: leader.id, size: 18)
                Text(leader.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(TelemetryFormatting.storageBytes(leader.bytes))
                  .monospacedDigit().foregroundStyle(.secondary)
              }
              .accessibilityElement(children: .combine)
            }
          }
        }
      }
    }
  }

  /// "Fan off" / "1556 RPM" line above the facts on the temperature popover, so the
  /// bar item can stay a plain temperature.
  @ViewBuilder
  private func fanLine(_ presentation: OverviewPresentation) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "fan").foregroundStyle(.secondary).accessibilityHidden(true)
      Text("Fan").foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(HeliosText.value(presentation.fans) { TelemetryFormatting.fanSummary($0) })
        .font(.body.weight(.semibold)).monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }

  /// Fan modes, only on a Mac with a fan and with cooling features on.
  @ViewBuilder
  private func fanModes(_ presentation: OverviewPresentation) -> some View {
    if let service = context.service, context.preferences.coolingFeaturesEnabled,
      HeliosCooling.hasFans(presentation)
    {
      HeliosFanModeBar(
        model: service.fanControl, client: service.client, preferences: context.preferences,
        host: HeliosCoolingSection.hostSummary(presentation),
        setUp: { context.actions.openSettingsRoute(.fans) })
    }
  }

  /// Applications by total memory, helpers folded into their app.
  struct MemoryLeader: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: UInt64
  }

  static func memoryLeaders(_ processes: [ProcessActivity], limit: Int) -> [MemoryLeader] {
    var totals: [String: MemoryLeader] = [:]
    for process in processes {
      let identity = HeliosAppIdentity.of(process)
      let previous = totals[identity.key]?.bytes ?? 0
      let sum = previous.addingReportingOverflow(process.physicalFootprintBytes)
      totals[identity.key] = MemoryLeader(
        id: identity.key, name: identity.name, bytes: sum.overflow ? .max : sum.partialValue)
    }
    return totals.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }
      .prefix(limit).map { $0 }
  }

  // MARK: Mapping (pure, shared with tests)

  static func title(_ metric: HeliosMenuBarMetric) -> String {
    switch metric {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .gpu: "GPU"
    case .temperature: "Temperature"
    case .cooling: "Cooling"
    case .fan: "Fan"
    case .battery: "Battery"
    case .power: "System Power"
    case .network: "Network"
    }
  }

  static func symbol(_ metric: HeliosMenuBarMetric) -> String {
    switch metric {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .gpu: "display"
    case .temperature: "thermometer.medium"
    case .cooling, .fan: "fan"
    case .battery: "battery.75percent"
    case .power: "bolt"
    case .network: "network"
    }
  }

  static func page(_ metric: HeliosMenuBarMetric) -> HeliosPage {
    switch metric {
    case .cpu: .cpu
    case .gpu: .gpu
    case .memory: .memory
    case .temperature, .cooling, .fan: .thermals
    case .battery, .power: .battery
    case .network: .network
    }
  }

  static func area(_ metric: HeliosMenuBarMetric) -> HeliosArea? {
    switch metric {
    case .cpu, .memory: .performance
    case .temperature, .cooling, .fan: .thermals
    case .battery: .battery
    case .gpu, .power, .network: nil
    }
  }

  static func chartMetric(_ metric: HeliosMenuBarMetric) -> HeliosChartMetric? {
    switch metric {
    case .cpu: .cpu
    case .memory: .memory
    case .gpu: .gpu
    case .temperature, .cooling: .temperature
    case .fan: .fan
    case .battery: .battery
    case .power: .power
    case .network: .network
    }
  }

  static func headline(_ metric: HeliosMenuBarMetric, _ p: OverviewPresentation) -> String {
    switch metric {
    case .cpu: return HeliosText.value(p.cpu) { TelemetryFormatting.percent($0.usagePercent) }
    case .memory: return HeliosText.value(p.memory) { TelemetryFormatting.percent($0.usagePercent) }
    case .gpu:
      return HeliosText.value(p.gpu.flatMap(\.deviceUtilizationPercent)) { TelemetryFormatting.percent($0) }
    case .temperature, .cooling:
      return HeliosText.value(p.thermals.flatMap(\.maximumSoCCelsius)) { TelemetryFormatting.temperature($0) }
    case .fan:
      return HeliosText.value(p.fans) { TelemetryFormatting.fanSummary($0) }
    case .battery:
      return HeliosText.value(p.battery.flatMap(\.stateOfChargePercent)) { TelemetryFormatting.percent($0) }
    case .power:
      return HeliosText.value(p.systemPower.flatMap(\.totalSystemWatts)) { TelemetryFormatting.watts($0) }
    case .network:
      return HeliosText.value(p.network.flatMap(\.throughput)) {
        "↓ \(TelemetryFormatting.bytesPerSecond($0.downloadBytesPerSecond))"
      }
    }
  }

  static func rows(_ metric: HeliosMenuBarMetric, _ p: OverviewPresentation) -> [HeliosEvidence] {
    switch metric {
    case .cpu:
      var rows = [
        HeliosEvidence(label: "User / System", value: HeliosText.value(p.cpu) {
          "\(TelemetryFormatting.percent($0.userPercent)) / \(TelemetryFormatting.percent($0.systemPercent))"
        }),
        HeliosEvidence(label: "Idle", value: HeliosText.value(p.cpu) { TelemetryFormatting.percent($0.idlePercent) }),
      ]
      if case .success(let system) = p.system {
        let loads = [system.loadAverage1, system.loadAverage5, system.loadAverage15]
          .map { HeliosText.value($0) { String(format: "%.2f", $0) } }
        rows.append(HeliosEvidence(label: "Load average", value: loads.joined(separator: " · ")))
      }
      if case .success(let metrics) = p.thermals, case .success(let average) = metrics.averageCPUCelsius {
        let hottest = (try? metrics.maximumSoCCelsius.get()).map { TelemetryFormatting.temperature($0) } ?? "—"
        rows.append(HeliosEvidence(label: "Temperature", value: "\(TelemetryFormatting.temperature(average)) / \(hottest)",
          source: "Average / hottest sensor"))
      }
      return rows
    case .memory:
      return [
        HeliosEvidence(label: "Used", value: HeliosText.value(p.memory) {
          "\(TelemetryFormatting.gibibytes($0.usedBytes)) of \(TelemetryFormatting.gibibytes($0.physicalBytes))"
        }),
        HeliosEvidence(label: "Pressure", value: HeliosText.value(p.memory.flatMap(\.pressure)) { $0.rawValue },
          source: "Reported by macOS"),
        HeliosEvidence(label: "Compressed", value: HeliosText.value(p.memory) { TelemetryFormatting.gibibytes($0.compressedBytes) }),
        HeliosEvidence(label: "Swap", value: HeliosText.value(p.memory.flatMap(\.swapUsedBytes)) { TelemetryFormatting.storageBytes($0) }),
      ]
    case .gpu:
      let hottest = (try? p.thermals.get())?.readings.filter { $0.displayGroup == .gpu }.map(\.celsius).max()
      return [
        HeliosEvidence(label: "Model", value: HeliosText.value(p.gpu.flatMap(\.model)) { $0 }),
        HeliosEvidence(label: "Cores", value: HeliosText.value(p.gpu.flatMap(\.coreCount)) { "\($0)" }),
        HeliosEvidence(label: "Memory in use", value: HeliosText.value(p.gpu.flatMap(\.inUseSystemMemoryBytes)) {
          TelemetryFormatting.storageBytes($0)
        }),
        HeliosEvidence(label: "Temperature", value: hottest.map { "\(TelemetryFormatting.temperature($0)) hottest" } ?? "—"),
      ]
    case .temperature, .cooling, .fan:
      // The fan is the line above the facts on the temperature popover, so it is
      // listed here only when the fan is the subject.
      var rows = [
        HeliosEvidence(label: "Hottest sensor", value: HeliosText.value(p.thermals.flatMap(\.maximumSoCCelsius)) {
          TelemetryFormatting.temperature($0)
        }, source: "Max SoC"),
        HeliosEvidence(label: "CPU average", value: HeliosText.value(p.thermals.flatMap(\.averageCPUCelsius)) {
          TelemetryFormatting.temperature($0)
        }, source: "Mean of the P- and E-core sensors"),
        HeliosEvidence(label: "Thermal pressure", value: HeliosText.value(p.system) { $0.thermalState.rawValue },
          source: "Reported by macOS"),
      ]
      if let gpu = (try? p.thermals.get())?.readings.filter({ $0.displayGroup == .gpu }).map(\.celsius).max() {
        rows.insert(HeliosEvidence(label: "GPU", value: TelemetryFormatting.temperature(gpu), source: "Hottest GPU sensor"), at: 2)
      }
      if metric == .fan {
        rows.append(HeliosEvidence(label: "Fan", value: HeliosText.value(p.fans) { TelemetryFormatting.fanSummary($0) }))
      }
      return rows
    case .battery:
      return [
        HeliosEvidence(label: "Status", value: powerStatus(p)),
        HeliosEvidence(label: "Capacity", value: HeliosText.value(p.battery.flatMap(\.healthPercent)) {
          TelemetryFormatting.percent($0)
        }, source: "Compared with design"),
        HeliosEvidence(label: "Cycles", value: HeliosText.value(p.battery.flatMap(\.cycleCount)) { "\($0)" }),
        HeliosEvidence(label: "Temperature", value: HeliosText.value(p.battery.flatMap(\.temperatureCelsius)) {
          TelemetryFormatting.temperature($0, decimals: 1)
        }),
        HeliosEvidence(label: "Time remaining", value: HeliosText.value(p.battery.flatMap(\.timeRemaining)) {
          TelemetryFormatting.batteryTimeRemaining($0)
        }),
        HeliosEvidence(label: "Power flow", value: HeliosText.value(p.battery.flatMap(\.power)) {
          TelemetryFormatting.watts($0.signedWatts, signed: true)
        }, source: "+ charging · − discharging"),
        HeliosEvidence(label: "Power adapter", value: adapterText(p)),
      ]
    case .power:
      return [
        HeliosEvidence(label: "System", value: HeliosText.value(p.systemPower.flatMap(\.totalSystemWatts)) {
          TelemetryFormatting.watts($0)
        }),
        HeliosEvidence(label: "Battery flow", value: HeliosText.value(p.battery.flatMap(\.power)) {
          TelemetryFormatting.watts($0.signedWatts, signed: true)
        }, source: "+ charging · − discharging"),
        HeliosEvidence(label: "Power source", value: powerStatus(p)),
        HeliosEvidence(label: "Power adapter", value: adapterText(p)),
      ]
    case .network:
      var rows = [
        HeliosEvidence(label: "Download", value: HeliosText.value(p.network.flatMap(\.throughput)) {
          TelemetryFormatting.bytesPerSecond($0.downloadBytesPerSecond)
        }),
        HeliosEvidence(label: "Upload", value: HeliosText.value(p.network.flatMap(\.throughput)) {
          TelemetryFormatting.bytesPerSecond($0.uploadBytesPerSecond)
        }),
        HeliosEvidence(label: "Interface", value: HeliosText.value(p.network.flatMap(\.primaryInterface)) { $0 },
          source: HeliosText.value(p.network.flatMap(\.linkSpeedBitsPerSecond)) { TelemetryFormatting.bitsPerSecond($0) }),
      ]
      if case .success(let wifi) = p.wifi, case .success(let rssi) = wifi.rssiDBm {
        rows.append(HeliosEvidence(label: "Wi-Fi signal", value: "\(rssi) dBm",
          source: HeliosText.value(wifi.transmitRateMbps) { String(format: "%.0f Mb/s", $0) }))
      }
      rows.append(HeliosEvidence(label: "This session", value: "↓ \(HeliosText.value(p.network.flatMap(\.sessionDownloadedBytes)) { TelemetryFormatting.storageBytes($0) })  ↑ \(HeliosText.value(p.network.flatMap(\.sessionUploadedBytes)) { TelemetryFormatting.storageBytes($0) })"))
      return rows
    }
  }

  private static func powerStatus(_ p: OverviewPresentation) -> String {
    guard case .success(let battery) = p.battery else { return "—" }
    if case .success(true) = battery.isCharging { return "Charging" }
    if case .success(true) = battery.isCharged { return "Charged" }
    switch battery.powerSource {
    case .success(.battery): return "On battery"
    case .success(.powerAdapter): return "Power adapter"
    case .failure(let error): return HeliosText.failure(error)
    }
  }

  private static func adapterText(_ p: OverviewPresentation) -> String {
    guard case .success(let battery) = p.battery else { return "—" }
    if case .success(.battery) = battery.powerSource { return "Not connected" }
    return HeliosText.value(battery.adapterWatts) { "\($0) W" }
  }
}

/// The memory popover's centrepiece: a coloured ring (what is used, split into
/// app / wired / compressed), the headline facts and the breakdown beneath it.
struct HeliosMemoryGaugeBlock: View {
  let memory: MemoryMetrics
  @ObservedObject var preferences: HeliosPreferences

  var body: some View {
    let composition = HeliosMemoryComposition(memory)
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        HeliosSegmentedArcGauge(
          segments: composition.gaugeSegments(
            showAvailable: preferences.memoryGaugeShowsAvailable, preferences: preferences),
          progress: composition.usedFraction,
          valueText: TelemetryFormatting.percent(memory.usagePercent),
          subtitle: "Used")
          .frame(width: 118, height: 106)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Memory used \(TelemetryFormatting.percent(memory.usagePercent))")
        VStack(alignment: .leading, spacing: 8) {
          summaryRow("Pressure", HeliosText.value(memory.pressure) { $0.rawValue },
            tint: pressureColor, emphasized: true)
          summaryRow("Used", TelemetryFormatting.gibibytes(composition.usedBytes),
            tint: preferences.color(for: .memory))
          summaryRow("Available", TelemetryFormatting.gibibytes(composition.availableBytes),
            tint: availableTint)
          summaryRow("Swap", HeliosText.value(memory.swapUsedBytes) { TelemetryFormatting.storageBytes($0) },
            tint: preferences.color(for: .swap))
        }
      }
      HeliosGroup {
        breakdownRow("App memory", composition.appBytes, composition, preferences.color(for: .memoryApp))
        breakdownRow("Wired", composition.wiredBytes, composition, preferences.color(for: .memoryWired))
        breakdownRow("Compressed", composition.compressedBytes, composition,
          preferences.color(for: .memoryCompressed))
        breakdownRow("Available", composition.availableBytes, composition, availableTint)
        breakdownRow("Reclaimable cache", composition.cacheBytes, composition,
          preferences.color(for: .memoryCache), showsPercent: false, showsDivider: false)
      }
    }
  }

  private var availableTint: Color {
    preferences.memoryGaugeShowsAvailable
      ? preferences.color(for: .memoryAvailable) : HeliosMemoryPalette.unfilled
  }

  private var pressureColor: Color {
    guard case .success(let pressure) = memory.pressure else { return .secondary }
    switch pressure {
    case .normal: return .green
    case .warning: return .orange
    case .critical: return .red
    }
  }

  private func summaryRow(_ label: String, _ value: String, tint: Color, emphasized: Bool = false)
    -> some View
  {
    HStack(spacing: 6) {
      if !emphasized { Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true) }
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(value).monospacedDigit().fontWeight(.semibold)
        .foregroundStyle(emphasized ? tint : Color.primary)
    }
    .font(.subheadline)
    .accessibilityElement(children: .combine)
  }

  private func breakdownRow(
    _ label: String, _ bytes: UInt64, _ composition: HeliosMemoryComposition, _ tint: Color,
    showsPercent: Bool = true, showsDivider: Bool = true
  ) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
        Text(label)
        Spacer(minLength: 8)
        Text(TelemetryFormatting.gibibytes(bytes)).monospacedDigit()
        Text(showsPercent ? TelemetryFormatting.percent(composition.percent(bytes)) : "")
          .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
      }
      .font(.subheadline)
      .padding(.vertical, 6)
      if showsDivider { Divider() }
    }
    .accessibilityElement(children: .combine)
  }
}
