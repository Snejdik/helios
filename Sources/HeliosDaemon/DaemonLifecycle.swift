import Foundation
import IOKit.pwr_mgt
import IOKit
import OSLog

/// Signal/power event bookkeeping is confined to the main queue. Callbacks
/// delegate asynchronous restoration to the coordinator, never a signal handler.
final class DaemonLifecycle: @unchecked Sendable {
    private let fans: FanControlCoordinator
    private let delegate: DaemonListenerDelegate
    private let logger = Logger(subsystem: HeliosServiceIdentity.machServiceName, category: "Lifecycle")
    private var signals: [DispatchSourceSignal] = []
    private var terminating = false
    private var powerConnection: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(fans: FanControlCoordinator, delegate: DaemonListenerDelegate) {
        self.fans = fans
        self.delegate = delegate
    }

    func start() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.terminate() }
            source.activate()
            signals.append(source)
        }
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let lifecycle = Unmanaged<DaemonLifecycle>.fromOpaque(context).takeUnretainedValue()
            let token = Int(bitPattern: argument)
            lifecycle.powerEvent(message, token: token)
        }, &notifier)
        if powerConnection != 0, let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            // Losing power notifications must prevent new takeover.
            fans.pause { _ in }
            logger.error("Power notifications unavailable; fan control paused.")
        }
    }

    private func powerEvent(_ message: UInt32, token: Int) {
        switch message {
        // IOMessage.h's iokit_common_msg macros do not import into Swift.
        // sys_iokit (0x38 << 26) | sub_iokit_common (0) | message.
        case 0xe0000270: IOAllowPowerChange(powerConnection, token) // CanSystemSleep
        case 0xe0000280: // SystemWillSleep
            logger.notice("SystemWillSleep received; disarming sessions before power acknowledgement.")
            delegate.shutdown()
            let connection = powerConnection
            fans.pause { [logger] restored in
                if !restored {
                    logger.fault("Automatic fan restoration before sleep was not confirmed; durable recovery state remains authoritative.")
                } else {
                    logger.notice("Pre-sleep fan restoration confirmed; allowing system sleep.")
                }
                IOAllowPowerChange(connection, token)
            }
        case 0xe0000300: // SystemHasPoweredOn
            logger.notice("SystemHasPoweredOn received; beginning fresh SMC reprobe before fan control can resume.")
            fans.wake { [logger] ready in
                if ready {
                    logger.notice("Post-wake fan safety reprobe completed.")
                } else {
                    logger.fault("Post-wake fan safety reprobe failed; fan control remains paused.")
                }
            }
        default: break
        }
    }

    private func terminate() {
        guard !terminating else { return }
        terminating = true
        delegate.shutdown()
        fans.shutdown { restored in exit(restored ? 0 : 1) }
        // A blocked kernel call cannot be repaired by a Swift timer. Leave the
        // durable journal for launchd's restart recovery if cleanup cannot finish.
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { exit(1) }
    }
}
