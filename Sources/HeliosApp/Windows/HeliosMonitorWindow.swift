import AppKit
import SwiftUI

enum HeliosMonitorRoute: String, CaseIterable, Identifiable, Sendable {
  case overview, cpu, memory, gpu, thermals, battery, energy, storage, network, processes, history,
    health,
    system, devices, maintenance, expert
  var id: String { rawValue }
  var title: String {
    switch self {
    case .overview: "Overview"
    case .cpu: "CPU"
    case .memory: "Memory"
    case .gpu: "GPU"
    case .thermals: "Thermals & Fans"
    case .battery: "Battery"
    case .energy: "Energy"
    case .storage: "Storage"
    case .network: "Network"
    case .processes: "Processes"
    case .history: "History"
    case .health: "Health & Alerts"
    case .system: "System"
    case .devices: "Devices"
    case .maintenance: "Maintenance"
    case .expert: "Expert"
    }
  }
  var symbol: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .gpu: "display"
    case .thermals: "thermometer.medium"
    case .battery: "battery.75percent"
    case .energy: "chart.bar.xaxis"
    case .storage: "internaldrive"
    case .network: "network"
    case .processes: "list.bullet.rectangle"
    case .history: "clock.arrow.circlepath"
    case .health: "heart.text.square"
    case .system: "macbook"
    case .devices: "macbook.and.iphone"
    case .maintenance: "wrench.and.screwdriver"
    case .expert: "slider.horizontal.3"
    }
  }
}

enum HeliosExpertSection: String, CaseIterable, Identifiable {
  case complete = "All Diagnostics"
  case sensors = "Sensors"
  case telemetry = "Telemetry"
  case services = "Services"
  case logs = "Logs"

  var id: String { rawValue }
}

@MainActor
final class HeliosMonitorNavigation: ObservableObject {
  var onSelectionChange: (() -> Void)?
  @Published var selection: HeliosMonitorRoute? = .overview {
    didSet { onSelectionChange?() }
  }
}

extension HeliosMonitorRoute {
  var detailDemand: TelemetryDetailDemand {
    switch self {
    case .overview, .cpu, .memory, .gpu, .battery, .energy, .storage, .processes: .processes
    case .thermals: .rawSensors
    case .devices, .system: .devices
    case .expert: .all
    case .network, .history, .health, .maintenance: []
    }
  }
}

struct HeliosMonitorWindowView: View {
  @ObservedObject var model: OverviewViewModel
  @ObservedObject var service: DaemonService
  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var navigation: HeliosMonitorNavigation
  let openEnergyInspector: () -> Void

  var body: some View {
    NavigationSplitView {
      List(preferences.monitorRoutesForPresentation, selection: $navigation.selection) { route in
        Label(route.title, systemImage: route.symbol).tag(route)
      }
      .navigationTitle("Helios")
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
    } detail: {
      ScrollView {
        HeliosModuleDetail(
          route: navigation.selection ?? .overview, model: model, service: service,
          preferences: preferences, openEnergyInspector: openEnergyInspector
        )
        .padding(20)
        .frame(maxWidth: 1280, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .navigationTitle((navigation.selection ?? .overview).title)
    }
    .onReceive(preferences.$monitorRoutes) { _ in
      repairNavigationSelectionAfterPreferenceMutation()
    }
    .onReceive(preferences.$telemetryModules) { _ in
      // Collection and presentation are persisted independently. When a
      // sampler stops or resumes, the visible route list must update without
      // destroying the user's saved order or requiring an app restart.
      repairNavigationSelectionAfterPreferenceMutation()
    }
  }

  private func repairNavigationSelectionAfterPreferenceMutation() {
    // @Published emits before the property mutation is visible through the
    // observed object. Defer one main-loop turn, then validate against the
    // regenerated presentation surface.
    DispatchQueue.main.async {
      let routes = preferences.monitorRoutesForPresentation
      guard let selection = navigation.selection, routes.contains(selection) else {
        navigation.selection = .overview
        return
      }
    }
  }
}
