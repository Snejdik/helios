#!/bin/bash
# Portable semantic/logic probes for UI8's Foundation-only chart merge and
# battery ETA code. This catches pure Swift regressions before macOS frameworks
# are needed; the native presentation/Xcode gate remains authoritative for UI.
set -euo pipefail
cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/helios-ui8.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

swift_compiler() {
  if command -v swiftc >/dev/null 2>&1; then
    command -v swiftc
  elif command -v xcrun >/dev/null 2>&1; then
    printf '%s\n' xcrun
  else
    return 1
  fi
}

compiler="$(swift_compiler)" || {
  echo "FAIL: Swift compiler unavailable for UI8 portable semantic probes" >&2
  exit 1
}

run_swift() {
  local source="$1" output="$2"
  if [ "$compiler" = "xcrun" ]; then
    xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors "$source" -o "$output"
  else
    "$compiler" -parse-as-library -swift-version 6 -warnings-as-errors "$source" -o "$output"
  fi
  "$output"
}

battery="$tmpdir/BatteryProbe.swift"
cat > "$battery" <<'SWIFT'
import Foundation

enum TelemetryError: Error, Equatable, Sendable { case unavailable(String) }
typealias MetricResult<Value: Sendable> = Result<Value, TelemetryError>

enum MacPowerSource: String, Sendable { case powerAdapter = "Power Adapter"; case battery = "Battery" }
enum BatteryTimeRemaining: Sendable, Equatable {
  case seconds(TimeInterval)
  case calculating
  case unlimited
}
struct BatteryPower: Sendable { let signedWatts: Double; let usesInstantaneousCurrent: Bool }
struct BatteryMetrics: Sendable {
  let maximumCapacityMAh: MetricResult<Int>
  let currentCapacityMAh: MetricResult<Int>
  let stateOfChargePercent: MetricResult<Double>
  let power: MetricResult<BatteryPower>
  let powerSource: MetricResult<MacPowerSource>
  let voltageVolts: MetricResult<Double>
  let currentAmps: MetricResult<Double>
  let timeRemaining: MetricResult<BatteryTimeRemaining>
}
struct TelemetryHistoryPoint: Sendable, Equatable {
  let capturedAt: Date
  let batteryPowerWatts: Double?
}
struct TelemetryHistory: Sendable { var points: [TelemetryHistoryPoint] = [] }
enum TelemetryFormatting {
  static func duration(_ seconds: TimeInterval) -> String { String(format: "%.0fs", seconds) }
}
SWIFT
sed '/^import Foundation$/d' Sources/HeliosApp/HeliosBatteryEstimate.swift >> "$battery"
cat >> "$battery" <<'SWIFT'

@main
struct BatteryProbe {
  static func main() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    let calculating = BatteryMetrics(
      maximumCapacityMAH: .success(6_300), currentCapacityMAH: .success(4_900),
      stateOfChargePercent: .success(78),
      power: .success(BatteryPower(signedWatts: -10, usesInstantaneousCurrent: true)),
      powerSource: .success(.battery), voltageVolts: .success(12), currentAmps: .success(-0.83),
      timeRemaining: .success(.calculating))
    let fast = HeliosBatteryEstimateEngine.estimate(
      battery: .success(calculating), history: TelemetryHistory(), now: now)
    precondition(fast.source == .helios && fast.approximate && fast.seconds != nil)

    let system = BatteryMetrics(
      maximumCapacityMAH: .success(6_300), currentCapacityMAH: .success(4_900),
      stateOfChargePercent: .success(78),
      power: .success(BatteryPower(signedWatts: -10, usesInstantaneousCurrent: true)),
      powerSource: .success(.battery), voltageVolts: .success(12), currentAmps: .success(-0.83),
      timeRemaining: .success(.seconds(14_400)))
    let native = HeliosBatteryEstimateEngine.estimate(
      battery: .success(system), history: TelemetryHistory(), now: now)
    precondition(native.source == .macOS && !native.approximate && native.seconds == 14_400)

    let adapter = BatteryMetrics(
      maximumCapacityMAH: .success(6_300), currentCapacityMAH: .success(4_900),
      stateOfChargePercent: .success(78), power: .failure(.unavailable("pending")),
      powerSource: .success(.powerAdapter), voltageVolts: .success(12), currentAmps: .success(0),
      timeRemaining: .success(.calculating))
    let ac = HeliosBatteryEstimateEngine.estimate(
      battery: .success(adapter), history: TelemetryHistory(), now: now)
    precondition(ac.source == .powerAdapter && ac.seconds == nil)
  }
}
SWIFT
# Match the real BatteryMetrics spelling while keeping the stub deliberately tiny.
sed -i.bak 's/maximumCapacityMAH/maximumCapacityMAh/g; s/currentCapacityMAH/currentCapacityMAh/g' "$battery" 2>/dev/null || true
rm -f "$battery.bak"
run_swift "$battery" "$tmpdir/BatteryProbe"

graph="$tmpdir/GraphProbe.swift"
cat > "$graph" <<'SWIFT'
import Foundation

enum HeliosGraphRange { case fiveMinutes; var seconds: TimeInterval { 300 } }
struct TelemetryHistoryPoint { let capturedAt: Date; let value: Double? }
struct PersistedTelemetryPoint { let capturedAt: Date; let value: Double? }
enum TelemetryFormatting {
  static func bytesPerSecond(_ value: Double) -> String { "\(value) B/s" }
  static func storageBytes(_ value: UInt64) -> String { "\(value) B" }
}
SWIFT
# Reuse only the real Foundation-compatible chart sample/merge implementation.
# The native renderer below HeliosGraphRangePicker imports AppKit/SwiftUI and is
# typechecked by the macOS presentation/Xcode gate instead.
awk '
  /^struct HeliosChartSample:/ {copy=1}
  /^struct HeliosGraphRangePicker:/ {copy=0}
  copy {print}
' Sources/HeliosApp/HeliosGraphKit.swift >> "$graph"
cat >> "$graph" <<'SWIFT'

@main
struct GraphProbe {
  static func main() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    let persistent = [
      PersistedTelemetryPoint(capturedAt: now.addingTimeInterval(-240), value: 10),
      PersistedTelemetryPoint(capturedAt: now.addingTimeInterval(-210), value: 20),
    ]
    let live = [
      // A live predecessor exists just before the cutoff. Because persistent
      // history already occupies the visible window, the merged series must not
      // prepend this older live point ahead of newer persistent samples.
      TelemetryHistoryPoint(capturedAt: now.addingTimeInterval(-301), value: 5),
      TelemetryHistoryPoint(capturedAt: now.addingTimeInterval(-4), value: 30),
      TelemetryHistoryPoint(capturedAt: now.addingTimeInterval(-3), value: 35),
    ]
    let merged = HeliosChartSeries.merged(
      now: now, range: .fiveMinutes, live: live, persistent: persistent,
      liveValue: { $0.value }, persistentValue: { $0.value })
    precondition(merged.last?.value == 35)
    precondition(merged.contains { $0.value == 10 })
    precondition(merged.contains { $0.value == 20 })
    precondition(!merged.contains { $0.capturedAt == now.addingTimeInterval(-301) })
    precondition(merged.contains { $0.value == nil })
    precondition(zip(merged, merged.dropFirst()).allSatisfy { $0.capturedAt < $1.capturedAt })

    // With no persistent history, keep exactly one real sample just before the
    // cutoff so the renderer can clip a continuous left-edge segment.
    let liveOnly = [
      TelemetryHistoryPoint(capturedAt: now.addingTimeInterval(-301), value: 7),
      TelemetryHistoryPoint(capturedAt: now.addingTimeInterval(-299), value: 8),
      TelemetryHistoryPoint(capturedAt: now.addingTimeInterval(-298), value: 9),
    ]
    let liveOnlyMerged = HeliosChartSeries.merged(
      now: now, range: .fiveMinutes, live: liveOnly, persistent: [],
      liveValue: { $0.value }, persistentValue: { $0.value })
    precondition(liveOnlyMerged.first?.capturedAt == now.addingTimeInterval(-301))
    precondition(liveOnlyMerged.last?.value == 9)
    precondition(zip(liveOnlyMerged, liveOnlyMerged.dropFirst()).allSatisfy {
      $0.capturedAt < $1.capturedAt
    })
  }
}
SWIFT
run_swift "$graph" "$tmpdir/GraphProbe"

legacy="$tmpdir/LegacyHistoryProbe.swift"
sed -n '1,69p' Sources/HeliosApp/Telemetry/PersistentHistory.swift > "$legacy"
cat >> "$legacy" <<'SWIFT'

@main
struct LegacyHistoryProbe {
  static func main() throws {
    let json = """
      {"capturedAt":10000,"cpuPercent":20,"gpuPercent":10,"maxSoCCelsius":50,"systemPowerWatts":10,"batteryPercent":80,"storageTemperatureCelsius":30,"fanRPM":0,"networkDownloadBytesPerSecond":1000,"networkUploadBytesPerSecond":500}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let decoded = try decoder.decode(PersistedTelemetryPoint.self, from: Data(json.utf8))
    precondition(decoded.cpuPercent == 20)
    precondition(decoded.memoryPercent == nil)
  }
}
SWIFT
run_swift "$legacy" "$tmpdir/LegacyHistoryProbe"

thermal="$tmpdir/ThermalDisplayProbe.swift"
cat > "$thermal" <<'SWIFT'
import Foundation

enum ThermalGroup: String, Sendable, CaseIterable {
  case performanceCPU = "P-core group"
  case efficiencyCPU = "E-core group"
  case gpu = "GPU group"
  case unclassified = "Unclassified"
}
struct ThermalReading: Sendable {
  let key: String
  let group: ThermalGroup
  let celsius: Double
}
SWIFT
awk '
  /^enum ThermalDisplayKind:/ {copy=1}
  /^final class SMCThermalReader/ {copy=0}
  copy {print}
' Sources/HeliosApp/Telemetry/ThermalProvider.swift >> "$thermal"
cat >> "$thermal" <<'SWIFT'

@main
struct ThermalDisplayProbe {
  static func main() {
    let readings = [
      ThermalReading(key: "TCMz", group: .unclassified, celsius: 66.6),
      ThermalReading(key: "TVMS", group: .unclassified, celsius: 90.8),
      ThermalReading(key: "TVmS", group: .unclassified, celsius: 72.0),
      ThermalReading(key: "TD14", group: .unclassified, celsius: 31.8),
      ThermalReading(key: "TDER", group: .unclassified, celsius: 31.4),
      ThermalReading(key: "Tm0p", group: .unclassified, celsius: 47.0),
      ThermalReading(key: "Ta01", group: .unclassified, celsius: 6.25),
      ThermalReading(key: "Ta05", group: .unclassified, celsius: 6.25),
      ThermalReading(key: "Ta09", group: .unclassified, celsius: 6.25),
      ThermalReading(key: "Txyz", group: .unclassified, celsius: 44.0),
    ]
    let classified = ThermalDisplayClassifier.classify(readings)
    func kind(_ key: String) -> ThermalDisplayKind? {
      classified.first(where: { $0.reading.key == key })?.info.kind
    }
    precondition(kind("TCMz") == .communityAuxiliary)
    precondition(kind("TVMS") == .virtualOrDerived)
    precondition(classified.first(where: { $0.reading.key == "TVMS" })?.info.title.contains("TVM*") == true)
    precondition(kind("TVmS") == .virtualOrDerived)
    precondition(kind("TD14") == .communityAuxiliary)
    precondition(kind("TDER") == .communityAuxiliary)
    precondition(kind("Tm0p") == .knownAuxiliary)
    precondition(kind("Ta01") == .placeholderCandidate)
    precondition(kind("Txyz") == .unknown)
  }
}
SWIFT
run_swift "$thermal" "$tmpdir/ThermalDisplayProbe"

thermal_cadence="$tmpdir/ThermalCadenceProbe.swift"
cat > "$thermal_cadence" <<'SWIFT'
import Foundation

enum TelemetryError: Error, Equatable, Sendable {
  case unavailable(String)
  case invalidData(String)
}
func captureMetric<Value>(_ operation: () throws -> Value) -> Result<Value, TelemetryError> {
  do { return .success(try operation()) }
  catch let error as TelemetryError { return .failure(error) }
  catch { return .failure(.unavailable(String(describing: error))) }
}
enum ThermalGroup: String, Sendable, CaseIterable {
  case performanceCPU = "P-core group"
  case efficiencyCPU = "E-core group"
  case gpu = "GPU group"
  case unclassified = "Unclassified"
}
struct ThermalReading: Sendable {
  let key: String
  let group: ThermalGroup
  let celsius: Double
}
struct ThermalMetrics: Sendable {
  let readings: [ThermalReading]
  let failures: [String: TelemetryError]
  let advisoryReadingsCapturedAt: Date?
  init(
    readings: [ThermalReading], failures: [String: TelemetryError],
    advisoryReadingsCapturedAt: Date? = nil
  ) {
    self.readings = readings
    self.failures = failures
    self.advisoryReadingsCapturedAt = advisoryReadingsCapturedAt
  }
}
struct ThermalClassifier {
  func group(for key: String) -> ThermalGroup {
    switch key {
    case "Tp01": return .performanceCPU
    case "Tg0G": return .gpu
    default: return .unclassified
    }
  }
}
struct FakeKeyInfo { let type: String; let size: Int }
struct FakeValue { let info: FakeKeyInfo; let bytes: [UInt8] }
struct FakeDiscovery {
  let keys: [String]
  let failures: [String: TelemetryError]
}
final class SMCClient {
  let keys = ["Tp01", "Tg0G", "TVMS", "Ta01"]
  var valueReads: [String: Int] = [:]
  func discoverKeys() throws -> FakeDiscovery { FakeDiscovery(keys: keys, failures: [:]) }
  func keyInfo(_ key: String) throws -> FakeKeyInfo { FakeKeyInfo(type: "sp78", size: 2) }
  func value(_ key: String) throws -> FakeValue {
    valueReads[key, default: 0] += 1
    let c: UInt8
    switch key {
    case "Tp01": c = 55
    case "Tg0G": c = 47
    case "TVMS": c = 91
    default: c = 6
    }
    return FakeValue(info: FakeKeyInfo(type: "sp78", size: 2), bytes: [c, 0])
  }
}
enum SMCCodec {
  static func temperature(type: String, bytes: [UInt8]) throws -> Double {
    guard let first = bytes.first else { throw TelemetryError.invalidData("empty") }
    return Double(first)
  }
}
SWIFT
awk '
  /^final class SMCThermalReader/ {copy=1}
  /^actor ThermalProvider/ {copy=0}
  copy {print}
' Sources/HeliosApp/Telemetry/ThermalProvider.swift >> "$thermal_cadence"
cat >> "$thermal_cadence" <<'SWIFT'

@main
struct ThermalCadenceProbe {
  static func main() throws {
    let client = SMCClient()
    let reader = SMCThermalReader(client: client, classifier: ThermalClassifier())
    let first = try reader.read()
    precondition(first.advisoryReadingsCapturedAt != nil)
    precondition(client.valueReads["Tp01"] == 1)
    precondition(client.valueReads["Tg0G"] == 1)
    precondition(client.valueReads["TVMS"] == 1)
    precondition(client.valueReads["Ta01"] == 1)

    let second = try reader.read()
    precondition(second.advisoryReadingsCapturedAt == first.advisoryReadingsCapturedAt)
    precondition(client.valueReads["Tp01"] == 2)
    precondition(client.valueReads["Tg0G"] == 2)
    precondition(client.valueReads["TVMS"] == 1)
    precondition(client.valueReads["Ta01"] == 1)
  }
}
SWIFT
run_swift "$thermal_cadence" "$tmpdir/ThermalCadenceProbe"

printf '%s\n' "PASS Next23 UI8 portable semantic probes: fast battery ETA, persistent/live graph merge, legacy 24h-history decode, display-only thermal classification, and split trusted/advisory thermal cadence"

notification_policy="$tmpdir/HealthNotificationPolicyProbe.swift"
cat > "$notification_policy" <<'SWIFT'
import Foundation

struct HealthIssue: Sendable, Equatable, Identifiable {
  enum Severity: Int, Sendable, Comparable {
    case attention = 1
    case critical = 2
    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
  }
  let id: String
  let severity: Severity
  let title: String
  let detail: String
}
SWIFT
awk '
  /^enum HealthNotificationPolicy/ {copy=1}
  /^actor HealthEventStore/ {copy=0}
  copy {print}
' Sources/HeliosApp/Telemetry/HealthAlerts.swift >> "$notification_policy"
cat >> "$notification_policy" <<'SWIFT'

@main
struct HealthNotificationPolicyProbe {
  static func main() {
    let now = Date(timeIntervalSinceReferenceDate: 50_000)
    let attention = HealthIssue(
      id: "attention", severity: .attention, title: "High temperature", detail: "90°C")
    let critical = HealthIssue(
      id: "critical", severity: .critical, title: "Critical temperature", detail: "95°C")

    precondition(!HealthNotificationPolicy.shouldNotify(
      issue: attention, activeSince: now.addingTimeInterval(-14), lastNotifiedAt: nil, now: now))
    precondition(HealthNotificationPolicy.shouldNotify(
      issue: attention, activeSince: now.addingTimeInterval(-15), lastNotifiedAt: nil, now: now))
    precondition(!HealthNotificationPolicy.shouldNotify(
      issue: attention, activeSince: now.addingTimeInterval(-60),
      lastNotifiedAt: now.addingTimeInterval(-5 * 60), now: now))
    precondition(HealthNotificationPolicy.shouldNotify(
      issue: attention, activeSince: now.addingTimeInterval(-60),
      lastNotifiedAt: now.addingTimeInterval(-31 * 60), now: now))

    precondition(HealthNotificationPolicy.shouldNotify(
      issue: critical, activeSince: now, lastNotifiedAt: nil, now: now))
    precondition(!HealthNotificationPolicy.shouldNotify(
      issue: critical, activeSince: now.addingTimeInterval(-30),
      lastNotifiedAt: now.addingTimeInterval(-5 * 60), now: now))
    precondition(HealthNotificationPolicy.shouldNotify(
      issue: critical, activeSince: now.addingTimeInterval(-30),
      lastNotifiedAt: now.addingTimeInterval(-11 * 60), now: now))

    // Backwards wall-clock movement must never bypass the cooldown.
    precondition(!HealthNotificationPolicy.shouldNotify(
      issue: critical, activeSince: now.addingTimeInterval(-30),
      lastNotifiedAt: now.addingTimeInterval(30), now: now))
  }
}
SWIFT
run_swift "$notification_policy" "$tmpdir/HealthNotificationPolicyProbe"

printf '%s\n' "PASS Next23 UI9 alert anti-spam policy: sustained attention threshold, bounded critical/attention cooldowns, and clock-rollback suppression"
