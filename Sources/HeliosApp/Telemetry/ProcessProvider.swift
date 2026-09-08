import Darwin
import Foundation

struct ProcessActivity: Sendable, Equatable, Identifiable {
    let pid: Int32
    let name: String
    let executablePath: String?
    let physicalFootprintBytes: UInt64
    let neuralFootprintBytes: UInt64
    let cpuPercent: Double?
    let powerWatts: Double?
    let performanceCorePowerWatts: Double?
    let diskReadBytesPerSecond: Double?
    let diskWriteBytesPerSecond: Double?
    let wakeupsPerSecond: Double?
    let instructionsPerSecond: Double?
    let cyclesPerSecond: Double?
    let instructionsPerCycle: Double?
    let sessionDiskReadBytes: UInt64
    let sessionDiskWriteBytes: UInt64

    init(
        pid: Int32,
        name: String,
        executablePath: String?,
        physicalFootprintBytes: UInt64,
        neuralFootprintBytes: UInt64,
        cpuPercent: Double?,
        powerWatts: Double?,
        performanceCorePowerWatts: Double?,
        diskReadBytesPerSecond: Double?,
        diskWriteBytesPerSecond: Double?,
        wakeupsPerSecond: Double?,
        instructionsPerSecond: Double?,
        cyclesPerSecond: Double?,
        instructionsPerCycle: Double?,
        sessionDiskReadBytes: UInt64 = 0,
        sessionDiskWriteBytes: UInt64 = 0
    ) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.physicalFootprintBytes = physicalFootprintBytes
        self.neuralFootprintBytes = neuralFootprintBytes
        self.cpuPercent = cpuPercent
        self.powerWatts = powerWatts
        self.performanceCorePowerWatts = performanceCorePowerWatts
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.wakeupsPerSecond = wakeupsPerSecond
        self.instructionsPerSecond = instructionsPerSecond
        self.cyclesPerSecond = cyclesPerSecond
        self.instructionsPerCycle = instructionsPerCycle
        self.sessionDiskReadBytes = sessionDiskReadBytes
        self.sessionDiskWriteBytes = sessionDiskWriteBytes
    }

    var id: String { "\(pid)-\(name)" }
}

struct ProcessMetrics: Sendable {
    let accessibleProcessCount: Int
    let topByCPU: [ProcessActivity]
    let topByEnergy: [ProcessActivity]
    /// A wider, still bounded set used for low-frequency per-app energy history.
    /// It avoids resolving names for every process on every 5-second sample.
    let energyHistoryLeaders: [ProcessActivity]
    let topByMemory: [ProcessActivity]
    let topByDiskRead: [ProcessActivity]
    let topByDiskWrite: [ProcessActivity]
    let topSessionReaders: [ProcessActivity]
    let topSessionWriters: [ProcessActivity]
    let accountedDiskReadBytesPerSecond: Double
    let accountedDiskWriteBytesPerSecond: Double
    let sessionAccountedReadBytes: UInt64
    let sessionAccountedWriteBytes: UInt64
    let heliosActivity: ProcessActivity?

    init(
        accessibleProcessCount: Int,
        topByCPU: [ProcessActivity],
        topByEnergy: [ProcessActivity],
        energyHistoryLeaders: [ProcessActivity] = [],
        topByMemory: [ProcessActivity],
        topByDiskRead: [ProcessActivity] = [],
        topByDiskWrite: [ProcessActivity] = [],
        topSessionReaders: [ProcessActivity] = [],
        topSessionWriters: [ProcessActivity] = [],
        accountedDiskReadBytesPerSecond: Double = 0,
        accountedDiskWriteBytesPerSecond: Double = 0,
        sessionAccountedReadBytes: UInt64 = 0,
        sessionAccountedWriteBytes: UInt64 = 0,
        heliosActivity: ProcessActivity? = nil
    ) {
        self.accessibleProcessCount = accessibleProcessCount
        self.topByCPU = topByCPU
        self.topByEnergy = topByEnergy
        self.energyHistoryLeaders = energyHistoryLeaders
        self.topByMemory = topByMemory
        self.topByDiskRead = topByDiskRead
        self.topByDiskWrite = topByDiskWrite
        self.topSessionReaders = topSessionReaders
        self.topSessionWriters = topSessionWriters
        self.accountedDiskReadBytesPerSecond = accountedDiskReadBytesPerSecond
        self.accountedDiskWriteBytesPerSecond = accountedDiskWriteBytesPerSecond
        self.sessionAccountedReadBytes = sessionAccountedReadBytes
        self.sessionAccountedWriteBytes = sessionAccountedWriteBytes
        self.heliosActivity = heliosActivity
    }
}

struct ProcessCounterSnapshot: Sendable, Equatable {
    let pid: Int32
    let startAbsoluteTime: UInt64
    let userTime: UInt64
    let systemTime: UInt64
    let energyNanojoules: UInt64
    let performanceEnergyNanojoules: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64
    let instructions: UInt64
    let cycles: UInt64
    let physicalFootprintBytes: UInt64
    let neuralFootprintBytes: UInt64
}

struct ProcessRateSnapshot: Sendable, Equatable {
    let cpuPercent: Double
    let powerWatts: Double
    let performanceCorePowerWatts: Double
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let diskReadBytesDelta: UInt64
    let diskWriteBytesDelta: UInt64
    let wakeupsPerSecond: Double
    let instructionsPerSecond: Double
    let cyclesPerSecond: Double
    let instructionsPerCycle: Double?
}

private struct ProcessKey: Sendable, Hashable {
    let pid: Int32
    let startAbsoluteTime: UInt64
}

private struct ProcessSessionEntry: Sendable {
    var readBytes: UInt64 = 0
    var writeBytes: UInt64 = 0
}

private struct ProcessCandidate: Sendable {
    let key: ProcessKey
    let counters: ProcessCounterSnapshot
    let rate: ProcessRateSnapshot?
}

enum ProcessRateCalculator {
    static func calculate(previous: ProcessCounterSnapshot, current: ProcessCounterSnapshot, elapsedSeconds: Double, logicalCPUCount: Int) -> ProcessRateSnapshot? {
        guard previous.pid == current.pid,
              previous.startAbsoluteTime == current.startAbsoluteTime,
              elapsedSeconds.isFinite, elapsedSeconds > 0, elapsedSeconds <= 15,
              logicalCPUCount > 0,
              current.userTime >= previous.userTime,
              current.systemTime >= previous.systemTime,
              current.energyNanojoules >= previous.energyNanojoules,
              current.performanceEnergyNanojoules >= previous.performanceEnergyNanojoules,
              current.diskReadBytes >= previous.diskReadBytes,
              current.diskWriteBytes >= previous.diskWriteBytes,
              current.packageIdleWakeups >= previous.packageIdleWakeups,
              current.interruptWakeups >= previous.interruptWakeups,
              current.instructions >= previous.instructions,
              current.cycles >= previous.cycles else { return nil }

        let cpuNanoseconds = Double((current.userTime - previous.userTime) + (current.systemTime - previous.systemTime))
        let rawCPU = cpuNanoseconds / 1_000_000_000.0 / elapsedSeconds * 100.0
        let cpuCeiling = Double(logicalCPUCount) * 100.0
        guard rawCPU.isFinite, rawCPU >= 0, rawCPU <= cpuCeiling * 1.25 else { return nil }

        let energyDelta = Double(current.energyNanojoules - previous.energyNanojoules)
        let pEnergyDelta = Double(current.performanceEnergyNanojoules - previous.performanceEnergyNanojoules)
        let readDelta = current.diskReadBytes - previous.diskReadBytes
        let writeDelta = current.diskWriteBytes - previous.diskWriteBytes
        let instructionsDelta = Double(current.instructions - previous.instructions)
        let cyclesDelta = Double(current.cycles - previous.cycles)
        let ipc = cyclesDelta > 0 ? instructionsDelta / cyclesDelta : nil

        let result = ProcessRateSnapshot(
            cpuPercent: min(cpuCeiling, rawCPU),
            powerWatts: energyDelta / 1_000_000_000.0 / elapsedSeconds,
            performanceCorePowerWatts: pEnergyDelta / 1_000_000_000.0 / elapsedSeconds,
            diskReadBytesPerSecond: Double(readDelta) / elapsedSeconds,
            diskWriteBytesPerSecond: Double(writeDelta) / elapsedSeconds,
            diskReadBytesDelta: readDelta,
            diskWriteBytesDelta: writeDelta,
            wakeupsPerSecond: Double((current.packageIdleWakeups - previous.packageIdleWakeups) + (current.interruptWakeups - previous.interruptWakeups)) / elapsedSeconds,
            instructionsPerSecond: instructionsDelta / elapsedSeconds,
            cyclesPerSecond: cyclesDelta / elapsedSeconds,
            instructionsPerCycle: ipc
        )
        guard result.powerWatts.isFinite, result.powerWatts >= 0, result.powerWatts < 10_000,
              result.performanceCorePowerWatts.isFinite, result.performanceCorePowerWatts >= 0, result.performanceCorePowerWatts < 10_000,
              result.diskReadBytesPerSecond.isFinite, result.diskReadBytesPerSecond >= 0,
              result.diskWriteBytesPerSecond.isFinite, result.diskWriteBytesPerSecond >= 0,
              result.diskReadBytesPerSecond < 100_000_000_000,
              result.diskWriteBytesPerSecond < 100_000_000_000 else { return nil }
        return result
    }
}

actor ProcessProvider {
    private var previous: [Int32: ProcessCounterSnapshot] = [:]
    private var previousTicks: UInt64?
    private var session: [ProcessKey: ProcessSessionEntry] = [:]
    private var identityCache: [ProcessKey: (name: String, path: String?)] = [:]
    private let logicalCPUCount = max(1, ProcessInfo.processInfo.processorCount)
    private let ownPID = getpid()

    /// Resets only the delta baseline. Session attribution intentionally survives
    /// sleep/wake so "since Helios started" remains useful for the whole app run.
    func reset() {
        previous.removeAll(keepingCapacity: true)
        previousTicks = nil
    }

    func resetSession() {
        reset()
        session.removeAll(keepingCapacity: true)
        identityCache.removeAll(keepingCapacity: true)
    }

    func sample() -> MetricSample<ProcessMetrics> {
        let ticks = HostClock.now
        let elapsed = previousTicks.map { HostClock.seconds(from: $0, to: ticks) }
        previousTicks = ticks
        return MetricSample(captureMetric { try read(elapsedSeconds: elapsed) }, capturedTicks: ticks)
    }

    private func read(elapsedSeconds: Double?) throws -> ProcessMetrics {
        let pids = try Self.listPIDs()
        var current: [Int32: ProcessCounterSnapshot] = [:]
        current.reserveCapacity(pids.count)
        var candidates: [ProcessCandidate] = []
        candidates.reserveCapacity(min(pids.count, 256))

        // rusage is the only per-process syscall on the broad enumeration path.
        // Resolve names/paths only for displayed leaders. This keeps the 5-second
        // process sampler cheap even when hundreds of sandboxed processes exist.
        for pid in pids.prefix(1_024) where pid > 0 {
            guard let counters = Self.rusage(pid: pid) else { continue }
            current[pid] = counters
            let key = ProcessKey(pid: pid, startAbsoluteTime: counters.startAbsoluteTime)
            let rate: ProcessRateSnapshot?
            if let elapsedSeconds, let old = previous[pid] {
                rate = ProcessRateCalculator.calculate(previous: old, current: counters, elapsedSeconds: elapsedSeconds, logicalCPUCount: logicalCPUCount)
            } else {
                rate = nil
            }
            if let rate {
                var total = session[key] ?? ProcessSessionEntry()
                total.readBytes = Self.saturatingAdd(total.readBytes, rate.diskReadBytesDelta)
                total.writeBytes = Self.saturatingAdd(total.writeBytes, rate.diskWriteBytesDelta)
                session[key] = total
            }
            candidates.append(ProcessCandidate(key: key, counters: counters, rate: rate))
        }
        previous = current
        guard !candidates.isEmpty else { throw TelemetryError.unavailable("No process resource usage accessible") }

        // Bound stale ledger growth during long sessions while preserving exited
        // processes that actually performed meaningful I/O for audit attribution.
        if session.count > 4_096 {
            let keep = session.sorted {
                Self.saturatingAdd($0.value.readBytes, $0.value.writeBytes) > Self.saturatingAdd($1.value.readBytes, $1.value.writeBytes)
            }.prefix(2_048)
            session = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            identityCache = identityCache.filter { session[$0.key] != nil }
        }

        func top(_ sorted: [ProcessCandidate]) -> [ProcessCandidate] { Array(sorted.prefix(6)) }
        let topCPU = top(candidates.sorted { ($0.rate?.cpuPercent ?? -1) > ($1.rate?.cpuPercent ?? -1) })
        let energySorted = candidates.sorted { ($0.rate?.powerWatts ?? -1) > ($1.rate?.powerWatts ?? -1) }
        let topEnergy = top(energySorted)
        let historyEnergy = Array(energySorted.prefix(24))
        let topMemory = top(candidates.sorted { $0.counters.physicalFootprintBytes > $1.counters.physicalFootprintBytes })
        let topRead = top(candidates.sorted { ($0.rate?.diskReadBytesPerSecond ?? -1) > ($1.rate?.diskReadBytesPerSecond ?? -1) })
        let topWrite = top(candidates.sorted { ($0.rate?.diskWriteBytesPerSecond ?? -1) > ($1.rate?.diskWriteBytesPerSecond ?? -1) })

        let candidateByKey = Dictionary(uniqueKeysWithValues: candidates.map { ($0.key, $0) })
        let sessionReadKeys = session.sorted { $0.value.readBytes > $1.value.readBytes }.prefix(6).map(\.key)
        let sessionWriteKeys = session.sorted { $0.value.writeBytes > $1.value.writeBytes }.prefix(6).map(\.key)

        func identity(for key: ProcessKey) -> (name: String, path: String?) {
            if let cached = identityCache[key] { return cached }
            let resolved = Self.identity(pid: key.pid)
            identityCache[key] = resolved
            return resolved
        }

        func activity(_ candidate: ProcessCandidate) -> ProcessActivity {
            let identity = identity(for: candidate.key)
            let totals = session[candidate.key] ?? ProcessSessionEntry()
            return ProcessActivity(
                pid: candidate.key.pid,
                name: identity.name,
                executablePath: identity.path,
                physicalFootprintBytes: candidate.counters.physicalFootprintBytes,
                neuralFootprintBytes: candidate.counters.neuralFootprintBytes,
                cpuPercent: candidate.rate?.cpuPercent,
                powerWatts: candidate.rate?.powerWatts,
                performanceCorePowerWatts: candidate.rate?.performanceCorePowerWatts,
                diskReadBytesPerSecond: candidate.rate?.diskReadBytesPerSecond,
                diskWriteBytesPerSecond: candidate.rate?.diskWriteBytesPerSecond,
                wakeupsPerSecond: candidate.rate?.wakeupsPerSecond,
                instructionsPerSecond: candidate.rate?.instructionsPerSecond,
                cyclesPerSecond: candidate.rate?.cyclesPerSecond,
                instructionsPerCycle: candidate.rate?.instructionsPerCycle,
                sessionDiskReadBytes: totals.readBytes,
                sessionDiskWriteBytes: totals.writeBytes
            )
        }

        func sessionActivity(_ key: ProcessKey) -> ProcessActivity {
            if let candidate = candidateByKey[key] { return activity(candidate) }
            let identity = identityCache[key] ?? ("PID \(key.pid) (exited)", nil)
            let totals = session[key] ?? ProcessSessionEntry()
            return ProcessActivity(
                pid: key.pid,
                name: identity.name,
                executablePath: identity.path,
                physicalFootprintBytes: 0,
                neuralFootprintBytes: 0,
                cpuPercent: nil,
                powerWatts: nil,
                performanceCorePowerWatts: nil,
                diskReadBytesPerSecond: nil,
                diskWriteBytesPerSecond: nil,
                wakeupsPerSecond: nil,
                instructionsPerSecond: nil,
                cyclesPerSecond: nil,
                instructionsPerCycle: nil,
                sessionDiskReadBytes: totals.readBytes,
                sessionDiskWriteBytes: totals.writeBytes
            )
        }

        let accountedReadRate = candidates.compactMap { $0.rate?.diskReadBytesPerSecond }.reduce(0, +)
        let accountedWriteRate = candidates.compactMap { $0.rate?.diskWriteBytesPerSecond }.reduce(0, +)
        let sessionRead = session.values.reduce(UInt64(0)) { Self.saturatingAdd($0, $1.readBytes) }
        let sessionWrite = session.values.reduce(UInt64(0)) { Self.saturatingAdd($0, $1.writeBytes) }
        let ownActivity = candidates.first(where: { $0.key.pid == ownPID }).map(activity)

        return ProcessMetrics(
            accessibleProcessCount: candidates.count,
            topByCPU: topCPU.map(activity),
            topByEnergy: topEnergy.map(activity),
            energyHistoryLeaders: historyEnergy.map(activity),
            topByMemory: topMemory.map(activity),
            topByDiskRead: topRead.map(activity),
            topByDiskWrite: topWrite.map(activity),
            topSessionReaders: sessionReadKeys.map(sessionActivity),
            topSessionWriters: sessionWriteKeys.map(sessionActivity),
            accountedDiskReadBytesPerSecond: accountedReadRate,
            accountedDiskWriteBytesPerSecond: accountedWriteRate,
            sessionAccountedReadBytes: sessionRead,
            sessionAccountedWriteBytes: sessionWrite,
            heliosActivity: ownActivity
        )
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private static func listPIDs() throws -> [Int32] {
        let requested = proc_listallpids(nil, 0)
        guard requested > 0, requested < 100_000 else { throw TelemetryError.unavailable("Process enumeration unavailable") }
        let capacity = Int(requested) + 256
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard count >= 0 else { throw TelemetryError.kernel("proc_listallpids", errno) }
        return Array(pids.prefix(min(Int(count), pids.count))).filter { $0 > 0 }
    }

    private static func rusage(pid: Int32) -> ProcessCounterSnapshot? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        guard status == 0 else { return nil }
        return ProcessCounterSnapshot(
            pid: pid,
            startAbsoluteTime: info.ri_proc_start_abstime,
            userTime: info.ri_user_time,
            systemTime: info.ri_system_time,
            energyNanojoules: info.ri_energy_nj,
            performanceEnergyNanojoules: info.ri_penergy_nj,
            diskReadBytes: info.ri_diskio_bytesread,
            diskWriteBytes: info.ri_diskio_byteswritten,
            packageIdleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            instructions: info.ri_instructions,
            cycles: info.ri_cycles,
            physicalFootprintBytes: info.ri_phys_footprint,
            neuralFootprintBytes: info.ri_neural_footprint
        )
    }

    private static func identity(pid: Int32) -> (name: String, path: String?) {
        var pathBytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = pathBytes.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        let path: String?
        if pathLength > 0 {
            path = String(decoding: pathBytes.prefix(Int(pathLength)).prefix(while: { $0 != 0 }), as: UTF8.self)
        } else {
            path = nil
        }

        var nameBytes = [UInt8](repeating: 0, count: 256)
        let nameLength = nameBytes.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        let name: String
        if nameLength > 0 {
            name = String(decoding: nameBytes.prefix(Int(nameLength)).prefix(while: { $0 != 0 }), as: UTF8.self)
        } else if let path, !path.isEmpty {
            name = URL(fileURLWithPath: path).lastPathComponent
        } else {
            name = "PID \(pid)"
        }
        return (name.isEmpty ? "PID \(pid)" : name, path)
    }
}
