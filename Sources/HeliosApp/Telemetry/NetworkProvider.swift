import Darwin
import Foundation
import SystemConfiguration

struct NetworkLinkCounters: Sendable, Equatable {
    let receivedBytes: UInt32
    let transmittedBytes: UInt32
    let receivedPackets: UInt32
    let transmittedPackets: UInt32
    let receiveErrors: UInt32
    let transmitErrors: UInt32
}

struct NetworkThroughput: Sendable, Equatable {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let receivePacketsPerSecond: Double
    let transmitPacketsPerSecond: Double
}

struct NetworkMetrics: Sendable {
    let primaryInterface: MetricResult<String>
    let ipv4Address: MetricResult<String>
    let ipv6Address: MetricResult<String>
    let isRunning: MetricResult<Bool>
    let mtu: MetricResult<Int>
    let linkSpeedBitsPerSecond: MetricResult<UInt64>
    let throughput: MetricResult<NetworkThroughput>
    let receiveErrors: MetricResult<UInt32>
    let transmitErrors: MetricResult<UInt32>
    let activeInterfaceCount: Int
    let activeInterfaces: [String]
    let gatewayIPv4: MetricResult<String>
    let dnsServers: [String]
    let searchDomains: [String]
    let sessionDownloadedBytes: MetricResult<UInt64>
    let sessionUploadedBytes: MetricResult<UInt64>

    init(primaryInterface: MetricResult<String>, ipv4Address: MetricResult<String>, ipv6Address: MetricResult<String>,
         isRunning: MetricResult<Bool>, mtu: MetricResult<Int>, linkSpeedBitsPerSecond: MetricResult<UInt64>,
         throughput: MetricResult<NetworkThroughput>, receiveErrors: MetricResult<UInt32>, transmitErrors: MetricResult<UInt32>,
         activeInterfaceCount: Int, activeInterfaces: [String] = [],
         gatewayIPv4: MetricResult<String> = .failure(.unavailable("Default gateway unavailable")),
         dnsServers: [String] = [], searchDomains: [String] = [],
         sessionDownloadedBytes: MetricResult<UInt64> = .failure(.warmingUp),
         sessionUploadedBytes: MetricResult<UInt64> = .failure(.warmingUp)) {
        self.primaryInterface = primaryInterface
        self.ipv4Address = ipv4Address
        self.ipv6Address = ipv6Address
        self.isRunning = isRunning
        self.mtu = mtu
        self.linkSpeedBitsPerSecond = linkSpeedBitsPerSecond
        self.throughput = throughput
        self.receiveErrors = receiveErrors
        self.transmitErrors = transmitErrors
        self.activeInterfaceCount = activeInterfaceCount
        self.activeInterfaces = activeInterfaces
        self.gatewayIPv4 = gatewayIPv4
        self.dnsServers = dnsServers
        self.searchDomains = searchDomains
        self.sessionDownloadedBytes = sessionDownloadedBytes
        self.sessionUploadedBytes = sessionUploadedBytes
    }
}

struct NetworkLinkSnapshot: Sendable, Equatable {
    let name: String
    let isRunning: Bool
    let mtu: Int
    let baudRate: UInt64
    let counters: NetworkLinkCounters
}

struct NetworkRawSnapshot: Sendable {
    let primaryInterface: String?
    let ipv4Address: String?
    let ipv6Address: String?
    let link: NetworkLinkSnapshot?
    let activeInterfaceCount: Int
    let activeInterfaces: [String]
    let gatewayIPv4: String?
    let dnsServers: [String]
    let searchDomains: [String]
}

struct NetworkRateCalculator: Sendable {
    private var previousName: String?
    private var previous: NetworkLinkCounters?

    mutating func reset() {
        previousName = nil
        previous = nil
    }

    mutating func consume(name: String, counters: NetworkLinkCounters, elapsedSeconds: Double) -> MetricResult<NetworkThroughput> {
        defer {
            previousName = name
            previous = counters
        }
        guard elapsedSeconds.isFinite, elapsedSeconds > 0, elapsedSeconds <= 10 else {
            return .failure(.unavailable("Network sampling interval invalid"))
        }
        guard previousName == name, let previous else { return .failure(.warmingUp) }

        let down = wrappedDelta(current: counters.receivedBytes, previous: previous.receivedBytes)
        let up = wrappedDelta(current: counters.transmittedBytes, previous: previous.transmittedBytes)
        let rxPackets = wrappedDelta(current: counters.receivedPackets, previous: previous.receivedPackets)
        let txPackets = wrappedDelta(current: counters.transmittedPackets, previous: previous.transmittedPackets)
        let result = NetworkThroughput(
            downloadBytesPerSecond: Double(down) / elapsedSeconds,
            uploadBytesPerSecond: Double(up) / elapsedSeconds,
            receivePacketsPerSecond: Double(rxPackets) / elapsedSeconds,
            transmitPacketsPerSecond: Double(txPackets) / elapsedSeconds
        )
        guard result.downloadBytesPerSecond.isFinite, result.uploadBytesPerSecond.isFinite,
              result.downloadBytesPerSecond >= 0, result.uploadBytesPerSecond >= 0,
              result.downloadBytesPerSecond <= 100_000_000_000,
              result.uploadBytesPerSecond <= 100_000_000_000 else {
            return .failure(.invalidData("Network throughput outside plausible range"))
        }
        return .success(result)
    }

    private func wrappedDelta(current: UInt32, previous: UInt32) -> UInt64 {
        if current >= previous { return UInt64(current - previous) }
        return UInt64(UInt32.max - previous) + 1 + UInt64(current)
    }
}

struct NetworkThroughputTracker: Sendable {
    private var calculator = NetworkRateCalculator()
    private var previousTicks: UInt64?

    mutating func reset() {
        calculator.reset()
        previousTicks = nil
    }

    mutating func update(name: String, counters: NetworkLinkCounters, ticks: UInt64) -> MetricResult<NetworkThroughput> {
        guard let previousTicks else {
            self.previousTicks = ticks
            _ = calculator.consume(name: name, counters: counters, elapsedSeconds: 1)
            return .failure(.warmingUp)
        }
        self.previousTicks = ticks
        return calculator.consume(name: name, counters: counters, elapsedSeconds: HostClock.seconds(from: previousTicks, to: ticks))
    }
}

enum NetworkDynamicStoreReader {
    static func primaryInterfaceAndAddresses() -> (name: String?, ipv4: String?, ipv6: String?, gateway: String?, dns: [String], search: [String]) {
        guard let store = SCDynamicStoreCreate(nil, "com.snejda.Helios.Network" as CFString, nil, nil) else {
            return (nil, nil, nil, nil, [], [])
        }
        let ipv4Global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6Global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        let dnsGlobal = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
        let name = (ipv4Global?["PrimaryInterface"] as? String) ?? (ipv6Global?["PrimaryInterface"] as? String)
        let gateway = (ipv4Global?["Router"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let dns = (dnsGlobal?["ServerAddresses"] as? [String] ?? []).filter { !$0.isEmpty }
        let search = (dnsGlobal?["SearchDomains"] as? [String] ?? []).filter { !$0.isEmpty }
        guard let name, !name.isEmpty else { return (nil, nil, nil, gateway, dns, search) }

        let ipv4 = addresses(store: store, interface: name, family: "IPv4").first
        let ipv6Candidates = addresses(store: store, interface: name, family: "IPv6")
        let ipv6 = ipv6Candidates.first(where: { !$0.lowercased().hasPrefix("fe80:") }) ?? ipv6Candidates.first
        return (name, ipv4, ipv6, gateway, dns, search)
    }

    private static func addresses(store: SCDynamicStore, interface: String, family: String) -> [String] {
        let key = "State:/Network/Interface/\(interface)/\(family)" as CFString
        guard let dictionary = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let values = dictionary["Addresses"] as? [String] else { return [] }
        return values.filter { !$0.isEmpty }
    }
}

enum NetworkInterfaceReader {
    static func read() throws -> NetworkRawSnapshot {
        let route = NetworkDynamicStoreReader.primaryInterfaceAndAddresses()
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else {
            throw TelemetryError.kernel("Enumerate network interfaces", errno)
        }
        defer { freeifaddrs(first) }

        var linkByName: [String: NetworkLinkSnapshot] = [:]
        var activeNames = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let item = current.pointee
            defer { cursor = item.ifa_next }
            guard let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let rawData = item.ifa_data else { continue }
            // getifaddrs() guarantees ifa_name as a NUL-terminated C string.
            // Decode the exact payload explicitly instead of deprecated
            // the deprecated C-string initializer so warnings-as-errors stays clean.
            let nameLength = strlen(item.ifa_name)
            let nameBytes = UnsafeRawBufferPointer(start: item.ifa_name, count: nameLength)
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard !name.isEmpty else { continue }
            let flags = item.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isRunning = (flags & UInt32(IFF_RUNNING)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if isUp && isRunning && !isLoopback { activeNames.insert(name) }

            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            let mtu = Int(data.ifi_mtu)
            let baudRate = UInt64(data.ifi_baudrate)
            guard mtu >= 0, mtu <= 1_000_000 else { continue }
            linkByName[name] = NetworkLinkSnapshot(
                name: name,
                isRunning: isUp && isRunning,
                mtu: mtu,
                baudRate: baudRate,
                counters: NetworkLinkCounters(
                    receivedBytes: UInt32(truncatingIfNeeded: data.ifi_ibytes),
                    transmittedBytes: UInt32(truncatingIfNeeded: data.ifi_obytes),
                    receivedPackets: UInt32(truncatingIfNeeded: data.ifi_ipackets),
                    transmittedPackets: UInt32(truncatingIfNeeded: data.ifi_opackets),
                    receiveErrors: UInt32(truncatingIfNeeded: data.ifi_ierrors),
                    transmitErrors: UInt32(truncatingIfNeeded: data.ifi_oerrors)
                )
            )
        }

        return NetworkRawSnapshot(
            primaryInterface: route.name,
            ipv4Address: route.ipv4,
            ipv6Address: route.ipv6,
            link: route.name.flatMap { linkByName[$0] },
            activeInterfaceCount: activeNames.count,
            activeInterfaces: activeNames.sorted(),
            gatewayIPv4: route.gateway,
            dnsServers: route.dns,
            searchDomains: route.search
        )
    }
}

actor NetworkProvider {
    private var tracker = NetworkThroughputTracker()
    private var sessionName: String?
    private var sessionPrevious: NetworkLinkCounters?
    private var sessionDownloadedBytes: UInt64 = 0
    private var sessionUploadedBytes: UInt64 = 0

    /// Reset only short-term rate calculation. Session transfer accounting is
    /// intentionally kept across sleep/wake for the lifetime of the app.
    func reset() { tracker.reset(); sessionName = nil; sessionPrevious = nil }

    private func updateSession(name: String, counters: NetworkLinkCounters) -> (UInt64, UInt64) {
        defer { sessionName = name; sessionPrevious = counters }
        guard sessionName == name, let previous = sessionPrevious else {
            return (sessionDownloadedBytes, sessionUploadedBytes)
        }
        sessionDownloadedBytes = Self.saturatingAdd(sessionDownloadedBytes, Self.wrappedDelta(current: counters.receivedBytes, previous: previous.receivedBytes))
        sessionUploadedBytes = Self.saturatingAdd(sessionUploadedBytes, Self.wrappedDelta(current: counters.transmittedBytes, previous: previous.transmittedBytes))
        return (sessionDownloadedBytes, sessionUploadedBytes)
    }

    private static func wrappedDelta(current: UInt32, previous: UInt32) -> UInt64 {
        if current >= previous { return UInt64(current - previous) }
        return UInt64(UInt32.max - previous) + 1 + UInt64(current)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    func sample() -> MetricSample<NetworkMetrics> {
        let result = captureMetric { try read() }
        return MetricSample(result)
    }

    private func read() throws -> NetworkMetrics {
        let raw = try NetworkInterfaceReader.read()
        let primary: MetricResult<String> = raw.primaryInterface.map { MetricResult<String>.success($0) } ?? .failure(.unavailable("No primary network interface"))
        let ipv4: MetricResult<String> = raw.ipv4Address.map { MetricResult<String>.success($0) } ?? .failure(.unavailable("Primary IPv4 address unavailable"))
        let ipv6: MetricResult<String> = raw.ipv6Address.map { MetricResult<String>.success($0) } ?? .failure(.unavailable("Primary IPv6 address unavailable"))

        guard let link = raw.link else {
            tracker.reset()
            let unavailable = TelemetryError.unavailable("Primary link statistics unavailable")
            return NetworkMetrics(
                primaryInterface: primary,
                ipv4Address: ipv4,
                ipv6Address: ipv6,
                isRunning: .failure(unavailable),
                mtu: .failure(unavailable),
                linkSpeedBitsPerSecond: .failure(unavailable),
                throughput: .failure(unavailable),
                receiveErrors: .failure(unavailable),
                transmitErrors: .failure(unavailable),
                activeInterfaceCount: raw.activeInterfaceCount, activeInterfaces: raw.activeInterfaces,
                gatewayIPv4: raw.gatewayIPv4.map(MetricResult<String>.success) ?? .failure(.unavailable("Default gateway unavailable")),
                dnsServers: raw.dnsServers, searchDomains: raw.searchDomains,
                sessionDownloadedBytes: .success(sessionDownloadedBytes),
                sessionUploadedBytes: .success(sessionUploadedBytes)
            )
        }

        let throughput = tracker.update(name: link.name, counters: link.counters, ticks: HostClock.now)
        let sessionTotals = updateSession(name: link.name, counters: link.counters)
        return NetworkMetrics(
            primaryInterface: primary,
            ipv4Address: ipv4,
            ipv6Address: ipv6,
            isRunning: .success(link.isRunning),
            mtu: link.mtu > 0 ? .success(link.mtu) : .failure(.unavailable("Interface MTU unavailable")),
            linkSpeedBitsPerSecond: link.baudRate > 0 ? .success(link.baudRate) : .failure(.unavailable("Link speed unavailable")),
            throughput: throughput,
            receiveErrors: .success(link.counters.receiveErrors),
            transmitErrors: .success(link.counters.transmitErrors),
            activeInterfaceCount: raw.activeInterfaceCount, activeInterfaces: raw.activeInterfaces,
            gatewayIPv4: raw.gatewayIPv4.map(MetricResult<String>.success) ?? .failure(.unavailable("Default gateway unavailable")),
            dnsServers: raw.dnsServers, searchDomains: raw.searchDomains,
            sessionDownloadedBytes: .success(sessionTotals.0),
            sessionUploadedBytes: .success(sessionTotals.1)
        )
    }
}
