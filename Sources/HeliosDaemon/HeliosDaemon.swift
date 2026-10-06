import Foundation
import OSLog

@main
enum HeliosDaemon {
    static func main() {
        let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "Startup")
        logger.notice("Starting PID \(getpid()), UID \(geteuid()), executable \(CommandLine.arguments[0], privacy: .private).")
        let requirement: XPCTrustRequirement
        do {
            requirement = try XPCTrustRequirement.production(localIdentifier: HeliosServiceIdentity.machServiceName, peerIdentifier: HeliosServiceIdentity.appIdentifier)
        } catch {
            logger.error("Secure IPC unavailable: \(error.localizedDescription, privacy: .public)")
            // Ad-hoc builds remain inert. Never fall back to a bundle-ID or PID check.
            guard let denied = try? XPCTrustRequirement(validating: "never") else { return }
            requirement = denied
        }

        // 1. Recover every journal Helios may have left (v2 and v3), on any
        //    model/build. Clean journals open no writer.
        var recoveryFailure: String?
        do {
            try FanLayerRecoveryBootstrap.run(current: try FanLayerMachineIdentity.current())
        } catch {
            logger.fault("Fan recovery bootstrap failed: \(error.localizedDescription, privacy: .public)")
            recoveryFailure = "Fan takeover is unavailable because the startup recovery check did not complete."
        }
        // 2. Read-only probe of this Mac for the cool-only fan layer.
        let layer = FanLayerRuntime.probe()

        let fans: FanControlCoordinator
        if recoveryFailure == nil, layer.enabled {
            // Experimental/validated fan layer, turned on by the user for this
            // exact model + OS build. Writer stays lazy until the first request.
            logger.notice("Fan layer enabled (\(layer.tier.label, privacy: .public)); writer remains lazy until first control request.")
            fans = FanControlCoordinator(
                validationMessage: nil,
                allowedModes: [.boost, .override],
                readyDetail: layer.readyDetail,
                makeEngine: { try layer.makeEngine() },
                wakeSafetyCheck: { try layer.wakeSafetyCheck() },
                emergencyMaximumCelsius: CoolingRulesSafetyProfile.emergencyMaximumCelsius,
                reacquireCooldownSeconds: FanLayerReacquireCooldown.defaultSeconds
            )
            layer.startSampling()
        } else {
            let fanGateMessage: String?
            if let recoveryFailure {
                fanGateMessage = recoveryFailure
            } else {
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
                        fanGateMessage = layer.tier == .unsupported
                            ? "Fan takeover is unavailable because the current Mac/OS/SMC baseline does not match the validated production profile."
                            : "Fan control on this Mac is available as an experimental feature. Turn it on in Settings › Cooling."
                        logger.error("Production fan-control safety gate blocked takeover: \(error.localizedDescription, privacy: .public)")
                    }
                } catch {
                    logger.fault("Production fan recovery bootstrap failed: \(error.localizedDescription, privacy: .public)")
                    fanGateMessage = "Fan takeover is unavailable because the startup recovery check did not complete."
                }
            }
            let validated = fanGateMessage == nil
            // Wake never fails on a Mac that was never writable: only journal recovery.
            let wakeCheck: @Sendable () throws -> Void
            if validated {
                wakeCheck = { _ = try ProductionFanWakeSafety.run() }
            } else {
                wakeCheck = { try layer.recoverOnly() }
            }
            fans = FanControlCoordinator(
                validationMessage: fanGateMessage,
                allowedModes: validated ? [.boost, .override] : [],
                readyDetail: validated
                    ? "Boost, Manual, and Auto Rules use the validated Mac16,1 / 25G83 path. The daemon forces factory max at 95°C; safety releases remain immediate."
                    : "",
                makeEngine: { try ProductionM4FanControlEngine() },
                wakeSafetyCheck: wakeCheck,
                emergencyMaximumCelsius: CoolingRulesSafetyProfile.emergencyMaximumCelsius
            )
        }
        let delegate = DaemonListenerDelegate(requirement: requirement, fans: fans, layer: layer)
        let lifecycle = DaemonLifecycle(fans: fans, delegate: delegate)
        delegate.setRestartHandler { [weak lifecycle] in lifecycle?.restartForConfigurationChange() }
        lifecycle.start()
        let listener = NSXPCListener(machServiceName: HeliosServiceIdentity.machServiceName)
        listener.setConnectionCodeSigningRequirement(requirement.expression)
        listener.delegate = delegate
        listener.resume()
        logger.notice("Listening on \(HeliosServiceIdentity.machServiceName, privacy: .public); client requirement: \(requirement.expression, privacy: .public)")
        withExtendedLifetime((listener, delegate, lifecycle, layer)) {
            RunLoop.current.run()
        }
    }
}
