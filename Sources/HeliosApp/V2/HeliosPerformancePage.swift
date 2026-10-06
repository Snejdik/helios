import SwiftUI

// CPU, GPU and Memory are separate pages. CPU and
// Memory share the Performance assessment; each page leads with its own finding.

/// Simple page header for a component without its own assessment.
struct HeliosComponentHeader: View {
  let explanation: String
  let value: String
  let caption: String

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Text(explanation)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 16)
      HeliosHeadlineValue(value: value, caption: caption)
    }
  }
}

struct HeliosCPUPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @State private var showAllProcesses = false
  @State private var showDetails = false

  var body: some View {
    let presentation = model.presentation
    let assessment = HeliosMacAssessment.performance(model.snapshot, now: Date())
    let range = context.preferences.graphRange(for: .cpu)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      if assessment.chartMetric == .cpu {
        HeliosAreaHeader(
          assessment: assessment, meaning: HeliosCopy.meaning(.performance), valueCaption: "Total CPU")
      } else {
        HeliosComponentHeader(
          explanation: "The processor. Memory needs attention right now — see Memory.",
          value: HeliosText.value(presentation.cpu) { TelemetryFormatting.percent($0.usagePercent) },
          caption: "Total CPU")
      }
      HeliosChartPanel(
        metric: .cpu, model: model, preferences: context.preferences, scope: .cpu,
        markers: context.feed.markers(for: .cpu, range: range))

      HeliosSection("Processor") {
        HeliosGroup { cpuRows(presentation) }
      }
      if case .success(let cpu) = presentation.cpu, !cpu.perCoreUsagePercent.isEmpty {
        HeliosSection("Per-core usage") {
          HeliosGroup { HeliosCoreClusters(cpu: cpu) }
        }
      }

      HeliosSection("What’s using your Mac") {
        HeliosRightNowList(context: context, presentation: presentation, limit: 5)
        if context.preferences.isTelemetryCollectionRequired(.processes) {
          DisclosureGroup("More processes", isExpanded: $showAllProcesses) {
            HeliosProcessTable(presentation: presentation)
              .padding(.top, 6)
          }
        }
      }

      DisclosureGroup("Details", isExpanded: $showDetails) {
        HeliosFactList(rows: HeliosPerformanceDetails.cpuRows(presentation))
          .padding(.top, 8)
      }
    }
  }

  @ViewBuilder
  private func cpuRows(_ p: OverviewPresentation) -> some View {
    switch p.cpu {
    case .success(let cpu):
      HeliosFactRow(label: "Usage", value: TelemetryFormatting.percent(cpu.usagePercent, decimals: 1))
      HeliosFactRow(
        label: "User / System",
        value: "\(TelemetryFormatting.percent(cpu.userPercent)) / \(TelemetryFormatting.percent(cpu.systemPercent))")
      HeliosFactRow(label: "Idle", value: TelemetryFormatting.percent(cpu.idlePercent, decimals: 1))
    case .failure(let error):
      HeliosFactRow(label: "CPU", value: HeliosText.failure(error))
    }
    if case .success(let system) = p.system {
      let loads = [system.loadAverage1, system.loadAverage5, system.loadAverage15]
        .map { HeliosText.value($0) { String(format: "%.2f", $0) } }
      HeliosFactRow(label: "Load average", value: loads.joined(separator: " · "))
    }
    if case .success(let cpu) = p.cpu {
      HeliosFactRow(label: "Cores", value: Self.coresText(cpu))
    }
    HeliosFactRow(label: "Temperature", value: Self.temperatureText(p.thermals))
    HeliosSystemPowerRow(context: context, presentation: p)
  }
}

extension HeliosCPUPage {
  /// "10 (4 performance + 6 efficiency)", or nil when the split is unknown.
  static func coreSplitText(_ cpu: CPUMetrics) -> String? {
    guard case .success(let performance) = cpu.performanceCoreCount,
      case .success(let efficiency) = cpu.efficiencyCoreCount
    else { return nil }
    return "\(performance + efficiency) (\(performance) performance + \(efficiency) efficiency)"
  }

  /// The split, or the plain core count when the split is unknown.
  static func coresText(_ cpu: CPUMetrics) -> String {
    coreSplitText(cpu) ?? HeliosText.value(cpu.physicalCoreCount) { "\($0)" }
  }

  /// "49°C average · 56°C hottest" from the identified P- and E-core sensors.
  static func temperatureText(_ thermals: MetricResult<ThermalMetrics>) -> String {
    guard case .success(let metrics) = thermals,
      case .success(let average) = metrics.averageCPUCelsius
    else { return "—" }
    let hottest = (try? metrics.maximumSoCCelsius.get()).map { " · \(TelemetryFormatting.temperature($0)) hottest" } ?? ""
    return "\(TelemetryFormatting.temperature(average)) average\(hottest)"
  }
}

struct HeliosGPUPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel

  var body: some View {
    let presentation = model.presentation
    let range = context.preferences.graphRange(for: .gpu)
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      if !context.preferences.isTelemetryCollectionRequired(.gpu) {
        HeliosCollectionOffNotice(
          title: "GPU monitoring is off.", module: .gpu, preferences: context.preferences)
      } else {
        HeliosComponentHeader(
          explanation: Self.subtitle(presentation),
          value: HeliosText.value(presentation.gpu.flatMap(\.deviceUtilizationPercent)) {
            TelemetryFormatting.percent($0)
          },
          caption: "GPU usage")
        HeliosChartPanel(
          metric: .gpu, model: model, preferences: context.preferences, scope: .gpu,
          markers: context.feed.markers(for: .gpu, range: range))
        HeliosSection("Utilization") {
          HeliosGroup { utilization(presentation) }
        }
        HStack(alignment: .top, spacing: 20) {
          HeliosSection("GPU") {
            HeliosGroup { memory(presentation) }
          }
          HeliosSection("Temperature & power") {
            HeliosGroup { temperatureAndPower(presentation) }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func utilization(_ p: OverviewPresentation) -> some View {
    switch p.gpu {
    case .success(let gpu):
      VStack(alignment: .leading, spacing: 10) {
        HeliosMeterRow(label: "Device", detail: "Overall GPU activity", value: try? gpu.deviceUtilizationPercent.get())
        HeliosMeterRow(label: "Renderer", detail: "Drawing pixels and effects", value: try? gpu.rendererUtilizationPercent.get())
        HeliosMeterRow(label: "Tiler", detail: "Preparing geometry", value: try? gpu.tilerUtilizationPercent.get())
      }
      .padding(.vertical, 6)
    case .failure(let error):
      HeliosFactRow(label: "GPU", value: HeliosText.failure(error), showsDivider: false)
    }
  }

  @ViewBuilder
  private func memory(_ p: OverviewPresentation) -> some View {
    switch p.gpu {
    case .success(let gpu):
      HeliosFactRow(label: "Model", value: HeliosText.value(gpu.model) { $0 })
      HeliosFactRow(label: "Cores", value: HeliosText.value(gpu.coreCount) { "\($0)" })
      HeliosFactRow(label: "Memory in use", value: HeliosText.value(gpu.inUseSystemMemoryBytes) { TelemetryFormatting.storageBytes($0) })
      HeliosFactRow(label: "Memory allocated", value: HeliosText.value(gpu.allocatedSystemMemoryBytes) { TelemetryFormatting.storageBytes($0) },
        showsDivider: false)
    case .failure(let error):
      HeliosFactRow(label: "Memory", value: HeliosText.failure(error), showsDivider: false)
    }
  }

  @ViewBuilder
  private func temperatureAndPower(_ p: OverviewPresentation) -> some View {
    let gpuTemperatures = (try? p.thermals.get())?.readings.filter { $0.group == .gpu }.map(\.celsius) ?? []
    HeliosFactRow(
      label: "GPU temperature",
      value: gpuTemperatures.max().map { "\(TelemetryFormatting.temperature($0)) max" } ?? "—")
    HeliosSystemPowerRow(context: context, presentation: p)
  }

  static func subtitle(_ p: OverviewPresentation) -> String {
    guard case .success(let gpu) = p.gpu else { return "The graphics processor." }
    let model = (try? gpu.model.get()) ?? "GPU"
    let cores = (try? gpu.coreCount.get()).map { " · \($0)-core GPU" } ?? ""
    return "\(model)\(cores). Video, games, effects and on-device AI."
  }
}

struct HeliosMemoryPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @State private var showDetails = false

  var body: some View {
    let presentation = model.presentation
    let assessment = HeliosMacAssessment.performance(model.snapshot, now: Date())
    let range = context.preferences.graphRange(for: .memory)
    let used = HeliosText.value(presentation.memory) { TelemetryFormatting.percent($0.usagePercent) }
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      if assessment.chartMetric == .memory || assessment.reason == nil {
        HeliosAreaHeader(
          assessment: assessment, meaning: HeliosCopy.meaning(.performance),
          valueCaption: "Memory used", valueOverride: used)
      } else {
        HeliosComponentHeader(
          explanation: "Memory holds your open apps and data. macOS reports the pressure on it.",
          value: used, caption: "Memory used")
      }
      HeliosChartPanel(
        metric: .memory, model: model, preferences: context.preferences, scope: .memory,
        markers: context.feed.markers(for: .memory, range: range))
      if case .success(let memory) = presentation.memory {
        HeliosSection("Breakdown") {
          HeliosMemoryGaugeBlock(memory: memory, preferences: context.preferences)
        }
      }
      HeliosSection("Memory") {
        HeliosGroup { memoryRows(presentation) }
      }
      HeliosSection("Using the most memory") {
        HeliosMemoryLeaders(context: context, presentation: presentation)
      }
      DisclosureGroup("Details", isExpanded: $showDetails) {
        HeliosFactList(rows: HeliosPerformanceDetails.memoryRows(presentation))
          .padding(.top, 8)
      }
    }
  }

  private func swapText(_ memory: MemoryMetrics) -> String {
    let used = HeliosText.value(memory.swapUsedBytes) { TelemetryFormatting.storageBytes($0) }
    guard case .success(let total) = memory.swapTotalBytes, total > 0 else { return used }
    return "\(used) of \(TelemetryFormatting.storageBytes(total))"
  }

  @ViewBuilder
  private func memoryRows(_ p: OverviewPresentation) -> some View {
    switch p.memory {
    case .success(let memory):
      HeliosFactRow(
        label: "Pressure",
        value: HeliosText.value(memory.pressure) { $0.rawValue })
        .help(HeliosCopy.memoryPressure)
      HeliosFactRow(
        label: "Used",
        value: "\(TelemetryFormatting.gibibytes(memory.usedBytes)) of \(TelemetryFormatting.gibibytes(memory.physicalBytes))",
        detail: "Apps, system and compressed memory; cached files excluded")
      HeliosFactRow(
        label: "Swap used",
        value: swapText(memory),
        detail: "Memory moved to the SSD when RAM is full")
      HeliosFactRow(
        label: "Swap activity",
        value: "\(memory.swapIns.formatted()) in · \(memory.swapOuts.formatted()) out",
        detail: "Pages swapped since the Mac started", showsDivider: false)
    case .failure(let error):
      HeliosFactRow(label: "Memory", value: HeliosText.failure(error), showsDivider: false)
    }
  }
}

/// System power, or why it is not shown. Last row of a group.
private struct HeliosSystemPowerRow: View {
  let context: HeliosContext
  let presentation: OverviewPresentation

  var body: some View {
    if !context.preferences.isTelemetryCollectionRequired(.power) {
      HeliosFactRow(label: "System power", value: "Not collected", showsDivider: false)
    } else {
      HeliosFactRow(
        label: "System power",
        value: HeliosText.value(presentation.systemPower.flatMap(\.totalSystemWatts)) { TelemetryFormatting.watts($0) },
        showsDivider: false)
    }
  }
}

/// Apps by memory footprint, helpers folded into their app (same grouping as
/// the Memory popover).
private struct HeliosMemoryLeaders: View {
  let context: HeliosContext
  let presentation: OverviewPresentation

  var body: some View {
    if !context.preferences.isTelemetryCollectionRequired(.processes) {
      HeliosCollectionOffNotice(
        title: "Process monitoring is off.", module: .processes, preferences: context.preferences)
    } else if case .success(let processes) = presentation.processes {
      let leaders = HeliosMetricStatusPopover.memoryLeaders(processes.topByMemory, limit: 8)
      if leaders.isEmpty {
        Text("Measuring activity…").foregroundStyle(.secondary)
      } else {
        HeliosGroup {
          ForEach(Array(leaders.enumerated()), id: \.element.id) { index, leader in
            HStack(spacing: 8) {
              HeliosAppIdentityIcon(appKey: leader.id, size: 16)
              Text(leader.name).lineLimit(1)
              Spacer()
              Text(TelemetryFormatting.storageBytes(leader.bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            if index < leaders.count - 1 { Divider() }
          }
        }
      }
    } else {
      Text("Process activity is unavailable right now.").foregroundStyle(.secondary)
    }
  }
}

/// Top processes or an honest reason why they are not shown.
struct HeliosRightNowList: View {
  let context: HeliosContext
  let presentation: OverviewPresentation
  let limit: Int
  var grouped = true

  var body: some View {
    if !context.preferences.isTelemetryCollectionRequired(.processes) {
      HeliosCollectionOffNotice(
        title: "Process monitoring is off.", module: .processes, preferences: context.preferences)
    } else {
      switch presentation.processes {
      case .success(let metrics):
        let rows = HeliosProcessRow.rows(metrics.topByCPU, system: presentation.system, limit: limit)
        if rows.isEmpty {
          Text("Measuring activity…").foregroundStyle(.secondary)
        } else if grouped {
          HeliosGroup {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
              HeliosProcessRowView(row: row)
                .padding(.vertical, 6)
              if index < rows.count - 1 { Divider() }
            }
          }
          .help(HeliosCopy.processCPU)
        } else {
          VStack(spacing: 6) {
            ForEach(rows) { row in HeliosProcessRowView(row: row) }
          }
          .help(HeliosCopy.processCPU)
        }
      case .failure(.warmingUp):
        Text("Measuring activity…").foregroundStyle(.secondary)
      case .failure:
        Text("Process activity is unavailable right now.").foregroundStyle(.secondary)
      }
    }
  }
}

/// Sortable table of the processes Helios tracks (bounded leader sets).
struct HeliosProcessTable: View {
  let presentation: OverviewPresentation
  @State private var sortOrder = [KeyPathComparator(\HeliosProcessTableRow.cpuSort, order: .reverse)]

  var body: some View {
    switch presentation.processes {
    case .success(let metrics):
      let rows = HeliosProcessTableRow.rows(metrics, system: presentation.system)
        .sorted(using: sortOrder)
      VStack(alignment: .leading, spacing: 6) {
        Table(rows, sortOrder: $sortOrder) {
          TableColumn("Process", value: \.name) { row in
            HStack(spacing: 6) {
              HeliosAppIdentityIcon(appKey: row.appKey, size: 16)
              Text(row.name).lineLimit(1)
            }
          }
          .width(min: 160, ideal: 220)
          TableColumn("CPU", value: \.cpuSort) { row in
            Text(row.cpuText).monospacedDigit()
          }
          .width(min: 56, ideal: 64)
          TableColumn("Memory", value: \.memoryBytes) { row in
            Text(TelemetryFormatting.storageBytes(row.memoryBytes)).monospacedDigit()
          }
          .width(min: 70, ideal: 84)
          TableColumn("Power", value: \.powerSort) { row in
            Text(row.powerText).monospacedDigit()
          }
          .width(min: 60, ideal: 70)
          TableColumn("Wakeups/s", value: \.wakeupsSort) { row in
            Text(row.wakeupsText).monospacedDigit()
          }
          .width(min: 70, ideal: 80)
          TableColumn("PID", value: \.pid) { row in
            Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
          }
          .width(min: 50, ideal: 60)
        }
        .frame(height: 260)
        Text("Helios tracks the most active processes, not every process (\(metrics.accessibleProcessCount) readable).")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    case .failure:
      Text("Process details are unavailable right now.").foregroundStyle(.secondary)
    }
  }
}

struct HeliosProcessTableRow: Identifiable {
  let pid: Int32
  let name: String
  let appKey: String
  let cpuSort: Double
  let cpuText: String
  let memoryBytes: UInt64
  let powerSort: Double
  let powerText: String
  let wakeupsSort: Double
  let wakeupsText: String
  var id: Int32 { pid }

  static func rows(_ metrics: ProcessMetrics, system: MetricResult<SystemMetrics>) -> [Self] {
    let logical = (try? system.get().logicalProcessorCount).map { max(1, $0) }
      ?? max(1, ProcessInfo.processInfo.processorCount)
    var seen = Set<Int32>()
    var result: [Self] = []
    for process in metrics.topByCPU + metrics.topByMemory + metrics.topByEnergy
    where seen.insert(process.pid).inserted {
      // The table stays per process; only the icon comes from the owning app.
      let identity = HeliosAppIdentity.of(process)
      let share = TelemetryFormatting.processCPUSharePercent(process.cpuPercent, logicalProcessorCount: logical)
      result.append(Self(
        pid: process.pid, name: process.name, appKey: identity.key,
        cpuSort: share ?? -1, cpuText: share.map { TelemetryFormatting.percent($0, decimals: 1) } ?? "—",
        memoryBytes: process.physicalFootprintBytes,
        powerSort: process.powerWatts ?? -1,
        powerText: process.powerWatts.map { TelemetryFormatting.watts($0, decimals: 2) } ?? "—",
        wakeupsSort: process.wakeupsPerSecond ?? -1,
        wakeupsText: process.wakeupsPerSecond.map { String(format: "%.1f", $0) } ?? "—"))
    }
    return result
  }
}

/// Detail rows of the CPU and Memory pages. Pure.
enum HeliosPerformanceDetails {
  static func cpuRows(_ presentation: OverviewPresentation) -> [HeliosEvidence] {
    var rows: [HeliosEvidence] = []
    if case .success(let processes) = presentation.processes, let helios = processes.heliosActivity {
      let share = TelemetryFormatting.processCPUShareText(helios.cpuPercent,
        logicalProcessorCount: (try? presentation.system.get().logicalProcessorCount) ?? ProcessInfo.processInfo.processorCount)
      rows.append(HeliosEvidence(label: "Helios itself",
        value: "\(share) CPU · \(TelemetryFormatting.storageBytes(helios.physicalFootprintBytes))",
        source: helios.wakeupsPerSecond.map { String(format: "%.1f wakeups/s", $0) }))
    }
    return rows
  }

  static func memoryRows(_ presentation: OverviewPresentation) -> [HeliosEvidence] {
    guard case .success(let memory) = presentation.memory else { return [] }
    return [
      HeliosEvidence(label: "App memory", value: TelemetryFormatting.gibibytes(memory.appBytes)),
      HeliosEvidence(label: "Wired", value: TelemetryFormatting.gibibytes(memory.wiredBytes)),
      HeliosEvidence(label: "Compressed", value: TelemetryFormatting.gibibytes(memory.compressedBytes)),
      HeliosEvidence(label: "Cached files", value: TelemetryFormatting.gibibytes(memory.cacheBytes)),
      HeliosEvidence(label: "Swap ins / outs", value: "\(memory.swapIns) / \(memory.swapOuts)"),
    ]
  }
}

/// Per-core usage grouped by cluster, like Stats: efficiency cores first (they
/// are the lower-numbered CPUs on Apple Silicon, verified on Mac16,1), then
/// performance cores, each with its average and a labelled bar per core.
struct HeliosCoreClusters: View {
  let cpu: CPUMetrics

  fileprivate static func clusters(_ cpu: CPUMetrics) -> [(title: String, prefix: String, values: [Double], color: Color)] {
    let values = cpu.perCoreUsagePercent
    if let e = try? cpu.efficiencyCoreCount.get(), let p = try? cpu.performanceCoreCount.get(),
      e + p == values.count, e > 0, p > 0
    {
      return [("Efficiency cores", "E", Array(values.prefix(e)), Color.teal),
              ("Performance cores", "P", Array(values.suffix(p)), Color.accentColor)]
    }
    return [("Cores", "", values, Color.accentColor)]
  }

  var body: some View {
    HStack(alignment: .top, spacing: 28) {
      ForEach(Array(Self.clusters(cpu).enumerated()), id: \.offset) { _, cluster in
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            Text(cluster.title).font(.subheadline.weight(.medium))
            Text("avg \(TelemetryFormatting.percent(cluster.values.reduce(0, +) / Double(max(1, cluster.values.count))))")
              .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
          }
          HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(cluster.values.enumerated()), id: \.offset) { index, value in
              HeliosCoreBar(value: value, label: "\(cluster.prefix)\(index + 1)", color: cluster.color)
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
  }
}

private struct HeliosCoreBar: View {
  let value: Double
  let label: String
  let color: Color

  var body: some View {
    let clamped = min(100, max(0, value.isFinite ? value : 0))
    VStack(spacing: 4) {
      Text("\(Int(clamped.rounded()))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
        RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.85))
          .frame(height: max(2, 64 * clamped / 100))
      }
      .frame(width: 18, height: 64)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Core \(label)")
    .accessibilityValue(TelemetryFormatting.percent(clamped))
  }
}

/// The same clusters in a form that fits a popover: one row per cluster, one thin
/// bar per core, the average at the end.
struct HeliosCoreStrips: View {
  let cpu: CPUMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(HeliosCoreClusters.clusters(cpu).enumerated()), id: \.offset) { _, cluster in
        HStack(spacing: 10) {
          Text(cluster.title.replacingOccurrences(of: " cores", with: ""))
            .font(.subheadline).frame(width: 84, alignment: .leading)
          HStack(spacing: 3) {
            ForEach(Array(cluster.values.enumerated()), id: \.offset) { _, value in
              ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(cluster.color)
                  .frame(height: 22 * CGFloat(min(1, max(0.06, value / 100))))
              }
              .frame(width: 10, height: 22)
            }
          }
          Spacer(minLength: 4)
          Text(TelemetryFormatting.percent(cluster.values.reduce(0, +) / Double(max(1, cluster.values.count))))
            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.vertical, 6)
  }
}

/// A labelled horizontal meter (0–100 %) with its value.
struct HeliosMeterRow: View {
  let label: String
  var detail: String? = nil
  let value: Double?

  var body: some View {
    let clamped = value.map { min(100, max(0, $0.isFinite ? $0 : 0)) }
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(label)
        if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
      .frame(width: 170, alignment: .leading)
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.secondary.opacity(0.15))
          Capsule().fill(Color.accentColor.opacity(0.85))
            .frame(width: max(0, geometry.size.width * CGFloat((clamped ?? 0) / 100)))
        }
      }
      .frame(height: 8)
      Text(clamped.map { TelemetryFormatting.percent($0) } ?? "—")
        .monospacedDigit().frame(width: 48, alignment: .trailing)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Short text for typed results. Never substitutes zero for a failure.
enum HeliosText {
  static func value<V>(_ result: MetricResult<V>, format: (V) -> String) -> String {
    switch result {
    case .success(let value): format(value)
    case .failure(let error): failure(error)
    }
  }

  /// NVMe 128-bit counters: exact when they fit, otherwise an explicit approximation.
  static func counter(_ value: NVMeCounter128) -> String {
    if let exact = value.uint64Value { return TelemetryFormatting.count(exact) }
    return "≈ " + String(format: "%.3g", value.approximateValue)
  }

  static func failure(_ error: TelemetryError) -> String {
    error == .warmingUp ? "Measuring…" : "Unavailable"
  }
}
