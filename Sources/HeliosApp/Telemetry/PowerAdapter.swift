import Foundation
import IOKit

/// The connected power adapter as AppleSmartBattery describes it. Read-only, from the
/// IORegistry; Helios never influences charging (scripts/check-battery-readonly.sh).
struct PowerAdapterDetails: Sendable, Equatable, Codable {
  /// "70W USB-C Power Adapter"; nil for adapters that do not say.
  var name: String?
  /// The rating in the adapter's own name ("70W …"), when it has one.
  var ratedWatts: Int?
  /// Highest power the adapter offers over this cable (USB-PD offers, volts × amps).
  var offeredWatts: Int?
  /// What the Mac and adapter agreed on.
  var negotiatedWatts: Int?
  var isWireless: Bool = false
  /// Seconds macOS has slowed charging because the battery was warm (counter, if published).
  var thermallyLimitedSeconds: Int?

  /// The adapter offers clearly less than its own rating: with USB-C that is almost always
  /// the cable (a 3 A cable caps a 96 W adapter at 60 W) or a hub in between.
  var limitedByCable: Bool {
    guard let rated = ratedWatts, let offered = offeredWatts, rated >= 45 else { return false }
    return Double(offered) < Double(rated) * 0.8
  }
}

enum PowerAdapterParser {
  /// `AdapterDetails` and `ChargerData` from AppleSmartBattery. nil when no adapter is
  /// described (on battery, or a Mac without a battery).
  static func parse(adapterDetails: [String: Any], chargerData: [String: Any]) -> PowerAdapterDetails? {
    let watts = integer(adapterDetails["Watts"]).flatMap { (1...500).contains($0) ? $0 : nil }
    let name = (adapterDetails["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(64).description
    let offers = (adapterDetails["UsbHvcMenu"] as? [[String: Any]] ?? []).compactMap { offer -> Int? in
      guard let millivolts = integer(offer["MaxVoltage"]), let milliamps = integer(offer["MaxCurrent"]),
        (1_000...50_000).contains(millivolts), (1...10_000).contains(milliamps)
      else { return nil }
      return Int((Double(millivolts) * Double(milliamps) / 1_000_000).rounded())
    }
    guard watts != nil || !(name ?? "").isEmpty || !offers.isEmpty else { return nil }
    var details = PowerAdapterDetails()
    details.name = (name ?? "").isEmpty ? nil : name
    details.ratedWatts = name.flatMap(ratedWatts(fromName:))
    details.offeredWatts = offers.max()
    details.negotiatedWatts = watts
    details.isWireless = (adapterDetails["IsWireless"] as? Bool) ?? false
    details.thermallyLimitedSeconds = integer(chargerData["TimeChargingThermallyLimited"])
      .flatMap { $0 >= 0 ? $0 : nil }
    return details
  }

  /// "70W USB-C Power Adapter" → 70; "96 W" → 96. Only a leading number with a W counts.
  static func ratedWatts(fromName name: String) -> Int? {
    let scanner = Scanner(string: name)
    scanner.charactersToBeSkipped = .whitespaces
    guard let value = scanner.scanInt(), (5...500).contains(value) else { return nil }
    guard scanner.scanCharacter().map({ $0 == "W" || $0 == "w" }) == true else { return nil }
    return value
  }

  private static func integer(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber:
      let int = number.int64Value
      return int >= Int64(Int32.min) && int <= Int64(Int32.max) ? Int(int) : nil
    case let int as Int: return int
    default: return nil
    }
  }
}

/// Reads only the two properties it needs, and only when asked (every few minutes while
/// the Mac is on the adapter, or when the Longevity page opens).
final class PowerAdapterReader: @unchecked Sendable {
  private let lock = NSLock()
  private var service: io_service_t = 0

  deinit { if service != 0 { IOObjectRelease(service) } }

  func read() -> PowerAdapterDetails? {
    lock.lock(); defer { lock.unlock() }
    if service == 0 {
      service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }
    guard service != 0 else { return nil }
    func property(_ key: String) -> [String: Any] {
      IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? [String: Any] ?? [:]
    }
    return PowerAdapterParser.parse(adapterDetails: property("AdapterDetails"), chargerData: property("ChargerData"))
  }
}
