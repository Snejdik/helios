import AppKit
import SwiftUI

enum HeliosSettingsRoute: String, CaseIterable, Identifiable {
  case general
  case modules
  case graphs
  case fans
  case battery
  case privacy
  case notifications
  case advanced
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .modules: "Modules"
    case .graphs: "Graphs & Colors"
    case .fans: "Cooling"
    case .battery: "Battery & Energy"
    case .privacy: "Privacy & Diagnostics"
    case .notifications: "Notifications"
    case .advanced: "Advanced"
    case .about: "About"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gear"
    case .modules: "square.grid.2x2"
    case .graphs: "chart.xyaxis.line"
    case .fans: "fan"
    case .battery: "battery.75percent"
    case .privacy: "hand.raised"
    case .notifications: "bell"
    case .advanced: "slider.horizontal.3"
    case .about: "info.circle"
    }
  }
}

private enum HeliosModuleSettingsTab: String, CaseIterable, Identifiable {
  case collection = "Data Collection"
  case menuBar = "Menu Bar"
  case popover = "Dashboard"
  case monitor = "Full Monitor"
  var id: String { rawValue }

  func title(_ style: HeliosInterfacePreferences.Style) -> String {
    guard style == .helios else { return rawValue }
    switch self {
    case .popover: return "Popover"
    case .monitor: return "Window"
    default: return rawValue
    }
  }
}

@MainActor
final class HeliosSettingsState: ObservableObject {
  @Published var selection: HeliosSettingsRoute? = .general
}

struct HeliosSettingsView: View {
  @ObservedObject private var updateChecker = HeliosUpdatePresenter.shared.checker
  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var service: DaemonService
  @ObservedObject var diagnostics: DiagnosticsController
  @ObservedObject private var diagnosticsPreferences: DiagnosticsPreferences
  @ObservedObject private var healthCenter: HealthAlertCenter
  @StateObject private var manualApproval = DiagnosticsManualApproval()
  @ObservedObject private var state: HeliosSettingsState
  /// Helios/Legacy choice and Helios layout live in their own observable.
  @ObservedObject private var interface: HeliosInterfacePreferences
  @State private var moduleTab: HeliosModuleSettingsTab = .collection
  @State private var goalsDraft: Set<HeliosGoal> = []
  @State private var goalsApplied = false
  @State private var showingPrepareRemoval = false
  @State private var eraseLocalDataOnRemoval = false
  @State private var removalStatus: String?
  @State private var diagnosticsPreview: FrozenDiagnosticsPayload?
  @State private var showingDiagnosticsPreview = false
  @State private var previewAllowsSend = false
  @State private var diagnosticsStatus: String?
  @State private var showingCompatibilityConsent = false
  @State private var generatingCompatibility = false
  @State private var compatibilityStatus: String?
  @State private var compatibilityTransitioningToPreview = false
  @State private var manualSendCompleted = false

  init(
    preferences: HeliosPreferences, service: DaemonService, diagnostics: DiagnosticsController,
    healthCenter: HealthAlertCenter? = nil, state: HeliosSettingsState = HeliosSettingsState()
  ) {
    self.state = state
    self.healthCenter = healthCenter ?? HealthAlertCenter(runtimeServicesEnabled: false)
    self.preferences = preferences
    interface = preferences.interface
    self.service = service
    self.diagnostics = diagnostics
    diagnosticsPreferences = diagnostics.preferences
  }

  var body: some View {
    NavigationSplitView {
      List(HeliosSettingsRoute.allCases, selection: $state.selection) { route in
        Label(route.title, systemImage: route.symbol).tag(route)
      }
      .navigationTitle("Settings")
      .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          settingsHeader
          settingsDetail(state.selection ?? .general)
        }
        .padding(22)
        // Same behaviour as the main window: a readable column that stays
        // centred in a wide or full-screen window.
        .frame(maxWidth: HeliosDesign.settingsContentWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .groupBoxStyle(HeliosSettingsGroupBoxStyle())
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 720, minHeight: 520)
    .sheet(isPresented: $showingDiagnosticsPreview, onDismiss: dismissDiagnosticsPreview) {
      diagnosticsPreviewSheet
    }
    .sheet(isPresented: $showingCompatibilityConsent, onDismiss: compatibilityConsentDismissed) {
      DiagnosticsCompatibilityConsentView(
        generating: generatingCompatibility, status: compatibilityStatus,
        onCancel: cancelCompatibilityReport,
        onGenerate: generateCompatibilityPreview)
    }
  }

  @ViewBuilder
  private var diagnosticsPreviewSheet: some View {
    if let diagnosticsPreview {
      if previewAllowsSend {
        DiagnosticsPayloadView(
          title: "Confirm diagnostic report",
          explanation:
            "Review the complete request body, then choose Send report. This one-shot action does not enable automatic diagnostics.",
          payload: diagnosticsPreview,
          sendTitle: manualSendCompleted ? "Sent" : "Send report",
          sending: diagnostics.sending,
          sendDisabled: manualSendCompleted,
          status: diagnosticsStatus,
          onSend: sendApprovedManualReport,
          onRegenerate: diagnosticsPreview.reportType == .manualCompatibility
            ? generateCompatibilityPreview : showManualHealthPreview)
      } else {
        DiagnosticsPayloadView(
          title: "Beta diagnostics preview",
          explanation:
            "This local preview shows the complete automatic diagnostics body. Viewing it sends nothing.",
          payload: diagnosticsPreview,
          status: diagnosticsStatus,
          onRegenerate: showAutomaticPreview)
      }
    }
  }

  private var settingsHeader: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text((state.selection ?? .general).title).font(.system(size: 24, weight: .semibold))
      Text(settingsSubtitle(state.selection ?? .general))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func settingsDetail(_ route: HeliosSettingsRoute) -> some View {
    switch route {
    case .general: general
    case .modules: modules
    case .graphs: graphs
    case .fans: fans
    case .battery: batterySettings
    case .privacy: privacy
    case .notifications: notificationSettings
    case .advanced: advanced
    case .about: about
    }
  }

  private func settingsSubtitle(_ route: HeliosSettingsRoute) -> String {
    switch route {
    case .general: "Interface, startup and updates."
    case .modules: "What Helios collects and where it appears."
    case .graphs: "Chart style, time ranges and colors."
    case .fans: "The fan helper and fan-control safety."
    case .battery: "Battery estimates and energy history."
    case .privacy: "What stays on this Mac, and optional diagnostics."
    case .notifications: "Informational alerts."
    case .advanced: "Reset and removal."
    case .about: "Version and links."
    }
  }

  private func setCoolingEnabled(_ enabled: Bool) {
    if !enabled {
      // Never hide the controls while leaving an invisible Helios override active.
      service.fanControl.setMode(.system)
    }
    preferences.setCoolingFeaturesEnabled(enabled)
  }

  private func setTelemetryCollection(_ module: HeliosTelemetryModule, enabled: Bool) {
    if module == .fans, !enabled, preferences.coolingFeaturesEnabled {
      // Fan control depends on fresh fan inventory. Returning to System before
      // stopping the read-only sampler keeps the write path impossible to
      // strand behind hidden controls.
      service.fanControl.setMode(.system)
      preferences.setCoolingFeaturesEnabled(false)
    }
    preferences.setTelemetryModuleEnabled(module, enabled: enabled)
  }

  private var notificationSettings: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox {
        HStack(spacing: 10) {
          Image(systemName: healthCenter.authorization == .denied ? "bell.slash" : "bell.badge")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(healthCenter.authorization == .denied ? "Notifications are off in macOS"
              : healthCenter.authorization == .notDetermined ? "Helios may not notify you yet" : "Notifications are on")
            Text(healthCenter.deliveryFailed
              ? "The last notification could not be queued; Helios retries while the condition lasts."
              : "Helios notifies only when a problem lasts 15 s, and repeats it at most every 30 min (10 min if critical).")
              .font(.subheadline).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          if healthCenter.authorization == .notDetermined {
            Button("Turn On…") { healthCenter.requestAuthorization() }
          } else if healthCenter.authorization == .denied {
            Button("Open System Settings…") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
      }
      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Picker("Notify me about", selection: Binding(
            get: { HeliosAlertSensitivity.current(preferences.healthAlerts) },
            set: { $0.apply(to: preferences) })) {
            ForEach(HeliosAlertSensitivity.selectable, id: \.self) { Text($0.title).tag($0) }
            if HeliosAlertSensitivity.current(preferences.healthAlerts) == .custom {
              Text("Custom").tag(HeliosAlertSensitivity.custom)
            }
          }
          .pickerStyle(.segmented)
          Text(HeliosAlertSensitivity.current(preferences.healthAlerts).detail)
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      ForEach(HeliosAlertGroup.all, id: \.title) { group in
        GroupBox(group.title) {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(group.pairs.enumerated()), id: \.offset) { index, pair in
              notificationPairRow(pair)
              if index < group.pairs.count - 1 { Divider() }
            }
          }
        }
      }
      HStack {
        Button("Restore Defaults") { preferences.restoreHealthAlertDefaults() }
        Spacer(minLength: 0)
        Text("Alerts only inform you. They never change fan control.")
          .font(.subheadline).foregroundStyle(.tertiary)
      }
    }
    .task { await healthCenter.refreshAuthorization() }
  }

  /// One subject with its warning and critical level on one line.
  private func notificationPairRow(_ pair: HeliosAlertPair) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(pair.title)
        Spacer()
        if let note = pair.note {
          Text(note).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 18) {
        ForEach(pair.rules, id: \.self) { rule in
          notificationLevel(rule, label: rule == pair.rules.first && pair.rules.count > 1 ? pair.firstLabel : pair.secondLabel)
        }
        Spacer(minLength: 0)
      }
      .font(.subheadline)
    }
  }

  private func notificationLevel(_ rule: HealthAlertRule, label: String) -> some View {
    let enabled = preferences.healthAlerts[rule].enabled
    return HStack(spacing: 6) {
      Toggle(label, isOn: Binding(
        get: { preferences.healthAlerts[rule].enabled },
        set: { preferences.setHealthAlert(rule, enabled: $0) }))
        .toggleStyle(.checkbox)
      if let threshold = preferences.healthAlerts[rule].threshold {
        Text(rule.isLowThreshold ? "below" : "at").foregroundStyle(.secondary)
        let value = Binding<Double>(
          get: { preferences.healthAlerts[rule].threshold ?? threshold },
          set: { preferences.setHealthAlert(rule, threshold: $0) })
        TextField("Threshold", value: value, format: .number.precision(.fractionLength(0...1)))
          .frame(width: 44)
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("\(rule.title) threshold in \(rule.unit)")
        Stepper("Adjust \(rule.title) threshold", value: value, in: rule.range, step: 1)
          .labelsHidden()
        Text(rule.unit).foregroundStyle(.secondary)
      }
    }
    .opacity(enabled ? 1 : 0.6)
    .help(rule.title)
  }

  private var general: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Interface") {
        VStack(alignment: .leading, spacing: 8) {
          Picker("Interface", selection: $interface.style) {
            Text("Helios").tag(HeliosInterfacePreferences.Style.helios)
            Text("Legacy").tag(HeliosInterfacePreferences.Style.legacy)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          Text(interface.style == .helios
            ? "The new window and menu-bar popover."
            : "The original 0.1 window and dashboard. Same monitoring underneath.")
            .font(.subheadline).foregroundStyle(.secondary)
          if interface.style == .legacy {
            Toggle(
              "Compact dashboard card spacing",
              isOn: Binding(
                get: { preferences.compactCards },
                set: { preferences.setCompactCards($0) }))
          }
        }
      }
      if interface.style == .helios {
        GroupBox("Your goals") {
          VStack(alignment: .leading, spacing: 10) {
            HeliosGoalPicker(selection: $goalsDraft)
            HStack {
              Button("Apply Goals") {
                preferences.applyGoals(goalsDraft)
                goalsApplied = true
              }
              .disabled(goalsDraft == interface.goals && !goalsDraft.isEmpty)
              if goalsApplied { Label("Applied", systemImage: "checkmark").foregroundStyle(.secondary) }
              Spacer(minLength: 0)
            }
            Text("Sets the menu bar, popover, sidebar and what Helios collects. Edit any of it afterwards in Modules.")
              .font(.subheadline).foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .onAppear { goalsDraft = interface.goals }
        .onChange(of: goalsDraft) { _ in goalsApplied = false }
      } else {
      GroupBox("What Helios collects") {
        VStack(alignment: .leading, spacing: 8) {
          HeliosPresetPicker(selection: Binding(
            get: { preferences.dashboardMode },
            set: { preferences.applyInterfacePreset($0) }))
          Text(preferences.dashboardMode.onboardingDetail)
            .font(.subheadline).foregroundStyle(.secondary)
          Text("A preset is a starting point. Fine-tune every sampler in Modules.")
            .font(.subheadline).foregroundStyle(.tertiary)
        }
      }
      }
      GroupBox("Units") {
        HStack {
          Text("Temperature")
          Spacer()
          Picker("Temperature", selection: $preferences.temperatureUnit) {
            ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
      }
      GroupBox("Startup") {
        HeliosLaunchAtLoginView(
          enabled: service.launchAtLoginEnabled,
          requiresApproval: service.launchAtLoginRequiresApproval,
          busy: service.launchAtLoginBusy, message: service.launchAtLoginMessage,
          setEnabled: { enabled in Task { await service.setLaunchAtLogin(enabled) } },
          openSettings: { service.openApprovalSettings() })
      }
      GroupBox("Updates") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Check automatically")
            Spacer()
            Picker("Check automatically", selection: $updateChecker.frequency) {
              ForEach(HeliosUpdateFrequency.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
          }
          HStack {
            Text("Last checked").foregroundStyle(.secondary)
            Text(lastSuccessfulUpdateCheck).foregroundStyle(.secondary)
            Spacer()
            Button("Check Now…") { HeliosUpdatePresenter.shared.check(manual: true) }
              .disabled(updateChecker.isChecking)
          }
          Text("Helios only asks GitHub for the latest release. No telemetry is sent.")
            .font(.subheadline).foregroundStyle(.tertiary)
        }
      }
    }
  }

  private var modules: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker("Module surface", selection: $moduleTab) {
        ForEach(HeliosModuleSettingsTab.allCases) { tab in
          Text(tab.title(interface.style)).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      // A segmented control in this scroll stack took a share of the spare height
      // and floated in the middle of a large empty band.
      .fixedSize(horizontal: false, vertical: true)
      switch moduleTab {
      case .collection: dataCollection
      case .menuBar: menuBar
      case .popover:
        if interface.style == .helios {
          HeliosPopoverSettings(interface: interface)
        } else {
          dashboard
        }
      case .monitor:
        if interface.style == .helios {
          HeliosWindowSettings(interface: interface)
        } else {
          monitor
        }
      }
    }
  }

  private var dataCollection: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Samplers") {
        VStack(spacing: 0) {
          ForEach(Array(HeliosTelemetryModule.allCases.enumerated()), id: \.element.id) { index, module in
            HeliosSamplerRow(
              title: module.label, detail: module.shortDetail, cost: module.monitoringCost,
              status: preferences.isTelemetryEnabled(module)
                ? "On"
                : preferences.isTelemetryCollectionRequired(module)
                  ? "On for alerts" : "Off",
              isCollecting: preferences.isTelemetryCollectionRequired(module),
              isOn: Binding(
                get: { preferences.isTelemetryEnabled(module) },
                set: { setTelemetryCollection(module, enabled: $0) }))
            if index < HeliosTelemetryModule.allCases.count - 1 { Divider() }
          }
        }
      }
      Text("Stop work you do not need: turning a sampler off stops its work and hides what depends on it. Temperature safety sampling always stays on; memory, battery and SSD alerts keep their sampler running.")
        .font(.subheadline).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var graphs: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Charts") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("Line shape")
            Spacer()
            Picker("Line shape", selection: $preferences.graphLineStyle) {
              ForEach(HeliosGraphLineStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
          }
          Toggle("Continuous graph motion", isOn: $preferences.animateGraphUpdates)
          Toggle("Color available memory in the gauge", isOn: $preferences.memoryGaugeShowsAvailable)
          Text("Hover a chart to see the nearest real sample. Smooth only changes how the line is drawn between real samples.")
            .font(.subheadline).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      GroupBox("Default time range") {
        VStack(alignment: .leading, spacing: 8) {
          HeliosGraphRangePicker(
            range: Binding(
              get: { preferences.graphRange },
              set: { preferences.setAllGraphRanges($0) }))
          Text("Sets every chart to this range. Each page then remembers its own.")
            .font(.subheadline).foregroundStyle(.tertiary)
        }
      }
      GroupBox("Colors") {
        VStack(alignment: .leading, spacing: 10) {
          colorRoleGroup(
            "Modules", roles: HeliosColorRole.allCases.filter { $0.group == "Modules" })
          Divider().opacity(0.45)
          colorRoleGroup(
            "Network", roles: HeliosColorRole.allCases.filter { $0.group == "Network" })
          Divider().opacity(0.45)
          colorRoleGroup(
            "Memory breakdown",
            roles: HeliosColorRole.allCases.filter { $0.group == "Memory breakdown" })
          HStack {
            Spacer()
            Button("Reset Colors") { preferences.resetColors() }
          }
        }
      }
    }
  }

  private var batterySettings: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("How Helios reads your battery") {
        VStack(alignment: .leading, spacing: 8) {
          settingsFact("Time remaining", "macOS estimate; an early ≈ estimate while macOS calculates")
          Divider()
          settingsFact("Energy per app", "Relative ranking from local history")
          Divider()
          settingsFact("Charging", "Always managed by macOS")
        }
      }
      Text("Helios only reads battery data. It never changes charge limits, the charger or optimized charging.")
        .font(.subheadline).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var dashboard: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Quick presets") {
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 8) {
            ForEach(HeliosDashboardMode.allCases.filter { $0 != .custom }) { mode in
              Button(mode.label) {
                preferences.applyDashboardPreset(mode)
              }
              .frame(maxWidth: .infinity)
              .help(mode.onboardingDetail)
            }
          }
          Text(
            "A preset replaces the visible module list once. After that, add, remove, or reorder anything below — Helios does not lock you into a mode."
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(4)
      }

      if preferences.isPopoverModuleEnabled(.summary) {
        GroupBox("Summary metrics") {
          VStack(spacing: 0) {
            ForEach(preferences.dashboardMetrics) { metric in
              configurableDashboardMetricRow(metric)
              if preferences.dashboardMetrics.last != metric { Divider() }
            }
            let availableMetrics = HeliosDashboardMetric.allCases.filter {
              !preferences.isDashboardMetricEnabled($0)
            }
            if !availableMetrics.isEmpty {
              Divider().opacity(0.45)
              HStack {
                Text("Add")
                  .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(availableMetrics) { metric in
                  Button {
                    preferences.setDashboardMetricEnabled(metric, enabled: true)
                  } label: {
                    Image(systemName: metric.symbolName)
                  }
                  .buttonStyle(.borderless)
                  .help("Add \(metric.label)")
                  .accessibilityLabel("Add \(metric.label)")
                }
                Spacer()
              }
              .padding(.vertical, 7)
            }
          }
          .padding(.horizontal, 4)
        }
      }

      GroupBox("Visible modules") {
        VStack(spacing: 0) {
          ForEach(preferences.popoverModules) { module in
            configurablePopoverRow(module)
            if preferences.popoverModules.last != module { Divider() }
          }
          if preferences.popoverModules.isEmpty {
            Text("No dashboard modules are enabled.")
              .font(.system(size: 11)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 8)
          }
        }
        .padding(.horizontal, 4)
      }

      let available = HeliosPopoverModule.allCases.filter {
        !preferences.isPopoverModuleEnabled($0)
      }
      if !available.isEmpty {
        GroupBox("Add a module") {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(available) { module in
              Button {
                preferences.setPopoverModuleEnabled(module, enabled: true)
              } label: {
                Label(module.label, systemImage: module.symbolName)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .padding(4)
        }
      }

      HStack {
        Spacer()
        Button("Reset Dashboard to Recommended") { preferences.resetDashboard() }
      }
    }
  }

  private func configurablePopoverRow(_ module: HeliosPopoverModule) -> some View {
    HStack(spacing: 10) {
      Label(module.label, systemImage: module.symbolName)
      Spacer()
      Button {
        preferences.movePopoverModule(module, offset: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.popoverModules.first == module)
      .help("Move up")
      .accessibilityLabel("Move up")
      Button {
        preferences.movePopoverModule(module, offset: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.popoverModules.last == module)
      .help("Move down")
      .accessibilityLabel("Move down")
      Button(role: .destructive) {
        preferences.setPopoverModuleEnabled(module, enabled: false)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove from dashboard")
      .accessibilityLabel("Remove from dashboard")
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  private var monitor: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Sidebar modules") {
        VStack(spacing: 0) {
          ForEach(preferences.monitorRoutes) { route in
            configurableMonitorRow(route)
            if preferences.monitorRoutes.last != route { Divider() }
          }
        }
        .padding(.horizontal, 4)
      }

      let available = HeliosMonitorRoute.allCases.filter { !preferences.isMonitorRouteEnabled($0) }
      if !available.isEmpty {
        GroupBox("Add a module") {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(available) { route in
              Button {
                preferences.setMonitorRouteEnabled(route, enabled: true)
              } label: {
                Label(route.title, systemImage: route.symbol)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .padding(4)
        }
      }

      GroupBox("Behavior") {
        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Detailed Full Monitor content",
            isOn: Binding(
              get: { preferences.detailedMonitorContent },
              set: { preferences.setDetailedMonitorContent($0) })
          )
          Text(
            preferences.detailedMonitorContent
              ? "Detailed content exposes per-core/process/diagnostic context by default. Detailed and Custom onboarding presets enable this automatically."
              : "Essential content keeps Full Monitor focused. Hidden detail is not deleted and can be re-enabled at any time."
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
          Text(
            "Overview stays pinned as the landing page. Hidden sidebar modules are not deleted; you can add them back here at any time."
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
          HStack {
            Spacer()
            Button("Show All Modules") { preferences.resetMonitor() }
          }
        }
        .padding(4)
      }
    }
  }

  private func configurableMonitorRow(_ route: HeliosMonitorRoute) -> some View {
    HStack(spacing: 10) {
      Label(route.title, systemImage: route.symbol)
      if route == .overview {
        Text("Pinned").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
      }
      Spacer()
      Button {
        preferences.moveMonitorRoute(route, offset: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(route == .overview || preferences.monitorRoutes.firstIndex(of: route) == 1)
      .help("Move up")
      .accessibilityLabel("Move up")
      Button {
        preferences.moveMonitorRoute(route, offset: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(route == .overview || preferences.monitorRoutes.last == route)
      .help("Move down")
      .accessibilityLabel("Move down")
      Button(role: .destructive) {
        preferences.setMonitorRouteEnabled(route, enabled: false)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .disabled(route == .overview)
      .help(route == .overview ? "Overview is always available" : "Hide from Full Monitor")
      .accessibilityLabel(route == .overview ? "Overview is always available" : "Hide from Full Monitor")
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  private var menuBar: some View {
    VStack(alignment: .leading, spacing: 14) {
      GroupBox("Layout") {
        VStack(alignment: .leading, spacing: 9) {
          Picker(
            "Menu bar layout",
            selection: Binding(
              get: { preferences.menuBarLayout },
              set: { preferences.setMenuBarLayout($0) })
          ) {
            ForEach(HeliosMenuBarLayout.allCases) { layout in
              Text(layout.label).tag(layout)
            }
          }
          .pickerStyle(.segmented)
          Text(preferences.menuBarLayout.detail)
            .font(.system(size: 11)).foregroundStyle(.secondary)
          Label(
            preferences.menuBarLayout == .nativeModules
              ? "Separate modules can open their own metric popups. The Helios sun is an optional extra Dashboard hub."
              : "The whole compact group is one Helios item and opens the Dashboard, so there is no separate hub icon.",
            systemImage: preferences.menuBarLayout == .nativeModules
              ? "rectangle.3.group" : "rectangle.compress.vertical"
          )
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Metric spacing")
                .font(.system(size: 11, weight: .medium))
              Spacer()
              Text(String(format: "%.1f pt", preferences.menuBarSpacing))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
              Text("Compact").font(.system(size: 11)).foregroundStyle(.secondary)
              Slider(
                value: Binding(
                  get: { preferences.menuBarSpacing },
                  set: { preferences.setMenuBarSpacing($0) }),
                in: 0...8, step: 0.5
              )
              .accessibilityLabel("Menu bar metric spacing")
              Text("Roomy").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(
              preferences.menuBarLayout == .nativeModules
                ? "Removes Helios-owned padding down to the fixed text width. macOS still reserves its own separation between independent status items; Single compact group is the tightest layout."
                : "Controls the internal gap and fixed padding inside the single Helios item. At Compact, Helios adds no extra gap between metric slots."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          if preferences.menuBarLayout == .nativeModules {
            Toggle(
              "Show Helios dashboard hub",
              isOn: Binding(
                get: { preferences.showMenuBarHub },
                set: { preferences.setMenuBarHubVisible($0) })
            )
            .disabled(preferences.menuBarMetricsForPresentation.isEmpty)
            .help(
              preferences.menuBarMetricsForPresentation.isEmpty
                ? "The Helios hub stays visible when no metric modules are enabled so the app remains reachable."
                : "Adds the Helios solar mark as a separate status item that opens the complete dashboard."
            )
            Label(
              "Hold ⌘ and drag native modules directly in the menu bar to reorder them. macOS remembers each module's position.",
              systemImage: "command"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
          }
        }
        .padding(4)
      }

      GroupBox("Thermals in the menu bar") {
        Label(
          "Temperature & Fan shows the fan state (Fan off, or its RPM) above the temperature. Use Temperature for the temperature alone, or Fan for the fan alone.",
          systemImage: "thermometer.medium"
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
      }

      GroupBox("Preview") {
        HStack {
          Spacer(minLength: 0)
          HeliosMenuBarPreview(preferences: preferences)
          Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
      }

      GroupBox("Visible metrics") {
        VStack(spacing: 0) {
          ForEach(preferences.menuBarMetrics) { metric in
            configurableMenuBarRow(metric)
            if preferences.menuBarMetrics.last != metric { Divider() }
          }
          if preferences.menuBarMetrics.isEmpty {
            Text(
              "No metric modules are enabled. The optional Helios hub can still open the dashboard."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
          }
        }
        .padding(.horizontal, 4)
      }

      let available = HeliosMenuBarMetric.allCases.filter { !preferences.isEnabled($0) }
      if !available.isEmpty {
        GroupBox("Add a metric") {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(available) { metric in
              Button {
                preferences.setEnabled(metric, enabled: true)
              } label: {
                Label(metric.label, systemImage: metric.symbolName)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
          .padding(4)
        }
      }

      HStack {
        Spacer()
        Button("Reset Menu Bar") { preferences.resetMenuBar() }
      }
    }
  }

  private func configurableMenuBarRow(_ metric: HeliosMenuBarMetric) -> some View {
    let content = preferences.menuBarContent(for: metric)
    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 9) {
        Label(metric.label, systemImage: metric.symbolName)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: 120, alignment: .leading)
        // The cooling item's top line is the live fan state, so it has no label to edit.
        TextField(
          "Label",
          text: Binding(
            get: { preferences.label(for: metric) },
            set: { preferences.setLabel($0, for: metric) })
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 76)
        .disabled(!content.showLabel || metric == .cooling)
        .opacity(metric == .cooling ? 0 : 1)
        .help("Optional short label shown when Label is enabled")
        Spacer(minLength: 4)
        if preferences.menuBarLayout == .compactGroup {
          Button {
            preferences.move(metric, offset: -1)
          } label: {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.borderless)
          .disabled(preferences.menuBarMetrics.first == metric)
          .help("Move left inside the compact group")
          .accessibilityLabel("Move left inside the compact group")
          Button {
            preferences.move(metric, offset: 1)
          } label: {
            Image(systemName: "chevron.right")
          }
          .buttonStyle(.borderless)
          .disabled(preferences.menuBarMetrics.last == metric)
          .help("Move right inside the compact group")
          .accessibilityLabel("Move right inside the compact group")
        }
        Button(role: .destructive) {
          preferences.setEnabled(metric, enabled: false)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove from menu bar")
        .accessibilityLabel("Remove from menu bar")
      }

      HStack(spacing: 15) {
        Text("Show")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 120, alignment: .trailing)
        if metric != .cooling {
          Toggle(
            "Icon",
            isOn: Binding(
              get: { preferences.menuBarContent(for: metric).showIcon },
              set: { preferences.setMenuBarIconVisible($0, for: metric) })
          )
          Toggle(
            "Label",
            isOn: Binding(
              get: { preferences.menuBarContent(for: metric).showLabel },
              set: { preferences.setMenuBarLabelVisible($0, for: metric) })
          )
        }
        Toggle(
          "Value",
          isOn: Binding(
            get: { preferences.menuBarContent(for: metric).showValue },
            set: { preferences.setMenuBarValueVisible($0, for: metric) })
        )
        Spacer()
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .font(.system(size: 11))
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  private func configurableDashboardMetricRow(_ metric: HeliosDashboardMetric) -> some View {
    HStack(spacing: 10) {
      Label(metric.label, systemImage: metric.symbolName)
      Spacer()
      Button {
        preferences.moveDashboardMetric(metric, offset: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.dashboardMetrics.first == metric)
      .help("Move up")
      .accessibilityLabel("Move up")
      Button {
        preferences.moveDashboardMetric(metric, offset: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(preferences.dashboardMetrics.last == metric)
      .help("Move down")
      .accessibilityLabel("Move down")
      Button(role: .destructive) {
        preferences.setDashboardMetricEnabled(metric, enabled: false)
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Hide from System summary")
      .accessibilityLabel("Hide from System summary")
    }
    .font(.system(size: 11))
    .padding(.vertical, 7)
  }

  @ViewBuilder
  private func colorRoleGroup(_ title: String, roles: [HeliosColorRole]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
        ForEach(roles) { role in
          HStack(spacing: 8) {
            ColorPicker(
              role.label,
              selection: Binding(
                get: { preferences.color(for: role) },
                set: { preferences.setColorHex($0.heliosHex, for: role) }),
              supportsOpacity: true
            )
            .labelsHidden()
            .frame(width: 28)
            Text(role.label)
              .font(.system(size: 11))
              .lineLimit(1)
            Spacer(minLength: 0)
          }
        }
      }
    }
  }

  private var fans: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Fan helper") {
        VStack(alignment: .leading, spacing: 10) {
          DaemonServiceCard(service: service, client: service.client, embedded: true)
          Text("Fan control needs this signed helper. Install it here once; macOS asks for your approval. Reading temperatures and fan speed works without it.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if preferences.coolingFeaturesEnabled {
        HeliosFanLayerConsentBox(client: service.client)
      }
      GroupBox("Fan control") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle(
            "Enable cooling controls",
            isOn: Binding(
              get: { preferences.coolingFeaturesEnabled },
              set: { setCoolingEnabled($0) }))
          Text(preferences.coolingFeaturesEnabled
            ? "Boost, Manual and Automatic Rules are available on the Thermals page. System (macOS) stays the recommended mode."
            : "Fan-control UI is off. Fan speed can still be shown if Fan telemetry is on in Modules.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HeliosRestoreAutoToggle(
            model: service.fanControl, isEnabled: preferences.coolingFeaturesEnabled)
          HStack {
            Button("Show safety guide again") {
              // Starting over also forgets a remembered Auto, so it is not re-armed before the guide is acknowledged.
              service.fanControl.setMode(.system)
              preferences.resetFanSafetyGuide()
            }
              .disabled(!preferences.fanSafetyGuideCompleted)
            Spacer()
          }
        }
      }
      DisclosureGroup("Safety model") {
        VStack(alignment: .leading, spacing: 8) {
          HeliosFanSafetyNotice()
          Text("The helper is a macOS LaunchDaemon: once registered, macOS may start it at boot even when Helios is closed. Uninstall it here if you do not want it registered at all.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
      }
    }
  }

  private var privacy: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("What stays on this Mac") {
        VStack(alignment: .leading, spacing: 8) {
          settingsFact("Analytics", "None")
          Divider()
          settingsFact("Network", backgroundNetworkSummary)
          Divider()
          settingsFact("Battery and fans", "Read-only; fan control only via the helper")
          Divider()
          settingsFact("Microphone", "Never requested")
        }
      }
      GroupBox("Beta diagnostics") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle(
            "Share anonymous beta diagnostics",
            isOn: Binding(
              get: { diagnosticsPreferences.automaticEnabled },
              set: { diagnostics.setAutomaticEnabled($0) }))
          settingsFact("Last report", diagnosticsLastSuccessfulReport)
          if diagnosticsPreferences.automaticEnabled {
            settingsFact("Next report", diagnosticsPreferences.nextEligibleTime?
              .formatted(date: .abbreviated, time: .shortened) ?? "Waiting for scheduling")
          }
          if diagnostics.sending { Text("Sending a report…").foregroundStyle(.secondary) }
          if diagnosticsPreferences.lastReportStatus == .failed {
            Text("Last failure: \(diagnosticsPreferences.lastStatusCategory.rawValue)")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          Divider()
          Toggle(
            "Include fan-control statistics",
            isOn: Binding(
              get: { diagnosticsPreferences.fanStatisticsEnabled },
              set: { diagnosticsPreferences.setFanStatisticsEnabled($0) }))
          Text("Adds how the fan layer behaved since Helios started: how many takeovers macOS accepted or refused, how long they took, and the highest temperature and fan speed as ranges. Off by default, kept in memory only, and never needed for fan control.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Divider()
          HStack {
            Button("View what is shared", action: showAutomaticPreview)
            Button("Send report now…", action: showManualHealthPreview)
            Button("Compatibility report…", action: beginCompatibilityReport)
            Spacer(minLength: 0)
          }
          Text("Off by default. Reports contain no identities, clicks or raw samples. You always see the exact data first, and manual reports need a separate Send.")
            .font(.subheadline).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      HStack {
        Button("Privacy information") { open("https://snejda.cz/helios/privacy") }
        Text("helios@snejda.cz").foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
  }

  private func settingsFact(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer(minLength: 12)
      Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
  }

  private var backgroundNetworkSummary: String {
    switch (updateChecker.automaticallyChecksForUpdates, diagnosticsPreferences.automaticEnabled) {
    case (true, true): "Automatic update checks + optional beta diagnostics"
    case (true, false): "Automatic update checks"
    case (false, true): "Optional beta diagnostics"
    case (false, false): "None; manual update checks remain available"
    }
  }

  private var lastSuccessfulUpdateCheck: String {
    updateChecker.lastSuccessfulCheck?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
  }

  private var diagnosticsLastSuccessfulReport: String {
    diagnosticsPreferences.lastSuccessfulReport?.formatted(date: .abbreviated, time: .shortened)
      ?? "Never"
  }

  private func showAutomaticPreview() {
    do {
      diagnosticsPreview = try diagnostics.makeHealthPayload(
        type: .automaticHealth,
        reason: diagnosticsPreferences.lastSuccessfulAutomaticSend == nil ? .initialOptIn : .daily)
      previewAllowsSend = false
      manualSendCompleted = false
      diagnosticsStatus = nil
      manualApproval.invalidate()
      showingDiagnosticsPreview = true
    } catch {
      diagnosticsStatus = "A safe diagnostics preview is not available yet. Nothing was sent."
    }
  }

  private func showManualHealthPreview() {
    do {
      let payload = try diagnostics.makeHealthPayload(
        type: .manualHealth, reason: .userInitiated)
      manualApproval.setFrozen(payload)
      diagnosticsPreview = manualApproval.payload
      previewAllowsSend = true
      manualSendCompleted = false
      diagnosticsStatus = nil
      showingDiagnosticsPreview = true
    } catch {
      diagnosticsStatus = "A safe manual report could not be created. Nothing was sent."
    }
  }

  private func beginCompatibilityReport() {
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    diagnosticsStatus = nil
    compatibilityStatus = nil
    compatibilityTransitioningToPreview = false
    showingCompatibilityConsent = true
  }

  private func cancelCompatibilityReport() {
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    compatibilityStatus = nil
    compatibilityTransitioningToPreview = false
    showingCompatibilityConsent = false
  }

  private func compatibilityConsentDismissed() {
    if compatibilityTransitioningToPreview {
      compatibilityTransitioningToPreview = false
      return
    }
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    compatibilityStatus = nil
  }

  private func dismissDiagnosticsPreview() {
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    diagnosticsStatus = nil
  }

  private func generateCompatibilityPreview() {
    let transitioningFromConsent = showingCompatibilityConsent
    manualApproval.invalidate()
    diagnosticsPreview = nil
    previewAllowsSend = false
    manualSendCompleted = false
    generatingCompatibility = true
    compatibilityStatus = "Reading bounded compatibility metadata…"
    Task {
      do {
        let payload = try await diagnostics.makeCompatibilityPayload()
        manualApproval.setFrozen(payload)
        diagnosticsPreview = manualApproval.payload
        previewAllowsSend = true
        diagnosticsStatus = nil
        compatibilityStatus = nil
        generatingCompatibility = false
        if transitioningFromConsent {
          compatibilityTransitioningToPreview = true
          showingCompatibilityConsent = false
        }
        showingDiagnosticsPreview = true
      } catch {
        generatingCompatibility = false
        compatibilityStatus =
          "A safe compatibility preview could not be created. Nothing was sent."
      }
    }
  }

  private func sendApprovedManualReport() {
    guard let payload = manualApproval.approve() else {
      diagnosticsStatus = "This preview expired. Regenerate it before sending."
      return
    }
    Task {
      let result = await diagnostics.sendManual(payload)
      switch result {
      case .accepted:
        diagnosticsStatus = "Report sent successfully."
        manualSendCompleted = true
      case .retryable:
        diagnosticsStatus = "Send failed. The same frozen preview can be retried explicitly."
      case .rejected:
        diagnosticsStatus = "The report was rejected and was not accepted."
      case .cancelled:
        diagnosticsStatus = "Send cancelled."
      }
    }
  }

  private var advanced: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Interface") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Button("Reset interface settings") { preferences.resetInterface() }
            Button("Show welcome setup next launch") { preferences.markOnboardingIncomplete() }
            Spacer(minLength: 0)
          }
          Text("Only layout preferences. The helper, fan control and monitoring history are untouched.")
            .font(.subheadline).foregroundStyle(.tertiary)
        }
      }
      GroupBox("Raw sensors") {
        VStack(alignment: .leading, spacing: 6) {
          settingsFact("Where",
            interface.style == .helios ? "Hardware → Raw SMC inventory" : "Full Monitor → Expert")
          Text("Raw values are for experts and never drive cooling unless separately validated.")
            .font(.subheadline).foregroundStyle(.tertiary)
        }
      }
      GroupBox("Remove Helios") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("Erase local Helios settings and monitoring history", isOn: $eraseLocalDataOnRemoval)
          Button("Prepare for removal…") { showingPrepareRemoval = true }
          Text("Returns fans to macOS, turns off Launch at Login and unregisters the helper. Then move Helios.app to the Trash.")
            .font(.subheadline).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
          if let removalStatus {
            Text(removalStatus).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
    }
    .alert("Prepare Helios for Removal?", isPresented: $showingPrepareRemoval) {
      Button("Cancel", role: .cancel) {}
      Button("Prepare", role: .destructive) {
        Task { await prepareForRemoval() }
      }
    } message: {
      Text(
        eraseLocalDataOnRemoval
          ? "Helios will return fan control to macOS, disable Launch at Login, unregister its helper, erase its local preferences/history and then quit. Move the app to Trash afterwards."
          : "Helios will return fan control to macOS, disable Launch at Login and unregister its helper. Monitoring history and preferences will be kept."
      )
    }
  }

  private func prepareForRemoval() async {
    removalStatus = "Preparing removal…"
    service.fanControl.setMode(.system)

    if service.launchAtLoginEnabled || service.launchAtLoginRequiresApproval {
      guard await service.setLaunchAtLogin(false) else {
        removalStatus =
          "Removal stopped: Launch at Login could not be disabled. Resolve the Service Management state and try again; no local data was erased."
        return
      }
    }

    if service.state == .installed || service.state == .requiresApproval {
      guard await service.uninstall() else {
        removalStatus =
          "Removal stopped: the privileged helper is still registered. Resolve the helper state and try again; no local data was erased."
        return
      }
    }

    guard eraseLocalDataOnRemoval else {
      removalStatus =
        "Helios is prepared for removal. The helper is unregistered and Launch at Login is off; you can move Helios.app to Trash."
      return
    }

    eraseLocalHeliosData()
    // Persistent/history services must not get another opportunity to recreate
    // files after a complete cleanup. The app cannot delete its own bundle, so
    // terminate cleanly and let the user move Helios.app to Trash.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
  }

  private func eraseLocalHeliosData() {
    let fileManager = FileManager.default
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    let heliosDirectory = base.appendingPathComponent("Helios", isDirectory: true)
    try? fileManager.removeItem(at: heliosDirectory)

    let domain = Bundle.main.bundleIdentifier ?? HeliosServiceIdentity.appIdentifier
    UserDefaults.standard.removePersistentDomain(forName: domain)
    UserDefaults.standard.synchronize()
  }

  private var about: some View {
    VStack(spacing: 14) {
      Spacer()
      HeliosApplicationIcon(size: 64)
      Text("Helios").font(.system(size: 28, weight: .semibold))
      Text("Native macOS system monitoring and fan control").foregroundStyle(.secondary)
      Text("Created by Jakub Šnejda").font(.system(size: 13, weight: .medium))
      Text(versionText).font(.system(size: 11)).foregroundStyle(.tertiary)
      Button(updateChecker.isChecking ? "Checking for Updates…" : "Check for Updates Now…") {
        HeliosUpdatePresenter.shared.check(manual: true)
      }
      .disabled(updateChecker.isChecking)
      Text("Last checked: \(lastSuccessfulUpdateCheck)")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      Button("Copy System Snapshot") {
        HeliosWindowCoordinator.copySystemSnapshot(diagnostics.session.commonFields())
      }
      .help("Copies version, coarse hardware identity and provider state. No names, paths, serial numbers or network identifiers.")

      HStack {
        Button("snejda.cz") { open("https://www.snejda.cz") }
        Button("GitHub") { open("https://github.com/Snejdik/helios") }
        Button("Report Issue") { open("https://github.com/Snejdik/helios/issues") }
        Button("Contact") { open("mailto:helios@snejda.cz") }
      }

      VStack(spacing: 8) {
        Label("Support Helios", systemImage: "cup.and.saucer")
          .font(.system(size: 13, weight: .semibold))
        Text(
          "Helios is independently developed and free to use. If you find it useful and want to support continued development, you can buy me a coffee."
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        Button("Buy Me a Coffee") { open("https://buymeacoffee.com/snejda") }
          .buttonStyle(.borderedProminent)
      }
      .padding(14)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

      Text("Battery telemetry is read-only. Fan control is isolated in the privileged helper.")
        .font(.system(size: 11)).foregroundStyle(.tertiary)
      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 390)
  }

  private var versionText: String {
    HeliosReleaseVersion.aboutText(
      tag: Bundle.main.object(forInfoDictionaryKey: "HeliosReleaseTag") as? String,
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
  }

  private func open(_ value: String) {
    guard let url = URL(string: value) else { return }
    NSWorkspace.shared.open(url)
  }
}

private struct HeliosMenuBarPreview: View {
  @ObservedObject var preferences: HeliosPreferences

  private var metrics: [HeliosMenuBarMetric] {
    preferences.menuBarMetricsForPresentation
  }

  private var previewGap: CGFloat {
    max(0, min(4, CGFloat(preferences.menuBarSpacing) * 0.45))
  }

  var body: some View {
    HStack(spacing: preferences.menuBarLayout == .compactGroup ? previewGap : 1) {
      if preferences.menuBarLayout == .nativeModules,
        preferences.showMenuBarHub || metrics.isEmpty
      {
        HeliosBrandMark(size: 16, colored: false)
          .frame(width: 24, height: 28)
          .background(Color.secondary.opacity(0.10), in: Capsule())
      }
      if metrics.isEmpty, !preferences.showMenuBarHub {
        Text("No menu-bar modules").font(.system(size: 11)).foregroundStyle(.secondary)
      } else {
        ForEach(metrics) { metric in
          previewMetric(metric)
            .fixedSize(horizontal: true, vertical: false)
            .frame(
              minWidth: max(
                24,
                CGFloat(metric.statusWidth)
                  + CGFloat(preferences.menuBarSpacing) * 0.55 - 4),
              minHeight: 28
            )
            .background(
              preferences.menuBarLayout == .nativeModules
                ? Color.secondary.opacity(0.08) : Color.clear,
              in: Capsule())
        }
      }
    }
    .padding(.horizontal, 9).padding(.vertical, 5)
    .foregroundStyle(.primary)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
    )
    .accessibilityLabel("Menu bar preview")
  }

  @ViewBuilder
  private func previewMetric(_ metric: HeliosMenuBarMetric) -> some View {
    let content = preferences.menuBarContent(for: metric)
    if metric == .cooling, content.showValue {
      VStack(spacing: -1) {
        Text("Fan off").font(.system(size: 7.5, weight: .medium).monospacedDigit())
        Text(sample(metric)).font(.system(size: 11, weight: .semibold).monospacedDigit())
      }
    } else if content.showValue && (content.showIcon || content.showLabel) {
      VStack(spacing: -1) {
        previewIdentity(metric, content: content)
        Text(sample(metric)).font(.system(size: 11, weight: .semibold).monospacedDigit())
      }
    } else if content.showValue {
      Text(sample(metric)).font(.system(size: 11, weight: .semibold).monospacedDigit())
    } else {
      previewIdentity(metric, content: content)
    }
  }

  @ViewBuilder
  private func previewIdentity(_ metric: HeliosMenuBarMetric, content: HeliosMenuBarContent)
    -> some View
  {
    HStack(spacing: 2) {
      if content.showIcon {
        Image(systemName: metric.symbolName).font(.system(size: 8.2, weight: .medium))
      }
      if content.showLabel {
        Text(preferences.label(for: metric)).font(.system(size: 7.5, weight: .medium))
      }
    }
  }

  private func sample(_ metric: HeliosMenuBarMetric) -> String {
    switch metric {
    case .cpu: "8%"
    case .memory: "58%"
    case .gpu: "22%"
    case .temperature, .cooling: String(format: "%.0f°", TemperatureUnit.current.convert(48))
    case .fan: "Off"
    case .battery: "92%"
    case .power: "5W"
    case .network: "650K"
    }
  }
}

/// Notification sensitivity presets over the existing per-rule configuration.
enum HeliosAlertSensitivity: Hashable {
  case critical, recommended, everything, custom

  static let selectable: [HeliosAlertSensitivity] = [.critical, .recommended, .everything]

  var title: String {
    switch self {
    case .critical: "Critical only"
    case .recommended: "Recommended"
    case .everything: "Everything"
    case .custom: "Custom"
    }
  }

  var detail: String {
    switch self {
    case .critical: "Only when something needs action now: critical temperatures, memory, battery or SSD."
    case .recommended: "Critical problems plus early warnings worth knowing. Short, common spikes (elevated memory or thermal pressure) stay quiet."
    case .everything: "Every warning Helios can detect, including short spikes."
    case .custom: "Your own selection below."
    }
  }

  static let criticalRules: Set<HealthAlertRule> = [
    .socCritical, .batteryHealthCritical, .batteryTempCritical, .ssdTempCritical,
    .thermalCritical, .memoryCritical, .smartCritical, .mediaErrors,
  ]

  var enabledRules: Set<HealthAlertRule>? {
    switch self {
    case .critical: Self.criticalRules
    case .recommended: Set(HealthAlertRule.allCases).subtracting([.memoryWarning, .thermalSerious])
    case .everything: Set(HealthAlertRule.allCases)
    case .custom: nil
    }
  }

  static func current(_ configuration: HealthAlertConfiguration) -> HeliosAlertSensitivity {
    let enabled = Set(HealthAlertRule.allCases.filter { configuration[$0].enabled })
    return selectable.first { $0.enabledRules == enabled } ?? .custom
  }

  @MainActor func apply(to preferences: HeliosPreferences) {
    guard let rules = enabledRules else { return }
    for rule in HealthAlertRule.allCases { preferences.setHealthAlert(rule, enabled: rules.contains(rule)) }
  }
}

struct HeliosAlertPair {
  let title: String
  let rules: [HealthAlertRule]
  var firstLabel = "Warn"
  var secondLabel = "Critical"
  var note: String? = nil
}

struct HeliosAlertGroup {
  let title: String
  let pairs: [HeliosAlertPair]

  static let all: [HeliosAlertGroup] = [
    HeliosAlertGroup(title: "Temperature", pairs: [
      HeliosAlertPair(title: "Chip (SoC)", rules: [.socHot, .socCritical]),
      HeliosAlertPair(title: "macOS thermal pressure", rules: [.thermalSerious, .thermalCritical],
                      firstLabel: "Serious", note: "Reported by macOS"),
    ]),
    HeliosAlertGroup(title: "Battery", pairs: [
      HeliosAlertPair(title: "Battery temperature", rules: [.batteryTempHot, .batteryTempCritical]),
      HeliosAlertPair(title: "Battery health", rules: [.batteryHealthLow, .batteryHealthCritical],
                      firstLabel: "Reduced", secondLabel: "Very low"),
    ]),
    HeliosAlertGroup(title: "Storage", pairs: [
      HeliosAlertPair(title: "SSD temperature", rules: [.ssdTempHot, .ssdTempCritical]),
      HeliosAlertPair(title: "SSD health (SMART)", rules: [.smartAttention, .smartCritical],
                      firstLabel: "Attention", note: "Reported by the SSD"),
      HeliosAlertPair(title: "SSD media errors", rules: [.mediaErrors], secondLabel: "Any new error"),
    ]),
    HeliosAlertGroup(title: "Memory", pairs: [
      HeliosAlertPair(title: "Memory pressure", rules: [.memoryWarning, .memoryCritical],
                      firstLabel: "Elevated", note: "Reported by macOS"),
    ]),
  ]
}
