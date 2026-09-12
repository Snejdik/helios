import AppKit
import SwiftUI

/// Uses the bundled application's multi-resolution icon without modifying its artwork.
struct HeliosApplicationIcon: View {
  var size: CGFloat = 28

  var body: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
      .accessibilityHidden(true)
  }
}

/// Monochrome menu-bar hub preview, matching MenuBarView's compact solar symbol.
/// Full-color branding surfaces use HeliosApplicationIcon instead.
struct HeliosBrandMark: View {
  var size: CGFloat = 28
  var colored = true

  var body: some View {
    ZStack {
      ForEach(0..<8, id: \.self) { index in
        let primary = index.isMultiple(of: 2)
        Capsule(style: .continuous)
          .fill(markColor)
          .frame(
            width: max(1.6, size * (primary ? 0.082 : 0.068)),
            height: size * (primary ? 0.205 : 0.13)
          )
          .offset(y: -size * (primary ? 0.39 : 0.365))
          .rotationEffect(.degrees(Double(index) * 45))
      }
      Circle()
        .fill(markColor)
        .frame(width: size * 0.47, height: size * 0.47)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var markColor: Color {
    colored ? Color(red: 1.0, green: 0.57, blue: 0.08) : Color.primary
  }
}

extension Color {
  init(heliosHex: String, fallback: Color = .accentColor) {
    let cleaned = heliosHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    guard cleaned.count == 6 || cleaned.count == 8, let raw = UInt64(cleaned, radix: 16) else {
      self = fallback
      return
    }
    let r: Double
    let g: Double
    let b: Double
    let a: Double
    if cleaned.count == 8 {
      r = Double((raw >> 24) & 0xff) / 255
      g = Double((raw >> 16) & 0xff) / 255
      b = Double((raw >> 8) & 0xff) / 255
      a = Double(raw & 0xff) / 255
    } else {
      r = Double((raw >> 16) & 0xff) / 255
      g = Double((raw >> 8) & 0xff) / 255
      b = Double(raw & 0xff) / 255
      a = 1
    }
    self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
  }

  var heliosHex: String {
    let ns = NSColor(self)
    guard let rgb = ns.usingColorSpace(.sRGB) else { return "#0A84FFFF" }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    let a = Int((rgb.alphaComponent * 255).rounded())
    return String(format: "#%02X%02X%02X%02X", r, g, b, a)
  }
}

@MainActor
extension HeliosPreferences {
  func color(for role: HeliosColorRole) -> Color {
    Color(heliosHex: colorHex(for: role), fallback: Color(heliosHex: role.defaultHex))
  }
}
