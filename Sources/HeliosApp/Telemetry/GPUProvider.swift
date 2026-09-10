import Foundation
import IOKit

enum GPURegistryParser {
    static func parse(_ properties: [String: Any]) throws -> GPUMetrics {
        let stats: [String: Any]
        if let raw = properties["PerformanceStatistics"] {
            guard let dictionary = raw as? [String: Any] else {
                throw TelemetryError.invalidData("Invalid GPU PerformanceStatistics dictionary")
            }
            stats = dictionary
        } else {
            // Identity can still be useful on a GPU/OS revision that does not
            // publish utilization counters. Keep those fields independently
            // unavailable instead of erasing model/core information.
            stats = [:]
        }
        return GPUMetrics(
            model: stringMetric([
                properties["model"], properties["MetalPluginName"],
                properties["IONameMatched"]
            ], name: "GPU model"),
            coreCount: integerMetric([properties["gpu-core-count"]], name: "GPU core count", range: 1...512),
            deviceUtilizationPercent: percentageMetric(stats, keys: ["Device Utilization %", "Device Utilization", "GPU Utilization %"], name: "GPU utilization"),
            rendererUtilizationPercent: percentageMetric(stats, keys: ["Renderer Utilization %", "Renderer Utilization"], name: "Renderer utilization"),
            tilerUtilizationPercent: percentageMetric(stats, keys: ["Tiler Utilization %", "Tiler Utilization"], name: "Tiler utilization"),
            allocatedSystemMemoryBytes: uint64Metric(stats, keys: ["Alloc system memory"], name: "GPU mapped memory"),
            inUseSystemMemoryBytes: uint64Metric(stats, keys: ["In use system memory", "In use system memory (driver)"], name: "GPU active memory")
        )
    }

    private static func percentageMetric(_ dictionary: [String: Any], keys: [String], name: String) -> MetricResult<Double> {
        captureMetric {
            let value = try number(dictionary, keys: keys, name: name)
            guard (0...100).contains(value) else { throw TelemetryError.invalidData("Invalid \(name.lowercased())") }
            return value
        }
    }

    private static func uint64Metric(_ dictionary: [String: Any], keys: [String], name: String) -> MetricResult<UInt64> {
        captureMetric {
            for key in keys {
                guard let raw = dictionary[key] else { continue }
                if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                   number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue {
                    return number.uint64Value
                }
                if let data = raw as? Data, let value = unsignedData(data) { return value }
                throw TelemetryError.invalidData("Invalid \(name.lowercased())")
            }
            throw TelemetryError.unavailable("\(name) unavailable")
        }
    }

    private static func integerMetric(_ candidates: [Any?], name: String, range: ClosedRange<Int>) -> MetricResult<Int> {
        captureMetric {
            for raw in candidates where raw != nil {
                if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                   number.doubleValue.rounded() == number.doubleValue {
                    let value = number.intValue
                    guard range.contains(value) else { throw TelemetryError.invalidData("Invalid \(name.lowercased())") }
                    return value
                }
                if let data = raw as? Data, let unsigned = unsignedData(data), let value = Int(exactly: unsigned), range.contains(value) {
                    return value
                }
                throw TelemetryError.invalidData("Invalid \(name.lowercased())")
            }
            throw TelemetryError.unavailable("\(name) unavailable")
        }
    }

    private static func stringMetric(_ candidates: [Any?], name: String) -> MetricResult<String> {
        captureMetric {
            for raw in candidates where raw != nil {
                if let string = raw as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
                if let data = raw as? Data {
                    let bytes = data.prefix { $0 != 0 }
                    if let string = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
                        return string
                    }
                }
            }
            throw TelemetryError.unavailable("\(name) unavailable")
        }
    }

    private static func number(_ dictionary: [String: Any], keys: [String], name: String) throws -> Double {
        for key in keys {
            guard let raw = dictionary[key] else { continue }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw TelemetryError.invalidData("Invalid \(name.lowercased())")
            }
            return number.doubleValue
        }
        throw TelemetryError.unavailable("\(name) unavailable")
    }

    private static func unsignedData(_ data: Data) -> UInt64? {
        guard !data.isEmpty, data.count <= 8 else { return nil }
        // IORegistry scalar Data values on Apple Silicon are little-endian.
        return data.enumerated().reduce(UInt64(0)) { partial, element in
            partial | (UInt64(element.element) << UInt64(element.offset * 8))
        }
    }
}

actor GPUProvider {
    private var service: io_service_t = 0
    private var cachedIdentity: (model: MetricResult<String>, coreCount: MetricResult<Int>)?
    private var cachedNoStatisticsMetrics: GPUMetrics?

    deinit { if service != 0 { IOObjectRelease(service) } }

    func reset() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
        cachedIdentity = nil
        cachedNoStatisticsMetrics = nil
    }

    func sample() -> MetricSample<GPUMetrics> {
        let result = captureMetric { try read() }
        if case .failure = result { reset() }
        return MetricSample(result)
    }

    private func read() throws -> GPUMetrics {
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
            if service == 0 {
                service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
            }
        }
        guard service != 0 else { throw TelemetryError.unavailable("Apple GPU accelerator unavailable") }

        // Model/core identity is effectively immutable for the lifetime of the
        // accelerator service. Read the broad registry dictionary once, then keep
        // the 1 Hz path to the single PerformanceStatistics property.
        if cachedIdentity == nil {
            var properties: Unmanaged<CFMutableDictionary>?
            let status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
            guard status == KERN_SUCCESS else { throw TelemetryError.ioKit("Read GPU accelerator", status) }
            guard let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
                throw TelemetryError.invalidData("Invalid GPU accelerator dictionary")
            }
            let initial = try GPURegistryParser.parse(dictionary)
            cachedIdentity = (initial.model, initial.coreCount)
            if dictionary["PerformanceStatistics"] == nil {
                // Some Apple-Silicon/macOS combinations expose accelerator identity
                // without live utilization statistics. Keep that a stable partial
                // success instead of falling into a 1 Hz rediscovery/failure loop.
                cachedNoStatisticsMetrics = initial
            }
            return initial
        }

        if let cachedNoStatisticsMetrics { return cachedNoStatisticsMetrics }

        guard let rawStats = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            throw TelemetryError.unavailable("GPU PerformanceStatistics unavailable")
        }
        guard let stats = rawStats as? [String: Any], let identity = cachedIdentity else {
            throw TelemetryError.invalidData("Invalid GPU PerformanceStatistics dictionary")
        }
        let live = try GPURegistryParser.parse(["PerformanceStatistics": stats])
        return GPUMetrics(
            model: identity.model,
            coreCount: identity.coreCount,
            deviceUtilizationPercent: live.deviceUtilizationPercent,
            rendererUtilizationPercent: live.rendererUtilizationPercent,
            tilerUtilizationPercent: live.tilerUtilizationPercent,
            allocatedSystemMemoryBytes: live.allocatedSystemMemoryBytes,
            inUseSystemMemoryBytes: live.inUseSystemMemoryBytes
        )
    }
}
