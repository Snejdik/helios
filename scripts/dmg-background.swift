// Draws the DMG window background: a calm field for the icons and an instruction band at the
// bottom that does not depend on where Finder places the icons. Used by scripts/package-release.sh; writes <out>/background.png (1x) and
// background@2x.png. Mid-tone colours keep Finder's icon labels readable in light and dark mode.
import AppKit

let size = NSSize(width: 600, height: 400)
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(scale: CGFloat) -> Data? {
  guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
  else { return nil }
  bitmap.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

  let bounds = NSRect(origin: .zero, size: size)
  NSGradient(
    starting: NSColor(srgbRed: 0.50, green: 0.50, blue: 0.53, alpha: 1),
    ending: NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1))?
    .draw(in: bounds, angle: -90)

  // No arrow between fixed spots: Finder does not always keep the icon layout, so the
  // instruction must read correctly wherever the icons end up. Icons use the top two thirds;
  // the bottom band holds the instruction.
  NSColor.black.withAlphaComponent(0.18).setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 0, width: size.width, height: 116)).fill()
  NSColor(srgbRed: 1, green: 0.62, blue: 0.20, alpha: 1).setFill()
  NSBezierPath(rect: NSRect(x: 0, y: 116, width: size.width, height: 2)).fill()

  let style = NSMutableParagraphStyle()
  style.alignment = .center
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
  shadow.shadowOffset = NSSize(width: 0, height: -1)
  shadow.shadowBlurRadius = 2
  let caption = NSAttributedString(
    string: "To install, drag Helios onto the Applications folder",
    attributes: [
      .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
      .foregroundColor: NSColor.white,
      .paragraphStyle: style,
      .shadow: shadow,
    ])
  caption.draw(in: NSRect(x: 0, y: 64, width: size.width, height: 26))
  let note = NSAttributedString(
    string: "If macOS blocks the first launch, use Open Anyway in Privacy & Security.",
    attributes: [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor.white.withAlphaComponent(0.85),
      .paragraphStyle: style,
    ])
  note.draw(in: NSRect(x: 20, y: 34, width: size.width - 40, height: 18))

  NSGraphicsContext.restoreGraphicsState()
  return bitmap.representation(using: .png, properties: [:])
}

for (scale, name) in [(CGFloat(1), "background.png"), (2, "background@2x.png")] {
  guard let data = render(scale: scale) else { fatalError("could not render \(name)") }
  try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}
