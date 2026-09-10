import Darwin
import Foundation

enum FanOwnershipPreflightState: String, Sendable {
    case readyForValidation
    case blocked
    case unsupported
}

struct FanOwnershipPreflightFan: Sendable {
    let id: Int
    let modeKey: String
    let mode: UInt8
    let actualRPM: Double
    let targetRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetType: String
}

struct FanOwnershipPreflightEvidence: Sendable {
    let modelIdentifier: String
    let osBuild: String
    let fanCount: Int
    let globalKeyType: String
    let globalKeySize: UInt32
    let globalValue: UInt8
    let fans: [FanOwnershipPreflightFan]
}

struct FanOwnershipMachineProfile: Sendable {
    let modelIdentifier: String
    let osBuild: String
    let fanCount: Int
    let globalKey: String
    let globalType: String
    let modeSuffix: String

    static let primaryM4 = Self(
        modelIdentifier: "Mac16,1",
        osBuild: "25G83",
        fanCount: 1,
        globalKey: "Ftst",
        globalType: "ui8 ",
        modeSuffix: "Md"
    )
}

struct FanOwnershipPreflightSnapshot: Sendable {
    let evidence: FanOwnershipPreflightEvidence
    let state: FanOwnershipPreflightState
    let reasons: [String]

    var isReadyForValidation: Bool { state == .readyForValidation }

    var summary: String {
        switch state {
        case .readyForValidation: "Ready for validation"
        case .blocked: "Blocked"
        case .unsupported: "Unsupported"
        }
    }

    var diagnosticText: String {
        var lines = [
            "Fan ownership preflight (read-only)",
            "Model: \(evidence.modelIdentifier)",
            "OS build: \(evidence.osBuild)",
            "State: \(summary)",
            "Ftst: type='\(evidence.globalKeyType)' size=\(evidence.globalKeySize) value=\(evidence.globalValue)",
            "Fan count: \(evidence.fanCount)"
        ]
        for fan in evidence.fans {
            lines.append("Fan \(fan.id): modeKey=\(fan.modeKey) mode=\(fan.mode) actual=\(Int(fan.actualRPM.rounded())) target=\(Int(fan.targetRPM.rounded())) min=\(Int(fan.minimumRPM.rounded())) max=\(Int(fan.maximumRPM.rounded())) targetType='\(fan.targetType)'")
        }
        if reasons.isEmpty {
            lines.append("Reasons: none")
        } else {
            lines.append("Reasons:")
            lines.append(contentsOf: reasons.map { "- \($0)" })
        }
        lines.append("This result is read-only evidence only; it does not authorize fan takeover. Crash/restart and sleep/wake validation are tracked separately.")
        return lines.joined(separator: "\n")
    }
}

enum FanOwnershipPreflightEvaluator {
    static func evaluate(_ evidence: FanOwnershipPreflightEvidence,
                         profile: FanOwnershipMachineProfile = .primaryM4) -> FanOwnershipPreflightSnapshot {
        guard evidence.modelIdentifier == profile.modelIdentifier else {
            return FanOwnershipPreflightSnapshot(
                evidence: evidence,
                state: .unsupported,
                reasons: ["No approved fan-ownership profile exists for \(evidence.modelIdentifier)."]
            )
        }

        var reasons: [String] = []
        if evidence.osBuild != profile.osBuild {
            reasons.append("Expected validated OS build \(profile.osBuild) but observed \(evidence.osBuild).")
        }
        if evidence.fanCount != profile.fanCount {
            reasons.append("Expected \(profile.fanCount) fan but discovered \(evidence.fanCount).")
        }
        if evidence.globalKeyType != profile.globalType || evidence.globalKeySize != 1 {
            reasons.append("Ftst metadata does not match the validated ui8/1-byte surface.")
        }
        if evidence.globalValue != 0 {
            reasons.append("Ftst is already active; another controller or stale diagnostic ownership may exist.")
        }
        if evidence.fans.count != evidence.fanCount {
            reasons.append("Fan capability inventory is incomplete.")
        }

        for fan in evidence.fans {
            let expectedModeKey = "F\(fan.id)\(profile.modeSuffix)"
            if fan.modeKey != expectedModeKey {
                reasons.append("Fan \(fan.id) exposes \(fan.modeKey), not the approved \(expectedModeKey) mode key.")
            }
            if ![UInt8(0), UInt8(3)].contains(fan.mode) {
                reasons.append("Fan \(fan.id) is not in an Apple-managed automatic mode (observed \(fan.mode)).")
            }
            if !(fan.minimumRPM.isFinite && fan.maximumRPM.isFinite && fan.minimumRPM >= 0 && fan.maximumRPM > fan.minimumRPM) {
                reasons.append("Fan \(fan.id) factory RPM limits are invalid.")
            }
            if !["fpe2", "flt "].contains(fan.targetType) {
                reasons.append("Fan \(fan.id) target type '\(fan.targetType)' is unsupported.")
            }
            if !(fan.actualRPM.isFinite && fan.targetRPM.isFinite) {
                reasons.append("Fan \(fan.id) RPM readback is non-finite.")
            }
        }

        return FanOwnershipPreflightSnapshot(
            evidence: evidence,
            state: reasons.isEmpty ? .readyForValidation : .blocked,
            reasons: reasons
        )
    }
}

enum HeliosMachineIdentity {
    static func sysctlString(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else {
            throw TelemetryError.kernel("Read \(name)", errno)
        }
        guard size > 1, size <= 4096 else { throw TelemetryError.invalidData("Invalid \(name) size") }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { buffer in
            sysctlbyname(name, buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { throw TelemetryError.kernel("Read \(name)", errno) }
        guard size <= bytes.count else { throw TelemetryError.invalidData("Truncated \(name)") }
        if let terminator = bytes.firstIndex(of: 0) { bytes.removeSubrange(terminator...) }
        let value = String(decoding: bytes, as: UTF8.self)
        guard !value.isEmpty else { throw TelemetryError.invalidData("Empty \(name)") }
        return value
    }

    static var modelIdentifier: String { get throws { try sysctlString("hw.model") } }
    static var osBuild: String { get throws { try sysctlString("kern.osversion") } }
}

/// Read-only live evidence for the exact ownership surface we intend to validate next.
/// This type has no write command and cannot acquire fan ownership.
final class SMCFanOwnershipPreflightReader {
    private let client: SMCClient
    private let fanReader: SMCFanReader

    init(client: SMCClient) {
        self.client = client
        self.fanReader = SMCFanReader(client: client)
    }

    convenience init() throws {
        self.init(client: SMCClient(transport: try SMCIOKitTransport()))
    }

    func read(profile: FanOwnershipMachineProfile = .primaryM4,
              modelIdentifier: String? = nil,
              osBuild: String? = nil) throws -> FanOwnershipPreflightSnapshot {
        let model: String
        if let modelIdentifier { model = modelIdentifier } else { model = try HeliosMachineIdentity.modelIdentifier }
        let build: String
        if let osBuild { build = osBuild } else { build = try HeliosMachineIdentity.osBuild }
        let global = try client.value(profile.globalKey)
        guard global.bytes.count == 1 else { throw TelemetryError.invalidData("Ftst requires one byte") }
        let fanCount = try FanCodec.count(client.value("FNum"))

        var fans: [FanOwnershipPreflightFan] = []
        fans.reserveCapacity(fanCount)
        for id in 0..<fanCount {
            let modeKey = try fanReader.modeKey(id)
            let mode = try fanReader.mode(id)
            let targetKey = try FanCodec.key(id, "Tg")
            let target = try client.value(targetKey)
            let actualRPM = try fanReader.rpm(id, "Ac")
            let targetRPM = try FanCodec.rpm(type: target.info.type, bytes: target.bytes)
            let minimumRPM = try fanReader.rpm(id, "Mn")
            let maximumRPM = try fanReader.rpm(id, "Mx")
            fans.append(FanOwnershipPreflightFan(
                id: id,
                modeKey: modeKey,
                mode: mode,
                actualRPM: actualRPM,
                targetRPM: targetRPM,
                minimumRPM: minimumRPM,
                maximumRPM: maximumRPM,
                targetType: target.info.type
            ))
        }

        let evidence = FanOwnershipPreflightEvidence(
            modelIdentifier: model,
            osBuild: build,
            fanCount: fanCount,
            globalKeyType: global.info.type,
            globalKeySize: global.info.size,
            globalValue: global.bytes[0],
            fans: fans
        )
        return FanOwnershipPreflightEvaluator.evaluate(evidence, profile: profile)
    }
}
