import CoreGraphics
import Darwin
import Foundation
import IOBluetooth
import IOKit
import IOKit.pwr_mgt

// MARK: - Displays

struct DisplayDeviceMetrics: Sendable, Identifiable, Equatable {
    let displayID: UInt32
    let builtIn: Bool
    let active: Bool
    let asleep: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let logicalWidth: Int
    let logicalHeight: Int
    let refreshRateHz: Double?
    let rotationDegrees: Double
    let physicalWidthMM: Double
    let physicalHeightMM: Double

    var id: UInt32 { displayID }
    var label: String { builtIn ? "Built-in Display" : "Display \(displayID)" }
}

struct DisplayMetrics: Sendable, Equatable {
    let displays: [DisplayDeviceMetrics]
}

actor DisplayProvider {
    func reset() {}
    func sample() -> MetricSample<DisplayMetrics> { MetricSample(captureMetric { try Self.read() }) }

    static func read() throws -> DisplayMetrics {
        var count: UInt32 = 0
        let first = CGGetOnlineDisplayList(0, nil, &count)
        guard first == .success else { throw TelemetryError.unavailable("Display enumeration failed (\(first.rawValue))") }
        guard count <= 64 else { throw TelemetryError.invalidData("Unexpected display count") }
        if count == 0 { return DisplayMetrics(displays: []) }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        let status = CGGetOnlineDisplayList(count, &ids, &actual)
        guard status == .success else { throw TelemetryError.unavailable("Display enumeration failed (\(status.rawValue))") }

        let values = ids.prefix(Int(actual)).map { id -> DisplayDeviceMetrics in
            let mode = CGDisplayCopyDisplayMode(id)
            let size = CGDisplayScreenSize(id)
            let refresh = mode?.refreshRate ?? 0
            return DisplayDeviceMetrics(
                displayID: id,
                builtIn: CGDisplayIsBuiltin(id) != 0,
                active: CGDisplayIsActive(id) != 0,
                asleep: CGDisplayIsAsleep(id) != 0,
                pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(id),
                logicalWidth: mode?.width ?? CGDisplayPixelsWide(id),
                logicalHeight: mode?.height ?? CGDisplayPixelsHigh(id),
                refreshRateHz: refresh.isFinite && refresh > 0 ? refresh : nil,
                rotationDegrees: CGDisplayRotation(id),
                physicalWidthMM: size.width,
                physicalHeightMM: size.height
            )
        }
        return DisplayMetrics(displays: values.sorted { lhs, rhs in
            if lhs.builtIn != rhs.builtIn { return lhs.builtIn }
            return lhs.displayID < rhs.displayID
        })
    }
}

// MARK: - Mounted volumes

struct MountedVolumeMetrics: Sendable, Identifiable, Equatable {
    let path: String
    let name: String
    let totalBytes: UInt64?
    let availableBytes: UInt64?
    let isInternal: Bool?
    let isRemovable: Bool?
    let isLocal: Bool?
    let isReadOnly: Bool?
    let localizedFormatDescription: String?
    let uuid: String?

    var id: String { path }
}

struct VolumeMetrics: Sendable, Equatable {
    let volumes: [MountedVolumeMetrics]
}

actor VolumeProvider {
    func reset() {}
    func sample() -> MetricSample<VolumeMetrics> { MetricSample(captureMetric { try Self.read() }) }

    static func read() throws -> VolumeMetrics {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> MountedVolumeMetrics? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let total = values.volumeTotalCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil }
            let available = values.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil }
            return MountedVolumeMetrics(
                path: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: total,
                availableBytes: available,
                isInternal: values.volumeIsInternal,
                isRemovable: values.volumeIsRemovable,
                isLocal: values.volumeIsLocal,
                isReadOnly: values.volumeIsReadOnly,
                localizedFormatDescription: values.volumeLocalizedFormatDescription,
                uuid: values.volumeUUIDString
            )
        }
        return VolumeMetrics(volumes: volumes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }
}

// MARK: - USB inventory

struct USBDeviceMetrics: Sendable, Identifiable, Equatable {
    let registryID: UInt64
    let product: String
    let vendor: String?
    let vendorID: Int?
    let productID: Int?
    let locationID: UInt64?
    let speed: UInt64?

    var id: UInt64 { registryID }
}

struct USBMetrics: Sendable, Equatable {
    let devices: [USBDeviceMetrics]
}

actor USBProvider {
    func reset() {}
    func sample() -> MetricSample<USBMetrics> { MetricSample(captureMetric { try Self.read() }) }

    static func read() throws -> USBMetrics {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard status == KERN_SUCCESS else { throw TelemetryError.ioKit("USB enumeration", status) }
        defer { IOObjectRelease(iterator) }

        var devices: [USBDeviceMetrics] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
            let product = string(service, keys: ["USB Product Name", "Product Name", "kUSBProductString"]) ?? "USB Device"
            let vendor = string(service, keys: ["USB Vendor Name", "Manufacturer", "kUSBVendorString"])
            devices.append(USBDeviceMetrics(
                registryID: registryID,
                product: product,
                vendor: vendor,
                vendorID: integer(service, keys: ["idVendor"]),
                productID: integer(service, keys: ["idProduct"]),
                locationID: uint64(service, keys: ["locationID", "LocationID"]),
                speed: uint64(service, keys: ["Device Speed", "USB Speed"])
            ))
        }
        return USBMetrics(devices: devices.sorted {
            let a = $0.product.localizedCaseInsensitiveCompare($1.product)
            return a == .orderedSame ? $0.registryID < $1.registryID : a == .orderedAscending
        })
    }

    private static func property(_ service: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func string(_ service: io_registry_entry_t, keys: [String]) -> String? {
        for key in keys {
            if let value = property(service, key: key) as? String, !value.isEmpty { return value }
            if let data = property(service, key: key) as? Data,
               let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !value.isEmpty { return value }
        }
        return nil
    }

    private static func integer(_ service: io_registry_entry_t, keys: [String]) -> Int? {
        for key in keys {
            if let n = property(service, key: key) as? NSNumber, n.doubleValue.isFinite,
               let value = Int(exactly: n.doubleValue), value >= 0 { return value }
        }
        return nil
    }

    private static func uint64(_ service: io_registry_entry_t, keys: [String]) -> UInt64? {
        for key in keys {
            if let n = property(service, key: key) as? NSNumber, n.doubleValue.isFinite, n.doubleValue >= 0,
               n.doubleValue.rounded() == n.doubleValue { return n.uint64Value }
        }
        return nil
    }
}

// MARK: - Bluetooth paired/connected devices (no active scan)

struct BluetoothBatteryMetrics: Sendable, Equatable {
    let mainPercent: Int?
    let leftPercent: Int?
    let rightPercent: Int?
    let casePercent: Int?
}

struct BluetoothDeviceMetrics: Sendable, Identifiable, Equatable {
    let address: String
    let name: String
    let connected: Bool
    let paired: Bool
    let rssiDBm: Int?
    let battery: BluetoothBatteryMetrics

    var id: String { address.isEmpty ? name : address }
}

struct BluetoothMetrics: Sendable, Equatable {
    let devices: [BluetoothDeviceMetrics]
}

actor BluetoothProvider {
    func reset() {}
    func sample() -> MetricSample<BluetoothMetrics> { MetricSample(captureMetric { try Self.read() }) }

    static func read() throws -> BluetoothMetrics {
        let batteries = readHIDBatteryMap()
        let paired = IOBluetoothDevice.pairedDevices() ?? []
        var devices: [BluetoothDeviceMetrics] = []
        devices.reserveCapacity(paired.count)

        for case let device as IOBluetoothDevice in paired {
            let address = device.addressString ?? ""
            let name = device.nameOrAddress ?? (address.isEmpty ? "Bluetooth Device" : address)
            // IOBluetoothDevice.rssi() is *relative to the controller's golden range*;
            // a value of 0 there does not mean 0 dBm. rawRSSI() is the public API that
            // reports the perceived RSSI in dBm. Apple documents +127 as unavailable.
            let rawRSSI = Int(device.rawRSSI())
            let battery = batteries[normalize(address)] ?? batteries[normalize(name)] ?? BluetoothBatteryMetrics(mainPercent: nil, leftPercent: nil, rightPercent: nil, casePercent: nil)
            devices.append(BluetoothDeviceMetrics(
                address: address,
                name: name,
                connected: device.isConnected(),
                paired: device.isPaired(),
                rssiDBm: normalizedRawRSSI(rawRSSI),
                battery: battery
            ))
        }
        return BluetoothMetrics(devices: devices.sorted {
            if $0.connected != $1.connected { return $0.connected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        })
    }

    static func normalizedRawRSSI(_ value: Int) -> Int? {
        value == 127 ? nil : value
    }

    private static func readHIDBatteryMap() -> [String: BluetoothBatteryMetrics] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: BluetoothBatteryMetrics] = [:]

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  (dict["BluetoothDevice"] as? Bool) == true else { continue }
            let battery = BluetoothBatteryMetrics(
                mainPercent: percent(dict["BatteryPercent"]),
                leftPercent: percent(dict["BatteryPercentLeft"]),
                rightPercent: percent(dict["BatteryPercentRight"]),
                casePercent: percent(dict["BatteryPercentCase"])
            )
            let names = [dict["DeviceAddress"] as? String, dict["SerialNumber"] as? String, dict["Product"] as? String].compactMap { $0 }
            for key in names where !key.isEmpty { result[normalize(key)] = battery }
        }
        return result
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        var value = number.doubleValue
        if value > 0, value <= 1 { value *= 100 }
        guard value >= 0, value <= 100 else { return nil }
        return Int(value.rounded())
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Sleep blockers / power assertions

struct PowerAssertionMetrics: Sendable, Identifiable, Equatable {
    let pid: Int32
    let processName: String
    let assertionType: String
    let reason: String?
    let preventsDisplaySleep: Bool
    let preventsSystemSleep: Bool

    var id: String { "\(pid)-\(assertionType)-\(reason ?? "")" }
}

struct PowerAssertionsMetrics: Sendable, Equatable {
    let assertions: [PowerAssertionMetrics]

    var displaySleepBlockers: [PowerAssertionMetrics] { assertions.filter(\.preventsDisplaySleep) }
    var systemSleepBlockers: [PowerAssertionMetrics] { assertions.filter(\.preventsSystemSleep) }
}

actor PowerAssertionsProvider {
    func reset() {}
    func sample() -> MetricSample<PowerAssertionsMetrics> { MetricSample(captureMetric { try Self.read() }) }

    static func read() throws -> PowerAssertionsMetrics {
        var unmanaged: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&unmanaged)
        guard status == kIOReturnSuccess else { throw TelemetryError.ioKit("Power assertion query", status) }
        guard let dictionary = unmanaged?.takeRetainedValue() else {
            throw TelemetryError.invalidData("Power assertion query returned no dictionary")
        }
        return parseDictionary(dictionary as NSDictionary, processNameResolver: processName)
    }

    /// Parses the public IOPMCopyAssertionsByProcess shape without assuming Swift-native
    /// String keys. IOPMLib documents top-level PIDs as CFNumbers and each value as a
    /// CFArray of CFDictionary assertion records.
    static func parseDictionary(
        _ raw: NSDictionary,
        processNameResolver: (Int32) -> String?
    ) -> PowerAssertionsMetrics {
        var assertions: [PowerAssertionMetrics] = []

        for (pidKey, rawValues) in raw {
            guard let pidNumber = pidKey as? NSNumber else { continue }
            let pid64 = pidNumber.int64Value
            guard pid64 > 0, pid64 <= Int64(Int32.max), let values = rawValues as? [Any] else { continue }
            let pid = Int32(pid64)
            let name = processNameResolver(pid) ?? "PID \(pid)"

            for case let value as [String: Any] in values {
                // Public IOPMLib keys are AssertLevel / AssertType / AssertName.
                // Keep the older aliases as tolerant fallbacks for OS variation.
                let level = (value["AssertLevel"] as? NSNumber) ?? (value["Level"] as? NSNumber)
                if level?.intValue == 0 { continue }

                let type = (value["AssertType"] as? String)
                    ?? (value["AssertionType"] as? String)
                    ?? (value["Type"] as? String)
                    ?? "Unknown"
                let reason = (value["HumanReadableReason"] as? String)
                    ?? (value["AssertName"] as? String)
                    ?? (value["AssertionName"] as? String)
                    ?? (value["Name"] as? String)
                let lower = type.lowercased()
                let display = lower.contains("preventuseridledisplaysleep") || lower.contains("displaywake")
                let system = lower.contains("preventuseridlesystemsleep") || lower.contains("preventsystemsleep") || lower.contains("systemisactive")
                assertions.append(PowerAssertionMetrics(
                    pid: pid,
                    processName: name,
                    assertionType: type,
                    reason: reason,
                    preventsDisplaySleep: display,
                    preventsSystemSleep: system
                ))
            }
        }

        assertions.sort {
            let name = $0.processName.localizedCaseInsensitiveCompare($1.processName)
            if name != .orderedSame { return name == .orderedAscending }
            if $0.assertionType != $1.assertionType { return $0.assertionType < $1.assertionType }
            return $0.pid < $1.pid
        }
        return PowerAssertionsMetrics(assertions: assertions)
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Clock/calendar metadata

struct ClockZoneMetrics: Sendable, Identifiable, Equatable {
    let identifier: String
    let abbreviation: String
    let offsetSeconds: Int
    let localDate: Date

    var id: String { identifier }
}

struct ClockMetrics: Sendable, Equatable {
    let localTimeZoneIdentifier: String
    let isoWeekOfYear: Int
    let dayOfYear: Int
    let zones: [ClockZoneMetrics]
}

actor ClockProvider {
    private let zoneIdentifiers: [String]

    init(zoneIdentifiers: [String] = ["UTC"]) { self.zoneIdentifiers = zoneIdentifiers }
    func reset() {}
    func sample() -> MetricSample<ClockMetrics> { MetricSample(.success(Self.read(zoneIdentifiers: zoneIdentifiers))) }

    static func read(now: Date = Date(), zoneIdentifiers: [String] = ["UTC"]) -> ClockMetrics {
        let calendar = Calendar(identifier: .iso8601)
        let week = calendar.component(.weekOfYear, from: now)
        let day = Calendar(identifier: .gregorian).ordinality(of: .day, in: .year, for: now) ?? 0
        var seen = Set<String>()
        let zones = zoneIdentifiers.compactMap { identifier -> ClockZoneMetrics? in
            guard seen.insert(identifier).inserted, let zone = TimeZone(identifier: identifier) else { return nil }
            return ClockZoneMetrics(identifier: identifier, abbreviation: zone.abbreviation(for: now) ?? identifier, offsetSeconds: zone.secondsFromGMT(for: now), localDate: now)
        }
        return ClockMetrics(localTimeZoneIdentifier: TimeZone.current.identifier, isoWeekOfYear: week, dayOfYear: day, zones: zones)
    }
}
