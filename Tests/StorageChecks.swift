import Darwin
import Foundation

private struct StorageCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw StorageCheckFailure(description: message) }
}

private func expectTelemetryFailure<Value>(_ operation: () throws -> Value) throws {
    do { _ = try operation() }
    catch is TelemetryError { return }
    throw StorageCheckFailure(description: "Expected a typed telemetry failure")
}

private func close(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.0001 }

@main
private struct StorageChecks {
    static func main() async {
        do {
            try deterministicChecks()
            print("PASS storage capacity/counters, throughput+IOPS deltas, NVMe SMART parsing/health, rollover rejection, and SMART capability classification")
            if CommandLine.arguments.contains("--live") { try await liveChecks() }
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    private static func deterministicChecks() throws {
        func uuidBytes(_ uuid: CFUUID) -> [UInt8] {
            let value = CFUUIDGetUUIDBytes(uuid)
            return [value.byte0, value.byte1, value.byte2, value.byte3, value.byte4, value.byte5, value.byte6, value.byte7, value.byte8, value.byte9, value.byte10, value.byte11, value.byte12, value.byte13, value.byte14, value.byte15]
        }
        try require(uuidBytes(NVMeSMARTUUIDs.pluginInterface()) == [0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F], "IOCFPlugIn interface UUID")
        try require(uuidBytes(NVMeSMARTUUIDs.userClient()) == [0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F], "NVMe SMART user-client UUID")
        try require(uuidBytes(NVMeSMARTUUIDs.interface()) == [0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6], "NVMe SMART interface UUID")

        let counters = try StorageParser.counters([
            "Bytes (Read)": NSNumber(value: UInt64(1_000_000)),
            "Bytes (Write)": NSNumber(value: UInt64(2_000_000)),
            "Operations (Read)": 10,
            "Operations (Write)": 20,
            "Errors (Read)": 0,
            "Errors (Write)": 1
        ])
        try require(counters.bytesRead == 1_000_000 && counters.bytesWritten == 2_000_000, "Storage byte counters")
        let volume = try StorageParser.rootVolume([.systemSize: NSNumber(value: UInt64(1_000)), .systemFreeSize: NSNumber(value: UInt64(250))])
        try require(volume.usedBytes == 750, "Root volume arithmetic")
        try require(StorageParser.smartCapability(nvme: true, ata: false) == .nvmeAdvertised, "NVMe capability classification")
        try require(StorageParser.smartCapability(nvme: false, ata: false) == .notAdvertised, "Unadvertised SMART capability")

        var rate = StorageRateCalculator()
        try expectTelemetryFailure { try rate.consume(counters, elapsedSeconds: 2).get() }
        let next = StorageIOCounters(bytesRead: 1_004_000, bytesWritten: 2_008_000, readOperations: 12, writeOperations: 24, readErrors: 0, writeErrors: 1)
        let throughput = try rate.consume(next, elapsedSeconds: 2).get()
        try require(close(throughput.readBytesPerSecond, 2_000) && close(throughput.writeBytesPerSecond, 4_000), "Storage throughput delta")
        try require(close(throughput.readIOPS, 1) && close(throughput.writeIOPS, 2), "Storage IOPS delta")

        var smartBytes = [UInt8](repeating: 0, count: 512)
        smartBytes[1] = 0x31; smartBytes[2] = 0x01 // 305 K = 31.85 C
        smartBytes[3] = 100; smartBytes[4] = 99; smartBytes[5] = 2
        func put64(_ value: UInt64, at offset: Int) {
            for i in 0..<8 { smartBytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt64(i * 8)) }
        }
        put64(10, at: 32); put64(20, at: 48); put64(7, at: 112); put64(81, at: 128); put64(3, at: 144)
        let smart = try NVMeSMARTParser.parse(smartBytes)
        try require(smart.state == .verified && smart.lifeRemainingPercent == 98, "NVMe SMART health classification")
        try require(smart.dataUnitsWritten.low == 20 && close(smart.lifetimeWrittenBytes, 10_240_000), "NVMe lifetime write conversion")
        try require(smart.powerOnHours.uint64Value == 81 && smart.unsafeShutdowns.uint64Value == 3, "NVMe lifetime counters")
        smartBytes[0] = 1
        try require(try NVMeSMARTParser.parse(smartBytes).state == .critical, "NVMe critical warning classification")
        try expectTelemetryFailure { try NVMeSMARTParser.parse([0, 1, 2]) }
        try expectTelemetryFailure {
            try rate.consume(StorageIOCounters(bytesRead: 1, bytesWritten: 1, readOperations: 0, writeOperations: 0, readErrors: 0, writeErrors: 0), elapsedSeconds: 2).get()
        }
        for invalid: Any in [true, -1, 1.5, "12"] {
            try expectTelemetryFailure { try StorageParser.counters(["Bytes (Read)": invalid, "Bytes (Write)": 2]) }
        }
    }

    private static func liveChecks() async throws {
        try require(geteuid() != 0, "Live storage check must run as the normal user")
        let baseline = try IOKitStorageReader().readWithSMARTProbe()
        print(baseline.diagnosticText)
        let provider = StorageProvider()
        let first = await provider.sample()
        _ = try first.result.get()
        try await Task.sleep(for: .seconds(2))
        let secondSample = await provider.sample()
        let second = try secondSample.result.get()
        if let primary = second.primaryDevice {
            print("Live primary: \(primary.bsdName) / \(primary.controllerClass) / \(primary.smartCapability.rawValue)")
        }
        switch second.smartHealth {
        case .success(let smart): print(String(format: "Live SMART: %@ wear=%u%% written=%.2f TB temp=%.1f C", smart.state.rawValue, smart.percentageUsed, smart.lifetimeWrittenBytes / 1_000_000_000_000, smart.temperatureCelsius ?? -.infinity))
        case .failure(let error): print("Live SMART unavailable: \(error.localizedDescription)")
        }
        switch second.throughput {
        case .success(let value): print(String(format: "Live throughput: read %.0f B/s, write %.0f B/s", value.readBytesPerSecond, value.writeBytesPerSecond))
        case .failure(let error): print("Live throughput unavailable: \(error.localizedDescription)")
        }
        print("PASS unprivileged read-only storage provider")
    }
}
