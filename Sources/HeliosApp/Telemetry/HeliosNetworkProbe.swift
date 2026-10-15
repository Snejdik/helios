import Darwin
import Foundation
import Network
import SystemConfiguration

/// On-demand network check (PLAN_0_3_0 M4). Runs only when the user asks (or a lens asks
/// on their behalf), never on a timer, and is bounded to about 8 seconds in total. It
/// uses in-process ICMP echo (no root), one uncached name lookup, the system's routing
/// state and a short `nettop` sample whose per-app results stay on this Mac.
enum HeliosNetworkProbe {
  static let internetHost = "1.1.1.1"
  static let pingCount = 5

  static func run(now: @escaping @Sendable () -> Date = Date.init) async -> HeliosNetworkCheck {
    let path = await currentPath()
    let gatewayAddress = defaultGateway()
    async let gateway: HeliosNetworkCheck.Ping? = pingIfPresent(gatewayAddress)
    async let internet = ping(internetHost)
    async let dns = lookupMilliseconds()
    async let traffic = topTraffic()
    async let congestion = HeliosWiFiScanner.scan()
    let (g, i, d, t, w) = await (gateway, internet, dns, traffic, congestion)
    return HeliosNetworkCheck(
      checkedAt: now(), connected: path.satisfied || gatewayAddress != nil, vpnActive: path.vpn,
      expensivePath: path.expensive, gateway: g, internet: i,
      dnsMilliseconds: d, dnsFailed: d == nil && path.satisfied, topTraffic: t, congestion: w)
  }

  // MARK: Path (VPN, hotspot)

  private struct PathState: Sendable {
    var satisfied = false
    var expensive = false
    var vpn = false
  }

  private static func currentPath() async -> PathState {
    await withCheckedContinuation { continuation in
      let monitor = NWPathMonitor()
      let queue = DispatchQueue(label: "com.snejda.Helios.network-path")
      let once = OnceFlag()
      monitor.pathUpdateHandler = { path in
        guard once.claim() else { return }
        var state = PathState()
        state.satisfied = path.status == .satisfied
        state.expensive = path.isExpensive
        state.vpn = path.availableInterfaces.first.map { isTunnel($0.name) } ?? false
        monitor.cancel()
        continuation.resume(returning: state)
      }
      monitor.start(queue: queue)
      queue.asyncAfter(deadline: .now() + 2) {
        guard once.claim() else { return }
        monitor.cancel()
        continuation.resume(returning: PathState())
      }
    }
  }

  static func isTunnel(_ interface: String) -> Bool {
    ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { interface.hasPrefix($0) }
  }

  /// IPv4 router from the system configuration store (no subprocess, no root).
  static func defaultGateway() -> String? {
    guard let store = SCDynamicStoreCreate(nil, "Helios" as CFString, nil, nil),
      let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
      let router = global["Router"] as? String, isIPv4(router)
    else { return nil }
    return router
  }

  static func isIPv4(_ text: String) -> Bool {
    var address = in_addr()
    return inet_pton(AF_INET, text, &address) == 1
  }

  // MARK: Ping

  private static func pingIfPresent(_ host: String?, count: Int = pingCount) async -> HeliosNetworkCheck.Ping? {
    guard let host else { return nil }
    return await ping(host, count: count)
  }

  /// The background latency look (opt-in history): three echoes to the router and to the
  /// internet, in parallel, about a second in total. No DNS, no scan, no subprocess.
  static func latencySample(now: Date) async -> HeliosLatencySample {
    async let router = pingIfPresent(defaultGateway(), count: HeliosLatencyHistory.echoesPerHost)
    async let internet = ping(internetHost, count: HeliosLatencyHistory.echoesPerHost)
    return await HeliosLatencySample(at: now, router: router, internet: internet)
  }

  /// In-process ICMP echo over an unprivileged datagram socket (macOS allows it without
  /// root), five probes 0.2 s apart, one second each. No subprocess.
  static func ping(_ host: String, count: Int = pingCount) async -> HeliosNetworkCheck.Ping? {
    guard isIPv4(host) else { return nil }
    return await Task.detached(priority: .utility) { icmpPing(host, count: count) }.value
  }

  static func icmpPing(_ host: String, count: Int, perProbeTimeout: TimeInterval = 1.0) -> HeliosNetworkCheck.Ping? {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: Int(perProbeTimeout), tv_usec: Int32((perProbeTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    // Concurrent checks share the process; a random identifier plus the reply's source
    // address keep one check from taking another's replies.
    let identifier = UInt16.random(in: 1...UInt16.max)
    var rtts: [Double] = []
    for sequence in 0..<count {
      if sequence > 0 { usleep(200_000) }
      var packet = icmpEcho(identifier: identifier, sequence: UInt16(sequence))
      let start = DispatchTime.now().uptimeNanoseconds
      let sent = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, &packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard sent == packet.count else { continue }
      var buffer = [UInt8](repeating: 0, count: 256)
      while true {
        var source = sockaddr_in()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &source) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &sourceLength) }
        }
        guard received > 0 else { break }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        if source.sin_addr.s_addr == address.sin_addr.s_addr,
          isEchoReply(Array(buffer.prefix(received)), sequence: UInt16(sequence))
        {
          rtts.append(elapsed)
          break
        }
        if elapsed > perProbeTimeout * 1_000 { break }
      }
    }
    let loss = Double(count - rtts.count) / Double(count) * 100
    return HeliosNetworkCheck.Ping(averageMilliseconds: rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count),
                                   lossPercent: loss)
  }

  static func icmpEcho(identifier: UInt16, sequence: UInt16) -> [UInt8] {
    var packet: [UInt8] = [8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xff),
                           UInt8(sequence >> 8), UInt8(sequence & 0xff)]
    packet += Array("helios-ping".utf8)
    let sum = checksum(packet)
    packet[2] = UInt8(sum >> 8)
    packet[3] = UInt8(sum & 0xff)
    return packet
  }

  static func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < bytes.count {
      sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
      index += 2
    }
    if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
  }

  /// An echo reply with our sequence number. The kernel may hand back the IP header too.
  static func isEchoReply(_ bytes: [UInt8], sequence: UInt16) -> Bool {
    var icmp = bytes[...]
    if let first = bytes.first, first >> 4 == 4 {
      let headerLength = Int(first & 0x0f) * 4
      guard bytes.count >= headerLength + 8 else { return false }
      icmp = bytes[headerLength...]
    }
    guard icmp.count >= 8 else { return false }
    let start = icmp.startIndex
    let replySequence = UInt16(icmp[start + 6]) << 8 | UInt16(icmp[start + 7])
    return icmp[start] == 0 && replySequence == sequence
  }

  // MARK: DNS

  /// One uncached lookup (a random label under apple.com answers NXDOMAIN from the
  /// authoritative servers), so the time is the resolver's real round trip. A resolver that
  /// answers at all, NXDOMAIN included, counts as working.
  static func lookupMilliseconds() async -> Double? {
    let host = "helios-\(UUID().uuidString.prefix(8).lowercased()).apple.com"
    return await Task.detached(priority: .utility) { () -> Double? in
      var hints = addrinfo()
      hints.ai_family = AF_UNSPEC
      hints.ai_socktype = SOCK_STREAM
      var result: UnsafeMutablePointer<addrinfo>?
      let start = DispatchTime.now().uptimeNanoseconds
      let status = getaddrinfo(host, "443", &hints, &result)
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      if let result { freeaddrinfo(result) }
      guard status == 0 || status == EAI_NONAME, elapsed.isFinite, elapsed < 10_000 else { return nil }
      return elapsed
    }.value
  }

  // MARK: Per-app traffic (local only)

  /// Two `nettop` samples a second apart; bytes per second per process, busiest first.
  static func topTraffic() async -> [HeliosNetworkCheck.AppTraffic] {
    guard let output = await runNettop(nettopRateArguments) else { return [] }
    return parseNettop(output)
  }

  /// `nettop -L 2` prints a header and one row per process for each sample. Rates come from
  /// the difference between the two samples of the same "name.pid".
  static func parseNettop(_ output: String) -> [HeliosNetworkCheck.AppTraffic] {
    var samples: [[String: Double]] = []
    var current: [String: Double] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if fields.first == "" && fields.count >= 3, fields[1] == "bytes_in" {
        if !current.isEmpty { samples.append(current) }
        current = [:]
        continue
      }
      guard fields.count >= 3, !fields[0].isEmpty, let inBytes = Double(fields[1]), let outBytes = Double(fields[2])
      else { continue }
      current[fields[0], default: 0] += inBytes + outBytes
    }
    if !current.isEmpty { samples.append(current) }
    guard samples.count >= 2 else { return [] }
    let (first, last) = (samples[samples.count - 2], samples[samples.count - 1])
    var rates: [String: Double] = [:]
    for (key, value) in last {
      let delta = value - (first[key] ?? value)
      guard delta > 0 else { continue }
      let name = key.range(of: #"\.\d+$"#, options: .regularExpression).map { String(key[..<$0.lowerBound]) } ?? key
      rates[name, default: 0] += delta
    }
    return rates.map { HeliosNetworkCheck.AppTraffic(name: $0.key, bytesPerSecond: $0.value) }
      .sorted { $0.bytesPerSecond > $1.bytesPerSecond }
      .prefix(5).map { $0 }
  }

  // MARK: Subprocess

  /// The one subprocess in Helios's runtime (owner decision 6, PLAN_0_3_0 §8): /usr/bin/nettop
  /// with fixed arguments, on request only, killed after six seconds. Per-app network bytes
  /// have no other public, unprivileged source. Its output stays on this Mac.
  static let nettopPath = "/usr/bin/nettop"
  /// Two samples a second apart (rates for the network check).
  static let nettopRateArguments = ["-P", "-x", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out"]
  /// One sample of cumulative totals (data usage, every ten minutes while that module is on).
  static let nettopTotalArguments = ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"]

  /// Cumulative bytes per "name.pid" right now, or nil when nettop could not run.
  static func cumulativeTotals() async -> [String: UInt64]? {
    guard let output = await runNettop(nettopTotalArguments) else { return nil }
    return HeliosDataUsageTracker.parseTotals(output)
  }

  private static func runNettop(_ arguments: [String]) async -> String? {
    guard arguments == nettopRateArguments || arguments == nettopTotalArguments else { return nil }
    return await Task.detached(priority: .utility) { runNettopBlocking(arguments) }.value
  }

  private static func runNettopBlocking(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: nettopPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // Drain the pipe while nettop runs: a sample larger than the pipe buffer would otherwise
    // block nettop until the time limit and leave a truncated sample.
    let output = PipeDrain()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      output.data = pipe.fileHandleForReading.readDataToEndOfFile()
      drained.signal()
    }
    if drained.wait(timeout: .now() + 6) == .timedOut {
      process.terminate()
      _ = drained.wait(timeout: .now() + 1)
      return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0, output.data.count <= 512 * 1024 else { return nil }
    return String(decoding: output.data, as: UTF8.self)
  }
}

/// Output of one subprocess, handed from the reading thread after it signals.
private final class PipeDrain: @unchecked Sendable {
  var data = Data()
}

/// Thread-safe one-shot latch.
final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false
  func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
}
