import Foundation

struct CPUMetrics: Sendable {
    let userPercent: Double
    let systemPercent: Double
    let nicePercent: Double
    let idlePercent: Double
    let perCoreUsagePercent: [Double]
    let physicalCoreCount: MetricResult<Int>
    let performanceCoreCount: MetricResult<Int>
    let efficiencyCoreCount: MetricResult<Int>

    init(userPercent: Double, systemPercent: Double, nicePercent: Double, idlePercent: Double,
         perCoreUsagePercent: [Double] = [],
         physicalCoreCount: MetricResult<Int> = .failure(.unavailable("Physical CPU core count unavailable")),
         performanceCoreCount: MetricResult<Int> = .failure(.unavailable("Performance-core count unavailable")),
         efficiencyCoreCount: MetricResult<Int> = .failure(.unavailable("Efficiency-core count unavailable"))) {
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.nicePercent = nicePercent
        self.idlePercent = idlePercent
        self.perCoreUsagePercent = perCoreUsagePercent
        self.physicalCoreCount = physicalCoreCount
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
    }

    var usagePercent: Double { userPercent + systemPercent + nicePercent }
}

enum MemoryPressure: String, Sendable {
    case normal = "Normal"
    case warning = "Warning"
    case critical = "Critical"

    static func decode(_ level: Int32) throws -> Self {
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: throw TelemetryError.invalidData("Unknown memory pressure level: \(level)")
        }
    }
}

struct MemoryMetrics: Sendable {
    let physicalBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let speculativeBytes: UInt64
    let purgeableBytes: UInt64
    let externalBytes: UInt64
    let freeBytes: UInt64
    let pressure: MetricResult<MemoryPressure>
    let swapUsedBytes: MetricResult<UInt64>
    let swapTotalBytes: MetricResult<UInt64>
    let swapFreeBytes: MetricResult<UInt64>
    let swapIns: UInt64
    let swapOuts: UInt64

    init(physicalBytes: UInt64, activeBytes: UInt64, inactiveBytes: UInt64, wiredBytes: UInt64,
         compressedBytes: UInt64, speculativeBytes: UInt64 = 0, purgeableBytes: UInt64 = 0,
         externalBytes: UInt64 = 0, freeBytes: UInt64, pressure: MetricResult<MemoryPressure>,
         swapUsedBytes: MetricResult<UInt64> = .failure(.unavailable("Swap usage unavailable")),
         swapTotalBytes: MetricResult<UInt64> = .failure(.unavailable("Swap usage unavailable")),
         swapFreeBytes: MetricResult<UInt64> = .failure(.unavailable("Swap usage unavailable")),
         swapIns: UInt64 = 0, swapOuts: UInt64 = 0) {
        self.physicalBytes = physicalBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.speculativeBytes = speculativeBytes
        self.purgeableBytes = purgeableBytes
        self.externalBytes = externalBytes
        self.freeBytes = freeBytes
        self.pressure = pressure
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapFreeBytes = swapFreeBytes
        self.swapIns = swapIns
        self.swapOuts = swapOuts
    }

    /// Activity-Monitor-style approximation using native VM counters. Cached
    /// purgeable/external pages are excluded from active application pressure.
    var usedBytes: UInt64 {
        let gross = Self.saturatingSum([activeBytes, inactiveBytes, speculativeBytes, wiredBytes, compressedBytes])
        let reclaimable = Self.saturatingSum([purgeableBytes, externalBytes])
        return gross >= reclaimable ? min(physicalBytes, gross - reclaimable) : 0
    }

    var appBytes: UInt64 {
        let reserved = Self.saturatingSum([wiredBytes, compressedBytes])
        return usedBytes >= reserved ? usedBytes - reserved : 0
    }

    var cacheBytes: UInt64 { Self.saturatingSum([purgeableBytes, externalBytes]) }

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(UInt64(0)) { partial, next in
            let (value, overflow) = partial.addingReportingOverflow(next)
            return overflow ? .max : value
        }
    }

    var availableBytes: UInt64 { physicalBytes >= usedBytes ? physicalBytes - usedBytes : 0 }
    var usagePercent: Double { physicalBytes > 0 ? Double(usedBytes) / Double(physicalBytes) * 100 : 0 }
}

struct GPUMetrics: Sendable {
    let model: MetricResult<String>
    let coreCount: MetricResult<Int>
    let deviceUtilizationPercent: MetricResult<Double>
    let rendererUtilizationPercent: MetricResult<Double>
    let tilerUtilizationPercent: MetricResult<Double>
    let allocatedSystemMemoryBytes: MetricResult<UInt64>
    let inUseSystemMemoryBytes: MetricResult<UInt64>
}

struct SystemPowerMetrics: Sendable {
    /// Board/system power reported by the read-only AppleSMC PSTR rail.
    let totalSystemWatts: MetricResult<Double>
}

struct BatteryPower: Sendable {
    /// Positive means charge into the battery; negative means discharge.
    let signedWatts: Double
    let usesInstantaneousCurrent: Bool

    var label: String {
        let direction = signedWatts > 0 ? "Battery Charge" : signedWatts < 0 ? "Battery Discharge" : "Battery Idle"
        return usesInstantaneousCurrent ? "\(direction) (instantaneous)" : "\(direction) (averaged current)"
    }
}


enum BatteryTimeRemaining: Sendable, Equatable {
    case seconds(TimeInterval)
    case calculating
    case unlimited
}

enum MacPowerSource: String, Sendable {
    case powerAdapter = "Power Adapter"
    case battery = "Battery"
}

struct BatteryMetrics: Sendable {
    let designCapacityMAh: MetricResult<Int>
    let maximumCapacityMAh: MetricResult<Int>
    /// Raw chemical/SMBus capacity. This is intentionally not the user-facing SoC.
    let currentCapacityMAh: MetricResult<Int>
    /// macOS-normalized state of charge (0...100). Prefer this for the UI.
    let systemChargePercent: MetricResult<Double>
    let cycleCount: MetricResult<Int>
    let temperatureCelsius: MetricResult<Double>
    let power: MetricResult<BatteryPower>
    let powerSource: MetricResult<MacPowerSource>
    let voltageVolts: MetricResult<Double>
    let currentAmps: MetricResult<Double>
    let adapterWatts: MetricResult<Int>
    /// Read-only charger telemetry published by AppleSmartBattery/IOPowerSources.
    /// These values are diagnostic only and never influence charging policy.
    let adapterVoltageVolts: MetricResult<Double>
    let chargingCurrentAmps: MetricResult<Double>
    let chargingVoltageVolts: MetricResult<Double>
    let cellVoltagesVolts: MetricResult<[Double]>
    let notChargingReasonRaw: MetricResult<UInt64>
    let isCharging: MetricResult<Bool>
    let isCharged: MetricResult<Bool>
    let optimizedChargingEngaged: MetricResult<Bool>
    let manufactureDate: MetricResult<Date>
    let timeRemaining: MetricResult<BatteryTimeRemaining>

    init(designCapacityMAh: MetricResult<Int>, maximumCapacityMAh: MetricResult<Int>,
         currentCapacityMAh: MetricResult<Int>, systemChargePercent: MetricResult<Double> = .failure(.unavailable("System battery state of charge unavailable")),
         cycleCount: MetricResult<Int>, temperatureCelsius: MetricResult<Double>, power: MetricResult<BatteryPower>,
         powerSource: MetricResult<MacPowerSource> = .failure(.unavailable("Power source unavailable")),
         voltageVolts: MetricResult<Double> = .failure(.unavailable("Battery voltage unavailable")),
         currentAmps: MetricResult<Double> = .failure(.unavailable("Battery current unavailable")),
         adapterWatts: MetricResult<Int> = .failure(.unavailable("Power adapter rating unavailable")),
         adapterVoltageVolts: MetricResult<Double> = .failure(.unavailable("Power adapter voltage unavailable")),
         chargingCurrentAmps: MetricResult<Double> = .failure(.unavailable("Charging current unavailable")),
         chargingVoltageVolts: MetricResult<Double> = .failure(.unavailable("Charging voltage unavailable")),
         cellVoltagesVolts: MetricResult<[Double]> = .failure(.unavailable("Battery cell voltages unavailable")),
         notChargingReasonRaw: MetricResult<UInt64> = .failure(.unavailable("Not-charging reason unavailable")),
         isCharging: MetricResult<Bool> = .failure(.unavailable("Charging state unavailable")),
         isCharged: MetricResult<Bool> = .failure(.unavailable("Charged state unavailable")),
         optimizedChargingEngaged: MetricResult<Bool> = .failure(.unavailable("Optimized charging state unavailable")),
         manufactureDate: MetricResult<Date> = .failure(.unavailable("Battery manufacture date unavailable")),
         timeRemaining: MetricResult<BatteryTimeRemaining> = .failure(.unavailable("Battery time remaining unavailable"))) {
        self.designCapacityMAh = designCapacityMAh
        self.maximumCapacityMAh = maximumCapacityMAh
        self.currentCapacityMAh = currentCapacityMAh
        self.systemChargePercent = systemChargePercent
        self.cycleCount = cycleCount
        self.temperatureCelsius = temperatureCelsius
        self.power = power
        self.powerSource = powerSource
        self.voltageVolts = voltageVolts
        self.currentAmps = currentAmps
        self.adapterWatts = adapterWatts
        self.adapterVoltageVolts = adapterVoltageVolts
        self.chargingCurrentAmps = chargingCurrentAmps
        self.chargingVoltageVolts = chargingVoltageVolts
        self.cellVoltagesVolts = cellVoltagesVolts
        self.notChargingReasonRaw = notChargingReasonRaw
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.optimizedChargingEngaged = optimizedChargingEngaged
        self.manufactureDate = manufactureDate
        self.timeRemaining = timeRemaining
    }


    var cellBalanceMillivolts: MetricResult<Double> {
        cellVoltagesVolts.flatMap { cells in
            captureMetric {
                guard cells.count >= 2, cells.allSatisfy({ $0.isFinite && (1.0...5.5).contains($0) }) else {
                    throw TelemetryError.unavailable("Battery cell balance unavailable")
                }
                guard let minimum = cells.min(), let maximum = cells.max() else {
                    throw TelemetryError.unavailable("Battery cell balance unavailable")
                }
                return (maximum - minimum) * 1_000
            }
        }
    }

    var healthPercent: MetricResult<Double> {
        captureMetric {
            let design = try designCapacityMAh.get()
            let maximum = try maximumCapacityMAh.get()
            guard design > 0 else { throw TelemetryError.invalidData("Invalid design capacity") }
            return Double(maximum) / Double(design) * 100
        }
    }

    /// Raw-capacity ratio retained for expert diagnostics. On modern Apple Silicon
    /// this can legitimately disagree with the percentage macOS presents to users.
    var rawStateOfChargePercent: MetricResult<Double> {
        captureMetric {
            let current = try currentCapacityMAh.get()
            let maximum = try maximumCapacityMAh.get()
            guard maximum > 0, current >= 0, current <= maximum * 2 else {
                throw TelemetryError.invalidData("Invalid raw battery state of charge")
            }
            return min(100, max(0, Double(current) / Double(maximum) * 100))
        }
    }

    /// User-facing SoC follows macOS' normalized CurrentCapacity first. The raw
    /// capacity ratio is only a fallback for older/partial battery providers.
    var stateOfChargePercent: MetricResult<Double> {
        switch systemChargePercent {
        case .success(let percent):
            guard percent.isFinite, (0...100).contains(percent) else {
                return .failure(.invalidData("Invalid system battery state of charge"))
            }
            return .success(percent)
        case .failure:
            return rawStateOfChargePercent
        }
    }
}

enum ThermalGroup: String, Sendable, CaseIterable {
    case performanceCPU = "P-core group"
    case efficiencyCPU = "E-core group"
    case gpu = "GPU group"
    /// Independently validated for conservative Max SoC monitoring on an exact
    /// hardware/build profile, without asserting a physical component identity.
    case validatedHotspot = "Validated hotspot"
    case unclassified = "Unclassified"
}

struct ThermalReading: Sendable {
    let key: String
    let group: ThermalGroup
    let celsius: Double
}

struct ThermalMetrics: Sendable {
    let readings: [ThermalReading]
    let failures: [String: TelemetryError]
    /// Raw/unclassified SMC inventory is intentionally sampled less often than
    /// the exact trusted keys used by Max SoC and Cooling Rules. This timestamp makes that
    /// relaxed cadence explicit in expert UI instead of pretending every raw
    /// value was captured with the fast safety sample.
    let advisoryReadingsCapturedAt: Date?

    init(readings: [ThermalReading], failures: [String: TelemetryError],
         advisoryReadingsCapturedAt: Date? = nil) {
        self.readings = readings
        self.failures = failures
        self.advisoryReadingsCapturedAt = advisoryReadingsCapturedAt
    }

    var maximumSoCReading: MetricResult<ThermalReading> {
        guard let hottest = readings
            .filter({ $0.group != .unclassified })
            .max(by: { $0.celsius < $1.celsius }) else {
            return .failure(.unavailable("No trusted temperature sensors available"))
        }
        return .success(hottest)
    }

    var maximumSoCCelsius: MetricResult<Double> {
        maximumSoCReading.map(\.celsius)
    }
}
