import Foundation

/// Anonymous, read-only SMC inventory a user can save and share to help Helios support
/// their Mac (PLAN_0_3_0 M1). It holds the model, chip, macOS build and, per key, the
/// name, type, size, attribute byte and a numeric value. Text and blob types are listed
/// without their value because they could carry identifiers. Nothing is sent anywhere;
/// the user decides what to do with the file. There is no write command on this path.
enum SMCDump {
  static let formatVersion = 1
  static let maximumKeys = 8_192

  /// Fixed-size numeric types whose value is safe to share. Anything else (`ch8*`,
  /// `{…` structures, `hex_`, unknown types) keeps an empty value.
  static func isShareableNumeric(type: String) -> Bool {
    switch type {
    case "flt ", "ui8 ", "ui16", "ui32", "ui64", "si8 ", "si16", "si32", "si64", "flag", "ioft":
      return true
    default:
      let characters = Array(type)
      guard characters.count == 4, characters[0] == "s" || characters[0] == "f",
        characters[1] == "p", characters[2].isHexDigit, characters[3].isHexDigit
      else { return false }
      return true
    }
  }

  static func make(transport: any SMCReadTransport, profile: MacProfile, date: Date = Date()) throws -> String {
    let client = SMCClient(transport: transport)
    let discovered = try client.discoverKeys()
    guard discovered.keys.count <= maximumKeys else {
      throw TelemetryError.invalidData("SMC key count outside supported bounds")
    }
    let day = ISO8601DateFormatter.string(
      from: date, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
    var lines = [
      "# Helios SMC dump v\(formatVersion)",
      "# model=\(profile.machineModel) chip=\(profile.cpuBrand) build=\(profile.osBuild) cores=\(cores(profile)) keys=\(discovered.keys.count) date=\(day)",
      "# Read-only. Key names, types, attributes and numeric values only; text and binary values are left out.",
      "key\ttype\tsize\tattr\tvalue",
    ]
    lines.reserveCapacity(discovered.keys.count + 4)
    for key in discovered.keys {
      try Task.checkCancellation()
      guard let info = try? client.keyInfo(key) else {
        lines.append("\(key)\t?\t?\t??\t")
        continue
      }
      lines.append("\(key)\t\(info.type)\t\(info.size)\t\(attribute(key, transport))\t\(value(key, info, client))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// "Apple M4 Mac16,1 26A434" style file name, without anything personal.
  static func suggestedFileName(_ profile: MacProfile) -> String {
    let parts = [profile.machineModel, profile.chip?.name ?? "unknown-chip", profile.osBuild]
      .map { $0.replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "," } }
      .filter { !$0.isEmpty }
    return "Helios-SMC-\(parts.joined(separator: "-")).tsv"
  }

  private static func cores(_ profile: MacProfile) -> String {
    guard let p = profile.performanceCoreCount, let e = profile.efficiencyCoreCount else { return "unknown" }
    return "\(p)P+\(e)E"
  }

  /// Raw keyInfo attribute byte (offset 36); "??" when unreadable.
  private static func attribute(_ key: String, _ transport: any SMCReadTransport) -> String {
    guard let reply = try? transport.exchange(SMCReadRequest(command: .keyInfo, key: key)),
      reply.count == SMCCodec.frameSize, reply[40] == 0
    else { return "??" }
    return String(format: "%02x", reply[36])
  }

  private static func value(_ key: String, _ info: SMCKeyInfo, _ client: SMCClient) -> String {
    guard isShareableNumeric(type: info.type), let raw = try? client.value(key) else { return "" }
    if key.hasPrefix("T"), let celsius = try? SMCCodec.temperature(type: raw.info.type, bytes: raw.bytes),
      celsius.isFinite
    {
      return String(format: "%.2f", celsius)
    }
    if let number = try? SMCCodec.numeric(type: raw.info.type, bytes: raw.bytes), number.isFinite {
      return String(format: "%g", number)
    }
    return raw.bytes.map { String(format: "%02x", $0) }.joined()
  }
}
