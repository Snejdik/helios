import Darwin
import Foundation
import OSLog

struct ThermalClassifier {
    let cpuBrand: String

    // Curated M4-family thermal-zone keys. Do not classify an arbitrary `Tp`,
    // `Te`, or `Tg` prefix as trusted SoC temperature data: undocumented SMC
    // namespaces evolve and a newly discovered key must not silently become a
    // fan-control input. The sets are the currently source-visible Stats M4
    // mappings plus the M4 Pro replacements independently reported in 2026.
    // References:
    // - github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
    // - github.com/exelban/stats/issues/3270
    // Missing keys are harmless because discovery only reads keys present on
    // this Mac; unknown keys remain visible as `.unclassified` diagnostics.
    private static let m4PerformanceCPUKeys: Set<String> = [
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"
    ]
    private static let m4EfficiencyCPUKeys: Set<String> = [
        "Te05", "Te06", "Te09", "Te0H", "Te0S", "Te0T"
    ]
    private static let m4GPUKeys: Set<String> = [
        "Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k"
    ]

    func group(for key: String) -> ThermalGroup {
        guard cpuBrand == "Apple M4" || cpuBrand.hasPrefix("Apple M4 ") else { return .unclassified }
        if Self.m4PerformanceCPUKeys.contains(key) { return .performanceCPU }
        if Self.m4EfficiencyCPUKeys.contains(key) { return .efficiencyCPU }
        if Self.m4GPUKeys.contains(key) { return .gpu }
        return .unclassified
    }

    static func native() throws -> Self {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else {
            throw TelemetryError.kernel("Read CPU identity", errno)
        }
        guard size > 0, size <= 256 else { throw TelemetryError.invalidData("Invalid CPU identity size") }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { sysctlbyname("machdep.cpu.brand_string", $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { throw TelemetryError.kernel("Read CPU identity", errno) }
        guard size <= bytes.count else { throw TelemetryError.invalidData("Truncated CPU identity") }
        return Self(cpuBrand: String(decoding: bytes.prefix(size).prefix(while: { $0 != 0 }), as: UTF8.self))
    }
}

final class SMCThermalReader {
    private let client: SMCClient
    private let classifier: ThermalClassifier
    private var temperatureKeys: [String]?
    private var discoveryFailures: [String: TelemetryError] = [:]

    init(client: SMCClient, classifier: ThermalClassifier) {
        self.client = client
        self.classifier = classifier
    }

    func read() throws -> ThermalMetrics {
        if temperatureKeys == nil {
            let discovered = try client.discoverKeys()
            discoveryFailures = discovered.failures
            var keys: [String] = []
            for key in discovered.keys where key.hasPrefix("T") {
                switch captureMetric({ try client.keyInfo(key) }) {
                case .success(let info):
                    if (info.type == "sp78" && info.size == 2) || (info.type == "flt " && info.size == 4) {
                        keys.append(key)
                    } else {
                        discoveryFailures[key] = .invalidData("Unsupported temperature type/size for \(key)")
                    }
                case .failure(let error): discoveryFailures[key] = error
                }
            }
            temperatureKeys = keys
        }
        guard let temperatureKeys, !temperatureKeys.isEmpty else { throw TelemetryError.unavailable("No supported SMC temperature keys discovered") }
        var readings: [ThermalReading] = []
        var failures = discoveryFailures
        for key in temperatureKeys {
            switch captureMetric({
                let value = try client.value(key)
                let celsius = try SMCCodec.temperature(type: value.info.type, bytes: value.bytes)
                // Zero commonly means an inactive sensor. This is data validation,
                // not a thermal safety limit or a fan-control threshold.
                guard celsius > 0, celsius <= 150 else { throw TelemetryError.invalidData("\(key) inactive or outside plausible temperature range") }
                return ThermalReading(key: key, group: classifier.group(for: key), celsius: celsius)
            }) {
            case .success(let reading): readings.append(reading)
            case .failure(let error): failures[key] = error
            }
        }
        guard !readings.isEmpty else {
            let firstFailure = failures.keys.sorted().first.flatMap { failures[$0] }
            throw firstFailure ?? TelemetryError.unavailable("No valid SMC temperature readings")
        }
        return ThermalMetrics(readings: readings, failures: failures)
    }
}

actor ThermalProvider {
    private let logger = Logger(subsystem: "com.snejda.Helios", category: "Thermals")
    private var reader: SMCThermalReader?
    private var retryAfter: ContinuousClock.Instant?
    private var lastFailure: TelemetryError?

    func reset() {
        reader = nil
        retryAfter = nil
        lastFailure = nil
    }

    func sample() -> MetricSample<ThermalMetrics> {
        if let retryAfter, ContinuousClock.now < retryAfter, let lastFailure {
            return MetricSample(.failure(lastFailure))
        }
        // Conservatively age the complete batch from its first read. A slow
        // driver call must not make earlier readings appear newly captured.
        let capturedAt = Date()
        let capturedTicks = HostClock.now
        let result = captureMetric {
            if reader == nil {
                let transport = try SMCIOKitTransport()
                // Identity failure only disables grouping, not sensor discovery.
                let identity = captureMetric { try ThermalClassifier.native() }
                let classifier: ThermalClassifier
                switch identity {
                case .success(let value): classifier = value
                case .failure(let error):
                    logger.error("SoC grouping unavailable: \(error.localizedDescription, privacy: .public)")
                    classifier = ThermalClassifier(cpuBrand: "")
                }
                reader = SMCThermalReader(client: SMCClient(transport: transport), classifier: classifier)
            }
            guard let reader else { throw TelemetryError.unavailable("Thermal reader unavailable") }
            return try reader.read()
        }
        if case .failure(let error) = result {
            reader = nil
            lastFailure = error
            retryAfter = ContinuousClock.now.advanced(by: .seconds(30))
        } else {
            lastFailure = nil
            retryAfter = nil
        }
        return MetricSample(result, capturedAt: capturedAt, capturedTicks: capturedTicks)
    }
}

// MARK: - Expert raw SMC numeric inventory

/// Read-only expert inventory of numeric SMC channels. Values are intentionally
/// unitless unless another dedicated provider has independently established a
/// unit/meaning (for example trusted thermal sensors or PSTR system power).
/// Unknown SMC names are never promoted into fan safety or policy inputs.
struct SMCNumericReading: Sendable, Equatable, Identifiable {
    let key: String
    let type: String
    let value: Double

    var id: String { key }
}

struct SMCNumericMetrics: Sendable, Equatable {
    let readings: [SMCNumericReading]
    let failures: [String: TelemetryError]
    let truncated: Bool
}

final class SMCNumericReader {
    private let client: SMCClient

    init(client: SMCClient) { self.client = client }

    func read(maximumReadings: Int = 512) throws -> SMCNumericMetrics {
        guard (1...2_048).contains(maximumReadings) else {
            throw TelemetryError.invalidData("Invalid SMC numeric inventory bound")
        }
        let discovered = try client.discoverKeys()
        var readings: [SMCNumericReading] = []
        readings.reserveCapacity(min(maximumReadings, discovered.keys.count))
        var failures = discovered.failures
        var truncated = false

        for key in discovered.keys where key != "#KEY" {
            if readings.count >= maximumReadings {
                truncated = true
                break
            }
            let infoResult = captureMetric { try client.keyInfo(key) }
            guard case .success(let info) = infoResult else {
                if case .failure(let error) = infoResult { failures[key] = error }
                continue
            }
            guard Self.isNumeric(info) else { continue }
            switch captureMetric({
                let raw = try client.value(key)
                let value = try SMCCodec.numeric(type: raw.info.type, bytes: raw.bytes)
                guard value.isFinite else { throw TelemetryError.invalidData("Non-finite SMC numeric value for \(key)") }
                return SMCNumericReading(key: key, type: raw.info.type, value: value)
            }) {
            case .success(let reading): readings.append(reading)
            case .failure(let error): failures[key] = error
            }
        }
        guard !readings.isEmpty else { throw TelemetryError.unavailable("No supported numeric SMC channels discovered") }
        return SMCNumericMetrics(readings: readings.sorted { $0.key < $1.key }, failures: failures, truncated: truncated)
    }

    private static func isNumeric(_ info: SMCKeyInfo) -> Bool {
        switch info.type {
        case "flt ": return info.size == 4
        case "ui8 ", "si8 ": return info.size == 1
        case "ui16", "si16": return info.size == 2
        case "ui32", "si32": return info.size == 4
        default:
            let chars = Array(info.type)
            guard chars.count == 4, info.size == 2,
                  (chars[0] == "s" || chars[0] == "f"), chars[1] == "p",
                  Int(String(chars[2]), radix: 16) != nil,
                  Int(String(chars[3]), radix: 16) != nil else { return false }
            return true
        }
    }
}

actor SMCNumericProvider {
    private var reader: SMCNumericReader?

    func reset() { reader = nil }

    /// Deliberately on-demand. Enumerating many undocumented SMC keys is useful
    /// for an Expert view but does not belong in the normal background cadence.
    func sample(maximumReadings: Int = 512) -> MetricSample<SMCNumericMetrics> {
        let capturedAt = Date()
        let capturedTicks = HostClock.now
        let result = captureMetric {
            if reader == nil {
                reader = SMCNumericReader(client: SMCClient(transport: try SMCIOKitTransport()))
            }
            guard let reader else { throw TelemetryError.unavailable("SMC numeric inventory unavailable") }
            return try reader.read(maximumReadings: maximumReadings)
        }
        if case .failure = result { reader = nil }
        return MetricSample(result, capturedAt: capturedAt, capturedTicks: capturedTicks)
    }
}
