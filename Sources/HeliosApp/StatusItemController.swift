import AppKit

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: MenuBarView.fixedWidth)
    private let readout = MenuBarView(frame: NSRect(x: 0, y: 0, width: MenuBarView.fixedWidth, height: 22))
    private let popover = NSPopover()
    private var snapshot = TelemetrySnapshot()
    private let service: DaemonService

    init(service: DaemonService) {
        self.service = service
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if let button = statusItem.button {
            button.title = ""
            button.addSubview(readout)
            readout.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                readout.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                readout.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                readout.topAnchor.constraint(equalTo: button.topAnchor),
                readout.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
            button.setAccessibilityLabel("Helios system monitor")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        update(snapshot)
    }

    func update(_ snapshot: TelemetrySnapshot) {
        self.snapshot = snapshot
        readout.update(snapshot)
        let cpu = readout.cpuText == "—" ? "unavailable" : readout.cpuText
        let temperature = readout.temperatureText == "—" ? "unavailable" : readout.temperatureText
        let description = "CPU \(cpu), maximum SoC temperature \(temperature)"
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityValue(description)
        if popover.isShown, let overview = popover.contentViewController as? OverviewViewController {
            overview.update(snapshot)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        readout.isHighlighted = false
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        // Retain the view hierarchy between openings; only its values refresh.
        service.refresh()
        let overview = (popover.contentViewController as? OverviewViewController) ?? OverviewViewController(service: service)
        _ = overview.view
        overview.update(snapshot)
        let availableHeight = (button.window?.screen?.visibleFrame.height ?? 800) - 24
        overview.preferredContentSize = NSSize(width: 380, height: min(700, availableHeight))
        popover.contentViewController = overview
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        readout.isHighlighted = true
    }
}
