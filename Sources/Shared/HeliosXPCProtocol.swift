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
    func calculate(session: UUID, sequence: UInt64, sampleTicks: UInt64, mode: HeliosFanMode, targetRPM: Double, temperature: Double,
                   reply: @escaping @Sendable (HeliosReplyCode, HeliosFanState, String) -> Void)
    func releaseControl(session: UUID, graceful: Bool, reply: @escaping @Sendable (HeliosFanState, String) -> Void)
}

@objc(HeliosAppXPC)
protocol HeliosAppXPC {
    func challenge(nonce: UUID, reply: @escaping @Sendable (UUID) -> Void)
    func didDisarm(reason: HeliosDisarmReason)
}
