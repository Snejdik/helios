import Foundation
import Security

enum XPCTrustError: Error, LocalizedError {
    case signingRequired
    case invalidIdentity
    case localIdentifierMismatch(expected: String, actual: String?)
    case localRequirementRejected(OSStatus)
    case securityOperation(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .signingRequired:
            return "Apple Development signing with a Team ID is required for secure helper communication."
        case .invalidIdentity:
            return "The signed Helios identity or allowed entitlements are invalid."
        case .localIdentifierMismatch(let expected, let actual):
            return "This Helios build has signing identifier \(actual ?? "<missing>"); expected \(expected)."
        case .localRequirementRejected(let code):
            return "This Helios build did not satisfy its own hardened signing requirement (Security status \(code))."
        case .securityOperation(let operation, let code):
            return "\(operation) failed (\(code))."
        }
    }
}

struct XPCTrustRequirement: Sendable {
    let expression: String

    init(validating expression: String) throws {
        // NSXPC's requirement setters raise an uncatchable Swift exception for
        // malformed input. Compile with Security first and fail normally.
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        guard status == errSecSuccess, requirement != nil else {
            throw XPCTrustError.securityOperation("Compile peer requirement", status)
        }
        self.expression = expression
    }

    static func production(localIdentifier: String, peerIdentifier: String) throws -> Self {
        var code: SecCode?
        let copyStatus = SecCodeCopySelf([], &code)
        guard copyStatus == errSecSuccess, let code else {
            throw XPCTrustError.securityOperation("Read signing identity", copyStatus)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw XPCTrustError.securityOperation("Read static signing identity", staticStatus)
        }
        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard infoStatus == errSecSuccess, let info = information as? [String: Any] else {
            throw XPCTrustError.securityOperation("Read signing information", infoStatus)
        }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            throw XPCTrustError.signingRequired
        }
        let actualIdentifier = info[kSecCodeInfoIdentifier as String] as? String
        guard actualIdentifier == localIdentifier else {
            throw XPCTrustError.localIdentifierMismatch(expected: localIdentifier, actual: actualIdentifier)
        }
        let own = try requirement(team: team, identifier: localIdentifier)
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(own.expression as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw XPCTrustError.securityOperation("Compile local signing requirement", status)
        }
        let validity = SecCodeCheckValidity(code, [], compiled)
        guard validity == errSecSuccess else {
            throw XPCTrustError.localRequirementRejected(validity)
        }
        return try requirement(team: team, identifier: peerIdentifier)
    }

    static func requirement(team: String, identifier: String) throws -> Self {
        guard team.utf8.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              [HeliosServiceIdentity.appIdentifier, HeliosServiceIdentity.machServiceName].contains(identifier) else {
            throw XPCTrustError.invalidIdentity
        }
        let unsafeEntitlements = [
            "com.apple.security.get-task-allow",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-dyld-environment-variables"
        ]
        let restrictions = unsafeEntitlements.map { " and !entitlement[\"\($0)\"] exists" }.joined()
        return try Self(validating: "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\"" + restrictions)
    }
}
