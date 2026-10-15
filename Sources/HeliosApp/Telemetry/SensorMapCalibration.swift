import Foundation

/// Optional, user-started CPU load so `SensorMapVerifier` can confirm the P-core map without
/// waiting for ordinary work (PLAN_0_3_0 M1 "Calibrate"). It only runs arithmetic on
/// high-priority threads for a bounded time; it never touches fans or the helper. The
/// caller stops it early when macOS reports thermal pressure or the Mac gets hot.
final class SensorMapCalibration: @unchecked Sendable {
  static let duration: Duration = .seconds(40)
  /// Stop early above this (any identified sensor) or at serious/critical thermal pressure.
  static let abortCelsius = 90.0

  private let lock = NSLock()
  private var stopRequested = false
  private var threads: [Thread] = []

  var isRunning: Bool { lock.withLock { !threads.isEmpty && !stopRequested } }

  /// Starts one busy thread per performance core (at least one, at most 32).
  func start(threadCount: Int) {
    lock.withLock {
      guard threads.isEmpty else { return }
      stopRequested = false
      for index in 0..<min(max(threadCount, 1), 32) {
        let thread = Thread { [weak self] in self?.spin() }
        thread.name = "Helios sensor calibration \(index)"
        thread.qualityOfService = .userInitiated
        threads.append(thread)
      }
      threads.forEach { $0.start() }
    }
  }

  func stop() {
    lock.withLock {
      stopRequested = true
      threads.removeAll()
    }
  }

  private var shouldStop: Bool { lock.withLock { stopRequested } }

  private func spin() {
    var value = 1.000_001
    while !shouldStop {
      for _ in 0..<200_000 { value = value * 1.000_000_1 + 0.000_000_1 }
      if value > 1e9 { value = 1 }
    }
    // Keep the optimizer from removing the loop.
    if value == 42 { print(value) }
  }

  /// Whether a running calibration must stop now.
  static func shouldAbort(thermalState: SystemThermalState?, hottestCelsius: Double?) -> Bool {
    if thermalState == .serious || thermalState == .critical { return true }
    if let hottestCelsius, hottestCelsius >= abortCelsius { return true }
    return false
  }
}
