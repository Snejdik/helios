import Foundation

actor FanOwnershipPreflightProvider {
    private var reader: SMCFanOwnershipPreflightReader?

    func reset() { reader = nil }

    func sample() -> MetricSample<FanOwnershipPreflightSnapshot> {
        MetricSample(captureMetric {
            if reader == nil { reader = try SMCFanOwnershipPreflightReader() }
            guard let reader else { throw TelemetryError.unavailable("Fan ownership preflight unavailable") }
            return try reader.read()
        })
    }
}

/// Offline preparation only. This assessment is deliberately never an input to
/// the production control coordinator, helper or write allowlist. A matching
/// read-only surface cannot establish lease/recovery safety on another OS.
struct FanOSValidationCandidate: Sendable {
    let modelIdentifier: String
    let candidateOSBuild: String
    let validatedOSBuild: String
    // The frozen generic preflight verdict, not the stricter production
    // takeover gate's result and never a write authorization.
    let productionPreflightState: FanOwnershipPreflightState
    let requiresPhysicalValidation: Bool
    let blockers: [String]

    static func assess(_ evidence: FanOwnershipPreflightEvidence,
        profile: FanOwnershipMachineProfile = .primaryM4) -> Self {
        let production = FanOwnershipPreflightEvaluator.evaluate(evidence, profile: profile)
        let validBuild = !evidence.osBuild.isEmpty && evidence.osBuild.utf8.count <= 32
            && evidence.osBuild.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil
        // Reuse the frozen structural checks against an explicitly unvalidated
        // build, solely to separate structural blockers from the exact OS gate.
        let candidateProfile = FanOwnershipMachineProfile(
            modelIdentifier: profile.modelIdentifier, osBuild: evidence.osBuild,
            fanCount: profile.fanCount, globalKey: profile.globalKey,
            globalType: profile.globalType, modeSuffix: profile.modeSuffix)
        let structure = FanOwnershipPreflightEvaluator.evaluate(evidence, profile: candidateProfile)
        var blockers = structure.reasons
        if !validBuild { blockers.append("Candidate OS build is missing or malformed.") }
        let newBuild = evidence.osBuild != profile.osBuild
        if newBuild {
            blockers.append("Production writes remain blocked until physical ownership, restoration, crash/restart and sleep/wake validation is recorded for this exact model/OS build.")
        }
        return Self(modelIdentifier: evidence.modelIdentifier, candidateOSBuild: evidence.osBuild,
            validatedOSBuild: profile.osBuild, productionPreflightState: production.state,
            requiresPhysicalValidation: newBuild, blockers: blockers)
    }
}
