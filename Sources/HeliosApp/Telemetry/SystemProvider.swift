import Darwin
import Foundation

enum SystemThermalState: String, Sendable {
    case nominal = "Nominal"
    case fair = "Fair"
    case serious = "Serious"
    case critical = "Critical"
}

struct SystemMetrics: Sendable {
    let modelIdentifier: MetricResult<String>
    let chipName: MetricResult<String>
    let osVersion: String
    let uptimeSeconds: TimeInterval
    let logicalProcessorCount: Int
    let physicalMemoryBytes: UInt64
    let loadAverage1: MetricResult<Double>
    let loadAverage5: MetricResult<Double>
    let loadAverage15: MetricResult<Double>
    let thermalState: SystemThermalState
    let lowPowerModeEnabled: Bool
}

enum SystemInfoReader {
    static func read() -> SystemMetrics {
        let info = ProcessInfo.processInfo
        let loads = loadAverages()
        return SystemMetrics(
            modelIdentifier: captureMetric { try sysctlString("hw.model", label: "Mac model identifier") },
            chipName: captureMetric { try sysctlString("machdep.cpu.brand_string", label: "Chip name") },
            osVersion: info.operatingSystemVersionString,
            uptimeSeconds: max(0, info.systemUptime),
            logicalProcessorCount: max(1, info.processorCount),
            physicalMemoryBytes: info.physicalMemory,
            loadAverage1: loads.map { $0.0 },
            loadAverage5: loads.map { $0.1 },
            loadAverage15: loads.map { $0.2 },
            thermalState: thermalState(info.thermalState),
            lowPowerModeEnabled: info.isLowPowerModeEnabled
        )
    }

    static func loadAverages() -> MetricResult<(Double, Double, Double)> {
        captureMetric {
            var values = [Double](repeating: 0, count: 3)
            let count = values.withUnsafeMutableBufferPointer { buffer in
                getloadavg(buffer.baseAddress, Int32(buffer.count))
            }
            guard count == 3, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 10_000 }) else {
                throw TelemetryError.unavailable("Load averages unavailable")
            }
            return (values[0], values[1], values[2])
        }
    }

    static func sysctlString(_ name: String, label: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size < 4096 else {
            throw TelemetryError.kernel(label, errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctlbyname(name, rawBuffer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else {
            throw TelemetryError.kernel(label, errno)
        }

        // sysctl string payloads are NUL-terminated. Swift 6.2 deprecates
        // the deprecated C-string initializer, so decode only the bytes actually returned and
        // explicitly remove the terminator. This also avoids reading beyond
        // the buffer if a future sysctl implementation reports an odd size.
        let returnedCount = min(size, buffer.count)
        let payload = buffer.prefix(returnedCount).prefix(while: { $0 != 0 })
        let value = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TelemetryError.invalidData("Empty \(label.lowercased())") }
        return value
    }

    static func thermalState(_ state: ProcessInfo.ThermalState) -> SystemThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}

actor SystemProvider {
    func reset() {}
    func sample() -> MetricSample<SystemMetrics> { MetricSample(.success(SystemInfoReader.read())) }
}
