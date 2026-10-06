import Foundation

/// The daemon's own trusted temperature input for the fan layer. It never
/// relies on the app for the safety floor or the emergency path.
protocol FanLayerThermalSource: AnyObject {
    /// Hottest trusted SoC reading in °C. Throws when any trusted group has no
    /// plausible reading; callers treat that as stale thermals and release.
    func maximumSoCCelsius() throws -> Double
}

/// Read-only. Uses exact allowlisted keys for this chip family; a missing or
/// implausible group is an error, never a guess.
final class SMCFanLayerThermals: FanLayerThermalSource {
    static let plausibleCelsius = 5.0...130.0

    private let client: SMCClient
    private let groups: [[String]]

    init(client: SMCClient, cpuBrand: String) throws {
        guard let allowlists = FanLayerTrustedThermals.groups(for: cpuBrand) else {
            throw TelemetryError.unavailable("No trusted temperature map for \(cpuBrand)")
        }
        var groups: [[String]] = []
        for allowlist in allowlists {
            let present = allowlist.sorted().filter { key in
                guard let info = try? client.keyInfo(key) else { return false }
                return (info.type == "flt " && info.size == 4) || (info.type == "sp78" && info.size == 2)
            }
            guard !present.isEmpty else {
                throw TelemetryError.unavailable("A trusted temperature group is missing on this Mac")
            }
            groups.append(present)
        }
        self.client = client
        self.groups = groups
    }

    func maximumSoCCelsius() throws -> Double {
        var hottest = -Double.infinity
        for group in groups {
            var groupMaximum: Double?
            for key in group {
                guard let value = try? client.value(key),
                      let celsius = try? SMCCodec.temperature(type: value.info.type, bytes: value.bytes),
                      Self.plausibleCelsius.contains(celsius) else { continue }
                groupMaximum = max(groupMaximum ?? celsius, celsius)
            }
            guard let groupMaximum else {
                throw TelemetryError.unavailable("Trusted temperature group returned no plausible reading")
            }
            hottest = max(hottest, groupMaximum)
        }
        guard hottest.isFinite else { throw TelemetryError.unavailable("No trusted temperature") }
        return hottest
    }
}
