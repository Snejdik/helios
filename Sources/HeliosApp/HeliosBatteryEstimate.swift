import Foundation

struct HeliosBatteryLifeEstimate: Equatable, Sendable {
  enum Source: String, Sendable {
    case macOS = "macOS estimate"
    case helios = "Helios estimate"
    case powerAdapter = "Power adapter"
    case calculating = "Calculating"
  }

  let seconds: TimeInterval?
  let source: Source
  let approximate: Bool

  var compactText: String {
    switch source {
    case .powerAdapter: return "On AC"
    case .calculating: return "Calculating…"
    case .macOS, .helios:
      guard let seconds else { return "—" }
      let prefix = approximate ? "≈ " : ""
      return prefix + TelemetryFormatting.duration(max(0, seconds))
    }
  }
}

/// Read-only fallback for the period where IOPowerSources still reports
/// `calculating`. It derives remaining energy from battery capacity/voltage and
/// recent discharge power; it never changes battery or charging policy.
enum HeliosBatteryEstimateEngine {
  static func estimate(
    battery result: MetricResult<BatteryMetrics>,
    history: TelemetryHistory,
    now: Date = Date()
  ) -> HeliosBatteryLifeEstimate {
    guard case .success(let battery) = result else {
      return HeliosBatteryLifeEstimate(seconds: nil, source: .calculating, approximate: false)
    }

    if case .success(let source) = battery.powerSource, source == .powerAdapter {
      return HeliosBatteryLifeEstimate(seconds: nil, source: .powerAdapter, approximate: false)
    }

    if case .success(let system) = battery.timeRemaining {
      switch system {
      case .seconds(let seconds) where seconds.isFinite && seconds >= 0:
        return HeliosBatteryLifeEstimate(seconds: seconds, source: .macOS, approximate: false)
      case .unlimited:
        return HeliosBatteryLifeEstimate(seconds: nil, source: .powerAdapter, approximate: false)
      case .calculating, .seconds:
        break
      }
    }

    guard let remainingWh = remainingEnergyWh(battery), remainingWh > 0,
      let dischargeWatts = recentDischargeWatts(history: history, battery: battery, now: now),
      dischargeWatts >= 0.5
    else {
      return HeliosBatteryLifeEstimate(seconds: nil, source: .calculating, approximate: false)
    }

    let seconds = remainingWh / dischargeWatts * 3_600
    guard seconds.isFinite, seconds > 0, seconds <= 30 * 60 * 60 else {
      return HeliosBatteryLifeEstimate(seconds: nil, source: .calculating, approximate: false)
    }
    return HeliosBatteryLifeEstimate(seconds: seconds, source: .helios, approximate: true)
  }

  private static func remainingEnergyWh(_ battery: BatteryMetrics) -> Double? {
    guard case .success(let voltage) = battery.voltageVolts, voltage.isFinite,
      (5...30).contains(voltage)
    else { return nil }

    if case .success(let currentMAh) = battery.currentCapacityMAh, currentMAh > 0 {
      return Double(currentMAh) * voltage / 1_000
    }
    if case .success(let maximumMAh) = battery.maximumCapacityMAh, maximumMAh > 0,
      case .success(let percent) = battery.stateOfChargePercent,
      percent.isFinite, (0...100).contains(percent)
    {
      return Double(maximumMAh) * (percent / 100) * voltage / 1_000
    }
    return nil
  }

  private static func recentDischargeWatts(
    history: TelemetryHistory, battery: BatteryMetrics, now: Date
  ) -> Double? {
    let cutoff = now.addingTimeInterval(-90)
    let recent = history.points
      .filter { $0.capturedAt >= cutoff }
      .compactMap(\.batteryPowerWatts)
      .filter { $0.isFinite && $0 < -0.5 && $0 > -150 }
      .suffix(45)
      .map { abs($0) }

    if !recent.isEmpty {
      // Trim one extreme at each end once we have enough samples. This keeps the
      // initial answer fast but rapidly stabilizes as real history arrives.
      let sorted = recent.sorted()
      let stable: ArraySlice<Double>
      if sorted.count >= 7 {
        stable = sorted.dropFirst().dropLast()
      } else {
        stable = sorted[...]
      }
      return stable.reduce(0, +) / Double(stable.count)
    }

    if case .success(let power) = battery.power,
      power.signedWatts.isFinite, power.signedWatts < -0.5, power.signedWatts > -150
    {
      return abs(power.signedWatts)
    }

    // Some battery snapshots expose current and voltage before the synthesized
    // BatteryPower field is ready. Use the same read-only electrical telemetry
    // so the first approximate ETA does not unnecessarily remain Calculating.
    if case .success(let current) = battery.currentAmps, current.isFinite, current < -0.04,
      case .success(let voltage) = battery.voltageVolts, voltage.isFinite,
      (5...30).contains(voltage)
    {
      let watts = abs(current * voltage)
      if watts >= 0.5, watts < 150 { return watts }
    }
    return nil
  }
}
