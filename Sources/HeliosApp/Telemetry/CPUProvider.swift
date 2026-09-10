import Darwin
import Foundation

struct CPUTopology: Sendable, Equatable {
    let physicalCoreCount: MetricResult<Int>
    let performanceCoreCount: MetricResult<Int>
    let efficiencyCoreCount: MetricResult<Int>
}

enum CPUTopologyReader {
    static func read() -> CPUTopology {
        let physical = integer("hw.physicalcpu", label: "Physical CPU core count")
        var performance: MetricResult<Int> = .failure(.unavailable("Performance-core count unavailable"))
        var efficiency: MetricResult<Int> = .failure(.unavailable("Efficiency-core count unavailable"))

        if case .success(let levels) = integer("hw.nperflevels", label: "CPU performance levels"), levels > 0, levels <= 8 {
            for level in 0..<levels {
                let name = string("hw.perflevel\(level).name")?.lowercased() ?? ""
                let count = integer("hw.perflevel\(level).physicalcpu", label: "CPU performance-level core count")
                if name.contains("performance") || name.contains("p-core") {
                    performance = count
                } else if name.contains("efficiency") || name.contains("e-core") {
                    efficiency = count
                }
            }
        }
        return CPUTopology(physicalCoreCount: physical, performanceCoreCount: performance, efficiencyCoreCount: efficiency)
    }

    private static func integer(_ key: String, label: String) -> MetricResult<Int> {
        captureMetric {
            var value: UInt32 = 0
            var size = MemoryLayout<UInt32>.size
            guard sysctlbyname(key, &value, &size, nil, 0) == 0 else {
                throw TelemetryError.kernel(label, errno)
            }
            guard size == MemoryLayout<UInt32>.size, value > 0, value <= 4096 else {
                throw TelemetryError.invalidData("Invalid \(label.lowercased())")
            }
            return Int(value)
        }
    }

    private static func string(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        if let nul = buffer.firstIndex(of: 0) { buffer.removeSubrange(nul...) }
        let value = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}


struct CPUTicks: Sendable {
    let user: UInt32
    let system: UInt32
    let nice: UInt32
    let idle: UInt32
}

struct CPUUsageCalculator {
    private var previous: [CPUTicks]?

    mutating func reset() { previous = nil }

    mutating func consume(_ current: [CPUTicks]) throws -> CPUMetrics {
        defer { previous = current }
        guard !current.isEmpty else { throw TelemetryError.invalidData("No CPU counters returned") }
        guard let previous, previous.count == current.count else { throw TelemetryError.warmingUp }

        var user: UInt64 = 0, system: UInt64 = 0, nice: UInt64 = 0, idle: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        for (new, old) in zip(current, previous) {
            // Each kernel tick counter is an unsigned 32-bit value and can wrap.
            let coreUser = UInt64(new.user &- old.user)
            let coreSystem = UInt64(new.system &- old.system)
            let coreNice = UInt64(new.nice &- old.nice)
            let coreIdle = UInt64(new.idle &- old.idle)
            user += coreUser
            system += coreSystem
            nice += coreNice
            idle += coreIdle
            let coreTotal = coreUser + coreSystem + coreNice + coreIdle
            if coreTotal == 0 {
                perCore.append(0)
            } else {
                let busy = coreUser + coreSystem + coreNice
                perCore.append(Double(busy) / Double(coreTotal) * 100)
            }
        }
        let total = Double(user + system + nice + idle)
        guard total > 0 else { throw TelemetryError.warmingUp }
        return CPUMetrics(
            userPercent: Double(user) / total * 100,
            systemPercent: Double(system) / total * 100,
            nicePercent: Double(nice) / total * 100,
            idlePercent: Double(idle) / total * 100,
            perCoreUsagePercent: perCore
        )
    }
}

actor CPUProvider {
    private var calculator = CPUUsageCalculator()

    func reset() { calculator.reset() }

    func sample() -> MetricSample<CPUMetrics> {
        let result = captureMetric {
            let raw = try calculator.consume(Self.readTicks())
            let topology = Self.topology
            return CPUMetrics(
                userPercent: raw.userPercent,
                systemPercent: raw.systemPercent,
                nicePercent: raw.nicePercent,
                idlePercent: raw.idlePercent,
                perCoreUsagePercent: raw.perCoreUsagePercent,
                physicalCoreCount: topology.physicalCoreCount,
                performanceCoreCount: topology.performanceCoreCount,
                efficiencyCoreCount: topology.efficiencyCoreCount
            )
        }
        if case .failure(let error) = result, error != .warmingUp { calculator.reset() }
        return MetricSample(result)
    }

    private static let topology = CPUTopologyReader.read()

    private static func readTicks() throws -> [CPUTicks] {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &count)
        guard status == KERN_SUCCESS else { throw TelemetryError.kernel("host_processor_info", status) }
        guard let info else { throw TelemetryError.invalidData("Missing processor counters") }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        guard processorCount > 0, processorCount <= 4096,
              Int(count) == Int(processorCount) * states else {
            throw TelemetryError.invalidData("Unexpected processor counter size")
        }
        return (0..<Int(processorCount)).map { processor in
            let base = processor * states
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            )
        }
    }
}
