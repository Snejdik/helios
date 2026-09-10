import AppKit
import QuartzCore
import SwiftUI

struct HeliosChartSample: Identifiable, Equatable, Sendable {
  let capturedAt: Date
  let value: Double?
  var id: Date { capturedAt }
}

/// Formatting stays separate from stored telemetry. The inspector always shows
/// the real sampled value; Smooth only changes geometry between those samples.
enum HeliosChartValueStyle: String, Sendable {
  case percent
  case celsius
  case watts
  case signedWatts
  case rpm
  case bytesPerSecond
  case bytes
  case count
  case milliwattHours
  case plain

  func format(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    switch self {
    case .percent:
      return String(format: "%.1f%%", value)
    case .celsius:
      return String(format: "%.1f°C", value)
    case .watts:
      return String(format: "%.2f W", value)
    case .signedWatts:
      return String(format: "%+.2f W", value)
    case .rpm:
      return value < 50 ? "Off" : String(format: "%.0f RPM", value)
    case .bytesPerSecond:
      return TelemetryFormatting.bytesPerSecond(value)
    case .bytes:
      guard value >= 0, value <= Double(UInt64.max) else { return "—" }
      return TelemetryFormatting.storageBytes(UInt64(value.rounded()))
    case .count:
      return String(format: "%.0f", value)
    case .milliwattHours:
      return String(format: "%.2f mWh", value)
    case .plain:
      return String(format: "%.2f", value)
    }
  }
}

enum HeliosChartSeries {
  /// Merge the high-frequency in-memory tail with the 24-hour persistent store.
  /// Persistent samples stop before the first live sample so a chart never
  /// double-weights the overlap window.
  static func merged(
    now: Date = Date(),
    range: HeliosGraphRange,
    live: [TelemetryHistoryPoint],
    persistent: [PersistedTelemetryPoint],
    liveValue: (TelemetryHistoryPoint) -> Double?,
    persistentValue: (PersistedTelemetryPoint) -> Double?
  ) -> [HeliosChartSample] {
    let cutoff = now.addingTimeInterval(-range.seconds)
    // Keep a small tail of real predecessors before the visible cutoff. The
    // renderer clips them outside the fixed plot aperture and uses only the
    // nearest valid predecessor for the outgoing segment, so the line can leave
    // the left edge continuously instead of disappearing a whole sample early.
    // No extra telemetry is created.
    let liveCandidates =
      live
      .filter { $0.capturedAt <= now.addingTimeInterval(5) }
      .map { HeliosChartSample(capturedAt: $0.capturedAt, value: finite(liveValue($0))) }
      .sorted { $0.capturedAt < $1.capturedAt }
    let liveVisible = liveCandidates.filter { $0.capturedAt >= cutoff }
    let firstLiveBoundary = liveVisible.first?.capturedAt ?? now.addingTimeInterval(1)
    let oldCandidates =
      persistent
      .filter {
        $0.capturedAt < firstLiveBoundary.addingTimeInterval(-0.25)
          && $0.capturedAt <= now.addingTimeInterval(5)
      }
      .map { HeliosChartSample(capturedAt: $0.capturedAt, value: finite(persistentValue($0))) }
      .sorted { $0.capturedAt < $1.capturedAt }
    let oldPoints = windowWithPredecessor(oldCandidates, cutoff: cutoff)

    // If persistent history already occupies the left side of the visible
    // window it owns the cutoff predecessor. Otherwise keep one live
    // predecessor so a short in-memory-only range still crosses the fixed
    // left clip cleanly. Never prepend a live predecessor ahead of newer
    // persistent points, which would make the merged timeline unsorted.
    let hasVisiblePersistent = oldPoints.contains { $0.capturedAt >= cutoff }
    let livePoints =
      hasVisiblePersistent ? liveVisible : windowWithPredecessor(liveCandidates, cutoff: cutoff)

    let persistentSafe = insertingGapMarkers(oldPoints, maximumGap: 90)
    let liveSafe = insertingGapMarkers(livePoints, maximumGap: 8)
    guard let oldLast = oldPoints.last, let liveFirst = livePoints.first else {
      return persistentSafe + liveSafe
    }
    let bridge = liveFirst.capturedAt.timeIntervalSince(oldLast.capturedAt)
    guard bridge > 90 else { return persistentSafe + liveSafe }
    let gapAt = oldLast.capturedAt.addingTimeInterval(bridge / 2)
    return persistentSafe + [HeliosChartSample(capturedAt: gapAt, value: nil)] + liveSafe
  }

  private static func windowWithPredecessor(
    _ samples: [HeliosChartSample], cutoff: Date
  ) -> [HeliosChartSample] {
    guard !samples.isEmpty else { return [] }
    // A predecessor is useful only when there is at least one sample in the
    // visible window for it to connect to. Returning a lone stale predecessor
    // would incorrectly make an old sample the chart's "now" anchor.
    guard let firstVisible = samples.firstIndex(where: { $0.capturedAt >= cutoff }) else {
      return []
    }
    // Keep a small real-sample overscan tail. The chart maps the visible range
    // exactly, so these points live at negative x and are used only to preserve
    // the outgoing segment while Core Animation slides it through the left
    // clip. Six samples comfortably covers normal 1 Hz jitter without creating
    // or extrapolating telemetry.
    let start = max(samples.startIndex, firstVisible - 6)
    return Array(samples[start...])
  }

  /// A missing sample is an explicit pen-up marker. This prevents charts from
  /// drawing invented straight lines across app termination, sleep or long
  /// telemetry outages while still allowing the normal 30-second persistent
  /// cadence to form a continuous long-range trend.
  private static func insertingGapMarkers(
    _ samples: [HeliosChartSample], maximumGap: TimeInterval
  ) -> [HeliosChartSample] {
    guard samples.count > 1 else { return samples }
    var result: [HeliosChartSample] = []
    result.reserveCapacity(samples.count + 4)
    for sample in samples {
      if let previous = result.last,
        sample.capturedAt.timeIntervalSince(previous.capturedAt) > maximumGap
      {
        let midpoint = previous.capturedAt.addingTimeInterval(
          sample.capturedAt.timeIntervalSince(previous.capturedAt) / 2)
        result.append(HeliosChartSample(capturedAt: midpoint, value: nil))
      }
      result.append(sample)
    }
    return result
  }

  private static func finite(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value
  }
}

/// Segmented range picker for the roomy Full Monitor. Compact metric popovers
/// use HeliosGraphRangeMenu so the control is not confused with refresh/reload.
struct HeliosGraphRangePicker: View {
  @Binding var range: HeliosGraphRange

  var body: some View {
    Picker("Range", selection: $range) {
      ForEach(HeliosGraphRange.allCases) { item in
        Text(item.label).tag(item)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .controlSize(.mini)
    .frame(maxWidth: 330)
    .accessibilityLabel("Graph time range")
  }
}

/// Native-looking compact time-range menu. There is deliberately no circular
/// arrow icon: that read as a refresh cadence rather than a visible history span.
struct HeliosGraphRangeMenu: View {
  @Binding var range: HeliosGraphRange

  var body: some View {
    Menu {
      ForEach(HeliosGraphRange.allCases) { item in
        Button {
          range = item
        } label: {
          if range == item {
            Label(item.menuLabel, systemImage: "checkmark")
          } else {
            Text(item.menuLabel)
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Text(range.menuLabel)
          .monospacedDigit()
        Image(systemName: "chevron.down")
          .font(.system(size: 7.5, weight: .semibold))
      }
      .font(.system(size: 9.5, weight: .medium))
      .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Graph time range")
  }
}

/// Timestamp-aware AppKit chart. Telemetry remains sample-driven. A fresh
/// sample redraws the final path once, then Core Animation continuously slides
/// that backing surface for roughly the observed sample interval. This mirrors
/// the low-work behavior of mature menu-bar monitors without fabricating data
/// points or increasing polling frequency.
struct HeliosTimeSeriesChart: View {
  let samples: [HeliosChartSample]
  let range: HeliosGraphRange
  let fixedRange: ClosedRange<Double>?
  var tint: Color = .secondary
  var lineStyle: HeliosGraphLineStyle = .smooth
  var animateUpdates = true
  var inspectorEnabled = true
  var valueStyle: HeliosChartValueStyle = .plain
  var seriesLabel: String = "Value"

  var body: some View {
    HeliosNativeChartRepresentable(
      samples: samples,
      range: range,
      fixedRange: fixedRange,
      tint: tint,
      lineStyle: lineStyle,
      animateUpdates: animateUpdates,
      inspectorEnabled: inspectorEnabled,
      valueStyle: valueStyle,
      seriesLabel: seriesLabel
    )
    .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(seriesLabel) history")
    .accessibilityValue(
      samples.last(where: { $0.value?.isFinite == true })?.value.map(valueStyle.format)
        ?? "Unavailable")
  }
}

private struct HeliosNativeChartRepresentable: NSViewRepresentable {
  let samples: [HeliosChartSample]
  let range: HeliosGraphRange
  let fixedRange: ClosedRange<Double>?
  let tint: Color
  let lineStyle: HeliosGraphLineStyle
  let animateUpdates: Bool
  let inspectorEnabled: Bool
  let valueStyle: HeliosChartValueStyle
  let seriesLabel: String

  func makeNSView(context: Context) -> HeliosNativeTimeSeriesView {
    let view = HeliosNativeTimeSeriesView()
    view.update(
      samples: samples,
      range: range,
      fixedRange: fixedRange,
      tint: NSColor(tint),
      lineStyle: lineStyle,
      animateUpdates: animateUpdates,
      inspectorEnabled: inspectorEnabled,
      valueStyle: valueStyle,
      seriesLabel: seriesLabel,
      allowAnimation: false)
    return view
  }

  func updateNSView(_ nsView: HeliosNativeTimeSeriesView, context: Context) {
    nsView.update(
      samples: samples,
      range: range,
      fixedRange: fixedRange,
      tint: NSColor(tint),
      lineStyle: lineStyle,
      animateUpdates: animateUpdates,
      inspectorEnabled: inspectorEnabled,
      valueStyle: valueStyle,
      seriesLabel: seriesLabel,
      allowAnimation: true)
  }
}

@MainActor
private final class HeliosNativeTimeSeriesView: NSView {
  /// The plot moves inside a fixed clip view. Keeping clipping on the parent,
  /// rather than animating the backing layer of the whole chart, fixes both
  /// live edges: a fresh sample is revealed only as it crosses the right edge,
  /// while the predecessor just outside the left edge keeps the outgoing line
  /// continuous until it actually leaves the visible time window.
  private final class PlotCanvasView: NSView {
    weak var owner: HeliosNativeTimeSeriesView?

    init(owner: HeliosNativeTimeSeriesView) {
      self.owner = owner
      super.init(frame: .zero)
      wantsLayer = true
      layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      owner?.drawPlot(context: context, canvasBounds: bounds)
    }
  }

  private final class InspectorOverlayView: NSView {
    weak var owner: HeliosNativeTimeSeriesView?

    init(owner: HeliosNativeTimeSeriesView) {
      self.owner = owner
      super.init(frame: .zero)
      wantsLayer = true
      layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      owner?.drawInspectorOverlay(context: context)
    }
  }

  private var samples: [HeliosChartSample] = []
  private var range: HeliosGraphRange = .fiveMinutes
  private var fixedRange: ClosedRange<Double>?
  private var tint: NSColor = .secondaryLabelColor
  private var lineStyle: HeliosGraphLineStyle = .smooth
  private var animateUpdates = true
  private var inspectorEnabled = true
  private var valueStyle: HeliosChartValueStyle = .plain
  private var seriesLabel = "Value"
  private var stableDynamicRange: ClosedRange<Double>?
  private var latestTimestamp: Date?
  private var cursorPoint: NSPoint?
  private var trackingAreaRef: NSTrackingArea?

  private let plotClipView = NSView(frame: .zero)
  private lazy var plotCanvasView = PlotCanvasView(owner: self)
  private lazy var inspectorOverlayView = InspectorOverlayView(owner: self)

  private let preciseTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private let compactTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  private static let liveSlideKey = "com.snejda.Helios.chart.liveSlide"
  private static let horizontalPlotInset: CGFloat = 0.5

  /// The animated plot layer is deliberately wider than the visible aperture.
  /// Translating a same-size layer exposes transparent pixels at the left edge
  /// even when the model retains a predecessor sample. Keeping real offscreen
  /// canvas on both sides lets the outgoing line remain drawn until it actually
  /// crosses the fixed parent clip.
  private var plotCanvasOverscan: CGFloat {
    let width = max(plotClipView.bounds.width, visiblePlotRect.width)
    return min(72, max(12, width * 0.08))
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.masksToBounds = true

    plotClipView.wantsLayer = true
    plotClipView.layer?.masksToBounds = true
    plotClipView.layer?.backgroundColor = NSColor.clear.cgColor
    addSubview(plotClipView)
    plotClipView.addSubview(plotCanvasView)
    addSubview(inspectorOverlayView)
  }

  convenience init() {
    self.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
    guard inspectorEnabled else {
      trackingAreaRef = nil
      return
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
      owner: self,
      userInfo: nil)
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func mouseEntered(with event: NSEvent) {
    guard inspectorEnabled else { return }
    // Freeze only presentation motion while inspecting. Telemetry collection and
    // history continue normally; the next sample after exit resumes live motion.
    plotCanvasView.layer?.removeAnimation(forKey: Self.liveSlideKey)
    cursorPoint = convert(event.locationInWindow, from: nil)
    inspectorOverlayView.needsDisplay = true
  }

  override func mouseMoved(with event: NSEvent) {
    guard inspectorEnabled else { return }
    cursorPoint = convert(event.locationInWindow, from: nil)
    inspectorOverlayView.needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    cursorPoint = nil
    inspectorOverlayView.needsDisplay = true
    plotCanvasView.needsDisplay = true
  }

  func update(
    samples newSamples: [HeliosChartSample],
    range newRange: HeliosGraphRange,
    fixedRange newFixedRange: ClosedRange<Double>?,
    tint newTint: NSColor,
    lineStyle newLineStyle: HeliosGraphLineStyle,
    animateUpdates newAnimateUpdates: Bool,
    inspectorEnabled newInspectorEnabled: Bool,
    valueStyle newValueStyle: HeliosChartValueStyle,
    seriesLabel newSeriesLabel: String,
    allowAnimation: Bool
  ) {
    let oldLatest = latestTimestamp
    let newLatest = Self.latestValidTimestamp(in: newSamples)
    let rangeChanged = range != newRange
    let fixedChanged = !Self.sameRange(fixedRange, newFixedRange)
    let styleChanged = lineStyle != newLineStyle
    let animationSettingChanged = animateUpdates != newAnimateUpdates
    let inspectorSettingChanged = inspectorEnabled != newInspectorEnabled

    range = newRange
    fixedRange = newFixedRange
    tint = newTint
    lineStyle = newLineStyle
    animateUpdates = newAnimateUpdates
    inspectorEnabled = newInspectorEnabled
    valueStyle = newValueStyle
    seriesLabel = newSeriesLabel
    samples = Self.decimated(
      newSamples, target: max(360, Int(max(plotClipView.bounds.width, max(bounds.width, 360)) * 2)))
    latestTimestamp = newLatest

    if inspectorSettingChanged {
      if !newInspectorEnabled { cursorPoint = nil }
      updateTrackingAreas()
    }

    if fixedChanged || rangeChanged {
      stableDynamicRange = nil
    }
    updateStableDynamicRange()

    // Always redraw the model frame first. Only the inner plot canvas is then
    // translated; guides, hover UI and the fixed clipping aperture never move.
    plotCanvasView.needsDisplay = true
    inspectorOverlayView.needsDisplay = true

    if styleChanged || rangeChanged || fixedChanged || animationSettingChanged {
      plotCanvasView.layer?.removeAnimation(forKey: Self.liveSlideKey)
      needsDisplay = true
      return
    }

    guard allowAnimation,
      newAnimateUpdates,
      cursorPoint == nil,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let oldLatest,
      let newLatest,
      newLatest > oldLatest
    else {
      if !newAnimateUpdates { plotCanvasView.layer?.removeAnimation(forKey: Self.liveSlideKey) }
      needsDisplay = true
      return
    }

    let sampleDelta = newLatest.timeIntervalSince(oldLatest)
    guard sampleDelta.isFinite, sampleDelta > 0, sampleDelta < max(15, newRange.seconds) else {
      needsDisplay = true
      return
    }

    let drawableWidth = max(1, plotClipView.bounds.width)
    // Never translate farther than the real offscreen canvas we have retained.
    // This is what prevents a transparent strip from opening on the left while
    // the newest sample glides in from the right. Long sampling gaps update
    // truthfully but do not manufacture a giant catch-up animation.
    let maximumSafeSlide = max(1, plotCanvasOverscan * 0.8)
    let requestedSlide = max(0.08, drawableWidth * sampleDelta / newRange.seconds)
    let dx = min(maximumSafeSlide, requestedSlide)
    guard dx >= 0.08 else {
      needsDisplay = true
      return
    }

    // If sampling jitter delivers the next point before the previous slide has
    // finished, carry the presentation translation into the new animation while
    // staying inside the overscan budget.
    let carry = min(
      maximumSafeSlide, max(0, CGFloat(plotCanvasView.layer?.presentation()?.transform.m41 ?? 0)))
    plotCanvasView.layer?.removeAnimation(forKey: Self.liveSlideKey)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    plotCanvasView.needsDisplay = true
    plotCanvasView.displayIfNeeded()

    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = min(maximumSafeSlide, carry + dx)
    animation.toValue = 0
    animation.duration = min(2.5, max(0.12, sampleDelta))
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.isRemovedOnCompletion = true
    plotCanvasView.layer?.add(animation, forKey: Self.liveSlideKey)
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    let plotRect = visiblePlotRect
    plotClipView.frame = plotRect
    let overscan = plotCanvasOverscan
    plotCanvasView.frame = NSRect(
      x: -overscan, y: 0,
      width: plotClipView.bounds.width + overscan * 2, height: plotClipView.bounds.height)
    inspectorOverlayView.frame = bounds
    needsDisplay = true
    plotCanvasView.needsDisplay = true
    inspectorOverlayView.needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 1, bounds.height > 1
    else { return }

    context.setShouldAntialias(true)
    drawGuides(context: context, valueRange: resolvedValueRange)
  }

  private var visiblePlotRect: NSRect {
    let requested = bounds.insetBy(dx: Self.horizontalPlotInset, dy: 0)
    guard requested.width > 2 else { return bounds }
    return requested
  }

  private func drawPlot(context: CGContext, canvasBounds: NSRect) {
    let overscan = plotCanvasOverscan
    let plotBounds = NSRect(
      x: overscan, y: 0, width: plotClipView.bounds.width, height: canvasBounds.height)
    guard plotBounds.width > 1, plotBounds.height > 1 else { return }
    context.setShouldAntialias(true)
    let valueRange = resolvedValueRange
    let segments = pointSegments(valueRange: valueRange, plotRect: plotBounds)

    context.saveGState()
    context.setStrokeColor(tint.withAlphaComponent(0.92).cgColor)
    context.setLineWidth(1.55)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    for segment in segments where !segment.isEmpty {
      let path = CGMutablePath()
      path.move(to: segment[0])
      if segment.count > 1 {
        switch lineStyle {
        case .raw:
          for point in segment.dropFirst() { path.addLine(to: point) }
        case .smooth:
          if segment.count == 2 {
            path.addLine(to: segment[1])
          } else {
            let tangents = Self.monotoneTangents(for: segment)
            for index in 0..<(segment.count - 1) {
              let start = segment[index]
              let end = segment[index + 1]
              let width = max(0.0001, end.x - start.x)
              path.addCurve(
                to: end,
                control1: CGPoint(
                  x: start.x + width / 3,
                  y: start.y + CGFloat(tangents[index]) * width / 3),
                control2: CGPoint(
                  x: end.x - width / 3,
                  y: end.y - CGFloat(tangents[index + 1]) * width / 3))
            }
          }
        }
      }
      context.addPath(path)
      context.strokePath()
    }
    context.restoreGState()

    // A permanent frontier dot makes continuous motion look like a bead being
    // pushed across the chart. Keep it only for the intentionally discrete
    // update mode; hover inspection has its own larger exact-sample marker.
    if !animateUpdates, cursorPoint == nil, let point = segments.last?.last {
      context.setFillColor(tint.withAlphaComponent(0.98).cgColor)
      context.fillEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
    }
  }

  private func drawInspectorOverlay(context: CGContext) {
    guard inspectorEnabled, let cursorPoint else { return }
    drawInspector(context: context, cursor: cursorPoint, valueRange: resolvedValueRange)
  }

  private var resolvedValueRange: ClosedRange<Double> {
    if let fixedRange { return fixedRange }
    return stableDynamicRange ?? 0...1
  }

  private func updateStableDynamicRange() {
    guard fixedRange == nil else {
      stableDynamicRange = fixedRange
      return
    }
    let valid = samples.compactMap(\.value).filter(\.isFinite)
    guard let minimum = valid.min(), let maximum = valid.max() else {
      if stableDynamicRange == nil { stableDynamicRange = 0...1 }
      return
    }
    let candidate = Self.paddedRange(minimum: minimum, maximum: maximum)
    guard let current = stableDynamicRange else {
      stableDynamicRange = candidate
      return
    }

    // Expand immediately, but do not continuously contract the Y scale. This
    // prevents live values from appearing to jump merely because the axis moved.
    let lower = min(current.lowerBound, candidate.lowerBound)
    let upper = max(current.upperBound, candidate.upperBound)
    stableDynamicRange = lower...max(lower + 0.0001, upper)
  }

  private static func paddedRange(minimum: Double, maximum: Double) -> ClosedRange<Double> {
    if minimum >= 0 {
      let requested = max(1, maximum * 1.25)
      return 0...niceCeiling(requested)
    }

    let spread = maximum - minimum
    let magnitude = max(abs(minimum), abs(maximum))
    let padding = max(0.25, max(spread * 0.12, magnitude * 0.025))
    let lower = minimum - padding
    return lower...max(lower + 1, maximum + padding)
  }

  private static func niceCeiling(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 1 }
    let exponent = floor(log10(value))
    let scale = pow(10, exponent)
    let normalized = value / scale
    let step: Double
    if normalized <= 1 {
      step = 1
    } else if normalized <= 2 {
      step = 2
    } else if normalized <= 5 {
      step = 5
    } else {
      step = 10
    }
    return max(1, step * scale)
  }

  private func drawGuides(context: CGContext, valueRange: ClosedRange<Double>) {
    let plotRect = visiblePlotRect
    context.saveGState()
    context.setLineWidth(0.5)
    context.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor)
    for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
      let y = plotRect.minY + plotRect.height * fraction
      context.move(to: CGPoint(x: plotRect.minX, y: y))
      context.addLine(to: CGPoint(x: plotRect.maxX, y: y))
      context.strokePath()
    }

    if valueRange.lowerBound < 0, valueRange.upperBound > 0 {
      let normalized =
        (0 - valueRange.lowerBound) / (valueRange.upperBound - valueRange.lowerBound)
      let y = plotRect.minY + plotRect.height * CGFloat(1 - normalized)
      context.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.16).cgColor)
      context.setLineDash(phase: 0, lengths: [3, 3])
      context.move(to: CGPoint(x: plotRect.minX, y: y))
      context.addLine(to: CGPoint(x: plotRect.maxX, y: y))
      context.strokePath()
    }
    context.restoreGState()
  }

  private func drawInspector(
    context: CGContext, cursor: NSPoint, valueRange: ClosedRange<Double>
  ) {
    guard let item = nearestInspectorPoint(to: cursor, valueRange: valueRange) else { return }
    let plotRect = visiblePlotRect

    context.saveGState()
    context.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.42).cgColor)
    context.setLineWidth(0.7)
    context.setLineDash(phase: 0, lengths: [2, 2])
    context.move(to: CGPoint(x: item.point.x, y: plotRect.minY))
    context.addLine(to: CGPoint(x: item.point.x, y: plotRect.maxY))
    context.strokePath()
    context.setLineDash(phase: 0, lengths: [])

    context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor)
    context.fillEllipse(
      in: CGRect(x: item.point.x - 4.5, y: item.point.y - 4.5, width: 9, height: 9))
    context.setFillColor(tint.cgColor)
    context.fillEllipse(
      in: CGRect(x: item.point.x - 2.5, y: item.point.y - 2.5, width: 5, height: 5))
    context.restoreGState()

    let formatter = range.seconds <= 15 * 60 ? preciseTimeFormatter : compactTimeFormatter
    let time = formatter.string(from: item.sample.capturedAt)
    let value = item.sample.value.map(valueStyle.format) ?? "—"
    let title = "\(seriesLabel)  \(value)"
    let subtitle = time

    let titleFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    let subtitleFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
    let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
    let subtitleWidth = ceil(
      (subtitle as NSString).size(withAttributes: [.font: subtitleFont]).width)
    let width = max(titleWidth, subtitleWidth) + 14
    let height: CGFloat = 34
    var x = item.point.x + 8
    if x + width > bounds.maxX - 4 { x = item.point.x - width - 8 }
    x = min(max(4, x), max(4, bounds.width - width - 4))
    let y = min(max(4, item.point.y - height - 8), max(4, bounds.height - height - 4))
    let rect = NSRect(x: x, y: y, width: width, height: height)

    let box = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
    box.fill()
    NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
    box.lineWidth = 0.5
    box.stroke()

    (title as NSString).draw(
      in: NSRect(x: rect.minX + 7, y: rect.minY + 5, width: rect.width - 14, height: 13),
      withAttributes: [.font: titleFont, .foregroundColor: NSColor.labelColor])
    (subtitle as NSString).draw(
      in: NSRect(x: rect.minX + 7, y: rect.minY + 19, width: rect.width - 14, height: 11),
      withAttributes: [.font: subtitleFont, .foregroundColor: NSColor.secondaryLabelColor])
  }

  private func nearestInspectorPoint(
    to cursor: NSPoint, valueRange: ClosedRange<Double>
  ) -> (sample: HeliosChartSample, point: CGPoint)? {
    guard let displayNow = latestTimestamp, range.seconds > 0,
      valueRange.upperBound > valueRange.lowerBound
    else { return nil }

    let plotRect = visiblePlotRect
    guard plotRect.width > 1 else { return nil }
    let visualSpan = range.seconds
    let cutoff = displayNow.addingTimeInterval(-visualSpan)
    let x = min(max(plotRect.minX, cursor.x), plotRect.maxX)
    let xFraction = (x - plotRect.minX) / plotRect.width
    let target = cutoff.addingTimeInterval(Double(xFraction) * visualSpan)
    let valid = samples.filter {
      $0.capturedAt >= cutoff && $0.capturedAt <= displayNow && $0.value?.isFinite == true
    }
    guard
      let sample = valid.min(by: {
        abs($0.capturedAt.timeIntervalSince(target)) < abs($1.capturedAt.timeIntervalSince(target))
      }), let raw = sample.value
    else { return nil }

    let sampleFraction = sample.capturedAt.timeIntervalSince(cutoff) / visualSpan
    let span = valueRange.upperBound - valueRange.lowerBound
    let value = min(valueRange.upperBound, max(valueRange.lowerBound, raw))
    let normalized = (value - valueRange.lowerBound) / span
    return (
      sample,
      CGPoint(
        x: plotRect.minX + plotRect.width * CGFloat(min(1, max(0, sampleFraction))),
        y: plotRect.minY + plotRect.height * CGFloat(1 - normalized))
    )
  }

  private func pointSegments(
    valueRange: ClosedRange<Double>, plotRect: NSRect
  ) -> [[CGPoint]] {
    guard let displayNow = latestTimestamp, range.seconds > 0,
      valueRange.upperBound > valueRange.lowerBound, plotRect.width > 1, plotRect.height > 1
    else { return [] }

    // The visible horizontal axis is exactly the selected range. Real samples
    // retained before the cutoff are rendered at negative x so the connecting
    // segment can leave through the fixed clip edge instead of disappearing a
    // sample early.
    let visualSpan = range.seconds
    let cutoff = displayNow.addingTimeInterval(-visualSpan)
    let span = valueRange.upperBound - valueRange.lowerBound
    var segments: [[CGPoint]] = []
    var current: [CGPoint] = []
    var predecessorTail: [HeliosChartSample] = []

    func point(for sample: HeliosChartSample, rawValue: Double) -> CGPoint {
      let rawFraction = sample.capturedAt.timeIntervalSince(cutoff) / visualSpan
      let value = min(valueRange.upperBound, max(valueRange.lowerBound, rawValue))
      let normalized = (value - valueRange.lowerBound) / span
      return CGPoint(
        x: plotRect.minX + plotRect.width * CGFloat(rawFraction),
        y: plotRect.minY + plotRect.height * CGFloat(1 - normalized))
    }

    func finish() {
      if !current.isEmpty {
        segments.append(current)
        current.removeAll(keepingCapacity: true)
      }
      predecessorTail.removeAll(keepingCapacity: true)
    }

    for sample in samples where sample.capturedAt <= displayNow {
      guard let rawValue = sample.value, rawValue.isFinite else {
        finish()
        continue
      }

      if sample.capturedAt < cutoff {
        // Keep the real predecessor tail, not just one point. During the live
        // slide the visible left edge temporarily looks farther back in time; a
        // single predecessor can therefore still expose a blank strip when the
        // cutoff falls between two samples. The bounded merge already retains
        // at most six points here.
        predecessorTail.append(sample)
        continue
      }

      if current.isEmpty, !predecessorTail.isEmpty {
        current.append(
          contentsOf: predecessorTail.compactMap { predecessor in
            guard let previousValue = predecessor.value, previousValue.isFinite else { return nil }
            return point(for: predecessor, rawValue: previousValue)
          })
      }
      predecessorTail.removeAll(keepingCapacity: true)
      current.append(point(for: sample, rawValue: rawValue))
    }
    finish()
    return segments
  }

  private static func latestValidTimestamp(in samples: [HeliosChartSample]) -> Date? {
    samples.last(where: { $0.value?.isFinite == true })?.capturedAt
  }

  private static func sameRange(
    _ lhs: ClosedRange<Double>?, _ rhs: ClosedRange<Double>?
  ) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (.some(let lhs), .some(let rhs)):
      return lhs.lowerBound == rhs.lowerBound && lhs.upperBound == rhs.upperBound
    default: return false
    }
  }

  /// Width-aware min/max decimation keeps long (6h/24h) charts cheap to draw
  /// while preserving spikes. Nil samples remain pen-up markers.
  private static func decimated(
    _ input: [HeliosChartSample], target: Int
  ) -> [HeliosChartSample] {
    guard input.count > target, target >= 32 else { return input }
    var output: [HeliosChartSample] = []
    var segment: [HeliosChartSample] = []

    func flush() {
      guard !segment.isEmpty else { return }
      if segment.count <= target {
        output.append(contentsOf: segment)
      } else {
        let bucketCount = max(1, target / 2)
        let bucketSize = Double(segment.count) / Double(bucketCount)
        var bucket = 0
        while bucket < bucketCount {
          let start = Int(Double(bucket) * bucketSize)
          let end = min(segment.count, max(start + 1, Int(Double(bucket + 1) * bucketSize)))
          let slice = segment[start..<end]
          if let minimum = slice.min(by: { ($0.value ?? .infinity) < ($1.value ?? .infinity) }),
            let maximum = slice.max(by: { ($0.value ?? -.infinity) < ($1.value ?? -.infinity) })
          {
            if minimum.capturedAt <= maximum.capturedAt {
              output.append(minimum)
              if maximum.id != minimum.id { output.append(maximum) }
            } else {
              output.append(maximum)
              if maximum.id != minimum.id { output.append(minimum) }
            }
          }
          bucket += 1
        }
      }
      segment.removeAll(keepingCapacity: true)
    }

    for sample in input {
      if sample.value == nil {
        flush()
        if output.last?.value != nil { output.append(sample) }
      } else {
        segment.append(sample)
      }
    }
    flush()
    return output.sorted { $0.capturedAt < $1.capturedAt }
  }

  private static func monotoneTangents(for points: [CGPoint]) -> [Double] {
    guard points.count > 1 else { return Array(repeating: 0, count: points.count) }
    var secants: [Double] = []
    secants.reserveCapacity(points.count - 1)
    for index in 0..<(points.count - 1) {
      let dx = max(0.0001, Double(points[index + 1].x - points[index].x))
      secants.append(Double(points[index + 1].y - points[index].y) / dx)
    }
    var tangents = Array(repeating: 0.0, count: points.count)
    tangents[0] = secants[0]
    tangents[points.count - 1] = secants[secants.count - 1]
    if points.count > 2 {
      for index in 1..<(points.count - 1) {
        let previous = secants[index - 1]
        let next = secants[index]
        guard previous != 0, next != 0, previous.sign == next.sign else {
          tangents[index] = 0
          continue
        }
        tangents[index] = (2 * previous * next) / (previous + next)
      }
    }
    return tangents
  }
}
