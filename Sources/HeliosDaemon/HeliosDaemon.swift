import Foundation
import OSLog

@main
enum HeliosDaemon {
    static func main() {
        let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "Startup")
        logger.notice("Starting PID \(getpid()), UID \(geteuid()), executable \(CommandLine.arguments[0], privacy: .public).")
        let requirement: XPCTrustRequirement
        do {
            requirement = try XPCTrustRequirement.production(localIdentifier: HeliosServiceIdentity.machServiceName, peerIdentifier: HeliosServiceIdentity.appIdentifier)
        } catch {
            logger.error("Secure IPC unavailable: \(error.localizedDescription, privacy: .public)")
            // Ad-hoc builds remain inert. Never fall back to a bundle-ID or PID check.
            guard let denied = try? XPCTrustRequirement(validating: "never") else { return }
            requirement = denied
        }

        let fanGateMessage: String?
        do {
            _ = try ProductionFanRecoveryBootstrap.run()
            do {
                // Read-only gate. This proves the exact physically validated
                // Mac16,1 / 25G83 surface is clean before XPC advertises Boost.
                // The production writer itself remains unopened and is created
                // lazily only after an authenticated fresh calculation arrives.
                try ProductionFanTakeoverGate.run()
                fanGateMessage = nil
                logger.notice("Production fan-control safety gate passed for Mac16,1 / 25G83; writer remains lazy until first control request.")
            } catch {
                fanGateMessage = "Fan takeover is unavailable because the current Mac/OS/SMC baseline does not match the validated production profile."
                logger.error("Production fan-control safety gate blocked takeover: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            logger.fault("Production fan recovery bootstrap failed: \(error.localizedDescription, privacy: .public)")
            fanGateMessage = "Fan takeover is unavailable because the startup recovery check did not complete."
        }

        let fans = FanControlCoordinator(
            validationMessage: fanGateMessage,
            allowedModes: fanGateMessage == nil ? [.boost, .override] : [],
            readyDetail: fanGateMessage == nil
                ? "Boost, Manual, and Auto Rules use the validated Mac16,1 / 25G83 path. The daemon forces factory max at 95°C; safety releases remain immediate."
                : "",
            makeEngine: { try ProductionM4FanControlEngine() },
            emergencyMaximumCelsius: CoolingRulesSafetyProfile.emergencyMaximumCelsius
        )
        let delegate = DaemonListenerDelegate(requirement: requirement, fans: fans)
        let lifecycle = DaemonLifecycle(fans: fans, delegate: delegate)
        lifecycle.start()
        let listener = NSXPCListener(machServiceName: HeliosServiceIdentity.machServiceName)
        listener.setConnectionCodeSigningRequirement(requirement.expression)
        listener.delegate = delegate
        listener.resume()
        logger.notice("Listening on \(HeliosServiceIdentity.machServiceName, privacy: .public); client requirement: \(requirement.expression, privacy: .public)")
        withExtendedLifetime((listener, delegate, lifecycle)) {
            RunLoop.current.run()
        }
    }
}
