import Foundation

@objc enum HeliosReplyCode: Int, Sendable {
    case ok, versionMismatch, invalidSession, invalidSequence, expired, challengeFailed, busy
    case controlUnavailable, invalidCalculation, hardwareFailure
}

@objc enum HeliosDisarmReason: Int, Sendable {
    case startup, clientDisconnected, leaseExpired, invalidRequest, shutdown
}

// Only bounded scalar values and Foundation UUIDs cross the wire. There are no
// dictionaries, selectors, paths, raw hardware keys, or caller-defined limits.
@objc(HeliosDaemonXPC)
protocol HeliosDaemonXPC {
    func handshake(version: Int, nonce: UUID,
                   reply: @escaping @Sendable (HeliosReplyCode, Int, UUID, UUID, Bool) -> Void)
    func ping(session: UUID, sequence: UInt64, nonce: UUID,
              reply: @escaping @Sendable (HeliosReplyCode, UUID, UInt64, Bool) -> Void)
    func fanStatus(session: UUID, reply: @escaping @Sendable (Bool, HeliosFanState, String) -> Void)
    /// `smoothness` is the bounded Response value (0…1, FanLayerResponse);
    /// anything else is rejected by the daemon.
    func calculate(session: UUID, sequence: UInt64, sampleTicks: UInt64, mode: HeliosFanMode, targetRPM: Double, temperature: Double,
                   smoothness: Double,
                   reply: @escaping @Sendable (HeliosReplyCode, HeliosFanState, String) -> Void)
    func releaseControl(session: UUID, graceful: Bool, reply: @escaping @Sendable (HeliosFanState, String) -> Void)
    /// Fan layer capability on this Mac: tier raw value, whether the user turned
    /// it on for this model + OS build, "model · build", a reason/detail, and
    /// whether the user unlocked the full factory maximum (FanLayerCeiling).
    func fanLayerInfo(session: UUID, reply: @escaping @Sendable (Int, Bool, String, String, Bool) -> Void)
    /// Turns the experimental fan layer on or off for this model + OS build only.
    /// The helper restores System, then restarts itself to apply the change.
    func setFanLayerConsent(session: UUID, accepted: Bool, reply: @escaping @Sendable (Bool, String) -> Void)
    /// Unlocks (or locks again) the full factory maximum. Off by default: the
    /// helper limits every fan to 90 % of its factory maximum.
    func setFanLayerFullMaximum(session: UUID, allowed: Bool, reply: @escaping @Sendable (Bool, String) -> Void)
}

@objc(HeliosAppXPC)
protocol HeliosAppXPC {
    func challenge(nonce: UUID, reply: @escaping @Sendable (UUID) -> Void)
    func didDisarm(reason: HeliosDisarmReason)
}
