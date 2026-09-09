import AppKit
import SwiftUI

struct HeliosMetricPopoverView: View {
  let metric: HeliosMenuBarMetric
  @ObservedObject var model: OverviewViewModel
  // The popup refreshes from the shared 1 Hz snapshot. DaemonService itself is
  // intentionally not observed because its registration heartbeat is unrelated
  // to metric rendering. FanControlModel *is* observed: changing System/Boost/
  // Manual/Auto from the thermal popup must update immediately.
  let service: DaemonService
  @ObservedObject private var fanControl: FanControlModel
  @ObservedObject var preferences: HeliosPreferences
  @State private var showingFanSafetyGuide = false
  @State private var pendingFanSelection: FanControlSelection?
  @State private var scrollGeneration = 0
  let openRoute: (HeliosMonitorRoute) -> Void
  let openEnergyInspector: () -> Void

  init(
    metric: HeliosMenuBarMetric,
    model: OverviewViewModel,
    service: DaemonService,
    preferences: HeliosPreferences,
    openRoute: @escaping (HeliosMonitorRoute) -> Void,
    openEnergyInspector: @escaping () -> Void = {}
  ) {
    self.metric = metric
    self.model = model
    self.service = service
    _fanControl = ObservedObject(wrappedValue: service.fanControl)
    self.preferences = preferences
    self.openRoute = openRoute
    self.openEnergyInspector = openEnergyInspector
  }

  private var p: OverviewPresentation { OverviewPresentation(model.snapshot) }

  static func preferredHeight(for metric: HeliosMenuBarMetric) -> CGFloat {
    switch metric {
    case .memory: 430
    case .battery: 446
    case .cpu: 356
    case .gpu: 310
    case .temperature, .cooling, .fan: 462
    case .power: 292
    case .network: 276
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)

      Divider().opacity(0.45)

      ScrollView(.vertical) {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
      }
      .scrollIndicators(.hidden)
      .clipped()
      .id(scrollGeneration)

      Divider().opacity(0.45)

      footer
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
    .frame(width: 344, height: Self.preferredHeight(for: metric), alignment: .top)
    .background(.regularMaterial)
    .alert("Before changing fan control", isPresented: $showingFanSafetyGuide) {
      Button("Stay on System", role: .cancel) {
        pendingFanSelection = nil
        scrollGeneration &+= 1
      }
      Button("I Understand") {
        preferences.completeFanSafetyGuide()
        if let pendingFanSelection { fanControl.setMode(pendingFanSelection) }
        pendingFanSelection = nil
        // Recreate the scroll surface after the one-time safety alert. SwiftUI can
        // otherwise preserve the focused control's scroll offset and let content
        // visually bleed under the fixed popover header on dismissal.
        scrollGeneration &+= 1
      }
    } message: {
      Text(
        "System control is recommended. Boost, Manual and Automatic Rules override macOS fan targets. Helios clamps targets to the validated factory fan range, and the privileged helper enforces a 95°C maximum-cooling guard using fresh trusted thermal telemetry. Custom Manual and Automatic Rules remain your responsibility. If you are unsure, stay on System."
      )
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: metric.symbolName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(metricTitle)
        .font(.system(size: 14.5, weight: .semibold))
      Spacer()
      if service.client.state == .connected && (metric == .cooling || metric == .fan) {
        HStack(spacing: 5) {
          Circle().fill(.green).frame(width: 6, height: 6)
          Text("Connected")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .help("Fan helper connected")
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if metric != .memory {
        graphControls
      }
      Spacer(minLength: 8)
      Button {
        openRoute(route)
      } label: {
        HStack(spacing: 5) {
          Text("Open \(route.title)")
          Image(systemName: "arrow.up.right")
            .font(.system(size: 9, weight: .semibold))
        }
      }
      .buttonStyle(.borderless)
      .font(.system(size: 10.5, weight: .medium))
    }
  }

  @ViewBuilder
  private var content: some View {
    switch metric {
    case .cpu: cpu
    case .memory: memory
    case .gpu: gpu
    case .temperature, .cooling, .fan: thermals
    case .battery: battery
    case .power: power
    case .network: network
    }
  }

  private var cpu: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        hero(value(p.cpu.map(\.usagePercent)) { String(format: "%.0f%%", $0) })
        Spacer()
        if case .success(let cpu) = p.cpu {
          Text(String(format: "%.0f%% idle", cpu.idlePercent))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      chart(
        samples: cpuSamples, fixedRange: 0...100, tint: preferences.color(for: .cpu),
        valueStyle: .percent, label: "CPU"
      )
      .frame(height: 74)
      if case .success(let cpu) = p.cpu {
        HStack(spacing: 8) {
          mini("User", String(format: "%.0f%%", cpu.userPercent))
          mini("System", String(format: "%.0f%%", cpu.systemPercent))
          mini("Idle", String(format: "%.0f%%", cpu.idlePercent))
        }
      }
      if case .success(let processes) = p.processes, !processes.topByCPU.isEmpty {
        Divider().opacity(0.35)
        compactSectionLabel("Top CPU")
        VStack(spacing: 5) {
          ForEach(processes.topByCPU.prefix(3)) { process in
            processRow(
              process.name,
              process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
          }
        }
      }
    }
  }

  private var memory: some View {
    VStack(alignment: .leading, spacing: 11) {
      if case .success(let memory) = p.memory {
        let composition = HeliosMemoryComposition(memory)
        HStack(alignment: .center, spacing: 16) {
          HeliosSegmentedArcGauge(
            segments: composition.gaugeSegments(
              showAvailable: preferences.memoryGaugeShowsAvailable, preferences: preferences),
            progress: composition.usedFraction,
            valueText: String(format: "%.0f%%", memory.usagePercent),
            subtitle: "Used"
          )
          .frame(width: 118, height: 106)

          VStack(alignment: .leading, spacing: 7) {
            HStack {
              Text("Memory pressure")
                .foregroundStyle(.secondary)
              Spacer()
              Text(value(memory.pressure) { $0.rawValue })
                .fontWeight(.semibold)
                .foregroundStyle(memoryPressureColor(memory.pressure))
            }
            memorySummaryRow(
              "Used", bytes: composition.usedBytes, tint: preferences.color(for: .memory))
            memorySummaryRow(
              "Available", bytes: composition.availableBytes,
              tint: preferences.memoryGaugeShowsAvailable
                ? preferences.color(for: .memoryAvailable) : HeliosMemoryPalette.unfilled)
            memorySummaryTextRow(
              "Swap", text: value(memory.swapUsedBytes, TelemetryFormatting.storageBytes),
              tint: preferences.color(for: .swap))
          }
          .font(.system(size: 10.5))
        }

        Divider().opacity(0.35)
        compactSectionLabel("Breakdown")
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
          alignment: .leading,
          spacing: 7
        ) {
          memoryTile(
            "App memory", bytes: composition.appBytes,
            percent: composition.percent(composition.appBytes),
            tint: preferences.color(for: .memoryApp))
          memoryTile(
            "Wired", bytes: composition.wiredBytes,
            percent: composition.percent(composition.wiredBytes),
            tint: preferences.color(for: .memoryWired))
          memoryTile(
            "Compressed", bytes: composition.compressedBytes,
            percent: composition.percent(composition.compressedBytes),
            tint: preferences.color(for: .memoryCompressed))
          memoryTile(
            "Available", bytes: composition.availableBytes,
            percent: composition.percent(composition.availableBytes),
            tint: preferences.memoryGaugeShowsAvailable
              ? preferences.color(for: .memoryAvailable) : HeliosMemoryPalette.unfilled)
        }
        HStack(spacing: 6) {
          Circle().fill(preferences.color(for: .memoryCache)).frame(width: 6, height: 6)
          Text("Reclaimable cache")
          Spacer()
          Text(TelemetryFormatting.storageBytes(composition.cacheBytes)).monospacedDigit()
          Text("not an extra physical segment")
            .font(.system(size: 8.5))
            .foregroundStyle(.tertiary)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
      } else {
        emptyMetric("Memory telemetry unavailable")
      }

      if case .success(let processes) = p.processes, !processes.topByMemory.isEmpty {
        Divider().opacity(0.35)
        compactSectionLabel("Top memory processes")
        ForEach(processes.topByMemory.prefix(3)) { process in
          processRow(process.name, TelemetryFormatting.storageBytes(process.physicalFootprintBytes))
        }
      }
    }
  }

  private var gpu: some View {
    VStack(alignment: .leading, spacing: 10) {
      hero(value(p.gpu.flatMap(\.deviceUtilizationPercent)) { String(format: "%.0f%%", $0) })
      chart(
        samples: gpuSamples, fixedRange: 0...100, tint: preferences.color(for: .gpu),
        valueStyle: .percent, label: "GPU"
      ).frame(height: 78)
      if case .success(let gpu) = p.gpu {
        HStack(spacing: 8) {
          mini("Renderer", value(gpu.rendererUtilizationPercent) { String(format: "%.0f%%", $0) })
          mini("Tiler", value(gpu.tilerUtilizationPercent) { String(format: "%.0f%%", $0) })
          mini("Cores", value(gpu.coreCount) { String($0) })
        }
      }
    }
  }

  private var thermals: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 1) {
          hero(value(p.thermals.flatMap(\.maximumSoCCelsius)) { String(format: "%.0f°C", $0) })
          Text("Max SoC")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 1) {
          Text(thermalStateText)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(thermalStateColor)
          Text("Thermal state")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
      }

      if preferences.isTelemetryEnabled(.fans) {
        HStack(spacing: 8) {
          thermalMini("Fan", fanText, symbol: "fan")
          thermalMini(
            "Control",
            preferences.coolingFeaturesEnabled ? fanControl.selection.label : "Read-only",
            symbol: preferences.coolingFeaturesEnabled ? "slider.horizontal.3" : "eye")
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          compactSectionLabel("Temperature")
          Spacer()
          Text("Max SoC").font(.system(size: 8.5)).foregroundStyle(.tertiary)
        }
        chart(
          samples: temperatureSamples, fixedRange: 20...100,
          tint: preferences.color(for: .temperature),
          valueStyle: .celsius, label: "Max SoC"
        )
        .frame(height: 58)
      }

      if preferences.isTelemetryEnabled(.fans) {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            compactSectionLabel("Fan speed")
            Spacer()
            Text(fanText).font(.system(size: 8.5).monospacedDigit()).foregroundStyle(.tertiary)
          }
          chart(
            samples: fanSamples, fixedRange: nil, tint: preferences.color(for: .fan),
            valueStyle: .rpm, label: "Fan"
          )
          .frame(height: 44)
        }
      }

      if preferences.coolingFeaturesEnabled {
        Divider().opacity(0.35)
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            compactSectionLabel("Cooling control")
            Spacer()
            Text(fanControl.selection == .system ? "macOS" : "Helios")
              .font(.system(size: 8.5, weight: .medium))
              .foregroundStyle(.tertiary)
          }
          FanModeControls(
            selection: Binding(
              get: { fanControl.selection },
              set: { requestFanSelection($0) }),
            targetRPM: $fanControl.targetRPM,
            bounds: fanControl.sliderBounds,
            boostEnabled: fanControl.canSelectBoost,
            overrideEnabled: fanControl.canSelectOverride,
            autoEnabled: fanControl.canSelectAuto
          )
          HeliosFanSafetyNotice(compact: true)
          Button(
            fanControl.selection == .auto ? "Edit Auto Rules…" : "Open full cooling controls…"
          ) {
            openRoute(.thermals)
          }
          .buttonStyle(.link)
          .controlSize(.small)
          .help(
            fanControl.selection == .auto
              ? "Open the full Thermals & Fans page to add, reorder and tune Auto rules"
              : "Open the full Thermals & Fans page for detailed fan state and controls")
        }

        HStack(spacing: 6) {
          Image(
            systemName: fanControl.selection == .system
              ? "checkmark.shield" : "fan.badge.automatic")
          Text(
            fanControl.selection == .system
              ? "macOS controls cooling"
              : "Helios \(fanControl.selection.label) active"
          )
          Spacer()
          Text("95°C guard")
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 9.5, weight: .medium))
      } else {
        Label("Cooling controls disabled", systemImage: "fan.slash")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
        Text(
          preferences.isTelemetryEnabled(.fans)
            ? "Temperature and fan RPM monitoring remain active. Re-enable Cooling in Settings only if you want fan-control overrides."
            : "Temperature monitoring remains active. Fan RPM monitoring and fan-control overrides can be enabled independently in Settings."
        )
        .font(.system(size: 9.5)).foregroundStyle(.secondary)
      }
    }
  }

  private var battery: some View {
    VStack(alignment: .leading, spacing: 10) {
      let estimate = HeliosBatteryEstimateEngine.estimate(
        battery: p.battery, history: model.history)

      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          hero(value(p.battery.flatMap(\.stateOfChargePercent)) { String(format: "%.0f%%", $0) })
          Text("Battery")
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(estimate.compactText)
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
          Text(estimate.source.rawValue)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
        }

        Spacer()
        if case .success(let battery) = p.battery {
          VStack(alignment: .trailing, spacing: 2) {
            Text(value(battery.power) { String(format: "%+.1f W", $0.signedWatts) })
              .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(batteryFlowDetail)
              .font(.system(size: 9.5))
              .foregroundStyle(.secondary)
          }
        }
      }

      chart(
        samples: batterySamples, fixedRange: 0...100, tint: preferences.color(for: .battery),
        valueStyle: .percent,
        label: "Battery"
      ).frame(height: 58)

      let energy = activeBatteryEnergy
      Divider().opacity(0.35)
      HStack {
        compactSectionLabel("What is using your battery?")
        Spacer()
        Text(activeGraphRange.label)
          .font(.system(size: 9.5, weight: .medium).monospacedDigit())
          .foregroundStyle(.tertiary)
      }

      if energy.topOnBattery.isEmpty {
        Text(
          "Collecting on-battery app energy history. Rankings appear after Helios has observed battery use in this time window."
        )
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        let leaders = Array(energy.topOnBattery.prefix(3))
        let trackedTotal = max(
          0.000_001, energy.topOnBattery.reduce(0) { $0 + $1.energyWattHours })
        ForEach(leaders) { entry in
          energyRow(entry, total: trackedTotal)
        }
        HStack {
          Text("Observed on battery")
          Spacer()
          Text(TelemetryFormatting.duration(energy.onBatteryCoverageSeconds))
            .monospacedDigit()
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
      }

      Button {
        openEnergyInspector()
      } label: {
        Label("Open Energy Inspector…", systemImage: "chart.bar.xaxis")
      }
      .buttonStyle(.borderless)
      .font(.system(size: 10, weight: .medium))
      .help("Open the dedicated per-app battery and energy history window")

      if case .success(let battery) = p.battery {
        HStack(spacing: 8) {
          mini("Health", value(battery.healthPercent) { String(format: "%.0f%%", $0) })
          mini("Cycles", value(battery.cycleCount) { String($0) })
          mini("Temp", value(battery.temperatureCelsius) { String(format: "%.0f°C", $0) })
        }
      }
    }
  }

  private var power: some View {
    VStack(alignment: .leading, spacing: 10) {
      hero(value(p.systemPower.flatMap(\.totalSystemWatts)) { String(format: "%.1f W", $0) })
      chart(
        samples: powerSamples, fixedRange: nil, tint: preferences.color(for: .power),
        valueStyle: .watts, label: "Power"
      ).frame(height: 78)
      if case .success(let battery) = p.battery {
        HStack(spacing: 8) {
          mini("Battery flow", value(battery.power) { String(format: "%+.1f W", $0.signedWatts) })
          mini("Source", value(battery.powerSource) { $0.rawValue })
        }
      }
    }
  }

  private var network: some View {
    VStack(alignment: .leading, spacing: 10) {
      if case .success(let network) = p.network, case .success(let rate) = network.throughput {
        HStack(spacing: 8) {
          mini("Download", TelemetryFormatting.bytesPerSecond(rate.downloadBytesPerSecond))
          mini("Upload", TelemetryFormatting.bytesPerSecond(rate.uploadBytesPerSecond))
        }
      }
      HStack(spacing: 8) {
        chart(
          samples: downloadSamples, fixedRange: nil, tint: preferences.color(for: .networkDownload),
          valueStyle: .bytesPerSecond,
          label: "Download"
        ).frame(height: 72)
        chart(
          samples: uploadSamples, fixedRange: nil, tint: preferences.color(for: .networkUpload),
          valueStyle: .bytesPerSecond,
          label: "Upload"
        ).frame(height: 72)
      }
    }
  }

  private func requestFanSelection(_ selection: FanControlSelection) {
    guard selection != .system, !preferences.fanSafetyGuideCompleted else {
      fanControl.setMode(selection)
      return
    }
    pendingFanSelection = selection
    showingFanSafetyGuide = true
  }

  private var graphControls: some View {
    HeliosGraphRangeMenu(
      range: Binding(
        get: { activeGraphRange },
        set: { preferences.setGraphRange($0, for: graphScope) }))
  }

  private var graphScope: HeliosGraphScope {
    switch metric {
    case .cpu: .cpu
    case .memory: .memory
    case .gpu: .gpu
    case .temperature, .cooling, .fan: .thermals
    case .battery: .battery
    case .power: .power
    case .network: .network
    }
  }

  private var activeGraphRange: HeliosGraphRange {
    preferences.graphRange(for: graphScope)
  }

  private var activeBatteryEnergy: AppEnergySummary {
    guard let anchor = model.appEnergy.buckets.last?.capturedAt else { return .empty }
    let cutoff = anchor.addingTimeInterval(-activeGraphRange.seconds)
    return AppEnergyHistoryEngine.summary(
      model.appEnergy.buckets.filter { $0.capturedAt >= cutoff && $0.capturedAt <= anchor })
  }

  private var metricTitle: String {
    switch metric {
    case .cooling: "Cooling"
    case .fan: "Fan"
    case .temperature: "Temperature"
    case .power: "System Power"
    default: metric.label
    }
  }

  private var route: HeliosMonitorRoute {
    switch metric {
    case .cpu: .cpu
    case .memory: .memory
    case .gpu: .gpu
    case .temperature, .cooling, .fan: .thermals
    case .battery, .power: .battery
    case .network: .network
    }
  }

  private var fanText: String {
    let fans = TelemetryFormatting.fresh(model.snapshot.fans, maxAge: 6)
    guard case .success(let inventory) = fans, let fan = inventory.fans.first,
      case .success(let rpm) = fan.actualRPM
    else {
      if case .success(let inventory) = fans, inventory.fans.isEmpty { return "Fanless" }
      return "—"
    }
    return rpm < 50 ? "Fan off" : String(format: "%.0f RPM", rpm)
  }

  private var thermalStateText: String {
    guard case .success(let system) = p.system else { return "—" }
    return system.thermalState.rawValue
  }

  private var thermalStateColor: Color {
    guard case .success(let system) = p.system else { return .secondary }
    switch system.thermalState {
    case .nominal: return .green
    case .fair: return .yellow
    case .serious: return .orange
    case .critical: return .red
    }
  }

  private func thermalMini(_ title: String, _ value: String, symbol: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 8.5)).foregroundStyle(.secondary)
        Text(value).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
  }

  private var batteryFlowDetail: String {
    if case .success(let battery) = p.battery {
      if case .success(let source) = battery.powerSource {
        switch source {
        case .battery: return "Discharging"
        case .powerAdapter: return "Power adapter"
        }
      }
    }
    return "Live flow"
  }

  private var cpuSamples: [HeliosChartSample] { series(\.cpuPercent, \.cpuPercent) }
  private var gpuSamples: [HeliosChartSample] { series(\.gpuPercent, \.gpuPercent) }
  private var temperatureSamples: [HeliosChartSample] { series(\.maxSoCCelsius, \.maxSoCCelsius) }
  private var fanSamples: [HeliosChartSample] { series(\.fanRPM, \.fanRPM) }
  private var batterySamples: [HeliosChartSample] { series(\.batteryPercent, \.batteryPercent) }
  private var powerSamples: [HeliosChartSample] { series(\.systemPowerWatts, \.systemPowerWatts) }
  private var downloadSamples: [HeliosChartSample] {
    series(\.networkDownloadBytesPerSecond, \.networkDownloadBytesPerSecond)
  }
  private var uploadSamples: [HeliosChartSample] {
    series(\.networkUploadBytesPerSecond, \.networkUploadBytesPerSecond)
  }

  private func series(
    _ live: KeyPath<TelemetryHistoryPoint, Double?>,
    _ persisted: KeyPath<PersistedTelemetryPoint, Double?>
  ) -> [HeliosChartSample] {
    HeliosChartSeries.merged(
      range: activeGraphRange,
      live: model.history.points,
      persistent: model.persistentHistory.points,
      liveValue: { $0[keyPath: live] },
      persistentValue: { $0[keyPath: persisted] })
  }

  private func chart(
    samples: [HeliosChartSample], fixedRange: ClosedRange<Double>?, tint: Color,
    valueStyle: HeliosChartValueStyle, label: String
  ) -> some View {
    HeliosTimeSeriesChart(
      samples: samples,
      range: activeGraphRange,
      fixedRange: fixedRange,
      tint: tint,
      lineStyle: preferences.graphLineStyle,
      animateUpdates: preferences.animateGraphUpdates,
      inspectorEnabled: true,
      valueStyle: valueStyle,
      seriesLabel: label)
  }

  private func hero(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 28, weight: .semibold).monospacedDigit())
  }

  private func mini(_ label: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.system(size: 8.5))
        .foregroundStyle(.secondary)
      Text(text)
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func compactSectionLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 9.5, weight: .semibold))
      .foregroundStyle(.secondary)
  }

  private func processRow(_ name: String, _ value: String) -> some View {
    HStack(spacing: 8) {
      Text(name).lineLimit(1)
      Spacer(minLength: 8)
      Text(value)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .font(.system(size: 10.25))
  }

  private func memorySummaryRow(_ title: String, bytes: UInt64, tint: Color) -> some View {
    memorySummaryTextRow(title, text: TelemetryFormatting.storageBytes(bytes), tint: tint)
  }

  private func memorySummaryTextRow(_ title: String, text: String, tint: Color) -> some View {
    HStack(spacing: 6) {
      Circle().fill(tint).frame(width: 6, height: 6)
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(text).monospacedDigit()
    }
  }

  private func memoryTile(
    _ title: String, bytes: UInt64, percent: Double? = nil, tint: Color
  ) -> some View {
    HStack(spacing: 7) {
      RoundedRectangle(cornerRadius: 2)
        .fill(tint.opacity(0.9))
        .frame(width: 7, height: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 8.5))
          .foregroundStyle(.secondary)
        HStack(spacing: 5) {
          Text(TelemetryFormatting.storageBytes(bytes))
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
          if let percent {
            Text(String(format: "%.0f%%", percent))
              .font(.system(size: 8.5).monospacedDigit())
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func energyRow(_ entry: AppEnergyEntry, total: Double) -> some View {
    let share = min(1, max(0, entry.energyWattHours / total))
    return HStack(spacing: 8) {
      HeliosAppIdentityIcon(appKey: entry.appKey, size: 22)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(entry.displayName)
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(String(format: "%.0f%%", share * 100))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        ProgressView(value: share, total: 1)
          .tint(preferences.color(for: .energy))
          .controlSize(.mini)
      }
      .font(.system(size: 10))
    }
  }

  private func emptyMetric(_ text: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: "ellipsis.circle")
        .foregroundStyle(.secondary)
      Text(text)
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func memoryPressureColor(_ pressure: MetricResult<MemoryPressure>) -> Color {
    guard case .success(let pressure) = pressure else { return .secondary }
    switch pressure {
    case .normal: return .green
    case .warning: return .orange
    case .critical: return .red
    }
  }

  private func value<Value>(_ result: MetricResult<Value>, _ formatter: (Value) -> String) -> String
  {
    DisplayValue(result, format: formatter).text
  }
}

enum HeliosMemoryPalette {
  // One semantic color per category. Available memory is neutral by default so
  // the empty arc reads literally as headroom; the optional setting may render
  // it as a muted green segment.
  static let app = Color.blue
  static let wired = Color.purple
  static let compressed = Color.pink
  static let cache = Color.cyan
  static let swap = Color.orange
  static let available = Color.green.opacity(0.72)
  static let used = Color.indigo
  static let unfilled = Color.secondary.opacity(0.55)
}

struct HeliosMemoryComposition: Sendable, Equatable {
  let physicalBytes: UInt64
  let usedBytes: UInt64
  let appBytes: UInt64
  let wiredBytes: UInt64
  let compressedBytes: UInt64
  let availableBytes: UInt64
  let cacheBytes: UInt64

  init(_ memory: MemoryMetrics) {
    let physical = memory.physicalBytes
    let used = min(physical, memory.usedBytes)
    let wired = min(used, memory.wiredBytes)
    let remainingAfterWired = used - wired
    let compressed = min(remainingAfterWired, memory.compressedBytes)
    let app = remainingAfterWired - compressed

    physicalBytes = physical
    usedBytes = used
    appBytes = app
    wiredBytes = wired
    compressedBytes = compressed
    availableBytes = physical - used
    cacheBytes = min(physical, memory.cacheBytes)
  }

  var usedFraction: Double {
    physicalBytes > 0 ? Double(usedBytes) / Double(physicalBytes) : 0
  }

  func percent(_ bytes: UInt64) -> Double {
    physicalBytes > 0 ? Double(bytes) / Double(physicalBytes) * 100 : 0
  }

  @MainActor
  func gaugeSegments(showAvailable: Bool, preferences: HeliosPreferences) -> [HeliosArcSegment] {
    var result = [
      HeliosArcSegment(
        id: "app", fraction: fraction(appBytes), tint: preferences.color(for: .memoryApp)),
      HeliosArcSegment(
        id: "wired", fraction: fraction(wiredBytes), tint: preferences.color(for: .memoryWired)),
      HeliosArcSegment(
        id: "compressed", fraction: fraction(compressedBytes),
        tint: preferences.color(for: .memoryCompressed)),
    ]
    if showAvailable {
      result.append(
        HeliosArcSegment(
          id: "available", fraction: fraction(availableBytes),
          tint: preferences.color(for: .memoryAvailable)))
    }
    return result
  }

  private func fraction(_ bytes: UInt64) -> Double {
    physicalBytes > 0 ? Double(bytes) / Double(physicalBytes) : 0
  }
}

struct HeliosArcSegment: Identifiable {
  let id: String
  let fraction: Double
  let tint: Color
}

private struct HeliosArcRange: Identifiable {
  let segment: HeliosArcSegment
  let start: Double
  let end: Double
  let roundedCaps: Bool
  var id: String { segment.id }
}

struct HeliosSegmentedArcGauge: View {
  let segments: [HeliosArcSegment]
  let progress: Double
  let valueText: String
  let subtitle: String

  var body: some View {
    ZStack {
      Circle()
        .trim(from: 0, to: 0.75)
        .stroke(
          Color.secondary.opacity(0.12),
          style: StrokeStyle(lineWidth: 9, lineCap: .round)
        )
        .rotationEffect(.degrees(135))

      ForEach(arcRanges) { item in
        Circle()
          .trim(from: item.start, to: item.end)
          .stroke(
            item.segment.tint,
            style: StrokeStyle(lineWidth: 9, lineCap: item.roundedCaps ? .round : .butt)
          )
          .rotationEffect(.degrees(135))
      }

      VStack(spacing: 0) {
        Text(valueText)
          .font(.system(size: 24, weight: .semibold).monospacedDigit())
        Text(subtitle)
          .font(.system(size: 8.5, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .offset(y: -2)
    }
    .padding(7)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(valueText) \(subtitle)")
    .accessibilityValue(String(format: "%.0f%%", min(1, max(0, progress)) * 100))
  }

  private var arcRanges: [HeliosArcRange] {
    let valid = segments.map {
      HeliosArcSegment(id: $0.id, fraction: min(1, max(0, $0.fraction)), tint: $0.tint)
    }
    let total = valid.reduce(0) { $0 + $1.fraction }
    guard total > 0 else { return [] }
    // Segment fractions are absolute fractions of physical memory. Do not
    // renormalize used categories to 100%: when Available is hidden, the
    // remaining neutral track is intentional free/reclaimable headroom.
    let scale = total > 1 ? 1 / total : 1
    let gap = min(0.0032, 0.75 / Double(max(valid.count, 1)) * 0.08)
    var cursor = 0.0
    return valid.enumerated().compactMap { index, segment in
      let span = 0.75 * segment.fraction * scale
      let isFirst = index == 0
      let reachesTrackEnd = index == valid.count - 1 && total * scale >= 0.999
      // The first colored segment begins exactly at the rounded track cap. RC4
      // inset it by half a gap, which left a visible neutral crescent under the
      // color. Round the exposed outer cap(s), while keeping internal boundaries
      // crisp enough to read as separate memory categories.
      let start = cursor + (isFirst ? 0 : gap / 2)
      let end = cursor + span - (reachesTrackEnd ? 0 : gap / 2)
      cursor += span
      guard end > start else { return nil }
      return HeliosArcRange(
        segment: segment, start: start, end: end, roundedCaps: isFirst || reachesTrackEnd)
    }
  }
}

/// Compatibility wrapper retained for older presentation fixtures. New memory
/// surfaces use HeliosSegmentedArcGauge so the arc communicates composition.
struct HeliosArcGauge: View {
  let progress: Double
  let valueText: String
  let subtitle: String
  let tint: Color

  var body: some View {
    HeliosSegmentedArcGauge(
      segments: [HeliosArcSegment(id: "value", fraction: min(1, max(0, progress)), tint: tint)],
      progress: progress,
      valueText: valueText,
      subtitle: subtitle)
  }
}

@MainActor
private final class HeliosAppIconCache {
  static let shared = HeliosAppIconCache()
  private let cache = NSCache<NSString, NSImage>()

  func icon(for appKey: String) -> NSImage? {
    guard appKey.hasPrefix("app:") else { return nil }
    let path = String(appKey.dropFirst(4))
    guard !path.isEmpty else { return nil }
    let key = path as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let image = NSWorkspace.shared.icon(forFile: path)
    image.size = NSSize(width: 32, height: 32)
    cache.setObject(image, forKey: key)
    return image
  }
}

struct HeliosAppIdentityIcon: View {
  let appKey: String
  var size: CGFloat = 24

  var body: some View {
    Group {
      if let image = HeliosAppIconCache.shared.icon(for: appKey) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      } else {
        Image(systemName: "app.fill")
          .resizable()
          .scaledToFit()
          .padding(size * 0.18)
          .foregroundStyle(.secondary)
          .background(
            Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.22))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
