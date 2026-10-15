import Foundation

/// The sections of the retired 0.1 monitor window. Kept as a stored preference: the
/// module list still decides which samplers run (`HeliosPreferences`).
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
