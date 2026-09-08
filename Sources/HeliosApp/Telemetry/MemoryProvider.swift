import Darwin
import Foundation

actor MemoryProvider {
    func sample() -> MetricSample<MemoryMetrics> {
        MetricSample(captureMetric { try Self.read() })
    }

    private static func read() throws -> MemoryMetrics {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64()
        let expectedCount = MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(expectedCount)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: expectedCount) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw TelemetryError.kernel("host_statistics64", status) }
        // Fields used here precede HOST_VM_INFO64_REV1_COUNT's end. New SDKs
        // append fields, so older supported kernels need not fill the whole struct.
        let requiredBytes = MemoryLayout<vm_statistics64>.offset(of: \.external_page_count).map { $0 + MemoryLayout<natural_t>.size }
        guard let requiredBytes, Int(count) * MemoryLayout<integer_t>.size >= requiredBytes else {
            throw TelemetryError.invalidData("Truncated VM statistics")
        }
        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(host, &pageSize)
        guard pageStatus == KERN_SUCCESS else { throw TelemetryError.kernel("host_page_size", pageStatus) }
        guard pageSize > 0, pageSize <= 1_048_576 else { throw TelemetryError.invalidData("Invalid VM page size") }
        let page = UInt64(pageSize)
        let swap = captureMetric { try readSwap() }
        return MemoryMetrics(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            activeBytes: UInt64(stats.active_count) * page,
            inactiveBytes: UInt64(stats.inactive_count) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            speculativeBytes: UInt64(stats.speculative_count) * page,
            purgeableBytes: UInt64(stats.purgeable_count) * page,
            externalBytes: UInt64(stats.external_page_count) * page,
            freeBytes: UInt64(stats.free_count) * page,
            pressure: captureMetric { try readPressure() },
            swapUsedBytes: swap.map { $0.used },
            swapTotalBytes: swap.map { $0.total },
            swapFreeBytes: swap.map { $0.free },
            swapIns: UInt64(stats.swapins),
            swapOuts: UInt64(stats.swapouts)
        )
    }

    private static func readSwap() throws -> (used: UInt64, total: UInt64, free: UInt64) {
        // Native `vm.swapusage` query using Darwin's imported xsw_usage ABI;
        // no `/usr/sbin/sysctl` process is spawned.
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            throw TelemetryError.kernel("Swap usage query", errno)
        }
        guard size == MemoryLayout<xsw_usage>.size,
              usage.xsu_used <= usage.xsu_total,
              usage.xsu_avail <= usage.xsu_total else {
            throw TelemetryError.invalidData("Invalid swap usage")
        }
        return (usage.xsu_used, usage.xsu_total, usage.xsu_avail)
    }

    private static func readPressure() throws -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Native Darwin call, not an invocation of the sysctl executable.
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            throw TelemetryError.kernel("Memory pressure query", errno)
        }
        guard size == MemoryLayout<Int32>.size else { throw TelemetryError.invalidData("Invalid memory pressure size") }
        return try MemoryPressure.decode(level)
    }
}
