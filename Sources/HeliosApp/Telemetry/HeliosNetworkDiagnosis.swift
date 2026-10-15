import Foundation

/// Result of one on-demand network check (PLAN_0_3_0 M4). Each step is optional: a probe
/// that could not run leaves its field nil and the diagnosis says so instead of guessing.
struct HeliosNetworkCheck: Sendable, Equatable {
  struct Ping: Sendable, Equatable {
    /// Round-trip average in milliseconds; nil when nothing came back.
    let averageMilliseconds: Double?
    let lossPercent: Double
  }

  struct AppTraffic: Sendable, Equatable {
    let name: String
    let bytesPerSecond: Double
  }

  let checkedAt: Date
  /// Default route exists (any interface).
  let connected: Bool
  /// The default route goes through a VPN tunnel (utun/ipsec/ppp).
  let vpnActive: Bool
  /// macOS marks the path expensive (personal hotspot, cellular).
  let expensivePath: Bool
  let gateway: Ping?
  /// Public DNS-independent internet reachability (1.1.1.1).
  let internet: Ping?
  /// Uncached name lookup time in milliseconds; nil when the lookup failed.
  let dnsMilliseconds: Double?
  let dnsFailed: Bool
  /// Busiest apps by network traffic during the check, local only.
  let topTraffic: [AppTraffic]
  /// Wi-Fi channel congestion from a scan during the check (nil when not on Wi-Fi).
  var congestion: HeliosWiFiCongestion? = nil
}

enum HeliosNetworkDiagnosis {
  static func causes(_ c: inout HeliosDiagnose.Context) -> [HeliosCause?] {
    let wifi = TelemetryFormatting.fresh(c.input.snapshot.wifi, maxAge: 30, now: c.now)
    guard let check = c.input.network else {
      c.gaps.append("Run a network check to measure the router, name lookups and the internet.")
      return [wifiWeak(wifi), wifiDrops(c.input.wifiDropsLastHour), latencyTrend(c.input.latencyHistory, now: c.now)]
    }
    guard check.connected else {
      return [HeliosCause(
        id: "net.offline", observation: "The Mac has no network connection right now.",
        reasoning: "Without a route to the router nothing beyond this Mac can be reached.",
        confidence: .likely, weight: 200, action: .openSystemSettings("Network"))]
    }
    if check.gateway == nil { c.gaps.append("The router could not be measured.") }
    if check.internet == nil { c.gaps.append("The internet could not be measured.") }
    return [wifiWeak(wifi), wifiDrops(c.input.wifiDropsLastHour), channelCrowded(check), routerSlow(check),
            dnsSlow(check), providerSlow(check), vpn(check), ownTraffic(check), hotspot(check),
            latencyTrend(c.input.latencyHistory, now: c.now)]
  }

  /// From the opt-in history: is the last hour worse than this Mac's own week? A change
  /// against its own baseline, not a single slow answer.
  static func latencyTrend(_ history: [HeliosLatencySample], now: Date) -> HeliosCause? {
    guard let trend = HeliosLatencyHistory.trend(history, now: now) else { return nil }
    let slower = trend.recentMedian > max(50, trend.usualMedian * 2)
    let lossy = trend.recentLossBeyondRouter >= 3
    guard slower || lossy else { return nil }
    let observation = slower
      ? "In the last hour the internet answered in \(ms(trend.recentMedian)), against \(ms(trend.usualMedian)) usually on this Mac."
      : "In the last hour \(trend.recentLossBeyondRouter) of \(trend.recentCount) measurements lost packets beyond your router."
    return HeliosCause(
      id: "net.history", observation: observation,
      reasoning: "Helios has measured this every five minutes, so it is a change from this Mac's usual, not a single slow answer. When the router stays fast, the cause is usually the provider or further out.",
      confidence: slower && lossy ? .likely : .possible, weight: 105,
      evidence: [HeliosCauseEvidence(label: "Usual internet latency", value: ms(trend.usualMedian)),
                 HeliosCauseEvidence(label: "Last hour", value: ms(trend.recentMedian))],
      action: .openPage("network"))
  }

  static func wifiDrops(_ count: Int) -> HeliosCause? {
    guard count > 0 else { return nil }
    return HeliosCause(
      id: "net.drops", observation: "Wi-Fi dropped \(count == 1 ? "once" : "\(count) times") in the last hour.",
      reasoning: "Every drop stops downloads and calls while the Mac reconnects; repeated drops point to a weak signal, interference or the router.",
      confidence: count >= 3 ? .likely : .possible, weight: 100 + Double(count), action: .openPage("network"))
  }

  static func channelCrowded(_ check: HeliosNetworkCheck) -> HeliosCause? {
    guard let congestion = check.congestion, congestion.crowded else { return nil }
    let better = congestion.quieterChannels.first.map { " Channel \($0) is quieter; your router can be set to it." } ?? ""
    return HeliosCause(
      id: "net.channel",
      observation: "Your Wi-Fi channel \(congestion.currentChannel) (\(congestion.band)) is shared with \(congestion.sameChannel) other networks nearby.",
      reasoning: "Networks on the same channel take turns, so each gets less airtime." + better,
      confidence: .possible, weight: 60 + Double(congestion.strongSameChannel),
      evidence: [HeliosCauseEvidence(label: "Networks nearby", value: "\(congestion.totalNearby)")],
      action: .openPage("network"))
  }

  private static func ms(_ value: Double) -> String { "\(Int(value.rounded())) ms" }

  static func wifiWeak(_ wifi: MetricResult<WiFiMetrics>) -> HeliosCause? {
    guard case .success(let metrics) = wifi, metrics.serviceActive else { return nil }
    let snr = try? metrics.signalToNoiseDB.get()
    let rssi = try? metrics.rssiDBm.get()
    let rate = try? metrics.transmitRateMbps.get()
    let weakSignal = (snr.map { $0 < 15 } ?? false) || (rssi.map { $0 < -75 } ?? false)
    let slowLink = rate.map { $0 < 50 } ?? false
    guard weakSignal || slowLink else { return nil }
    var evidence: [HeliosCauseEvidence] = []
    if let rssi { evidence.append(HeliosCauseEvidence(label: "Signal", value: "\(rssi) dBm")) }
    if let snr { evidence.append(HeliosCauseEvidence(label: "Signal-to-noise", value: "\(snr) dB")) }
    if let rate { evidence.append(HeliosCauseEvidence(label: "Link rate", value: "\(Int(rate.rounded())) Mbit/s")) }
    return HeliosCause(
      id: "net.wifi",
      observation: weakSignal
        ? "The Wi-Fi signal is weak\(snr.map { " (signal-to-noise \($0) dB)" } ?? "")."
        : "The Wi-Fi link runs at only \(Int((rate ?? 0).rounded())) Mbit/s.",
      reasoning: "A weak or slow link loses and retransmits packets; moving closer to the router or away from walls and microwaves helps.",
      confidence: weakSignal ? .likely : .possible, weight: 90 - Double(snr ?? 15),
      evidence: evidence, action: .openPage("network"))
  }

  /// One lost echo of five says little (routers often drop pings when busy); two or more do.
  static let meaningfulLossPercent = 30.0

  static func routerSlow(_ check: HeliosNetworkCheck) -> HeliosCause? {
    guard let gateway = check.gateway else { return nil }
    let slow = (gateway.averageMilliseconds ?? .infinity) > 50
    let lossy = gateway.lossPercent >= meaningfulLossPercent
    guard slow || lossy else { return nil }
    return HeliosCause(
      id: "net.router",
      observation: gateway.averageMilliseconds.map { "Your router answers in \(ms($0)) with \(Int(gateway.lossPercent)) % loss." }
        ?? "Your router did not answer.",
      reasoning: "The router should answer within a few milliseconds; a slow or lossy answer points to the Wi-Fi or the router itself, before the internet is even involved.",
      confidence: .likely, weight: 120,
      evidence: [HeliosCauseEvidence(label: "Router", value: gateway.averageMilliseconds.map(ms) ?? "no answer")],
      action: .runNetworkCheck)
  }

  static func dnsSlow(_ check: HeliosNetworkCheck) -> HeliosCause? {
    if check.dnsFailed {
      return HeliosCause(
        id: "net.dns", observation: "Name lookups fail.",
        reasoning: "Without working DNS, web addresses cannot be turned into servers, so pages do not load even though the connection is up.",
        confidence: .likely, weight: 110, action: .openSystemSettings("Network"))
    }
    guard let dns = check.dnsMilliseconds, dns > 300 else { return nil }
    return HeliosCause(
      id: "net.dns", observation: "Name lookups take \(ms(dns)).",
      reasoning: "Every new site waits for a lookup first; a slow DNS server makes pages start late. Another DNS server may help.",
      confidence: .likely, weight: min(100, dns / 10),
      evidence: [HeliosCauseEvidence(label: "DNS", value: ms(dns))], action: .openSystemSettings("Network"))
  }

  static func providerSlow(_ check: HeliosNetworkCheck) -> HeliosCause? {
    guard let internet = check.internet else { return nil }
    let routerFine = check.gateway.map { ($0.averageMilliseconds ?? .infinity) <= 20 && $0.lossPercent < meaningfulLossPercent } ?? false
    let slow = (internet.averageMilliseconds ?? .infinity) > 150 || internet.lossPercent >= meaningfulLossPercent
    guard slow else { return nil }
    let routerText = check.gateway?.averageMilliseconds.map { "Your router answers in \(ms($0)), " } ?? ""
    let internetText = internet.averageMilliseconds.map { "the internet in \(ms($0))" } ?? "the internet does not answer"
    return HeliosCause(
      id: "net.provider",
      observation: "\(routerText)\(internetText)\(internet.lossPercent > 0 ? " with \(Int(internet.lossPercent)) % loss" : "").",
      reasoning: routerFine
        ? "The local network is fine, so the delay is beyond your router: at your provider or further out."
        : "The internet is slow, but so is the local network, so the router or Wi-Fi may be part of it.",
      confidence: routerFine ? .likely : .possible, weight: 100,
      evidence: [HeliosCauseEvidence(label: "Internet", value: internet.averageMilliseconds.map(ms) ?? "no answer")],
      action: .runNetworkCheck)
  }

  static func vpn(_ check: HeliosNetworkCheck) -> HeliosCause? {
    guard check.vpnActive else { return nil }
    return HeliosCause(
      id: "net.vpn", observation: "Traffic goes through a VPN.",
      reasoning: "A VPN sends everything through its own server first, which adds delay and may limit speed.",
      confidence: .possible, weight: 50, action: .openSystemSettings("VPN"))
  }

  static func ownTraffic(_ check: HeliosNetworkCheck) -> HeliosCause? {
    guard let top = check.topTraffic.first, top.bytesPerSecond >= 2_000_000 else { return nil }
    return HeliosCause(
      id: "net.app",
      observation: "\(top.name) is transferring \(TelemetryFormatting.storageBytes(UInt64(top.bytesPerSecond)))/s.",
      reasoning: "A big download, upload or sync on this Mac fills the line, so everything else waits behind it.",
      confidence: .possible, weight: min(90, top.bytesPerSecond / 100_000), action: .openActivityMonitor)
  }

  static func hotspot(_ check: HeliosNetworkCheck) -> HeliosCause? {
    guard check.expensivePath else { return nil }
    return HeliosCause(
      id: "net.hotspot", observation: "The Mac is on a personal hotspot or another metered connection.",
      reasoning: "Mobile connections vary with signal and may be throttled after a data limit.",
      confidence: .possible, weight: 40, action: .openPage("network"))
  }
}
