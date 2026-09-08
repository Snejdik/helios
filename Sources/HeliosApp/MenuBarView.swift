import AppKit

/// The status item and both drawing columns have fixed geometry. Text never
/// participates in status-item sizing, including unavailable and three-digit values.
@MainActor
final class MenuBarView: NSView {
    static let fixedWidth: CGFloat = 80
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private let captionFont = NSFont.systemFont(ofSize: 8, weight: .medium)
    private let thermometer = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)
    private(set) var cpuText = "—"
    private(set) var temperatureText = "—"
    var isHighlighted = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.fixedWidth, height: NSView.noIntrinsicMetric) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false) // The native status button owns accessibility and clicks.
    }

    required init?(coder: NSCoder) { nil }

    func update(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
        let cpu = DisplayValue(TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now)) {
            String(format: "%.0f%%", $0.usagePercent)
        }.text
        let temperature = DisplayValue(TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now).flatMap(\.maximumSoCCelsius)) {
            String(format: "%.0f°C", $0)
        }.text
        guard cpu != cpuText || temperature != temperatureText else { return }
        cpuText = cpu
        temperatureText = temperature
        needsDisplay = true
    }

    // Keep AppKit's native button hit testing, highlight, context menu, and action.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let foreground = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        let top = floor((bounds.height - 22) / 2)
        drawText("CPU", in: NSRect(x: 2, y: top, width: 36, height: 9), font: captionFont, color: foreground)
        if let thermometer {
            let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
                .applying(.init(paletteColors: [foreground]))
            let image = thermometer.withSymbolConfiguration(configuration) ?? thermometer
            let rect = NSRect(x: 56, y: top, width: 8, height: 9)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            drawText("°C", in: NSRect(x: 42, y: top, width: 36, height: 9), font: captionFont, color: foreground)
        }
        drawText(cpuText, in: NSRect(x: 2, y: top + 8, width: 36, height: 14), font: Self.valueFont, color: foreground)
        drawText(temperatureText, in: NSRect(x: 42, y: top + 8, width: 36, height: 14), font: Self.valueFont, color: foreground)
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
