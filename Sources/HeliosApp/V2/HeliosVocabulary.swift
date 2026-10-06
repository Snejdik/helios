import Foundation

// Dependency-free vocabulary shared by the Helios interface, its
// preferences and the standalone preference/fixture probes.

/// Health areas of the Helios interface. Network and Hardware are pages,
/// not assessed areas: they describe the Mac rather than judge it.
enum HeliosArea: String, CaseIterable, Identifiable, Sendable {
  case performance, thermals, battery, storage

  var id: String { rawValue }
  var title: String {
    switch self {
    case .performance: "Performance"
    case .thermals: "Thermals"
    case .battery: "Battery"
    case .storage: "Storage"
    }
  }
  var symbol: String {
    switch self {
    case .performance: "cpu"
    case .thermals: "thermometer.medium"
    case .battery: "battery.75percent"
    case .storage: "internaldrive"
    }
  }
}

/// Metrics the Helios charts can show. The automatic Overview chart follows the
/// area that currently needs attention.
enum HeliosChartMetric: String, CaseIterable, Identifiable, Sendable {
  case cpu, gpu, memory, temperature, power, fan, battery, network, networkUpload, disk

  var id: String { rawValue }
  var title: String {
    switch self {
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .memory: "Memory"
    case .temperature: "Temperature"
    case .power: "System Power"
    case .fan: "Fan"
    case .battery: "Battery"
    case .network: "Download"
    case .networkUpload: "Upload"
    case .disk: "Disk"
    }
  }
}
