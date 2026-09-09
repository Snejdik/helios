import AppKit

/// Next23 menu-bar renderer. Width changes only when the user changes modules;
/// live values use fixed per-module geometry and can never jitter the status item.
@MainActor
final class MenuBarView: NSView {
  static var fixedWidth: CGFloat {
    let content = HeliosMenuBarContent(legacy: .label)
    return configuredWidth(for: .cpu, content: content, label: "CPU", spacing: defaultModuleSpacing)
      + configuredWidth(
        for: .temperature, content: content, label: "TEMP", spacing: defaultModuleSpacing)
      + compactGroupGap(for: defaultModuleSpacing)
  }
  static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
  private static let secondaryValueFont = NSFont.monospacedDigitSystemFont(
    ofSize: 9, weight: .medium)
  private static let compactValueFont = NSFont.monospacedDigitSystemFont(
    ofSize: 10, weight: .semibold)
  private static let captionFont = NSFont.systemFont(ofSize: 8, weight: .medium)
  private static let iconPointSize: CGFloat = 9
  private static let defaultModuleSpacing: CGFloat = 2

  private(set) var cpuText = "—"
  private(set) var temperatureText = "—"
  private(set) var coolingFanText = "—"
  private var values: [HeliosMenuBarMetric: String] = [:]
  private var metrics: [HeliosMenuBarMetric]
  private var identityStyle: HeliosMenuBarIdentityStyle
  private var identityStyles: [HeliosMenuBarMetric: HeliosMenuBarIdentityStyle] = [:]
  private var contentOptions: [HeliosMenuBarMetric: HeliosMenuBarContent] = [:]
  private var identityLabels: [HeliosMenuBarMetric: String] = [:]
  private var moduleSpacing: CGFloat = MenuBarView.defaultModuleSpacing
  /// Kept for deterministic presentation fixtures. Next23 deliberately does
  /// not invert menu-bar telemetry while the popover is open.
  var isHighlighted = false { didSet { needsDisplay = true } }

  init(
    frame frameRect: NSRect,
    metrics: [HeliosMenuBarMetric] = HeliosPreferences.defaultMenuBarMetrics,
    identityStyle: HeliosMenuBarIdentityStyle = .label
  ) {
    self.metrics = metrics
    self.identityStyle = identityStyle
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }

  convenience init(
    frame frameRect: NSRect, metrics: [HeliosMenuBarMetric], showsSymbols: Bool
  ) {
    self.init(
      frame: frameRect, metrics: metrics, identityStyle: showsSymbols ? .symbol : .label)
  }

  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: configuredWidth, height: NSView.noIntrinsicMetric)
  }

  var configuredWidth: CGFloat {
    guard !metrics.isEmpty else { return 24 }
    return metrics.reduce(CGFloat.zero) { $0 + configuredWidth(for: $1) } + interItemGap
      * CGFloat(max(0, metrics.count - 1))
  }

  private var interItemGap: CGFloat {
    Self.compactGroupGap(for: moduleSpacing)
  }

  private func configuredWidth(for metric: HeliosMenuBarMetric) -> CGFloat {
    Self.configuredWidth(
      for: metric, content: content(for: metric), label: label(for: metric),
      spacing: moduleSpacing)
  }

  /// Fixed geometry is derived from worst-case display templates rather than
  /// the current live value. That keeps status items jitter-free while letting
  /// the Compact end of the spacing slider remove almost all Helios-owned
  /// whitespace. Separate native status items still retain macOS' own system
  /// separation; the single compact group is the tightest possible layout.
  static func configuredWidth(
    for metric: HeliosMenuBarMetric, content: HeliosMenuBarContent, label: String,
    spacing: CGFloat
  ) -> CGFloat {
    let padding = modulePadding(for: spacing)
    let identity = identityWidth(label: label, content: content)

    if metric == .cooling {
      guard content.showValue else { return max(16, ceil(identity) + padding * 2) }
      let temperature = textWidth("100°C", font: compactValueFont)
      let fan = textWidth("6550 RPM", font: secondaryValueFont)
      let values = max(temperature, fan)
      let identityGap: CGFloat = identity > 0 ? 2 : 0
      return max(28, ceil(identity + identityGap + values + padding * 2))
    }

    let value = content.showValue ? fixedValueWidth(for: metric) : 0
    let core = max(identity, value)
    return max(content.showValue ? 18 : 16, ceil(core + padding * 2))
  }

  static func compactGroupGap(for spacing: CGFloat) -> CGFloat {
    max(0, min(4, spacing * 0.45))
  }

  private static func modulePadding(for spacing: CGFloat) -> CGFloat {
    max(0, min(5, spacing * 0.55))
  }

  private static func fixedValueWidth(for metric: HeliosMenuBarMetric) -> CGFloat {
    let template: String
    switch metric {
    case .cpu, .memory, .gpu, .battery: template = "100%"
    case .temperature: template = "100°"
    case .power: template = "999W"
    case .fan: template = "No fan"
    case .network: template = "999M"
    case .cooling: template = "6550 RPM"
    }
    return textWidth(template, font: valueFont)
  }

  private static func identityWidth(label: String, content: HeliosMenuBarContent) -> CGFloat {
    var width: CGFloat = 0
    if content.showIcon { width += 10 }
    if content.showIcon && content.showLabel { width += 2 }
    if content.showLabel { width += textWidth(label, font: captionFont) }
    return width
  }

  private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }

  func setModuleSpacing(_ value: Double) {
    let next = max(0, min(8, CGFloat(value)))
    guard abs(next - moduleSpacing) > 0.001 else { return }
    moduleSpacing = next
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  func configure(metrics: [HeliosMenuBarMetric], identityStyle: HeliosMenuBarIdentityStyle) {
    let changed =
      self.metrics != metrics || self.identityStyle != identityStyle || !identityStyles.isEmpty
      || !contentOptions.isEmpty || !identityLabels.isEmpty
    guard changed else { return }
    self.metrics = metrics
    self.identityStyle = identityStyle
    identityStyles.removeAll(keepingCapacity: true)
    contentOptions.removeAll(keepingCapacity: true)
    identityLabels.removeAll(keepingCapacity: true)
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  func configure(
    metrics: [HeliosMenuBarMetric],
    identityStyles: [HeliosMenuBarMetric: HeliosMenuBarIdentityStyle],
    labels: [HeliosMenuBarMetric: String]
  ) {
    self.metrics = metrics
    self.identityStyles = identityStyles
    contentOptions.removeAll(keepingCapacity: true)
    identityLabels = labels
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  func configure(
    metrics: [HeliosMenuBarMetric],
    content: [HeliosMenuBarMetric: HeliosMenuBarContent],
    labels: [HeliosMenuBarMetric: String]
  ) {
    self.metrics = metrics
    contentOptions = content
    identityLabels = labels
    invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  private func style(for metric: HeliosMenuBarMetric) -> HeliosMenuBarIdentityStyle {
    identityStyles[metric] ?? identityStyle
  }

  private func content(for metric: HeliosMenuBarMetric) -> HeliosMenuBarContent {
    contentOptions[metric] ?? HeliosMenuBarContent(legacy: style(for: metric))
  }

  private func label(for metric: HeliosMenuBarMetric) -> String {
    identityLabels[metric] ?? metric.shortLabel
  }

  func configure(metrics: [HeliosMenuBarMetric], showsSymbols: Bool) {
    configure(metrics: metrics, identityStyle: showsSymbols ? .symbol : .label)
  }

  func update(_ snapshot: TelemetrySnapshot, now: Date = Date()) {
    let cpu = display(
      TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now).map(\.usagePercent)
    ) { String(format: "%.0f%%", $0) }
    let temp = display(
      TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now).flatMap(\.maximumSoCCelsius)
    ) { String(format: "%.0f°", $0) }
    let memory = display(
      TelemetryFormatting.fresh(snapshot.memory, maxAge: 5, now: now).map(\.usagePercent)
    ) { String(format: "%.0f%%", $0) }
    let gpu = display(
      TelemetryFormatting.fresh(snapshot.gpu, maxAge: 5, now: now).flatMap(
        \.deviceUtilizationPercent)
    ) { String(format: "%.0f%%", $0) }
    let battery = display(
      TelemetryFormatting.fresh(snapshot.battery, maxAge: 15, now: now).flatMap(
        \.stateOfChargePercent)
    ) { String(format: "%.0f%%", $0) }
    let power = display(
      TelemetryFormatting.fresh(snapshot.systemPower, maxAge: 5, now: now).flatMap(
        \.totalSystemWatts)
    ) { String(format: "%.0fW", $0) }
    let fanInventory = TelemetryFormatting.fresh(snapshot.fans, maxAge: 6, now: now)
    let fanRPM = fanInventory.flatMap { inventory -> MetricResult<Double> in
      guard let first = inventory.fans.first else {
        return .failure(.unavailable("No fan installed"))
      }
      return first.actualRPM
    }
    let fan: String
    let coolingFan: String
    switch fanInventory {
    case .success(let inventory) where inventory.fans.isEmpty:
      fan = "No fan"
      coolingFan = "Fanless"
    default:
      switch fanRPM {
      case .success(let rpm):
        fan =
          rpm < 50
          ? "Off"
          : (rpm >= 1_000 ? String(format: "%.1fk", rpm / 1_000) : String(format: "%.0f", rpm))
        coolingFan = rpm < 50 ? "Fan off" : String(format: "%.0f RPM", rpm)
      case .failure:
        fan = "—"
        coolingFan = "—"
      }
    }
    let coolingTemperature = temp == "—" ? "—" : temp.replacingOccurrences(of: "°", with: "°C")
    let network = display(
      TelemetryFormatting.fresh(snapshot.network, maxAge: 5, now: now).flatMap(\.throughput)
    ) { rate in
      Self.shortRate(rate.downloadBytesPerSecond)
    }

    let next: [HeliosMenuBarMetric: String] = [
      .cpu: cpu, .memory: memory, .gpu: gpu, .temperature: temp,
      .cooling: "\(coolingTemperature)\n\(coolingFan)",
      .fan: fan, .battery: battery, .power: power, .network: network,
    ]
    cpuText = cpu
    // Retain the Next22 public test surface while the visual display uses a shorter degree suffix.
    temperatureText = temp == "—" ? "—" : temp.replacingOccurrences(of: "°", with: "°C")
    coolingFanText = coolingFan
    guard next != values else { return }
    values = next
    needsDisplay = true
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let foreground = NSColor.labelColor
    let verticalCenter = bounds.midY
    if metrics.isEmpty {
      drawHeliosMark(
        in: NSRect(x: 5, y: verticalCenter - 7, width: 14, height: 14), color: foreground)
      return
    }

    var x: CGFloat = 0
    for metric in metrics {
      let width = configuredWidth(for: metric)
      drawMetric(
        metric, value: values[metric] ?? "—",
        in: NSRect(x: x, y: 0, width: width, height: bounds.height), color: foreground)
      x += width + interItemGap
    }
  }

  private func drawMetric(
    _ metric: HeliosMenuBarMetric, value: String, in rect: NSRect, color: NSColor
  ) {
    if metric == .cooling {
      drawCoolingMetric(value, in: rect, color: color)
      return
    }

    let presentation = content(for: metric)
    let hasIdentity = presentation.showIcon || presentation.showLabel
    if presentation.showValue && hasIdentity {
      let top = floor(rect.midY - 11)
      drawIdentity(
        metric, content: presentation,
        in: NSRect(x: rect.minX + 1, y: top, width: max(0, rect.width - 2), height: 9),
        color: color)
      drawText(
        value,
        in: NSRect(x: rect.minX + 1, y: top + 8, width: max(0, rect.width - 2), height: 14),
        font: Self.valueFont, color: color)
    } else if presentation.showValue {
      drawText(
        value,
        in: NSRect(x: rect.minX + 1, y: rect.midY - 7, width: max(0, rect.width - 2), height: 14),
        font: Self.valueFont, color: color)
    } else {
      drawIdentity(
        metric, content: presentation,
        in: NSRect(x: rect.minX + 2, y: rect.midY - 7, width: max(0, rect.width - 4), height: 14),
        color: color)
    }
  }

  /// Temperature and fan belong together, but their identity is independently
  /// configurable like every other module. The values remain a compact two-line
  /// pair; icon/label live beside them rather than stealing their numeric width.
  private func drawCoolingMetric(_ value: String, in rect: NSRect, color: NSColor) {
    let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let temperature = lines.first ?? "—"
    let fan = lines.count > 1 ? lines[1] : "—"
    let presentation = content(for: .cooling)
    let hasIdentity = presentation.showIcon || presentation.showLabel

    guard presentation.showValue else {
      drawIdentity(
        .cooling, content: presentation,
        in: NSRect(x: rect.minX + 2, y: rect.midY - 7, width: max(0, rect.width - 4), height: 14),
        color: color)
      return
    }

    let identityWidth =
      hasIdentity ? min(rect.width * 0.46, identityWidth(for: .cooling, content: presentation)) : 0
    let spacing: CGFloat = hasIdentity ? 3 : 0
    let valueWidth = max(22, rect.width - identityWidth - spacing)
    let totalWidth = identityWidth + spacing + valueWidth
    var x = rect.midX - totalWidth / 2
    if hasIdentity {
      drawIdentity(
        .cooling, content: presentation,
        in: NSRect(x: x, y: rect.midY - 7, width: identityWidth, height: 14), color: color)
      x += identityWidth + spacing
    }
    drawText(
      temperature, in: NSRect(x: x, y: rect.midY - 10, width: valueWidth, height: 11),
      font: Self.compactValueFont, color: color)
    drawText(
      fan, in: NSRect(x: x, y: rect.midY + 1, width: valueWidth, height: 10),
      font: Self.secondaryValueFont, color: color)
  }

  private func identityWidth(
    for metric: HeliosMenuBarMetric, content: HeliosMenuBarContent
  ) -> CGFloat {
    Self.identityWidth(label: label(for: metric), content: content)
  }

  private func drawIdentity(
    _ metric: HeliosMenuBarMetric, content: HeliosMenuBarContent, in rect: NSRect, color: NSColor
  ) {
    let width = identityWidth(for: metric, content: content)
    var x = rect.midX - width / 2
    if content.showIcon {
      drawSymbol(
        metric.symbolName,
        in: NSRect(x: x, y: rect.midY - 5, width: 10, height: 10), color: color)
      x += 10
      if content.showLabel { x += 2 }
    }
    if content.showLabel {
      let labelWidth = max(0, rect.maxX - x)
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .left
      paragraph.lineBreakMode = .byClipping
      (label(for: metric) as NSString).draw(
        in: NSRect(x: x, y: rect.midY - 5, width: labelWidth, height: 10),
        withAttributes: [
          .font: Self.captionFont, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }
  }

  /// Small monochrome Helios brand mark for the menu bar. It intentionally
  /// avoids SF Symbols so Helios has a stable visual identity while still
  /// inheriting the current menu-bar foreground color like a template image.
  private func drawHeliosMark(in rect: NSRect, color: NSColor) {
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = min(rect.width, rect.height) * 0.235
    color.setFill()
    NSBezierPath(
      ovalIn: NSRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
      )
    ).fill()

    let scale = min(rect.width, rect.height)
    for index in 0..<8 {
      let primary = index.isMultiple(of: 2)
      let rayLength = scale * (primary ? 0.20 : 0.125)
      let rayWidth = max(1.0, scale * (primary ? 0.075 : 0.06))
      let inner = radius + scale * (primary ? 0.135 : 0.12)
      let angle = Double(index) * Double.pi / 4
      let midpoint = NSPoint(
        x: center.x + CGFloat(cos(angle)) * (inner + rayLength / 2),
        y: center.y + CGFloat(sin(angle)) * (inner + rayLength / 2))
      let path = NSBezierPath(
        roundedRect: NSRect(
          x: midpoint.x - rayWidth / 2, y: midpoint.y - rayLength / 2,
          width: rayWidth, height: rayLength), xRadius: rayWidth / 2, yRadius: rayWidth / 2)
      var transform = AffineTransform.identity
      transform.translate(x: midpoint.x, y: midpoint.y)
      transform.rotate(byRadians: CGFloat(angle - Double.pi / 2))
      transform.translate(x: -midpoint.x, y: -midpoint.y)
      path.transform(using: transform)
      path.fill()
    }
  }

  /// Aspect-fit SF Symbols instead of stretching them into arbitrary status-item rectangles.
  private func drawSymbol(_ name: String, in target: NSRect, color: NSColor) {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
    let configuration = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .medium)
      .applying(.init(paletteColors: [color]))
    let image = base.withSymbolConfiguration(configuration) ?? base
    let size = image.size
    guard size.width > 0, size.height > 0 else { return }
    let scale = min(target.width / size.width, target.height / size.height)
    let fitted = NSSize(width: size.width * scale, height: size.height * scale)
    let rect = NSRect(
      x: target.midX - fitted.width / 2, y: target.midY - fitted.height / 2, width: fitted.width,
      height: fitted.height)
    image.draw(
      in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }

  private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping
    (text as NSString).draw(
      in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
  }

  private func display<Value>(_ result: MetricResult<Value>, _ formatter: (Value) -> String)
    -> String
  {
    DisplayValue(result, format: formatter).text
  }

  private static func shortRate(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
    if bytesPerSecond >= 1_000_000_000 {
      return String(format: "%.1fG", bytesPerSecond / 1_000_000_000)
    }
    if bytesPerSecond >= 1_000_000 { return String(format: "%.1fM", bytesPerSecond / 1_000_000) }
    if bytesPerSecond >= 1_000 { return String(format: "%.0fK", bytesPerSecond / 1_000) }
    return String(format: "%.0fB", bytesPerSecond)
  }
}
