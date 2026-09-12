import AppKit
import SwiftUI

struct HeliosPopoverView: View {
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var service: DaemonService
  @ObservedObject var preferences: HeliosPreferences
  let openMonitor: () -> Void
  let openCooling: () -> Void
  let openSettings: () -> Void
  var openRoute: (HeliosMonitorRoute) -> Void = { _ in }
  @State private var editingDashboard = false

  private var presentation: OverviewPresentation { OverviewPresentation(model.snapshot) }

  /// The 420×600 popover is a glance surface, not the 24-hour history viewer.
  /// Bound its tiny sparklines to the most recent two minutes so opening Helios
  /// never asks SwiftUI to spline thousands of historical points every second.
  private var dashboardHistoryTail: ArraySlice<TelemetryHistoryPoint> {
    model.history.points.suffix(120)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(spacing: preferences.compactCards ? 8 : 10) {
          if editingDashboard {
            dashboardEditToolbar
          }
          ForEach(visiblePopoverModules) { module in
            VStack(spacing: 5) {
              if editingDashboard {
                dashboardModuleEditBar(module)
              }
              moduleView(module)
            }
          }
          if visiblePopoverModules.isEmpty {
            emptyDashboard
          }
          dashboardCustomizationFooter
        }
        .padding(14)
      }
    }
    .frame(width: 420, height: 600)
    .background(.regularMaterial)
  }

  private var header: some View {
    HStack(spacing: 10) {
      HeliosBrandMark(size: 27)
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text("Helios").font(.system(size: 15, weight: .semibold))
        Text(systemSubtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      if preferences.coolingFeaturesEnabled {
        connectionBadge
      }
      if !model.healthCenter.issues.isEmpty {
        Button {
          openRoute(.health)
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "exclamationmark.shield.fill")
            Text(String(model.healthCenter.issues.count))
              .font(.system(size: 8.5, weight: .bold).monospacedDigit())
          }
          .foregroundStyle(
            model.healthCenter.issues.contains(where: { $0.severity == .critical })
              ? Color.red : Color.orange)
        }
        .buttonStyle(.borderless)
        .help("Open active health alerts")
      }
      Button {
        openRoute(.energy)
      } label: {
        Image(systemName: "chart.bar.xaxis")
          .font(.system(size: 11, weight: .medium))
      }
      .buttonStyle(.borderless)
      .help("Open Energy")
      Button(action: openMonitor) {
        Label("Full Monitor", systemImage: "macwindow")
          .font(.system(size: 10, weight: .medium))
      }
      .buttonStyle(.borderless)
      .help("Open Full Monitor")
      Menu {
        Button(action: openSettings) {
          Label("Settings…", systemImage: "gearshape")
        }
        Divider()
        Button {
          NSApplication.shared.terminate(nil)
        } label: {
          Label("Quit Helios", systemImage: "power")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("More Helios actions")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  private var connectionBadge: some View {
    HStack(spacing: 5) {
      Circle().fill(connectionColor).frame(width: 6, height: 6)
      Text(connectionLabel)
        .font(.system(size: 10, weight: .medium))
    }
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(Color.primary.opacity(0.06), in: Capsule())
    .help(service.client.detail ?? service.client.state.rawValue)
  }

  private var connectionLabel: String {
    switch service.client.state {
    case .connected: "Connected"
    case .connecting: "Connecting"
    case .disconnected: "Disconnected"
    case .signingRequired: "Setup needed"
    case .versionMismatch: "Reinstall"
    case .failed: "Unavailable"
    }
  }

  private var connectionColor: Color {
    switch service.client.state {
    case .connected: .green
    case .connecting: .yellow
    case .disconnected: .secondary
    case .signingRequired, .versionMismatch: .orange
    case .failed: .red
    }
  }

  @ViewBuilder
  private func moduleView(_ module: HeliosPopoverModule) -> some View {
    switch module {
    case .summary:
      summaryGrid
    case .cooling:
      coolingCard
    case .performance:
      performanceCard
    case .network:
      networkCard
    case .topCPU:
      topCPUCard
    case .system:
      systemCard
    case .energy:
      energyCard
    case .alerts:
      alertsCard
    }
  }

  private var summaryGrid: some View {
    Group {
      if preferences.dashboardMetricsForPresentation.isEmpty {
        HeliosPanel(title: "System summary", symbol: "square.grid.2x2") {
          Text(
            "No summary metrics are visible. Add only the metrics you want in Settings → Modules → Popups."
          )
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        LazyVGrid(
          columns: [GridItem(.flexible()), GridItem(.flexible())],
          spacing: preferences.compactCards ? 8 : 10
        ) {
          ForEach(preferences.dashboardMetricsForPresentation) { metric in
            summaryMetricTile(metric)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func summaryMetricTile(_ metric: HeliosDashboardMetric) -> some View {
    switch metric {
    case .cpu:
      dashboardTile(
        metric: .cpu, route: .cpu, title: "CPU", symbol: "cpu",
        value: metricValue(presentation.cpu.map(\.usagePercent), { String(format: "%.0f%%", $0) }),
        trend: dashboardHistoryTail.map(\.cpuPercent), fixedRange: 0...100,
        tint: preferences.color(for: .cpu))
    case .memory:
      dashboardTile(
        metric: .memory, route: .memory, title: "Memory", symbol: "memorychip",
        value: metricValue(
          presentation.memory.map(\.usagePercent), { String(format: "%.0f%%", $0) }),
        trend: dashboardHistoryTail.map(\.memoryPercent), fixedRange: 0...100,
        tint: preferences.color(for: .memory))
    case .gpu:
      dashboardTile(
        metric: .gpu, route: .gpu, title: "GPU", symbol: "display",
        value: metricValue(
          presentation.gpu.flatMap(\.deviceUtilizationPercent), { String(format: "%.0f%%", $0) }),
        trend: dashboardHistoryTail.map(\.gpuPercent), fixedRange: 0...100,
        tint: preferences.color(for: .gpu))
    case .temperature:
      dashboardTile(
        metric: .temperature, route: .thermals, title: "Temperature", symbol: "thermometer.medium",
        value: metricValue(
          presentation.thermals.flatMap(\.maximumSoCCelsius), { String(format: "%.0f°C", $0) }),
        trend: dashboardHistoryTail.map(\.maxSoCCelsius), fixedRange: 20...100,
        tint: preferences.color(for: .temperature))
    case .battery:
      dashboardTile(
        metric: .battery, route: .battery, title: "Battery", symbol: "battery.75percent",
        value: metricValue(
          presentation.battery.flatMap(\.stateOfChargePercent), { String(format: "%.0f%%", $0) }),
        trend: dashboardHistoryTail.map(\.batteryPercent), fixedRange: 0...100,
        tint: preferences.color(for: .battery))
    case .energy:
      dashboardTile(
        metric: .energy, route: .energy, title: "Energy", symbol: "chart.bar.xaxis",
        value: dashboardBatteryDeltaPercent.map { String(format: "%+.0f%%", $0) } ?? "History",
        trend: dashboardHistoryTail.map(\.batteryPercent), fixedRange: 0...100,
        tint: preferences.color(for: .energy))
    case .power:
      dashboardTile(
        metric: .power, route: .energy, title: "Power", symbol: "bolt.fill",
        value: metricValue(
          presentation.systemPower.flatMap(\.totalSystemWatts), { String(format: "%.1f W", $0) }),
        trend: dashboardHistoryTail.map(\.systemPowerWatts), fixedRange: nil,
        tint: preferences.color(for: .power))
    }
  }

  @ViewBuilder
  private func dashboardTile(
    metric: HeliosDashboardMetric, route: HeliosMonitorRoute, title: String, symbol: String,
    value: String, trend: [Double?], fixedRange: ClosedRange<Double>?, tint: Color
  ) -> some View {
    if editingDashboard {
      HeliosMetricTile(
        title: title, symbol: symbol, value: value, trend: trend, fixedRange: fixedRange,
        tint: tint, showsDisclosure: false
      )
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 3) {
          dashboardMetricMoveButton(metric, offset: -1, symbol: "chevron.left")
          dashboardMetricMoveButton(metric, offset: 1, symbol: "chevron.right")
          Button {
            preferences.setDashboardMetricEnabled(metric, enabled: false)
          } label: {
            Image(systemName: "xmark")
          }
          .help("Hide \(title)")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(4)
      }
    } else {
      Button {
        openRoute(route)
      } label: {
        HeliosMetricTile(
          title: title, symbol: symbol, value: value, trend: trend, fixedRange: fixedRange,
          tint: tint, showsDisclosure: true)
      }
      .buttonStyle(.plain)
      .help("Open \(title) details")
    }
  }

  private var visiblePopoverModules: [HeliosPopoverModule] {
    preferences.popoverModulesForPresentation
  }

  private var dashboardEditToolbar: some View {
    HStack(spacing: 8) {
      Label("Edit Dashboard", systemImage: "slider.horizontal.3")
        .font(.system(size: 11, weight: .semibold))
      Spacer()
      let available = HeliosPopoverModule.allCases.filter {
        !preferences.isPopoverModuleEnabled($0)
          && (preferences.isTelemetryEnabled(.fans) || $0 != .cooling)
      }
      if !available.isEmpty {
        Menu("Add module") {
          ForEach(available) { module in
            Button {
              preferences.setPopoverModuleEnabled(module, enabled: true)
            } label: {
              Label(module.label, systemImage: module.symbolName)
            }
          }
        }
        .controlSize(.small)
      }
    }
    .padding(9)
    .background(
      Color.accentColor.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var dashboardCustomizationFooter: some View {
    HStack {
      Spacer(minLength: 0)
      Button {
        withAnimation(.easeInOut(duration: 0.16)) { editingDashboard.toggle() }
      } label: {
        Label(
          editingDashboard ? "Done Customizing" : "Customize Dashboard",
          systemImage: editingDashboard ? "checkmark.circle" : "slider.horizontal.3"
        )
        .font(.system(size: 10.5, weight: .medium))
      }
      .buttonStyle(.borderless)
      .help(editingDashboard ? "Finish dashboard editing" : "Customize this dashboard")
      Spacer(minLength: 0)
    }
    .padding(.top, 3)
    .padding(.bottom, 1)
  }

  private func dashboardModuleEditBar(_ module: HeliosPopoverModule) -> some View {
    HStack(spacing: 7) {
      Label(module.label, systemImage: module.symbolName)
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        preferences.movePopoverModule(module, offset: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(preferences.popoverModules.first == module)
      .help("Move module up")
      Button {
        preferences.movePopoverModule(module, offset: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(preferences.popoverModules.last == module)
      .help("Move module down")
      Button {
        preferences.setPopoverModuleEnabled(module, enabled: false)
      } label: {
        Image(systemName: "xmark")
      }
      .help("Hide \(module.label)")
    }
    .buttonStyle(.borderless)
    .controlSize(.mini)
    .padding(.horizontal, 5)
  }

  private func dashboardMetricMoveButton(
    _ metric: HeliosDashboardMetric, offset: Int, symbol: String
  ) -> some View {
    Button {
      preferences.moveDashboardMetric(metric, offset: offset)
    } label: {
      Image(systemName: symbol)
    }
    .disabled(
      offset < 0
        ? preferences.dashboardMetrics.first == metric
        : preferences.dashboardMetrics.last == metric
    )
    .help(offset < 0 ? "Move earlier" : "Move later")
  }

  private var coolingCard: some View {
    HeliosPanel(title: "Temperature & Fan", symbol: "thermometer.medium", trailing: fanSummary) {
      HStack(spacing: 12) {
        compactMetric(
          "Temperature",
          metricValue(
            presentation.thermals.flatMap(\.maximumSoCCelsius),
            { String(format: "%.0f°C", $0) }))
        compactMetric("Fan", fanSummary)
      }
      if preferences.coolingFeaturesEnabled {
        HeliosCoolingQuickControl(
          model: service.fanControl, preferences: preferences, openCooling: openCooling)
      } else {
        HStack(alignment: .center, spacing: 8) {
          Label("Read-only fan telemetry", systemImage: "eye")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
          Spacer(minLength: 6)
          Button("Open details…", action: openCooling)
            .buttonStyle(.link)
            .font(.system(size: 9.5, weight: .medium))
        }
        Text(
          "Fan-control writes are disabled. Enable Cooling in Settings only if you want System / Boost / Manual / Auto controls."
        )
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var performanceCard: some View {
    HeliosPanel(title: "Performance", symbol: "gauge.with.dots.needle.50percent") {
      HStack(spacing: 12) {
        compactMetric(
          "GPU",
          metricValue(
            presentation.gpu.flatMap(\.deviceUtilizationPercent), { String(format: "%.0f%%", $0) }))
        compactMetric(
          "Power",
          metricValue(
            presentation.systemPower.flatMap(\.totalSystemWatts), { String(format: "%.1f W", $0) }))
        compactMetric(
          "Pressure", metricValue(presentation.memory.flatMap(\.pressure), { $0.rawValue }))
      }
      HStack(spacing: 8) {
        HeliosMiniChart(
          values: dashboardHistoryTail.map(\.gpuPercent), fixedRange: 0...100,
          tint: preferences.color(for: .gpu))
        HeliosMiniChart(
          values: dashboardHistoryTail.map(\.systemPowerWatts), fixedRange: nil,
          tint: preferences.color(for: .power))
      }
      .frame(height: 30)
      .accessibilityHidden(true)
    }
  }

  private var networkCard: some View {
    HeliosPanel(title: "Network", symbol: "network") {
      if case .success(let network) = presentation.network,
        case .success(let throughput) = network.throughput
      {
        HStack {
          Label(
            TelemetryFormatting.bytesPerSecond(throughput.downloadBytesPerSecond),
            systemImage: "arrow.down")
          Spacer()
          Label(
            TelemetryFormatting.bytesPerSecond(throughput.uploadBytesPerSecond),
            systemImage: "arrow.up")
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        HStack(spacing: 8) {
          HeliosMiniChart(
            values: dashboardHistoryTail.map(\.networkDownloadBytesPerSecond), fixedRange: nil,
            tint: preferences.color(for: .networkDownload))
          HeliosMiniChart(
            values: dashboardHistoryTail.map(\.networkUploadBytesPerSecond), fixedRange: nil,
            tint: preferences.color(for: .networkUpload))
        }
        .frame(height: 30)
      } else {
        unavailable("Network throughput is warming up or unavailable.")
      }
    }
  }

  @ViewBuilder private var topCPUCard: some View {
    if case .success(let processes) = presentation.processes {
      HeliosPanel(title: "Top CPU", symbol: "list.bullet.rectangle") {
        ForEach(processes.topByCPU.prefix(4)) { process in
          HStack {
            Text(process.name).lineLimit(1)
            Spacer()
            Text(TelemetryFormatting.processCPUShareText(process.cpuPercent))
              .monospacedDigit().foregroundStyle(.secondary)
          }.font(.system(size: 11))
        }
      }
    }
  }

  private var energyCard: some View {
    HeliosPanel(title: "Energy", symbol: "chart.bar.xaxis") {
      let summary = dashboardEnergySummary
      if let delta = dashboardBatteryDeltaPercent {
        detailLine("Battery change", String(format: "%+.0f%%", delta))
      } else {
        detailLine("Battery change", "Collecting")
      }
      if let leader = summary.topOnBattery.first {
        let total = max(0.000_001, summary.topOnBattery.reduce(0) { $0 + $1.energyWattHours })
        let share = min(1, max(0, leader.energyWattHours / total))
        HStack(spacing: 8) {
          HeliosAppIdentityIcon(appKey: leader.appKey, size: 20)
          Text(leader.displayName).lineLimit(1)
          Spacer()
          Text(String(format: "%.0f%%", share * 100))
            .monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.system(size: 10.5))
        ProgressView(value: share, total: 1)
          .tint(preferences.color(for: .energy))
          .controlSize(.mini)
      } else {
        Text("Use the Mac on battery to build per-app energy history.")
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Button {
        openRoute(.energy)
      } label: {
        Label("Open Energy", systemImage: "arrow.up.right")
      }
      .buttonStyle(.borderless)
      .font(.system(size: 10.5, weight: .medium))
    }
  }

  private var alertsCard: some View {
    let issues = model.healthCenter.issues
    return HeliosPanel(
      title: "Health & Alerts", symbol: "exclamationmark.shield",
      trailing: issues.isEmpty ? "Clear" : "\(issues.count) active"
    ) {
      if issues.isEmpty {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          Text("No active health alerts")
            .font(.system(size: 10.5, weight: .medium))
          Spacer()
        }
      } else {
        ForEach(issues.prefix(3)) { issue in
          HStack(alignment: .top, spacing: 7) {
            Image(
              systemName: issue.severity == .critical
                ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(issue.severity == .critical ? Color.red : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
              Text(issue.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
              Text(issue.detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
          }
        }
      }
      Button {
        openRoute(.health)
      } label: {
        Label("Open Health & Alerts", systemImage: "arrow.up.right")
      }
      .buttonStyle(.borderless)
      .font(.system(size: 10.5, weight: .medium))
    }
  }

  private var dashboardEnergySummary: AppEnergySummary {
    guard let anchor = model.appEnergy.buckets.last?.capturedAt else { return .empty }
    let cutoff = anchor.addingTimeInterval(-6 * 60 * 60)
    return AppEnergyHistoryEngine.summary(
      model.appEnergy.buckets.filter { $0.capturedAt >= cutoff && $0.capturedAt <= anchor })
  }

  private var dashboardBatteryDeltaPercent: Double? {
    let values = dashboardEnergySummary.buckets.compactMap { bucket -> Double? in
      guard bucket.onBattery == true, let value = bucket.batteryPercent, value.isFinite else {
        return nil
      }
      return value
    }
    guard let first = values.first, let last = values.last, values.count >= 2 else { return nil }
    return last - first
  }

  private var systemCard: some View {
    HeliosPanel(title: "System", symbol: "desktopcomputer") {
      detailLine(
        "Thermal state", metricValue(presentation.system.map(\.thermalState), { $0.rawValue }))
      detailLine(
        "Low Power Mode",
        metricValue(presentation.system.map(\.lowPowerModeEnabled), { $0 ? "On" : "Off" }))
      detailLine("Storage", storageSummary)
      detailLine("Sleep blockers", blockersSummary)
    }
  }

  private var emptyDashboard: some View {
    VStack(spacing: 10) {
      Image(systemName: "square.grid.2x2")
        .font(.system(size: 28))
        .foregroundStyle(.secondary)
      Text("Your dashboard is empty").font(.system(size: 13, weight: .semibold))
      Text("Use Customize Dashboard below to add only the modules that matter to you.")
        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 50)
  }

  private var fanSummary: String {
    guard case .success(let inventory) = presentationSnapshotFans else { return "—" }
    guard let fan = inventory.fans.first else { return "Fanless" }
    guard let rpm = try? fan.actualRPM.get() else { return "—" }
    return rpm < 50 ? "Fan off" : String(format: "%.0f RPM", rpm)
  }

  private var presentationSnapshotFans: MetricResult<FanInventory> {
    TelemetryFormatting.fresh(model.snapshot.fans, maxAge: 6)
  }

  private var systemSubtitle: String {
    guard case .success(let system) = presentation.system else { return "System monitor" }
    return (try? system.chipName.get()) ?? "Mac"
  }

  private var storageSummary: String {
    guard case .success(let storage) = presentation.storage,
      case .success(let root) = storage.rootVolume
    else { return "—" }
    return "\(TelemetryFormatting.storageBytes(root.usedBytes)) used"
  }

  private var blockersSummary: String {
    guard case .success(let blockers) = presentation.powerAssertions else { return "—" }
    return "\(blockers.systemSleepBlockers.count) system"
  }

  private func compactMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).lineLimit(1)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func detailLine(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }
    .font(.system(size: 11))
  }

  private func unavailable(_ text: String) -> some View {
    Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(
      horizontal: false, vertical: true)
  }

  private func metricValue<Value>(_ result: MetricResult<Value>, _ formatter: (Value) -> String)
    -> String
  {
    DisplayValue(result, format: formatter).text
  }
}

struct HeliosFanSafetyNotice: View {
  var compact: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: compact ? 9 : 10, weight: .semibold))
        .foregroundStyle(.orange)
        .padding(.top, 1)
      Text(
        "System control is recommended. Manual, Boost and Automatic Rules override macOS fan targets. Helios clamps targets to the validated factory range, and the privileged helper enforces a 95°C maximum-cooling guard from fresh trusted thermal telemetry. Custom cooling choices remain the user's responsibility."
      )
      .font(.system(size: compact ? 9 : 10))
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct HeliosCoolingQuickControl: View {
  @ObservedObject var model: FanControlModel
  @ObservedObject var preferences: HeliosPreferences
  let openCooling: () -> Void
  @State private var expanded = false
  @State private var showingSafetyGuide = false

  var body: some View {
    if isFanless {
      HStack(alignment: .top, spacing: 9) {
        Image(systemName: "wind")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Fanless Mac").font(.system(size: 11, weight: .semibold))
          Text(
            "Helios monitors temperature and macOS thermal pressure. Fan controls stay hidden because this Mac has no fan hardware."
          )
          .font(.system(size: 9.5)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(modeTitle).font(.system(size: 11, weight: .semibold))
              if model.selection == .system {
                Text("Recommended")
                  .font(.system(size: 8.5, weight: .semibold))
                  .foregroundStyle(.green)
                  .padding(.horizontal, 5).padding(.vertical, 2)
                  .background(Color.green.opacity(0.10), in: Capsule())
              }
            }
            Text(modeDetail)
              .font(.system(size: 9.5))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Button {
            if !expanded, !preferences.fanSafetyGuideCompleted {
              showingSafetyGuide = true
            } else {
              withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            }
          } label: {
            HStack(spacing: 5) {
              Text(expanded ? "Done" : "Change")
              Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .medium))
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(expanded ? "Hide cooling options" : "Change cooling mode")
        }

        if expanded {
          Divider().opacity(0.5)
          VStack(spacing: 4) {
            modeOption(
              .system, title: "System",
              detail: "Let macOS manage the fan. Recommended for normal use.",
              symbol: "checkmark.shield")
            modeOption(
              .boost, title: "Boost", detail: "Run the fan at the validated factory maximum.",
              symbol: "wind")
            modeOption(
              .override, title: "Manual",
              detail: "Choose a fixed target inside the validated factory fan range.",
              symbol: "slider.horizontal.3")
            modeOption(
              .auto, title: "Automatic Rules",
              detail: "Use your temperature and power-source rules.",
              symbol: "point.3.connected.trianglepath.dotted")
          }
          HeliosFanSafetyNotice(compact: true)
        }

        if model.selection == .override, let bounds = model.sliderBounds {
          Divider().opacity(0.5)
          HStack(spacing: 8) {
            Slider(
              value: Binding(get: { model.targetRPM }, set: { model.targetRPM = $0 }), in: bounds,
              step: 50
            )
            .accessibilityLabel("Manual fan target")
            Text(manualValue(bounds))
              .font(.system(size: 10, weight: .semibold).monospacedDigit())
              .frame(width: 96, alignment: .trailing)
          }
          Text("Manual targets are clamped to this fan's validated hardware range.")
            .font(.system(size: 9)).foregroundStyle(.secondary)
        } else if model.selection == .auto {
          Divider().opacity(0.5)
          HStack(alignment: .top, spacing: 8) {
            Text(
              model.autoDetail.isEmpty
                ? "Rules use fresh telemetry and return control to macOS whenever no rule matches."
                : model.autoDetail
            )
            .font(.system(size: 9.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Edit Rules…", action: openCooling)
              .buttonStyle(.link)
              .font(.system(size: 9.5, weight: .medium))
          }
        } else if model.selection == .boost {
          Text(
            "Boost holds the fan at its validated factory maximum until you return to System or Helios safely releases control."
          )
          .font(.system(size: 9)).foregroundStyle(.secondary)
        }
      }
      .alert("Before changing fan control", isPresented: $showingSafetyGuide) {
        Button("Stay on System", role: .cancel) {}
        Button("I Understand") {
          preferences.completeFanSafetyGuide()
          withAnimation(.easeInOut(duration: 0.16)) { expanded = true }
        }
      } message: {
        Text(
          "System control is recommended. Boost, Manual and Automatic Rules override macOS fan targets. Helios clamps targets to the validated factory fan range, and the privileged helper enforces a 95°C maximum-cooling guard using fresh trusted thermal telemetry. Custom Manual and Automatic Rules remain your responsibility. If you are unsure, stay on System."
        )
      }
    }
  }

  private var isFanless: Bool {
    guard case .success(let inventory) = model.inventory.result else { return false }
    return inventory.fans.isEmpty
  }

  private var modeTitle: String {
    switch model.selection {
    case .system: "System control"
    case .boost: "Maximum cooling"
    case .override: "Manual cooling"
    case .auto: "Automatic cooling"
    }
  }

  private var modeDetail: String {
    switch model.selection {
    case .system: "macOS decides when the fan starts and how fast it runs."
    case .boost: "Helios is holding the fan at its validated factory maximum."
    case .override: "Helios is holding the target speed you selected below."
    case .auto: "Helios takes control only while one of your cooling rules matches."
    }
  }

  @ViewBuilder
  private func modeOption(
    _ selection: FanControlSelection, title: String, detail: String, symbol: String
  ) -> some View {
    let enabled = modeEnabled(selection)
    Button {
      guard enabled else { return }
      model.setMode(selection)
      if selection == .system || selection == .boost {
        withAnimation(.easeInOut(duration: 0.16)) { expanded = false }
      }
    } label: {
      HStack(spacing: 9) {
        Image(systemName: symbol)
          .font(.system(size: 11, weight: .medium))
          .frame(width: 17)
          .foregroundStyle(selection == model.selection ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 10.5, weight: .semibold))
          Text(detail).font(.system(size: 8.8)).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer(minLength: 6)
        if selection == model.selection {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .background(
        selection == model.selection
          ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }

  private func modeEnabled(_ selection: FanControlSelection) -> Bool {
    switch selection {
    case .system: true
    case .boost: model.canSelectBoost
    case .override: model.canSelectOverride
    case .auto: model.canSelectAuto
    }
  }

  private func manualValue(_ bounds: ClosedRange<Double>) -> String {
    guard model.targetRPM.isFinite, bounds.upperBound > bounds.lowerBound else { return "— RPM" }
    return String(format: "%.0f RPM", model.targetRPM)
  }
}

struct HeliosMetricTile: View {
  let title: String
  let symbol: String
  let value: String
  var trend: [Double?] = []
  var fixedRange: ClosedRange<Double>? = nil
  let tint: Color
  var showsDisclosure: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 16, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(tint)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
          Text(value).font(.system(size: 19, weight: .semibold).monospacedDigit()).lineLimit(1)
        }
        Spacer(minLength: 0)
        if showsDisclosure {
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
      }
      if trend.compactMap({ $0 }).count > 1 {
        HeliosMiniChart(values: trend, fixedRange: fixedRange, tint: tint)
          .frame(height: 24)
      }
    }
    .padding(11)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.58),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

struct HeliosPanel<Content: View>: View {
  let title: String
  let symbol: String
  var trailing: String? = nil
  @ViewBuilder let content: Content

  init(title: String, symbol: String, trailing: String? = nil, @ViewBuilder content: () -> Content)
  {
    self.title = title
    self.symbol = symbol
    self.trailing = trailing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
        Spacer()
        if let trailing {
          Text(trailing).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(
            .secondary)
        }
      }
      content
    }
    .padding(12)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
        Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 0.5))
  }
}

/// Lightweight native SwiftUI sparkline used throughout the Next23 interface.
/// Missing/stale samples deliberately break the line rather than inventing data.
struct HeliosMiniChart: View {
  let values: [Double?]
  let fixedRange: ClosedRange<Double>?
  var tint: Color = .secondary
  var showsFrontierPoint: Bool = false

  var body: some View {
    GeometryReader { geometry in
      let valid = values.compactMap { value -> Double? in
        guard let value, value.isFinite else { return nil }
        return value
      }
      let derivedMin = valid.min() ?? 0
      let derivedMax = valid.max() ?? 1
      let padding = max(0.5, (derivedMax - derivedMin) * 0.08)
      let dynamicMin = derivedMin - padding
      let dynamicMax = max(dynamicMin + 1, derivedMax + padding)
      let range = fixedRange ?? (dynamicMin...dynamicMax)
      let lastValid = values.enumerated().reversed().first { _, value in
        guard let value else { return false }
        return value.isFinite
      }
      let lastPoint: CGPoint? = lastValid.flatMap { index, raw in
        guard let raw, values.count > 1, range.upperBound > range.lowerBound else { return nil }
        let value = min(range.upperBound, max(range.lowerBound, raw))
        let x = geometry.size.width * CGFloat(index) / CGFloat(max(1, values.count - 1))
        let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        let y = geometry.size.height * CGFloat(1 - normalized)
        return CGPoint(x: x, y: y)
      }

      ZStack {
        ForEach([CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)], id: \.self) { fraction in
          Path { path in
            let y = geometry.size.height * fraction
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
          }
          .stroke(Color.secondary.opacity(0.07), lineWidth: 0.5)
        }

        if range.lowerBound < 0, range.upperBound > 0 {
          Path { path in
            let normalized = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
            let y = geometry.size.height * CGFloat(1 - normalized)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
          }
          .stroke(Color.secondary.opacity(0.14), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
        }

        smoothPath(in: geometry.size, range: range)
          .stroke(
            tint.opacity(0.88),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
          )

        if showsFrontierPoint, let lastPoint {
          Circle()
            .fill(tint.opacity(0.95))
            .frame(width: 4, height: 4)
            .position(lastPoint)
        }
      }
    }
    .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
    .accessibilityHidden(true)
  }

  /// Draws exact telemetry samples with a monotone cubic spline. This rounds
  /// the visual path without inventing intermediate extrema or bridging stale
  /// gaps. Every original sample remains on the curve.
  private func smoothPath(in size: CGSize, range: ClosedRange<Double>) -> Path {
    var result = Path()
    guard values.count > 1, range.upperBound > range.lowerBound else { return result }

    for segment in pointSegments(in: size, range: range) {
      guard let first = segment.first else { continue }
      result.move(to: first)
      guard segment.count > 1 else { continue }
      if segment.count == 2 {
        result.addLine(to: segment[1])
        continue
      }

      let slopes = monotoneTangents(for: segment)
      for index in 0..<(segment.count - 1) {
        let start = segment[index]
        let end = segment[index + 1]
        let width = max(0.0001, end.x - start.x)
        let control1 = CGPoint(
          x: start.x + width / 3,
          y: start.y + CGFloat(slopes[index]) * width / 3)
        let control2 = CGPoint(
          x: end.x - width / 3,
          y: end.y - CGFloat(slopes[index + 1]) * width / 3)
        result.addCurve(to: end, control1: control1, control2: control2)
      }
    }
    return result
  }

  private func pointSegments(in size: CGSize, range: ClosedRange<Double>) -> [[CGPoint]] {
    var segments: [[CGPoint]] = []
    var current: [CGPoint] = []
    let denominator = CGFloat(max(1, values.count - 1))
    let span = range.upperBound - range.lowerBound

    func finishSegment() {
      if !current.isEmpty {
        segments.append(current)
        current.removeAll(keepingCapacity: true)
      }
    }

    for (index, raw) in values.enumerated() {
      guard let raw, raw.isFinite else {
        finishSegment()
        continue
      }
      let value = min(range.upperBound, max(range.lowerBound, raw))
      let x = size.width * CGFloat(index) / denominator
      let normalized = (value - range.lowerBound) / span
      let y = size.height * CGFloat(1 - normalized)
      current.append(CGPoint(x: x, y: y))
    }
    finishSegment()
    return segments
  }

  /// Fritsch-Carlson-style monotone tangents for equally ordered x samples.
  /// Sign changes flatten the tangent, preventing spline overshoot at spikes.
  private func monotoneTangents(for points: [CGPoint]) -> [Double] {
    guard points.count > 1 else { return Array(repeating: 0, count: points.count) }
    var secants: [Double] = []
    secants.reserveCapacity(points.count - 1)
    for index in 0..<(points.count - 1) {
      let dx = max(0.0001, Double(points[index + 1].x - points[index].x))
      secants.append(Double(points[index + 1].y - points[index].y) / dx)
    }

    var tangents = Array(repeating: 0.0, count: points.count)
    tangents[0] = secants[0]
    tangents[points.count - 1] = secants[secants.count - 1]
    if points.count > 2 {
      for index in 1..<(points.count - 1) {
        let previous = secants[index - 1]
        let next = secants[index]
        guard previous != 0, next != 0, previous.sign == next.sign else {
          tangents[index] = 0
          continue
        }
        tangents[index] = (2 * previous * next) / (previous + next)
      }
    }
    return tangents
  }
}
