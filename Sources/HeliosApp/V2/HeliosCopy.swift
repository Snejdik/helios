import Foundation

/// User-facing explanations in one place. Short on main surfaces; the Why?
/// layer may be longer. Never claims knowledge Helios does not have.
enum HeliosCopy {
  static func meaning(_ area: HeliosArea) -> String {
    switch area {
    case .performance:
      "Performance is judged by memory pressure as reported by macOS. High CPU alone is not a problem — a busy Mac that keeps up is healthy."
    case .thermals:
      "Thermals combine macOS thermal pressure with the hottest identified CPU/GPU sensor (Max SoC). Max SoC is not an average; it is usually higher than core averages."
    case .battery:
      "Battery health compares today’s full-charge capacity with the design capacity. Temperature is read from the battery itself. Helios never changes charging."
    case .storage:
      "Storage looks at free space on the startup disk and the SSD’s own NVMe SMART health report."
    }
  }

  static let maxSoC =
    "Hottest valid reading among Helios’s identified CPU/GPU sensors and validated SoC hotspots. Unclassified raw sensors are excluded."
  static let unclassifiedSensor =
    "Apple does not publicly document what this sensor measures. Helios shows its value but never uses it for decisions."
  static let inactiveSensors =
    "These sensors are switched off at the moment, for example while the GPU sleeps. That is normal and not a fault."
  static let unsupportedSensors =
    "These sensors store their value in a format Helios does not read yet. That is normal on Apple Silicon and not a fault."
  static let catalogueSensors =
    "On this chip the sensors are identified from a public sensor catalogue. Helios has verified that map only on M4 Macs, so these values are shown but never used for fan control."
  static let processCPU =
    "Share of your Mac’s total CPU capacity. A process using one full core on a 10-core Mac shows 10 %."
  static let memoryPressure =
    "macOS reports memory pressure when apps need more memory than is readily available. Used memory alone is not a problem: macOS keeps memory busy with caches on purpose."

  private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()
  private static let weekdayTimeFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()

  static func shortTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    calendar.isDate(date, inSameDayAs: now)
      ? date.formatted(timeFormat) : date.formatted(weekdayTimeFormat)
  }

  static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return "Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(day, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }
    return day.formatted(.dateTime.weekday(.wide).day().month())
  }

  static func symbol(_ event: HeliosActivityEvent) -> String {
    switch event.kind {
    case .issueStarted:
      event.tone == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    case .issueResolved: "checkmark.circle.fill"
    case .powerConnected: "powerplug"
    case .powerDisconnected: "battery.75percent"
    case .peak: "chart.line.uptrend.xyaxis"
    }
  }

  static func duration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    if seconds < 60 { return "under 1 min" }
    return TelemetryFormatting.duration(seconds)
  }
}
