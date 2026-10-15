import CoreWLAN
import Foundation

// Network health beyond one check (PLAN_0_3_0 M4): Wi-Fi channel congestion from an
// on-demand scan (no Location permission: names stay hidden, only channels and signal are
// used), Wi-Fi drops in the last hour, and data usage per day and app. All local only.

// MARK: - Wi-Fi channel congestion

struct HeliosWiFiNeighbor: Equatable, Sendable {
  let channel: Int
  /// "2.4 GHz", "5 GHz", "6 GHz".
  let band: String
  let rssi: Int
}

struct HeliosWiFiCongestion: Equatable, Sendable {
  let currentChannel: Int
  let band: String
  /// Other networks on this exact channel.
  let sameChannel: Int
  /// Of those, the ones strong enough to compete (≥ −75 dBm).
  let strongSameChannel: Int
  /// Least used channels in the same band, best first.
  let quieterChannels: [Int]
  let totalNearby: Int

  var crowded: Bool { strongSameChannel >= 4 || sameChannel >= 7 }

  /// 2.4 GHz neighbours overlap within ±4 channels; 5/6 GHz channels are counted exactly.
  static func analyze(_ neighbors: [HeliosWiFiNeighbor], currentChannel: Int, band: String) -> Self {
    let sameBand = neighbors.filter { $0.band == band }
    func competes(_ n: HeliosWiFiNeighbor) -> Bool {
      band == "2.4 GHz" ? abs(n.channel - currentChannel) <= 4 : n.channel == currentChannel
    }
    let same = sameBand.filter(competes)
    let candidates: [Int] = band == "2.4 GHz" ? [1, 6, 11]
      : Array(Set(sameBand.map(\.channel) + [currentChannel])).sorted()
    let load = Dictionary(grouping: sameBand, by: \.channel).mapValues(\.count)
    let quieter = candidates.filter { $0 != currentChannel }
      .sorted { (load[$0] ?? 0, $0) < (load[$1] ?? 0, $1) }
      .filter { (load[$0] ?? 0) < same.count }
    return Self(currentChannel: currentChannel, band: band, sameChannel: same.count,
                strongSameChannel: same.filter { $0.rssi >= -75 }.count,
                quieterChannels: Array(quieter.prefix(3)), totalNearby: neighbors.count)
  }
}

enum HeliosWiFiScanner {
  /// One active scan (about 3–5 s). nil when Wi-Fi is off or not associated.
  static func scan() async -> HeliosWiFiCongestion? {
    await Task.detached(priority: .utility) { () -> HeliosWiFiCongestion? in
      guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
        let current = interface.wlanChannel(), let networks = try? interface.scanForNetworks(withSSID: nil)
      else { return nil }
      let neighbors = networks.compactMap { network -> HeliosWiFiNeighbor? in
        guard let channel = network.wlanChannel else { return nil }
        return HeliosWiFiNeighbor(channel: channel.channelNumber, band: bandName(channel.channelBand),
                                  rssi: network.rssiValue)
      }
      // The scan includes the network this Mac is on; do not count it against itself.
      var others = neighbors
      if let index = others.firstIndex(where: {
        $0.channel == current.channelNumber && $0.band == bandName(current.channelBand)
      }) { others.remove(at: index) }
      return HeliosWiFiCongestion.analyze(others, currentChannel: current.channelNumber,
                                          band: bandName(current.channelBand))
    }.value
  }

  static func bandName(_ band: CWChannelBand) -> String {
    switch band {
    case .band2GHz: "2.4 GHz"
    case .band5GHz: "5 GHz"
    case .band6GHz: "6 GHz"
    default: "unknown"
    }
  }
}

// MARK: - Wi-Fi drops

/// Counts Wi-Fi disconnections (service active → inactive while powered on) over the last hour.
struct HeliosWiFiDropTracker: Sendable {
  private(set) var drops: [Date] = []
  private var wasActive: Bool?

  mutating func observe(_ wifi: WiFiMetrics?, now: Date) {
    drops.removeAll { now.timeIntervalSince($0) > 3_600 }
    guard let wifi, wifi.powerOn else { wasActive = nil; return }
    if wasActive == true, !wifi.serviceActive { drops.append(now) }
    wasActive = wifi.serviceActive
  }
}

// MARK: - Data usage per day and app

struct HeliosDataUsageDay: Codable, Equatable, Sendable {
  /// yyyy-MM-dd in the user's calendar.
  let day: String
  var apps: [String: UInt64]
  /// Bytes moved while macOS marked the connection as metered (personal hotspot).
  var metered: UInt64

  var total: UInt64 { apps.values.reduce(0, +) }
}

/// Turns successive cumulative `nettop` totals per "name.pid" into per-app deltas.
/// A process first seen in a later sample started in between, so all its bytes count;
/// processes present in the very first sample only set the baseline.
struct HeliosDataUsageTracker: Sendable {
  private(set) var last: [String: UInt64]?

  mutating func deltas(_ totals: [String: UInt64]) -> [String: UInt64] {
    defer { last = totals }
    guard let last else { return [:] }
    var result: [String: UInt64] = [:]
    for (key, value) in totals {
      let previous = last[key]
      let delta = previous.map { value >= $0 ? value - $0 : 0 } ?? value
      guard delta > 0 else { continue }
      result[Self.appName(key), default: 0] += delta
    }
    return result
  }

  static func appName(_ key: String) -> String {
    key.range(of: #"\.\d+$"#, options: .regularExpression).map { String(key[..<$0.lowerBound]) } ?? key
  }

  /// One `nettop -L 1` sample: cumulative bytes in + out per "name.pid".
  static func parseTotals(_ output: String) -> [String: UInt64] {
    var totals: [String: UInt64] = [:]
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard fields.count >= 3, !fields[0].isEmpty, let inBytes = UInt64(fields[1]), let outBytes = UInt64(fields[2])
      else { continue }
      totals[fields[0], default: 0] += inBytes &+ outBytes
    }
    return totals
  }
}

enum HeliosDataUsageStore {
  static let retentionDays = 60
  static let appsPerDay = 30
  static let otherName = "Other"

  static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// Adds one sample's deltas to today, keeps the top apps (the rest folds into "Other")
  /// and drops days past retention.
  static func merge(_ days: [HeliosDataUsageDay], deltas: [String: UInt64], metered: Bool, now: Date,
                    calendar: Calendar = .current) -> [HeliosDataUsageDay] {
    let key = dayKey(now, calendar: calendar)
    var result = days.filter { $0.day != key }
    var today = days.first { $0.day == key } ?? HeliosDataUsageDay(day: key, apps: [:], metered: 0)
    for (app, bytes) in deltas { today.apps[app, default: 0] &+= bytes }
    if metered { today.metered &+= deltas.values.reduce(0, &+) }
    if today.apps.count > appsPerDay {
      let sorted = today.apps.sorted { $0.value > $1.value }
      var kept = Dictionary(uniqueKeysWithValues: sorted.prefix(appsPerDay - 1).map { ($0.key, $0.value) })
      kept[otherName, default: 0] &+= sorted.dropFirst(appsPerDay - 1).reduce(0) { $0 &+ $1.value }
      today.apps = kept
    }
    result.append(today)
    let cutoff = dayKey(now.addingTimeInterval(-Double(retentionDays) * 86_400), calendar: calendar)
    return result.filter { $0.day > cutoff }.sorted { $0.day < $1.day }
  }

  /// Top apps over the last `days` days.
  static func top(_ days: [HeliosDataUsageDay], last count: Int, now: Date, calendar: Calendar = .current,
                  limit: Int = 5) -> [(app: String, bytes: UInt64)] {
    let cutoff = dayKey(now.addingTimeInterval(-Double(count - 1) * 86_400), calendar: calendar)
    var totals: [String: UInt64] = [:]
    for day in days where day.day >= cutoff { for (app, bytes) in day.apps { totals[app, default: 0] &+= bytes } }
    return totals.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
  }

  /// Hotspot thresholds crossed by the latest sample, each reported once per day.
  static let meteredThresholds: [UInt64] = [250_000_000, 1_000_000_000, 3_000_000_000]

  static func crossed(previous: UInt64, current: UInt64) -> UInt64? {
    meteredThresholds.last { previous < $0 && current >= $0 }
  }

  static var url: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Helios", isDirectory: true).appendingPathComponent("data-usage.json")
  }

  static func load(from url: URL = url) -> [HeliosDataUsageDay] {
    guard let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return [] }
    return (try? JSONDecoder().decode([HeliosDataUsageDay].self, from: data)) ?? []
  }

  static func save(_ days: [HeliosDataUsageDay], to url: URL = url) {
    guard let data = try? JSONEncoder().encode(days) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? data.write(to: url, options: [.atomic])
  }
}

// MARK: - Latency over time

/// One background latency look (opt-in): the router and the internet, three echoes each.
struct HeliosLatencySample: Codable, Equatable, Sendable {
  let at: Date
  var routerMilliseconds: Double?
  var routerLossPercent: Double?
  var internetMilliseconds: Double?
  var internetLossPercent: Double?

  init(at: Date, router: HeliosNetworkCheck.Ping?, internet: HeliosNetworkCheck.Ping?) {
    self.at = at
    routerMilliseconds = router?.averageMilliseconds
    routerLossPercent = router?.lossPercent
    internetMilliseconds = internet?.averageMilliseconds
    internetLossPercent = internet?.lossPercent
  }

  /// No answer at all counts as full loss; a partial answer keeps its measured loss.
  var internetLost: Bool { (internetLossPercent ?? 0) > 0 }
  var routerLost: Bool { (routerLossPercent ?? 0) > 0 }
}

/// Seven days of samples every five minutes, so "is it always like this, or just now?" has
/// an answer. Pure: bounds, order and the summary; the app owns the file and the timer.
enum HeliosLatencyHistory {
  static let interval: TimeInterval = 300
  static let retention: TimeInterval = 7 * 86_400
  static let maximumSamples = 2_100
  static let echoesPerHost = 3

  /// Appends in time order; drops samples past retention, from the future and over the cap.
  static func appended(_ samples: [HeliosLatencySample], _ sample: HeliosLatencySample, now: Date)
    -> [HeliosLatencySample]
  {
    sanitized(samples + [sample], now: now)
  }

  static func sanitized(_ samples: [HeliosLatencySample], now: Date) -> [HeliosLatencySample] {
    let kept = samples.filter { $0.at <= now.addingTimeInterval(60) && now.timeIntervalSince($0.at) <= retention }
      .filter { sample in
        [sample.routerMilliseconds, sample.internetMilliseconds].allSatisfy { value in
          value.map { $0.isFinite && $0 >= 0 && $0 < 60_000 } ?? true
        }
      }
      .sorted { $0.at < $1.at }
    return Array(kept.suffix(maximumSamples))
  }

  struct Summary: Equatable, Sendable {
    let count: Int
    let internetMedian: Double?
    /// The slowest 5 % of answers start here.
    let internetSlowest: Double?
    let routerMedian: Double?
    /// Looks where the internet lost packets while the router lost none.
    let lossBeyondRouter: Int
    /// Looks where the router itself lost packets.
    let lossAtRouter: Int
  }

  static func summary(_ samples: [HeliosLatencySample], since: Date) -> Summary {
    let window = samples.filter { $0.at >= since }
    let internet = window.compactMap(\.internetMilliseconds).sorted()
    let router = window.compactMap(\.routerMilliseconds).sorted()
    return Summary(
      count: window.count,
      internetMedian: percentile(internet, 0.5), internetSlowest: percentile(internet, 0.95),
      routerMedian: percentile(router, 0.5),
      lossBeyondRouter: window.filter { $0.internetLost && !$0.routerLost }.count,
      lossAtRouter: window.filter(\.routerLost).count)
  }

  static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let index = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[max(0, min(sorted.count - 1, index))]
  }

  /// "Is it worse than usual?": the last hour against this Mac's own week. Nil until there is
  /// enough of both (an hour of looks and a day of history).
  struct Trend: Equatable, Sendable {
    let recentMedian: Double
    let usualMedian: Double
    let recentLossBeyondRouter: Int
    let recentCount: Int
  }

  static func trend(_ samples: [HeliosLatencySample], now: Date) -> Trend? {
    let recentStart = now.addingTimeInterval(-3_600)
    let recent = samples.filter { $0.at >= recentStart && $0.at <= now }
    let usual = samples.filter { $0.at < recentStart }
    guard recent.count >= 6, usual.count >= 48,
      let recentMedian = percentile(recent.compactMap(\.internetMilliseconds).sorted(), 0.5),
      let usualMedian = percentile(usual.compactMap(\.internetMilliseconds).sorted(), 0.5)
    else { return nil }
    return Trend(recentMedian: recentMedian, usualMedian: usualMedian,
                 recentLossBeyondRouter: recent.filter { $0.internetLost && !$0.routerLost }.count,
                 recentCount: recent.count)
  }
}
