import AppKit
import SwiftUI

/// Everything a Helios surface needs, passed explicitly. `service` is nil
/// for deterministic fixtures, which therefore can never reach helper/fan code.
@MainActor
struct HeliosContext {
  let model: OverviewViewModel
  let preferences: HeliosPreferences
  let service: DaemonService?
  let feed: HeliosActivityFeed
  var actions = HeliosActions()
  /// Lets the Overview offer the diagnostics reminder; nil in fixtures.
  var diagnosticsPreferences: DiagnosticsPreferences? = nil

  var interface: HeliosInterfacePreferences { preferences.interface }
}

/// App-level actions owned by the window coordinator / status item controller.
@MainActor
struct HeliosActions {
  var openSettings: () -> Void = {}
  var openSettingsRoute: (HeliosSettingsRoute) -> Void = { _ in }
  var openEnergyInspector: () -> Void = {}
  var openPage: (HeliosPage) -> Void = { _ in }
  var copySystemSnapshot: () -> Void = {}
}

@MainActor
final class HeliosNavigation: ObservableObject {
  var onSelectionChange: (() -> Void)?
  @Published var selection: HeliosPage? = .overview {
    didSet { if oldValue != selection { onSelectionChange?() } }
  }
}

/// Root of the Helios main window.
struct HeliosMainWindowView: View {
  let context: HeliosContext
  @ObservedObject var navigation: HeliosNavigation
  @ObservedObject var interface: HeliosInterfacePreferences

  init(context: HeliosContext, navigation: HeliosNavigation) {
    self.context = context
    self.navigation = navigation
    interface = context.preferences.interface
  }

  var body: some View {
    NavigationSplitView {
      HeliosSidebar(context: context, navigation: navigation, pages: interface.visiblePages)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
    } detail: {
      HeliosPageContainer(page: currentPage, context: context, navigation: navigation)
        .navigationTitle(currentPage.title)
    }
    .onChange(of: interface.hiddenPages) { _ in
      if !interface.visiblePages.contains(currentPage) { navigation.selection = .overview }
    }
  }

  private var currentPage: HeliosPage {
    guard let selection = navigation.selection, interface.visiblePages.contains(selection)
    else { return .overview }
    return selection
  }
}

private struct HeliosSidebar: View {
  let context: HeliosContext
  @ObservedObject var navigation: HeliosNavigation
  let pages: [HeliosPage]

  var body: some View {
    List(selection: $navigation.selection) {
      ForEach(pages.filter { $0.section == .main }) { simpleRow($0) }
      let components = pages.filter { $0.section == .components }
      if !components.isEmpty {
        Section("Components") {
          ForEach(components) { page in
            HeliosSidebarComponentRow(
              page: page, model: context.model, preferences: context.preferences)
              .tag(page)
          }
        }
      }
      let insights = pages.filter { $0.section == .insights }
      if !insights.isEmpty {
        Section("Insights") { ForEach(insights) { simpleRow($0) } }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) { HeliosSupportRow() }
  }

  private func simpleRow(_ page: HeliosPage) -> some View {
    // Design direction: icons are monochrome secondary; color is reserved for state.
    Label {
      Text(page.title)
    } icon: {
      Image(systemName: page.symbol).foregroundStyle(.secondary)
    }
    .tag(page)
  }
}

/// A component with its live value underneath, plus a badge only when it needs
/// attention. Observes the model in this small view so the 1 Hz sample never
/// re-evaluates the whole sidebar.
private struct HeliosSidebarComponentRow: View {
  let page: HeliosPage
  @ObservedObject var model: OverviewViewModel
  let preferences: HeliosPreferences

  var body: some View {
    let status = page.area.map {
      HeliosMacAssessment.area($0, snapshot: model.snapshot, configuration: preferences.healthAlerts)
    }.flatMap { page.shows($0) ? $0 : nil }
    HStack(spacing: 8) {
      Image(systemName: page.symbol).foregroundStyle(.secondary).frame(width: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(page.title)
        Text(HeliosSidebarSummary.text(for: page, presentation: model.presentation, assessment: status))
          .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
      }
      Spacer(minLength: 4)
      if let status = status?.status, status.isProblem {
        Image(systemName: HeliosDesign.symbol(status))
          .font(.system(size: 11))
          .foregroundStyle(HeliosDesign.color(status))
          .accessibilityLabel(status.label)
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
  }
}

extension HeliosPage {
  /// The page that explains an assessment: memory pressure opens Memory, any
  /// other Performance finding opens CPU.
  init(focus assessment: HeliosAreaAssessment) {
    if assessment.area == .performance, assessment.chartMetric == .memory {
      self = .memory
    } else {
      self.init(assessment.area)
    }
  }

  /// CPU and Memory share the Performance assessment; each shows only its own finding.
  func shows(_ assessment: HeliosAreaAssessment) -> Bool {
    switch self {
    case .memory: assessment.chartMetric == .memory || !assessment.status.isProblem
    case .cpu: assessment.chartMetric != .memory || !assessment.status.isProblem
    default: true
    }
  }
}

/// The one-line live value shown under a component's name. Pure.
enum HeliosSidebarSummary {
  static func text(
    for page: HeliosPage, presentation p: OverviewPresentation, assessment: HeliosAreaAssessment?
  ) -> String {
    switch page {
    case .cpu:
      return (try? p.cpu.get()).map { TelemetryFormatting.percent($0.usagePercent) } ?? "—"
    case .gpu:
      return (try? p.gpu.flatMap(\.deviceUtilizationPercent).get()).map { TelemetryFormatting.percent($0) } ?? "—"
    case .memory:
      guard let memory = try? p.memory.get() else { return "—" }
      let used = TelemetryFormatting.percent(memory.usagePercent)
      return (try? memory.pressure.get()).map { "\(used) · \($0.rawValue)" } ?? used
    case .thermals:
      let temperature = (try? p.thermals.flatMap(\.maximumSoCCelsius).get())
        .map { TelemetryFormatting.temperature($0) } ?? "—"
      guard let fans = try? p.fans.get() else { return temperature }
      return "\(temperature) · \(TelemetryFormatting.fanSummary(fans))"
    case .battery:
      if assessment?.status == .notPresent { return "No battery" }
      return assessment?.value ?? "—"
    case .energy:
      guard let battery = try? p.battery.get(), let power = try? battery.power.get() else { return "—" }
      return TelemetryFormatting.watts(power.signedWatts, signed: true)
    case .storage:
      return assessment?.value ?? "—"
    case .network:
      guard let rate = try? p.network.flatMap(\.throughput).get() else { return "—" }
      return "↓ \(TelemetryFormatting.bytesPerSecond(rate.downloadBytesPerSecond))"
    case .hardware:
      return (try? p.system.flatMap(\.modelIdentifier).get()) ?? "—"
    case .overview, .activity, .history, .diagnostics:
      return ""
    }
  }
}

extension HeliosMacAssessment {
  /// Single-area evaluation for badges and area pages.
  static func area(
    _ area: HeliosArea, snapshot: TelemetrySnapshot, now: Date = Date(),
    configuration: HealthAlertConfiguration
  ) -> HeliosAreaAssessment {
    switch area {
    case .performance: performance(snapshot, now: now)
    case .thermals: thermals(snapshot, now: now, configuration: configuration)
    case .battery: battery(snapshot, now: now, configuration: configuration)
    case .storage: storage(snapshot, now: now, configuration: configuration)
    }
  }
}

/// Scrollable page body with consistent width and padding.
private struct HeliosPageContainer: View {
  let page: HeliosPage
  let context: HeliosContext
  let navigation: HeliosNavigation

  var body: some View {
    ScrollView {
      Group {
        switch page {
        case .overview: HeliosOverviewPage(context: context, model: context.model,
          interface: context.interface, feed: context.feed, navigation: navigation)
        case .activity: HeliosActivityPage(feed: context.feed)
        case .history: HeliosHistoryPage(context: context, model: context.model, feed: context.feed)
        case .diagnostics: HeliosDiagnosticsPage(context: context, model: context.model)
        case .cpu: HeliosCPUPage(context: context, model: context.model)
        case .gpu: HeliosGPUPage(context: context, model: context.model)
        case .memory: HeliosMemoryPage(context: context, model: context.model)
        case .thermals: HeliosThermalsPage(context: context, model: context.model)
        case .battery: HeliosBatteryPage(context: context, model: context.model)
        case .energy: HeliosEnergyPage(context: context, model: context.model)
        case .storage: HeliosStoragePage(context: context, model: context.model)
        case .network: HeliosNetworkPage(context: context, model: context.model)
        case .hardware: HeliosHardwarePage(context: context, model: context.model)
        }
      }
      .padding(HeliosDesign.pagePadding)
      .frame(maxWidth: HeliosDesign.maxContentWidth, alignment: .topLeading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    // A new page starts at the top with its disclosures collapsed.
    .id(page)
  }
}

/// Header used by every Health page: status, one sentence, Why?, key value.
struct HeliosAreaHeader: View {
  let assessment: HeliosAreaAssessment
  let meaning: String
  var valueCaption: String? = nil
  /// Thermals shows its value in the temperature/fan block right below instead.
  var showsValue = true
  /// A page that shows one part of an area (Memory of Performance) shows its own value.
  var valueOverride: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          HeliosStatusLabel(status: assessment.status, prominent: true)
          Text(assessment.explanation)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 16)
        if showsValue, let value = valueOverride ?? assessment.value {
          HeliosHeadlineValue(value: value, caption: valueCaption ?? "")
        }
      }
      HeliosWhyDisclosure(assessment: assessment, meaning: meaning)
    }
  }
}

/// Owns the Helios main window's navigation and Activity feed; both are released
/// with the window. The telemetry model is shared and never owned here.
@MainActor
final class HeliosMainWindowController: NSWindowController {
  static let frameName = "Helios.Main"
  private let navigation = HeliosNavigation()
  private let feed: HeliosActivityFeed

  init(
    model: OverviewViewModel, preferences: HeliosPreferences, service: DaemonService?,
    actions: HeliosActions, diagnosticsPreferences: DiagnosticsPreferences? = nil,
    onPageChange: @escaping () -> Void
  ) {
    feed = HeliosActivityFeed(model: model)
    let context = HeliosContext(
      model: model, preferences: preferences, service: service, feed: feed, actions: actions,
      diagnosticsPreferences: diagnosticsPreferences)
    let hosting = NSHostingController(
      rootView: HeliosMainWindowView(context: context, navigation: navigation))
    let window = NSWindow(contentViewController: hosting)
    window.title = "Helios"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.applyHeliosChrome(toolbar: "Helios.Main.Toolbar")
    window.contentMinSize = NSSize(width: 820, height: 560)
    window.setContentSize(NSSize(width: 1040, height: 720))
    window.isReleasedWhenClosed = false
    window.center()
    // Restore before registering autosave, as for Settings.
    _ = window.setFrameUsingName(Self.frameName)
    window.clampContentToMinimum()
    _ = window.setFrameAutosaveName(Self.frameName)
    super.init(window: window)
    navigation.onSelectionChange = onPageChange
  }

  required init?(coder: NSCoder) { nil }

  func select(_ page: HeliosPage) { navigation.selection = page }
  var selectedPage: HeliosPage { navigation.selection ?? .overview }

  /// Saves the frame and releases the autosave name before the tree is detached.
  func prepareForClose() {
    guard let window else { return }
    window.saveFrame(usingName: Self.frameName)
    _ = window.setFrameAutosaveName("")
  }
}
