import Foundation

// Read-only capability evaluation for the cool-only fan layer
// (docs/FAN_LAYER_DESIGN.md §8). It decides whether a Mac is Validated,
// Experimental or Unsupported from evidence only; it never writes.

enum FanLayerTier: Int, Sendable {
    case unsupported = 0
    case experimental = 1
    case validated = 2

    var label: String {
        switch self {
        case .unsupported: "Unsupported"
        case .experimental: "Experimental"
        case .validated: "Validated"
        }
    }
}

/// Model and OS build a consent, journal entry or profile belongs to.
struct FanLayerMachineIdentity: Equatable, Sendable {
    static let maximumLength = 16
    let modelIdentifier: String
    let osBuild: String

    init(modelIdentifier: String, osBuild: String) throws {
        for value in [modelIdentifier, osBuild] {
            let bytes = Array(value.utf8)
            guard !bytes.isEmpty, bytes.count <= Self.maximumLength,
                  bytes.allSatisfy({ (0x21...0x7e).contains($0) }) else {
                throw TelemetryError.invalidData("Invalid machine identity")
            }
        }
        self.modelIdentifier = modelIdentifier
        self.osBuild = osBuild
    }

    static func current() throws -> FanLayerMachineIdentity {
        try FanLayerMachineIdentity(modelIdentifier: HeliosMachineIdentity.modelIdentifier,
                                    osBuild: HeliosMachineIdentity.osBuild)
    }

    var summary: String { "\(modelIdentifier) · \(osBuild)" }
}

/// Exact trusted SoC temperature keys per chip family. Prefixes are never
/// trusted. These sets mirror the app's `ThermalClassifier` allowlists (checked
/// by the fan-layer tests) so the daemon judges the same sensors as the app.
enum FanLayerTrustedThermals {
    static let m4PerformanceCPU: Set<String> = [
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
    ]
    static let m4EfficiencyCPU: Set<String> = ["Te05", "Te09", "Te0H", "Te0S"]
    static let m4GPU: Set<String> = [
        "Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k",
    ]

    static func isM4Family(_ cpuBrand: String) -> Bool {
        cpuBrand == "Apple M4" || cpuBrand.hasPrefix("Apple M4 ")
    }

    /// Key groups for this chip, or nil when Helios has no trusted map yet.
    static func groups(for cpuBrand: String) -> [Set<String>]? {
        guard isM4Family(cpuBrand) else { return nil }
        return [m4PerformanceCPU, m4EfficiencyCPU, m4GPU]
    }
}

struct FanLayerFanSurface: Equatable, Sendable {
    let id: Int
    let modeKey: String
    let minimumRPM: Double
    let maximumRPM: Double

    var limits: FanLayerFanLimits {
        FanLayerFanLimits(id: id, minimumRPM: minimumRPM, maximumRPM: maximumRPM)
    }
}

/// Raw SMC key attribute bytes (keyInfo offset 36). 0x40 is the write bit as
/// observed on Mac16,1 for Ftst/F0Md/F0Tg (0xd0/0xd0/0xd4) and absent on
/// F0Mn/F0Mx (0x84/0x85). Community knowledge, not Apple documentation.
struct FanLayerKeyAccess: Equatable, Sendable {
    static let writeBit: UInt8 = 0x40
    var attributes: [String: UInt8]

    func writable(_ key: String) -> Bool {
        guard let value = attributes[key] else { return false }
        return value & Self.writeBit != 0
    }

    /// Reads only keyInfo frames; there is no write command on this path.
    static func read(keys: [String], transport: any SMCReadTransport) throws -> FanLayerKeyAccess {
        var attributes: [String: UInt8] = [:]
        for key in keys {
            let reply = try transport.exchange(SMCReadRequest(command: .keyInfo, key: key))
            guard reply.count == SMCCodec.frameSize, reply[40] == 0 else {
                throw TelemetryError.invalidData("Invalid key attributes for \(key)")
            }
            attributes[key] = reply[36]
        }
        return FanLayerKeyAccess(attributes: attributes)
    }
}

struct FanLayerProfile: Sendable {
    let identity: FanLayerMachineIdentity
    let cpuBrand: String
    let tier: FanLayerTier
    let fans: [FanLayerFanSurface]
    let reasons: [String]

    var summary: String {
        switch tier {
        case .validated: "Validated on this Mac and macOS build"
        case .experimental: "Experimental on this Mac and macOS build"
        case .unsupported: reasons.first ?? "Fan control is not supported on this Mac"
        }
    }
}

enum FanLayerProbe {
    static let maximumPlausibleRPM = 12_000.0
    static let minimumUsefulRangeRPM = 500.0

    /// Keys whose attributes the probe needs for the given fan count.
    static func accessKeys(fanCount: Int) -> [String] {
        ["Ftst"] + (0..<max(0, min(fanCount, FanCodec.maximumFanCount))).flatMap { ["F\($0)Md", "F\($0)Tg"] }
    }

    static func evaluate(evidence: FanOwnershipPreflightEvidence, cpuBrand: String,
                         access: FanLayerKeyAccess?, trustedThermalsAvailable: Bool) throws -> FanLayerProfile {
        let identity = try FanLayerMachineIdentity(modelIdentifier: evidence.modelIdentifier,
                                                   osBuild: evidence.osBuild)
        var reasons: [String] = []
        if !cpuBrand.hasPrefix("Apple M") {
            reasons.append("Fan control is only available on Apple silicon Macs.")
        }
        if evidence.fanCount == 0 {
            reasons.append("This Mac has no fans.")
        }
        if evidence.fans.count != evidence.fanCount {
            reasons.append("Not every fan could be read.")
        }
        if FanLayerTrustedThermals.groups(for: cpuBrand) == nil {
            reasons.append("Helios does not have a verified temperature map for \(cpuBrand.isEmpty ? "this chip" : cpuBrand) yet.")
        } else if !trustedThermalsAvailable {
            reasons.append("Trusted temperature sensors could not be read.")
        }
        if evidence.globalKeyType != "ui8 " || evidence.globalKeySize != 1 {
            reasons.append("The fan arbitration key has an unexpected format.")
        }
        if evidence.globalValue != 0 {
            reasons.append("Another fan controller appears to be active (Ftst is set).")
        }
        if let access {
            if !access.writable("Ftst") { reasons.append("The fan arbitration key is not writable.") }
        } else {
            reasons.append("Fan key attributes could not be read.")
        }

        var fans: [FanLayerFanSurface] = []
        for fan in evidence.fans {
            let expectedMode = "F\(fan.id)Md"
            var fanOK = true
            if fan.modeKey != expectedMode {
                reasons.append("Fan \(fan.id + 1) uses an unsupported mode key (\(fan.modeKey)).")
                fanOK = false
            }
            if fan.mode != 0 && fan.mode != 3 {
                reasons.append("Fan \(fan.id + 1) is not under macOS control right now (mode \(fan.mode)).")
                fanOK = false
            }
            if fan.targetType != "flt " {
                reasons.append("Fan \(fan.id + 1) uses an unsupported target format.")
                fanOK = false
            }
            if !(fan.minimumRPM.isFinite && fan.maximumRPM.isFinite && fan.minimumRPM > 0
                 && fan.maximumRPM <= maximumPlausibleRPM
                 && fan.maximumRPM - fan.minimumRPM >= minimumUsefulRangeRPM) {
                reasons.append("Fan \(fan.id + 1) reports implausible factory limits.")
                fanOK = false
            }
            if !(fan.actualRPM.isFinite && fan.targetRPM.isFinite && fan.actualRPM >= 0 && fan.targetRPM >= 0) {
                reasons.append("Fan \(fan.id + 1) speed could not be read.")
                fanOK = false
            }
            if let access, !(access.writable(expectedMode) && access.writable("F\(fan.id)Tg")) {
                reasons.append("Fan \(fan.id + 1) mode or target key is not writable.")
                fanOK = false
            }
            if fanOK {
                fans.append(FanLayerFanSurface(id: fan.id, modeKey: expectedMode,
                                               minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM))
            }
        }

        let tier: FanLayerTier
        if !reasons.isEmpty {
            tier = .unsupported
        } else if isValidatedTuple(evidence) {
            tier = .validated
        } else {
            tier = .experimental
        }
        return FanLayerProfile(identity: identity, cpuBrand: cpuBrand, tier: tier,
                               fans: reasons.isEmpty ? fans : [], reasons: reasons)
    }

    /// The only physically validated tuple (same numbers as the frozen
    /// production profile).
    static func isValidatedTuple(_ evidence: FanOwnershipPreflightEvidence) -> Bool {
        let profile = FanOwnershipMachineProfile.primaryM4
        guard evidence.modelIdentifier == profile.modelIdentifier, evidence.osBuild == profile.osBuild,
              evidence.fanCount == 1, let fan = evidence.fans.first, fan.id == 0 else { return false }
        return abs(fan.minimumRPM - 2_317) <= 0.5 && abs(fan.maximumRPM - 6_550) <= 0.5
    }

    /// The same surface still present (used on every acquisition and after
    /// wake). Any drift in fan count, keys or limits fails closed.
    static func sameSurface(_ live: FanLayerProfile, as expected: FanLayerProfile) -> Bool {
        guard live.tier != .unsupported, live.identity == expected.identity,
              live.fans.count == expected.fans.count else { return false }
        return zip(live.fans, expected.fans).allSatisfy { a, b in
            a.id == b.id && a.modeKey == b.modeKey
                && abs(a.minimumRPM - b.minimumRPM) <= 0.5 && abs(a.maximumRPM - b.maximumRPM) <= 0.5
        }
    }
}
