import Foundation
import CoreFoundation
import IOKit

struct StorageIOCounters: Sendable, Equatable {
    let bytesRead: UInt64
    let bytesWritten: UInt64
    let readOperations: UInt64
    let writeOperations: UInt64
    let readErrors: UInt64
    let writeErrors: UInt64
}

struct StorageThroughput: Sendable, Equatable {
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
    let readIOPS: Double
    let writeIOPS: Double
}

struct NVMeCounter128: Sendable, Equatable {
    let low: UInt64
    let high: UInt64

    var approximateValue: Double {
        Double(high) * 18_446_744_073_709_551_616.0 + Double(low)
    }

    var uint64Value: UInt64? { high == 0 ? low : nil }
}

enum StorageHealthState: String, Sendable, Equatable {
    case verified = "Verified"
    case attention = "Attention"
    case critical = "Critical"
}

struct NVMeSMARTHealth: Sendable, Equatable {
    let criticalWarning: UInt8
    let temperatureCelsius: Double?
    let availableSparePercent: UInt8
    let availableSpareThresholdPercent: UInt8
    let percentageUsed: UInt8
    let dataUnitsRead: NVMeCounter128
    let dataUnitsWritten: NVMeCounter128
    let hostReadCommands: NVMeCounter128
    let hostWriteCommands: NVMeCounter128
    let controllerBusyMinutes: NVMeCounter128
    let powerCycles: NVMeCounter128
    let powerOnHours: NVMeCounter128
    let unsafeShutdowns: NVMeCounter128
    let mediaErrors: NVMeCounter128
    let errorLogEntries: NVMeCounter128

    var lifetimeReadBytes: Double { dataUnitsRead.approximateValue * 512_000.0 }
    var lifetimeWrittenBytes: Double { dataUnitsWritten.approximateValue * 512_000.0 }
    var lifeRemainingPercent: Int { max(0, 100 - Int(percentageUsed)) }

    var state: StorageHealthState {
        if criticalWarning != 0 || availableSparePercent < availableSpareThresholdPercent || percentageUsed >= 100 { return .critical }
        if percentageUsed >= 80 { return .attention }
        return .verified
    }
}

enum StorageSMARTCapability: String, Sendable, Equatable {
    case nvmeAdvertised = "NVMe SMART advertised"
    case ataAdvertised = "ATA SMART advertised"
    case notAdvertised = "SMART not advertised"
}

struct StorageDeviceMetrics: Sendable, Equatable {
    let registryID: UInt64
    let bsdName: String
    let model: String
    let capacityBytes: UInt64
    let isInternal: Bool
    let isRemovable: Bool
    let transport: String
    let controllerClass: String
    let smartCapability: StorageSMARTCapability
    let counters: MetricResult<StorageIOCounters>

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.registryID == rhs.registryID && lhs.bsdName == rhs.bsdName && lhs.model == rhs.model &&
        lhs.capacityBytes == rhs.capacityBytes && lhs.isInternal == rhs.isInternal &&
        lhs.isRemovable == rhs.isRemovable && lhs.transport == rhs.transport &&
        lhs.controllerClass == rhs.controllerClass && lhs.smartCapability == rhs.smartCapability &&
        equalMetric(lhs.counters, rhs.counters)
    }

    private static func equalMetric<T: Equatable>(_ lhs: MetricResult<T>, _ rhs: MetricResult<T>) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a), .success(let b)): return a == b
        case (.failure(let a), .failure(let b)): return a == b
        default: return false
        }
    }
}

struct RootVolumeMetrics: Sendable, Equatable {
    let totalBytes: UInt64
    let freeBytes: UInt64
    var usedBytes: UInt64 { totalBytes >= freeBytes ? totalBytes - freeBytes : 0 }
}

/// Refresh cadences for data that does not need to be rediscovered at the
/// two-second live I/O sampling rate. Live device counters remain on the
/// existing TelemetryMonitor cadence; only slow/static discovery work is
/// decoupled from it.
struct StorageInventoryRefreshPolicy: Sendable, Equatable {
    let topologySeconds: Double
    let metadataSeconds: Double

    static let production = StorageInventoryRefreshPolicy(
        topologySeconds: 5,
        metadataSeconds: 300
    )

    func shouldRefresh(lastTicks: UInt64?, nowTicks: UInt64, intervalSeconds: Double) -> Bool {
        guard let lastTicks else { return true }
        return shouldRefresh(ageSeconds: HostClock.seconds(from: lastTicks, to: nowTicks), intervalSeconds: intervalSeconds)
    }

    func shouldRefresh(ageSeconds: Double, intervalSeconds: Double) -> Bool {
        guard intervalSeconds.isFinite, intervalSeconds > 0 else { return true }
        return !ageSeconds.isFinite || ageSeconds < 0 || ageSeconds >= intervalSeconds
    }
}

fileprivate struct StorageTopologyIdentity: Sendable, Equatable, Comparable {
    let registryID: UInt64
    let bsdName: String
    let capacityBytes: UInt64
    let isRemovable: Bool

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.bsdName != rhs.bsdName {
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
        return lhs.registryID < rhs.registryID
    }
}

fileprivate struct CachedStorageDevice: Sendable, Equatable {
    let registryID: UInt64
    let bsdName: String
    let model: String
    let capacityBytes: UInt64
    let isInternal: Bool
    let isRemovable: Bool
    let transport: String
    let controllerClass: String
    let smartCapability: StorageSMARTCapability
    let counterSourceRegistryID: UInt64?

    var topologyIdentity: StorageTopologyIdentity {
        StorageTopologyIdentity(
            registryID: registryID,
            bsdName: bsdName,
            capacityBytes: capacityBytes,
            isRemovable: isRemovable
        )
    }

    func metrics(counters: MetricResult<StorageIOCounters>) -> StorageDeviceMetrics {
        StorageDeviceMetrics(
            registryID: registryID,
            bsdName: bsdName,
            model: model,
            capacityBytes: capacityBytes,
            isInternal: isInternal,
            isRemovable: isRemovable,
            transport: transport,
            controllerClass: controllerClass,
            smartCapability: smartCapability,
            counters: counters
        )
    }
}

struct StorageMetrics: Sendable {
    let rootVolume: MetricResult<RootVolumeMetrics>
    let devices: [StorageDeviceMetrics]
    let primaryDeviceBSDName: String?
    let throughput: MetricResult<StorageThroughput>
    let smartHealth: MetricResult<NVMeSMARTHealth>
    let smartHealthCapturedTicks: UInt64?
    /// Physical primary-device counter deltas since this Helios process first
    /// observed the device. These are device I/O, not per-process attribution.
    let monitoringReadBytes: MetricResult<UInt64>
    let monitoringWrittenBytes: MetricResult<UInt64>

    init(rootVolume: MetricResult<RootVolumeMetrics>, devices: [StorageDeviceMetrics], primaryDeviceBSDName: String?,
         throughput: MetricResult<StorageThroughput>, smartHealth: MetricResult<NVMeSMARTHealth>, smartHealthCapturedTicks: UInt64?,
         monitoringReadBytes: MetricResult<UInt64> = .failure(.warmingUp),
         monitoringWrittenBytes: MetricResult<UInt64> = .failure(.warmingUp)) {
        self.rootVolume = rootVolume
        self.devices = devices
        self.primaryDeviceBSDName = primaryDeviceBSDName
        self.throughput = throughput
        self.smartHealth = smartHealth
        self.smartHealthCapturedTicks = smartHealthCapturedTicks
        self.monitoringReadBytes = monitoringReadBytes
        self.monitoringWrittenBytes = monitoringWrittenBytes
    }

    var primaryDevice: StorageDeviceMetrics? {
        guard let primaryDeviceBSDName else { return devices.first(where: { $0.isInternal }) }
        return devices.first(where: { $0.bsdName == primaryDeviceBSDName })
    }

    /// Real external block devices only. Mounted DMGs are represented by
    /// IOBlockStorageDriver/"Disk Image" entries and must never be presented as
    /// physical external storage.
    var externalPhysicalDevices: [StorageDeviceMetrics] {
        devices.filter {
            !$0.isInternal &&
            $0.model.caseInsensitiveCompare("Disk Image") != .orderedSame &&
            $0.controllerClass != "IOBlockStorageDriver" &&
            $0.transport != "Virtual Interface"
        }
    }
}

struct StorageRateCalculator: Sendable {
    private var previous: StorageIOCounters?

    mutating func reset() { previous = nil }

    mutating func consume(_ counters: StorageIOCounters, elapsedSeconds: Double) -> MetricResult<StorageThroughput> {
        defer { previous = counters }
        guard let previous else { return .failure(.warmingUp) }
        guard elapsedSeconds.isFinite, elapsedSeconds > 0, elapsedSeconds <= 30 else {
            return .failure(.unavailable("Storage sampling interval invalid"))
        }
        guard counters.bytesRead >= previous.bytesRead, counters.bytesWritten >= previous.bytesWritten else {
            return .failure(.warmingUp)
        }
        let readOps = counters.readOperations >= previous.readOperations ? counters.readOperations - previous.readOperations : 0
        let writeOps = counters.writeOperations >= previous.writeOperations ? counters.writeOperations - previous.writeOperations : 0
        return .success(StorageThroughput(
            readBytesPerSecond: Double(counters.bytesRead - previous.bytesRead) / elapsedSeconds,
            writeBytesPerSecond: Double(counters.bytesWritten - previous.bytesWritten) / elapsedSeconds,
            readIOPS: Double(readOps) / elapsedSeconds,
            writeIOPS: Double(writeOps) / elapsedSeconds
        ))
    }
}

struct StorageThroughputTracker: Sendable {
    private var calculator = StorageRateCalculator()
    private var previousTicks: UInt64?

    mutating func reset() { calculator.reset(); previousTicks = nil }

    mutating func update(counters: StorageIOCounters, ticks: UInt64) -> MetricResult<StorageThroughput> {
        guard let previousTicks else {
            self.previousTicks = ticks
            _ = calculator.consume(counters, elapsedSeconds: 1)
            return .failure(.warmingUp)
        }
        self.previousTicks = ticks
        return calculator.consume(counters, elapsedSeconds: HostClock.seconds(from: previousTicks, to: ticks))
    }
}

enum StorageParser {
    static func counters(_ statistics: [String: Any]) throws -> StorageIOCounters {
        StorageIOCounters(
            bytesRead: try uint64(statistics, key: "Bytes (Read)"),
            bytesWritten: try uint64(statistics, key: "Bytes (Write)"),
            readOperations: try uint64(statistics, key: "Operations (Read)", defaultValue: 0),
            writeOperations: try uint64(statistics, key: "Operations (Write)", defaultValue: 0),
            readErrors: try uint64(statistics, key: "Errors (Read)", defaultValue: 0),
            writeErrors: try uint64(statistics, key: "Errors (Write)", defaultValue: 0)
        )
    }

    static func rootVolume(_ attributes: [FileAttributeKey: Any]) throws -> RootVolumeMetrics {
        guard let totalNumber = attributes[.systemSize] as? NSNumber,
              let freeNumber = attributes[.systemFreeSize] as? NSNumber else {
            throw TelemetryError.unavailable("Root volume capacity unavailable")
        }
        let total = totalNumber.uint64Value
        let free = freeNumber.uint64Value
        guard total > 0, free <= total else { throw TelemetryError.invalidData("Invalid root volume capacity") }
        return RootVolumeMetrics(totalBytes: total, freeBytes: free)
    }

    static func smartCapability(nvme: Bool, ata: Bool) -> StorageSMARTCapability {
        if nvme { return .nvmeAdvertised }
        if ata { return .ataAdvertised }
        return .notAdvertised
    }

    private static func uint64(_ dictionary: [String: Any], key: String, defaultValue: UInt64? = nil) throws -> UInt64 {
        guard let raw = dictionary[key] else {
            if let defaultValue { return defaultValue }
            throw TelemetryError.unavailable("Storage statistic \(key) unavailable")
        }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw TelemetryError.invalidData("Storage statistic \(key) is not an integer")
        }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double, double <= Double(UInt64.max) else {
            throw TelemetryError.invalidData("Storage statistic \(key) is invalid")
        }
        return number.uint64Value
    }
}

private enum IORegistryStorage {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func bool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        (property(entry, key) as? NSNumber)?.boolValue
    }

    static func uint64(_ entry: io_registry_entry_t, _ key: String) -> UInt64? {
        guard let number = property(entry, key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.uint64Value
    }

    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    static func dictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        property(entry, key) as? [String: Any]
    }

    static func className(_ entry: io_object_t) -> String {
        guard let value = IOObjectCopyClass(entry)?.takeRetainedValue() else { return "Unknown" }
        return value as String
    }

    static func ancestors(from entry: io_registry_entry_t, limit: Int = 12) -> [io_registry_entry_t] {
        var result: [io_registry_entry_t] = []
        var current = entry
        for _ in 0..<limit {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    static func nestedString(_ entry: io_registry_entry_t, dictionaryKey: String, valueKey: String) -> String? {
        dictionary(entry, dictionaryKey)?[valueKey] as? String
    }

    static func firstString(_ entries: [io_registry_entry_t], keys: [String]) -> String? {
        for entry in entries {
            for key in keys {
                if let value = string(entry, key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            }
            if let value = nestedString(entry, dictionaryKey: "Device Characteristics", valueKey: "Product Name"), !value.isEmpty { return value }
        }
        return nil
    }

    static func registryID(_ entry: io_registry_entry_t) -> UInt64? {
        var value: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &value) == KERN_SUCCESS, value != 0 else { return nil }
        return value
    }

    static func statisticsSource(in entries: [io_registry_entry_t]) -> (entry: io_registry_entry_t, registryID: UInt64)? {
        for entry in entries {
            guard let stats = dictionary(entry, "Statistics"),
                  stats["Bytes (Read)"] != nil || stats["Bytes (Write)"] != nil,
                  let registryID = registryID(entry) else { continue }
            return (entry, registryID)
        }
        return nil
    }
}

/// Process-lifetime retained handle to the exact IORegistry node that publishes
/// live storage counters. Keeping the service object avoids rebuilding an
/// IORegistry matching dictionary and performing a service lookup for every
/// device on every two-second sample. If the underlying service disappears,
/// the property read fails and StorageProvider performs a bounded rediscovery.
fileprivate final class StorageCounterSource {
    let registryID: UInt64
    private let entry: io_registry_entry_t

    init?(retaining entry: io_registry_entry_t, registryID: UInt64) {
        guard IOObjectRetain(entry) == KERN_SUCCESS else { return nil }
        self.entry = entry
        self.registryID = registryID
    }

    deinit {
        IOObjectRelease(entry)
    }

    func readCounters() throws -> StorageIOCounters {
        guard let statistics = IORegistryStorage.dictionary(entry, "Statistics") else {
            throw TelemetryError.unavailable("Storage statistics source unavailable")
        }
        return try StorageParser.counters(statistics)
    }
}

fileprivate struct StorageInventoryDiscovery {
    let devices: [CachedStorageDevice]
    let counterSources: [UInt64: StorageCounterSource]
}


private typealias NVMeSMARTReadDataFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
private typealias NVMeGetIdentifyDataFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> IOReturn
private typealias NVMeGetLogPageFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> IOReturn
private typealias NVMeQueryInterfaceFunction = @convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
private typealias NVMeReferenceFunction = @convention(c) (UnsafeMutableRawPointer?) -> UInt32

/// Prefix of Apple's public IONVMeSMARTInterface vtable. The version/revision
/// fields are intentionally present between IUnknown and SMARTReadData; omitting
/// them shifts the function pointer and can crash the process.
private struct IONVMeSMARTInterfacePrefix {
    var reserved: UnsafeMutableRawPointer?
    var queryInterface: NVMeQueryInterfaceFunction?
    var addRef: NVMeReferenceFunction?
    var release: NVMeReferenceFunction?
    var version: UInt16
    var revision: UInt16
    var smartReadData: NVMeSMARTReadDataFunction?
    var getIdentifyData: NVMeGetIdentifyDataFunction?
    var reserved0: UInt64
    var reserved1: UInt64
    var getLogPage: NVMeGetLogPageFunction?
}

struct NVMeSMARTParser {
    static func parse(_ bytes: [UInt8]) throws -> NVMeSMARTHealth {
        guard bytes.count >= 192 else { throw TelemetryError.invalidData("NVMe SMART log is shorter than 192 bytes") }
        let kelvin = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        let temperature: Double?
        if kelvin == 0 { temperature = nil }
        else {
            let celsius = Double(kelvin) - 273.15
            guard celsius.isFinite, (-80...200).contains(celsius) else { throw TelemetryError.invalidData("NVMe SMART temperature is invalid") }
            temperature = celsius
        }
        return NVMeSMARTHealth(
            criticalWarning: bytes[0],
            temperatureCelsius: temperature,
            availableSparePercent: bytes[3],
            availableSpareThresholdPercent: bytes[4],
            percentageUsed: bytes[5],
            dataUnitsRead: counter128(bytes, offset: 32),
            dataUnitsWritten: counter128(bytes, offset: 48),
            hostReadCommands: counter128(bytes, offset: 64),
            hostWriteCommands: counter128(bytes, offset: 80),
            controllerBusyMinutes: counter128(bytes, offset: 96),
            powerCycles: counter128(bytes, offset: 112),
            powerOnHours: counter128(bytes, offset: 128),
            unsafeShutdowns: counter128(bytes, offset: 144),
            mediaErrors: counter128(bytes, offset: 160),
            errorLogEntries: counter128(bytes, offset: 176)
        )
    }

    private static func counter128(_ bytes: [UInt8], offset: Int) -> NVMeCounter128 {
        func word(_ start: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(bytes[start + index]) << UInt64(index * 8) }
            return value
        }
        return NVMeCounter128(low: word(offset), high: word(offset + 8))
    }
}

/// Native, unprivileged, read-only NVMe SMART reader. It uses Apple's
/// NVMeSMARTLib COM plugin interface and reads only the SMART/Health log via
/// SMARTReadData or GetLogPage(0x02). It never sends a storage mutation command
/// or opens the privileged fan helper.
enum NVMeSMARTUUIDs {
    /// IOCFPlugIn.h publishes this as the C macro kIOCFPlugInInterfaceID.
    /// Swift 6 cannot import that macro because it expands to a CFUUID object,
    /// so construct the exact public UUID explicitly instead of shadowing the
    /// unavailable macro at the call site.
    static func pluginInterface() -> CFUUID {
        CFUUIDCreateWithBytes(kCFAllocatorDefault, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }

    static func userClient() -> CFUUID {
        CFUUIDCreateWithBytes(kCFAllocatorDefault, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    }

    static func interface() -> CFUUID {
        CFUUIDCreateWithBytes(kCFAllocatorDefault, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    }
}

struct NVMeSMARTNativeReader {

    func read(bsdName: String) throws -> NVMeSMARTHealth {
        guard bsdName.hasPrefix("disk"), let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            throw TelemetryError.invalidData("Invalid storage BSD name")
        }
        var service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw TelemetryError.unavailable("Storage service \(bsdName) unavailable") }
        defer { if service != 0 { _ = IOObjectRelease(service) } }

        var hops = 0
        while IORegistryStorage.bool(service, "NVMe SMART Capable") != true {
            guard hops < 16 else { throw TelemetryError.unavailable("NVMe SMART-capable parent not found") }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
            guard status == KERN_SUCCESS, parent != 0 else { throw TelemetryError.unavailable("NVMe SMART-capable parent not found") }
            _ = IOObjectRelease(service)
            service = parent
            hops += 1
        }

        let userClient = NVMeSMARTUUIDs.userClient()
        let pluginInterface = NVMeSMARTUUIDs.pluginInterface()
        let interfaceID = NVMeSMARTUUIDs.interface()

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let createStatus = IOCreatePlugInInterfaceForService(service, userClient, pluginInterface, &plugin, &score)
        guard createStatus == kIOReturnSuccess, let plugin, let pluginVTable = plugin.pointee?.pointee else {
            throw TelemetryError.ioKit("Create NVMe SMART plugin", createStatus)
        }
        defer { _ = IODestroyPlugInInterface(plugin) }

        var smartRaw: UnsafeMutableRawPointer?
        let queryStatus: Int32 = withUnsafeMutablePointer(to: &smartRaw) { output in
            output.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) { rebound in
                pluginVTable.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceID), rebound)
            }
        }
        guard queryStatus == 0, let smartRaw else {
            throw TelemetryError.unavailable("NVMe SMART QueryInterface failed (\(queryStatus))")
        }

        let smartPointer = smartRaw.assumingMemoryBound(to: Optional<UnsafeMutablePointer<IONVMeSMARTInterfacePrefix>>.self)
        guard let tablePointer = smartPointer.pointee else {
            throw TelemetryError.unavailable("NVMe SMART interface vtable unavailable")
        }
        let table = tablePointer.pointee
        defer { _ = table.release?(smartRaw) }
        guard table.smartReadData != nil || table.getLogPage != nil else {
            throw TelemetryError.unavailable("NVMe SMART interface exposes no read-only health-log method")
        }

        // Apple's interface exposes SMARTReadData directly, while smartmontools
        // deliberately uses GetLogPage for NVMe admin log-page reads. Support
        // both read-only paths so Apple controller/OS revisions can choose the
        // method they actually implement. Log page 0x02 is the standard 512-byte
        // NVMe SMART / Health Information log; NumDWords is zero-based.
        var bytes = [UInt8](repeating: 0, count: 512)
        var directReadFailure: IOReturn?
        if let smartReadData = table.smartReadData {
            let status = bytes.withUnsafeMutableBytes { buffer -> IOReturn in
                guard let baseAddress = buffer.baseAddress else { return kIOReturnNoMemory }
                return smartReadData(smartRaw, baseAddress)
            }
            if status == kIOReturnSuccess { return try NVMeSMARTParser.parse(bytes) }
            directReadFailure = status
        }

        if let getLogPage = table.getLogPage {
            bytes = [UInt8](repeating: 0, count: 512)
            let status = bytes.withUnsafeMutableBytes { buffer -> IOReturn in
                guard let baseAddress = buffer.baseAddress else { return kIOReturnNoMemory }
                return getLogPage(smartRaw, baseAddress, 0x02, UInt32(buffer.count / 4 - 1))
            }
            if status == kIOReturnSuccess { return try NVMeSMARTParser.parse(bytes) }
            throw TelemetryError.ioKit("Read NVMe SMART health log page", status)
        }

        throw TelemetryError.ioKit("Read NVMe SMART health log", directReadFailure ?? kIOReturnUnsupported)
    }
}

struct IOKitStorageReader {
    func read() throws -> StorageMetrics {
        let discovery = try discoverInventory()
        guard !discovery.devices.isEmpty else { throw TelemetryError.unavailable("No whole storage devices discovered") }
        let devices = discovery.devices.map { device in
            device.metrics(counters: captureMetric {
                guard let sourceID = device.counterSourceRegistryID,
                      let source = discovery.counterSources[sourceID] else {
                    throw TelemetryError.unavailable("IOBlockStorage statistics unavailable")
                }
                return try source.readCounters()
            })
        }
        let rootVolume = readRootVolume()
        let primary = devices.first(where: { $0.isInternal && !$0.isRemovable }) ?? devices.first(where: { $0.isInternal }) ?? devices.first
        return StorageMetrics(rootVolume: rootVolume, devices: devices, primaryDeviceBSDName: primary?.bsdName, throughput: .failure(.warmingUp), smartHealth: .failure(.warmingUp), smartHealthCapturedTicks: nil)
    }

    func readWithSMARTProbe() throws -> StorageMetrics {
        let metrics = try read()
        let smart: MetricResult<NVMeSMARTHealth>
        if let primary = metrics.primaryDevice, primary.smartCapability == .nvmeAdvertised {
            smart = captureMetric { try NVMeSMARTNativeReader().read(bsdName: primary.bsdName) }
        } else {
            smart = .failure(.unavailable("Primary storage does not advertise native NVMe SMART"))
        }
        return StorageMetrics(
            rootVolume: metrics.rootVolume,
            devices: metrics.devices,
            primaryDeviceBSDName: metrics.primaryDeviceBSDName,
            throughput: metrics.throughput,
            smartHealth: smart,
            smartHealthCapturedTicks: HostClock.now
        )
    }

    func readRootVolume() -> MetricResult<RootVolumeMetrics> {
        captureMetric { try StorageParser.rootVolume(FileManager.default.attributesOfFileSystem(forPath: "/")) }
    }

    /// Lightweight topology probe. It intentionally reads only properties on
    /// whole IOMedia nodes and never walks ancestors, resolves controller
    /// classes, or probes SMART capability. Full metadata discovery is only
    /// repeated when this identity set changes or the slow fallback expires.
    fileprivate func topologySnapshot() throws -> [StorageTopologyIdentity] {
        guard let matching = IOServiceMatching("IOMedia") else { throw TelemetryError.unavailable("IOMedia matching unavailable") }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else { throw TelemetryError.ioKit("Enumerate storage topology", status) }
        defer { IOObjectRelease(iterator) }

        var identities: [StorageTopologyIdentity] = []
        while true {
            let media = IOIteratorNext(iterator)
            guard media != 0 else { break }
            defer { IOObjectRelease(media) }
            guard IORegistryStorage.bool(media, "Whole") == true,
                  let bsdName = IORegistryStorage.string(media, "BSD Name"),
                  let size = IORegistryStorage.uint64(media, "Size"), size > 0,
                  let registryID = IORegistryStorage.registryID(media) else { continue }
            identities.append(StorageTopologyIdentity(
                registryID: registryID,
                bsdName: bsdName,
                capacityBytes: size,
                isRemovable: IORegistryStorage.bool(media, "Removable") ?? false
            ))
        }
        return identities.sorted()
    }

    /// Full storage discovery. This is intentionally slow-cadence: it walks
    /// the registry lineage once to cache immutable/slow metadata and the exact
    /// registry entry that publishes live I/O Statistics.
    fileprivate func discoverInventory() throws -> StorageInventoryDiscovery {
        guard let matching = IOServiceMatching("IOMedia") else { throw TelemetryError.unavailable("IOMedia matching unavailable") }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else { throw TelemetryError.ioKit("Enumerate storage media", status) }
        defer { IOObjectRelease(iterator) }

        var devices: [CachedStorageDevice] = []
        var counterSources: [UInt64: StorageCounterSource] = [:]
        while true {
            let media = IOIteratorNext(iterator)
            guard media != 0 else { break }
            defer { IOObjectRelease(media) }
            guard IORegistryStorage.bool(media, "Whole") == true,
                  let bsdName = IORegistryStorage.string(media, "BSD Name"),
                  let size = IORegistryStorage.uint64(media, "Size"), size > 0,
                  let registryID = IORegistryStorage.registryID(media) else { continue }

            let ancestors = IORegistryStorage.ancestors(from: media)
            defer { ancestors.forEach { IOObjectRelease($0) } }
            let lineage = [media] + ancestors
            let removable = IORegistryStorage.bool(media, "Removable") ?? false
            let internalLocation = lineage.compactMap {
                IORegistryStorage.nestedString($0, dictionaryKey: "Protocol Characteristics", valueKey: "Physical Interconnect Location")
            }.first
            let transport = lineage.compactMap {
                IORegistryStorage.nestedString($0, dictionaryKey: "Protocol Characteristics", valueKey: "Physical Interconnect")
            }.first ?? "Unknown"
            let isInternal = internalLocation?.localizedCaseInsensitiveContains("internal") == true || (!removable && bsdName == "disk0")
            let model = IORegistryStorage.firstString(lineage, keys: ["Model", "Product Name", "IOName"]) ?? "Internal storage"
            let classes = lineage.map(IORegistryStorage.className)
            let controllerClass = classes.first(where: {
                $0.localizedCaseInsensitiveContains("NVMe") || $0.localizedCaseInsensitiveContains("ANS")
            }) ?? classes.first(where: {
                $0.localizedCaseInsensitiveContains("Storage")
            }) ?? IORegistryStorage.className(media)
            let nvmeSMART = lineage.contains { IORegistryStorage.bool($0, "NVMe SMART Capable") == true }
            let ataSMART = lineage.contains { IORegistryStorage.bool($0, "SMART Capable") == true }
            let counterSourceInfo = IORegistryStorage.statisticsSource(in: lineage)
            let counterSourceRegistryID = counterSourceInfo?.registryID
            if let info = counterSourceInfo, counterSources[info.registryID] == nil,
               let retained = StorageCounterSource(retaining: info.entry, registryID: info.registryID) {
                counterSources[info.registryID] = retained
            }
            devices.append(CachedStorageDevice(
                registryID: registryID,
                bsdName: bsdName,
                model: model,
                capacityBytes: size,
                isInternal: isInternal,
                isRemovable: removable,
                transport: transport,
                controllerClass: controllerClass,
                smartCapability: StorageParser.smartCapability(nvme: nvmeSMART, ata: ataSMART),
                counterSourceRegistryID: counterSourceRegistryID
            ))
        }
        let sortedDevices = devices.sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal && !$1.isInternal }
            return $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
        return StorageInventoryDiscovery(devices: sortedDevices, counterSources: counterSources)
    }
}

actor StorageProvider {
    private var tracker = StorageThroughputTracker()
    private var monitoringDeviceBSDName: String?
    private var monitoringBaseline: StorageIOCounters?
    private var smartHealth: MetricResult<NVMeSMARTHealth> = .failure(.warmingUp)
    private var smartDeviceBSDName: String?
    private var smartSampleTicks: UInt64?
    private let smartRefreshSeconds = 30.0

    private let refreshPolicy = StorageInventoryRefreshPolicy.production
    private var cachedDevices: [CachedStorageDevice] = []
    private var counterSources: [UInt64: StorageCounterSource] = [:]
    private var cachedTopology: [StorageTopologyIdentity] = []
    private var topologyProbeTicks: UInt64?
    private var metadataRefreshTicks: UInt64?
    private var counterFailureRediscoveryTicks: UInt64?

    func reset() {
        tracker.reset()
        // A disabled collector or sleep/wake may hide a topology change. Force
        // one fresh discovery when sampling resumes, while preserving the
        // process-lifetime physical-I/O baseline below.
        cachedDevices.removeAll(keepingCapacity: true)
        counterSources.removeAll(keepingCapacity: true)
        cachedTopology.removeAll(keepingCapacity: true)
        topologyProbeTicks = nil
        metadataRefreshTicks = nil
        counterFailureRediscoveryTicks = nil
        // Keep the physical-device baseline across sleep/wake so the UI can
        // answer "how much I/O happened while this Helios process has existed".
        // A device change or counter rollback resets it independently below.
        smartHealth = .failure(.warmingUp)
        smartDeviceBSDName = nil
        smartSampleTicks = nil
    }

    func sample() -> MetricSample<StorageMetrics> {
        let date = Date()
        let ticks = HostClock.now
        let result = captureMetric {
            let reader = IOKitStorageReader()
            try refreshInventoryIfNeeded(reader: reader, ticks: ticks)
            guard !cachedDevices.isEmpty else { throw TelemetryError.unavailable("No whole storage devices discovered") }

            var counterFailureNeedsRediscovery = false
            var devices = cachedDevices.map { device -> StorageDeviceMetrics in
                let counters: MetricResult<StorageIOCounters>
                if device.counterSourceRegistryID == nil {
                    counters = .failure(.unavailable("IOBlockStorage statistics unavailable"))
                } else {
                    do { counters = .success(try readCounters(for: device)) }
                    catch {
                        counters = .failure((error as? TelemetryError) ?? .unavailable(error.localizedDescription))
                        counterFailureNeedsRediscovery = true
                    }
                }
                return device.metrics(counters: counters)
            }

            // A cached statistics publisher disappearing is stronger evidence
            // of topology/driver churn than the slow probe. Rediscover once
            // immediately so removal/reprobe does not stay stale until the next topology probe.
            if counterFailureNeedsRediscovery && refreshPolicy.shouldRefresh(
                lastTicks: counterFailureRediscoveryTicks,
                nowTicks: ticks,
                intervalSeconds: refreshPolicy.topologySeconds
            ) {
                counterFailureRediscoveryTicks = ticks
                if let refreshed = try? reader.discoverInventory(), !refreshed.devices.isEmpty {
                    installInventory(refreshed, ticks: ticks)
                    devices = cachedDevices.map { device in
                        device.metrics(counters: captureMetric { try readCounters(for: device) })
                    }
                }
            }

            let rootVolume = reader.readRootVolume()
            let primary = devices.first(where: { $0.isInternal && !$0.isRemovable }) ?? devices.first(where: { $0.isInternal }) ?? devices.first
            let primaryBSDName = primary?.bsdName
            let throughput: MetricResult<StorageThroughput>
            if let primary {
                switch primary.counters {
                case .success(let counters): throughput = tracker.update(counters: counters, ticks: ticks)
                case .failure(let error): throughput = .failure(error)
                }
            } else {
                throughput = .failure(.unavailable("Primary internal storage unavailable"))
            }

            let monitoring: (MetricResult<UInt64>, MetricResult<UInt64>)
            if let primary, case .success(let counters) = primary.counters {
                if monitoringDeviceBSDName != primary.bsdName || monitoringBaseline == nil {
                    monitoringDeviceBSDName = primary.bsdName
                    monitoringBaseline = counters
                    monitoring = (.success(0), .success(0))
                } else if let baseline = monitoringBaseline,
                          counters.bytesRead >= baseline.bytesRead,
                          counters.bytesWritten >= baseline.bytesWritten {
                    monitoring = (
                        .success(counters.bytesRead - baseline.bytesRead),
                        .success(counters.bytesWritten - baseline.bytesWritten)
                    )
                } else {
                    // A rollback means the device/driver counters restarted.
                    monitoringDeviceBSDName = primary.bsdName
                    monitoringBaseline = counters
                    monitoring = (.failure(.warmingUp), .failure(.warmingUp))
                }
            } else {
                monitoring = (.failure(.unavailable("Primary storage counters unavailable")), .failure(.unavailable("Primary storage counters unavailable")))
            }

            if let primary, primary.smartCapability == .nvmeAdvertised {
                let changedDevice = smartDeviceBSDName != primary.bsdName
                let age = smartSampleTicks.map { HostClock.seconds(from: $0, to: ticks) } ?? .infinity
                if changedDevice || !age.isFinite || age >= smartRefreshSeconds {
                    smartHealth = captureMetric { try NVMeSMARTNativeReader().read(bsdName: primary.bsdName) }
                    smartDeviceBSDName = primary.bsdName
                    smartSampleTicks = ticks
                }
            } else {
                smartHealth = .failure(.unavailable("Primary storage does not advertise native NVMe SMART"))
                smartDeviceBSDName = primaryBSDName
                smartSampleTicks = ticks
            }

            return StorageMetrics(
                rootVolume: rootVolume,
                devices: devices,
                primaryDeviceBSDName: primaryBSDName,
                throughput: throughput,
                smartHealth: smartHealth,
                smartHealthCapturedTicks: smartSampleTicks,
                monitoringReadBytes: monitoring.0,
                monitoringWrittenBytes: monitoring.1
            )
        }
        if case .failure = result { tracker.reset() }
        return MetricSample(result, capturedAt: date, capturedTicks: ticks)
    }

    private func refreshInventoryIfNeeded(reader: IOKitStorageReader, ticks: UInt64) throws {
        if cachedDevices.isEmpty {
            let discovered = try reader.discoverInventory()
            guard !discovered.devices.isEmpty else { throw TelemetryError.unavailable("No whole storage devices discovered") }
            installInventory(discovered, ticks: ticks)
            return
        }

        let metadataExpired = refreshPolicy.shouldRefresh(
            lastTicks: metadataRefreshTicks,
            nowTicks: ticks,
            intervalSeconds: refreshPolicy.metadataSeconds
        )
        if metadataExpired {
            if let discovered = try? reader.discoverInventory(), !discovered.devices.isEmpty {
                installInventory(discovered, ticks: ticks)
            } else {
                // Avoid retrying an expensive full discovery every two seconds
                // during a transient IOKit failure; the topology probe and live
                // counter failure path still provide earlier recovery signals.
                metadataRefreshTicks = ticks
            }
            return
        }

        guard refreshPolicy.shouldRefresh(
            lastTicks: topologyProbeTicks,
            nowTicks: ticks,
            intervalSeconds: refreshPolicy.topologySeconds
        ) else { return }
        topologyProbeTicks = ticks
        guard let topology = try? reader.topologySnapshot() else { return }
        guard topology != cachedTopology else { return }
        if let discovered = try? reader.discoverInventory(), !discovered.devices.isEmpty {
            installInventory(discovered, ticks: ticks)
        }
    }

    private func installInventory(_ discovery: StorageInventoryDiscovery, ticks: UInt64) {
        cachedDevices = discovery.devices
        counterSources = discovery.counterSources
        cachedTopology = discovery.devices.map(\.topologyIdentity).sorted()
        topologyProbeTicks = ticks
        metadataRefreshTicks = ticks
    }

    private func readCounters(for device: CachedStorageDevice) throws -> StorageIOCounters {
        guard let sourceID = device.counterSourceRegistryID,
              let source = counterSources[sourceID] else {
            throw TelemetryError.unavailable("IOBlockStorage statistics unavailable")
        }
        return try source.readCounters()
    }

}

extension StorageMetrics {
    var diagnosticText: String {
        var lines = ["Storage preflight (read-only)"]
        switch rootVolume {
        case .success(let volume):
            lines.append("Root volume: total=\(volume.totalBytes) free=\(volume.freeBytes) used=\(volume.usedBytes)")
        case .failure(let error):
            lines.append("Root volume: unavailable — \(error.localizedDescription)")
        }
        lines.append("Whole devices: \(devices.count)")
        for device in devices {
            lines.append("Device \(device.bsdName): model='\(device.model)' size=\(device.capacityBytes) internal=\(device.isInternal) removable=\(device.isRemovable)")
            lines.append("  transport='\(device.transport)' controller='\(device.controllerClass)' smart='\(device.smartCapability.rawValue)'")
            switch device.counters {
            case .success(let counters):
                lines.append("  since-boot IO: read=\(counters.bytesRead) write=\(counters.bytesWritten) readOps=\(counters.readOperations) writeOps=\(counters.writeOperations) readErrors=\(counters.readErrors) writeErrors=\(counters.writeErrors)")
            case .failure(let error):
                lines.append("  since-boot IO: unavailable — \(error.localizedDescription)")
            }
        }
        lines.append("Primary device: \(primaryDeviceBSDName ?? "none")")
        switch smartHealth {
        case .success(let smart):
            lines.append("NVMe SMART: state=\(smart.state.rawValue) critical=0x\(String(smart.criticalWarning, radix: 16)) temperature=\(smart.temperatureCelsius.map { String(format: "%.1fC", $0) } ?? "n/a") spare=\(smart.availableSparePercent)% threshold=\(smart.availableSpareThresholdPercent)% used=\(smart.percentageUsed)%")
            lines.append(String(format: "  lifetime IO: read=%.0f bytes written=%.0f bytes", smart.lifetimeReadBytes, smart.lifetimeWrittenBytes))
            lines.append("  power: cycles=\(smart.powerCycles.uint64Value.map(String.init) ?? "overflow") hours=\(smart.powerOnHours.uint64Value.map(String.init) ?? "overflow") unsafeShutdowns=\(smart.unsafeShutdowns.uint64Value.map(String.init) ?? "overflow") mediaErrors=\(smart.mediaErrors.uint64Value.map(String.init) ?? "overflow")")
        case .failure(let error):
            lines.append("NVMe SMART: unavailable — \(error.localizedDescription)")
        }
        lines.append("This probe is read-only and does not use smartctl, system_profiler, diskutil, or any subprocess.")
        return lines.joined(separator: "\n")
    }
}
