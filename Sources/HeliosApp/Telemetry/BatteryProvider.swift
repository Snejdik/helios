import Foundation
import IOKit
import IOKit.ps

enum BatteryParser {
    static func parse(_ properties: [String: Any], powerSourceDescription: [String: Any] = [:], timeRemaining: MetricResult<BatteryTimeRemaining> = .failure(.unavailable("Battery time remaining unavailable"))) -> BatteryMetrics {
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        let charger = properties["ChargerData"] as? [String: Any] ?? [:]
        let adapter = properties["AdapterDetails"] as? [String: Any] ?? [:]
        return BatteryMetrics(
            designCapacityMAh: integer([properties["DesignCapacity"], data["DesignCapacity"]], name: "Design capacity", range: 1...200_000),
            maximumCapacityMAh: integer([
                properties["AppleRawMaxCapacity"], properties["NominalChargeCapacity"],
                data["NominalChargeCapacity"], data["FullChargeCapacity"]
            ], name: "Full charge capacity", range: 1...200_000),
            currentCapacityMAh: integer([properties["AppleRawCurrentCapacity"], data["RemainingCapacity"]], name: "Current capacity", range: 0...200_000),
            systemChargePercent: percentage([
                properties["CurrentCapacity"], powerSourceDescription[kIOPSCurrentCapacityKey as String]
            ], name: "System battery state of charge"),
            cycleCount: integer([properties["CycleCount"], data["CycleCount"]], name: "Cycle count", range: 0...1_000_000),
            temperatureCelsius: captureMetric {
                let raw = try numeric(properties["Temperature"], name: "Battery temperature")
                let celsius = raw.doubleValue / 100
                guard (-40...100).contains(celsius) else { throw TelemetryError.invalidData("Invalid battery temperature") }
                return celsius
            },
            power: captureMetric { try power(properties) },
            powerSource: powerSource(properties),
            voltageVolts: captureMetric { try voltageVolts(properties) },
            currentAmps: captureMetric { try currentAmps(properties) },
            adapterWatts: adapterWatts(properties),
            adapterVoltageVolts: millivolts([adapter["AdapterVoltage"]], name: "Power adapter voltage", range: 1_000...50_000),
            chargingCurrentAmps: milliamps([charger["ChargingCurrent"]], name: "Charging current", range: 0...20_000),
            chargingVoltageVolts: millivolts([charger["ChargingVoltage"]], name: "Charging voltage", range: 1_000...50_000),
            cellVoltagesVolts: cellVoltages([data["CellVoltage"], properties["CellVoltage"]]),
            notChargingReasonRaw: unsignedInteger([charger["NotChargingReason"], properties["NotChargingReason"]], name: "Not-charging reason"),
            isCharging: boolean(properties["IsCharging"] ?? powerSourceDescription[kIOPSIsChargingKey as String], name: "Charging state"),
            isCharged: boolean(powerSourceDescription[kIOPSIsChargedKey as String] ?? properties["FullyCharged"], name: "Charged state"),
            optimizedChargingEngaged: boolean(powerSourceDescription["Optimized Battery Charging Engaged"] ?? properties["Optimized Battery Charging Engaged"], name: "Optimized charging state"),
            manufactureDate: manufactureDate([properties["ManufactureDate"], data["ManufactureDate"]]),
            timeRemaining: timeRemaining
        )
    }

    private static func boolean(_ value: Any?, name: String) -> MetricResult<Bool> {
        captureMetric {
            guard let value else { throw TelemetryError.unavailable("\(name) unavailable") }
            guard let result = booleanValue(value) else { throw TelemetryError.invalidData("Invalid \(name.lowercased())") }
            return result
        }
    }

    /// IORegistry usually bridges these properties as CFBoolean, but some OS/
    /// driver revisions expose an integral NSNumber. Accept only exact 0/1 in
    /// that case; never coerce arbitrary nonzero numbers or strings.
    private static func booleanValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let value = value as? Bool { return value }
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        guard number.doubleValue.rounded() == number.doubleValue, (0...1).contains(number.intValue) else { return nil }
        return number.intValue == 1
    }

    private static func voltageVolts(_ properties: [String: Any]) throws -> Double {
        let millivolts = try numeric(properties["Voltage"], name: "Battery voltage").doubleValue
        guard (1_000...100_000).contains(millivolts) else { throw TelemetryError.invalidData("Invalid battery voltage") }
        return millivolts / 1_000
    }

    private static func currentAmps(_ properties: [String: Any]) throws -> Double {
        let instantaneous = properties["InstantAmperage"] != nil
        let raw = try numeric(properties[instantaneous ? "InstantAmperage" : "Amperage"], name: "Battery current")
        return Double(try signedAmperage(raw)) / 1_000
    }

    private static func millivolts(_ candidates: [Any?], name: String, range: ClosedRange<Double>) -> MetricResult<Double> {
        var failure = TelemetryError.unavailable("\(name) unavailable")
        for candidate in candidates where candidate != nil {
            do {
                let raw = try numeric(candidate, name: name).doubleValue
                guard raw.isFinite, range.contains(raw) else { throw TelemetryError.invalidData("Invalid \(name.lowercased())") }
                return .success(raw / 1_000)
            } catch let error as TelemetryError { failure = error }
            catch { failure = .invalidData("Invalid \(name.lowercased())") }
        }
        return .failure(failure)
    }

    private static func milliamps(_ candidates: [Any?], name: String, range: ClosedRange<Double>) -> MetricResult<Double> {
        var failure = TelemetryError.unavailable("\(name) unavailable")
        for candidate in candidates where candidate != nil {
            do {
                let raw = try numeric(candidate, name: name).doubleValue
                guard raw.isFinite, range.contains(raw) else { throw TelemetryError.invalidData("Invalid \(name.lowercased())") }
                return .success(raw / 1_000)
            } catch let error as TelemetryError { failure = error }
            catch { failure = .invalidData("Invalid \(name.lowercased())") }
        }
        return .failure(failure)
    }

    private static func unsignedInteger(_ candidates: [Any?], name: String) -> MetricResult<UInt64> {
        var failure = TelemetryError.unavailable("\(name) unavailable")
        for candidate in candidates where candidate != nil {
            do {
                let number = try numeric(candidate, name: name)
                let raw = number.doubleValue
                guard raw >= 0, raw.rounded() == raw else { throw TelemetryError.invalidData("Invalid \(name.lowercased())") }
                return .success(number.uint64Value)
            } catch let error as TelemetryError { failure = error }
            catch { failure = .invalidData("Invalid \(name.lowercased())") }
        }
        return .failure(failure)
    }

    private static func cellVoltages(_ candidates: [Any?]) -> MetricResult<[Double]> {
        var failure = TelemetryError.unavailable("Battery cell voltages unavailable")
        for candidate in candidates where candidate != nil {
            do {
                let values: [Any]
                if let array = candidate as? [Any] { values = array }
                else if let array = candidate as? NSArray { values = array.map { $0 } }
                else { throw TelemetryError.invalidData("Invalid battery cell voltages") }
                guard (1...16).contains(values.count) else { throw TelemetryError.invalidData("Invalid battery cell count") }
                let volts = try values.map { element -> Double in
                    let mv = try numeric(element, name: "Battery cell voltage").doubleValue
                    guard mv.isFinite, (1_000...5_500).contains(mv) else { throw TelemetryError.invalidData("Invalid battery cell voltage") }
                    return mv / 1_000
                }
                return .success(volts)
            } catch let error as TelemetryError { failure = error }
            catch { failure = .invalidData("Invalid battery cell voltages") }
        }
        return .failure(failure)
    }

    private static func adapterWatts(_ properties: [String: Any]) -> MetricResult<Int> {
        let details = properties["AdapterDetails"] as? [String: Any] ?? [:]
        return integer([details["Watts"]], name: "Power adapter rating", range: 1...500)
    }

    private static func powerSource(_ properties: [String: Any]) -> MetricResult<MacPowerSource> {
        captureMetric {
            // AppleSmartBattery exposes ExternalConnected on Apple Silicon Macs.
            // Treat this only as a profile selector; failure never guesses a
            // power source and Auto Rules will fail closed to System instead.
            if let connected = booleanValue(properties["ExternalConnected"]) {
                return connected ? .powerAdapter : .battery
            }
            // IsCharging can prove adapter presence when true, but false is
            // ambiguous (full battery on adapter vs actually on battery).
            if booleanValue(properties["IsCharging"]) == true { return .powerAdapter }
            throw TelemetryError.unavailable("Battery power-source state unavailable")
        }
    }

    private static func percentage(_ candidates: [Any?], name: String) -> MetricResult<Double> {
        var failure = TelemetryError.unavailable("\(name) unavailable")
        for candidate in candidates where candidate != nil {
            do {
                let number = try numeric(candidate, name: name)
                let value = number.doubleValue
                guard value.isFinite, (0...100).contains(value) else {
                    throw TelemetryError.invalidData("Invalid \(name.lowercased())")
                }
                return .success(value)
            } catch let error as TelemetryError { failure = error }
            catch { failure = .invalidData("Invalid \(name.lowercased())") }
        }
        return .failure(failure)
    }

    /// Smart Battery System packed date: day bits 0...4, month 5...8,
    /// year offset from 1980 in bits 9...15. Treat anything else as unavailable.
    private static func manufactureDate(_ candidates: [Any?]) -> MetricResult<Date> {
        var failure = TelemetryError.unavailable("Battery manufacture date unavailable")
        for candidate in candidates where candidate != nil {
            do {
                let number = try numeric(candidate, name: "Battery manufacture date")
                guard let packed = UInt16(exactly: number.uint64Value) else {
                    throw TelemetryError.invalidData("Invalid battery manufacture date")
                }
                let day = Int(packed & 0x1f)
                let month = Int((packed >> 5) & 0x0f)
                let year = 1980 + Int((packed >> 9) & 0x7f)
                guard (1...31).contains(day), (1...12).contains(month), (1980...2200).contains(year) else {
                    throw TelemetryError.invalidData("Invalid battery manufacture date")
                }
                var components = DateComponents()
                components.calendar = Calendar(identifier: .gregorian)
                components.timeZone = TimeZone(secondsFromGMT: 0)
                components.year = year
                components.month = month
                components.day = day
                guard let date = components.date else {
                    throw TelemetryError.invalidData("Invalid battery manufacture date")
                }
                return .success(date)
            } catch let error as TelemetryError { failure = error }
            catch { failure = .invalidData("Invalid battery manufacture date") }
        }
        return .failure(failure)
    }

    private static func integer(_ candidates: [Any?], name: String, range: ClosedRange<Int>) -> MetricResult<Int> {
        var failure = TelemetryError.unavailable("\(name) unavailable")
        for candidate in candidates where candidate != nil {
            do {
                let number = try numeric(candidate, name: name)
                guard let value = Int(exactly: number.doubleValue), range.contains(value) else {
                    throw TelemetryError.invalidData("Invalid \(name.lowercased())")
                }
                return .success(value)
            } catch let error as TelemetryError { failure = error }
            catch { failure = .invalidData("Invalid \(name.lowercased())") }
        }
        return .failure(failure)
    }

    private static func numeric(_ value: Any?, name: String) throws -> NSNumber {
        guard let value else { throw TelemetryError.unavailable("\(name) unavailable") }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw TelemetryError.invalidData("Invalid \(name.lowercased())")
        }
        return number
    }

    static func signedAmperage(_ number: NSNumber) throws -> Int64 {
        guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue else {
            throw TelemetryError.invalidData("Invalid battery current")
        }
        // IORegistry may carry negative mA as signed integers, or unsigned
        // 32-/64-bit two's-complement numbers. Do not lose their sign via Double.
        let unsigned = number.uint64Value
        let value: Int64
        if number.int64Value < 0 {
            value = number.int64Value
        } else if unsigned > UInt64(Int32.max), unsigned <= UInt64(UInt32.max) {
            value = Int64(Int32(bitPattern: UInt32(unsigned)))
        } else {
            value = number.int64Value
        }
        guard (-100_000...100_000).contains(value) else { throw TelemetryError.invalidData("Battery current outside plausible range") }
        return value
    }

    private static func power(_ properties: [String: Any]) throws -> BatteryPower {
        let voltage = try voltageVolts(properties)
        let instantaneous = properties["InstantAmperage"] != nil
        let current = try currentAmps(properties)
        return BatteryPower(signedWatts: voltage * current, usesInstantaneousCurrent: instantaneous)
    }
}

actor BatteryProvider {
    private var service: io_service_t = 0

    deinit { if service != 0 { IOObjectRelease(service) } }

    func reset() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
    }

    func sample() -> MetricSample<BatteryMetrics> {
        let result = captureMetric { try read() }
        if case .failure = result { reset() }
        return MetricSample(result)
    }

    private func readTimeRemaining() -> MetricResult<BatteryTimeRemaining> {
        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate == kIOPSTimeRemainingUnlimited { return .success(.unlimited) }
        if estimate == kIOPSTimeRemainingUnknown { return .success(.calculating) }
        guard estimate.isFinite, estimate >= 0, estimate <= 7 * 24 * 60 * 60 else {
            return .failure(.invalidData("Battery time remaining outside plausible range"))
        }
        return .success(.seconds(estimate))
    }

    private func read() throws -> BatteryMetrics {
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        }
        guard service != 0 else { throw TelemetryError.unavailable("AppleSmartBattery unavailable") }
        var properties: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS else { throw TelemetryError.ioKit("Read AppleSmartBattery", status) }
        guard let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
            throw TelemetryError.invalidData("Invalid AppleSmartBattery dictionary")
        }
        return BatteryParser.parse(dictionary, powerSourceDescription: readPowerSourceDescription(), timeRemaining: readTimeRemaining())
    }

    private func readPowerSourceDescription() -> [String: Any] {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               description[kIOPSTypeKey as String] as? String == (kIOPSInternalBatteryType as String) {
                return description
            }
        }
        return [:]
    }
}
