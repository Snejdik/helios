import AppKit
import SwiftUI

@MainActor
final class HeliosAppIconCache {
  static let shared = HeliosAppIconCache()

  private static let pointSize = 32
  private static let backingPixels = 64
  private static let approximateCost = backingPixels * backingPixels * 4
  private let cache = NSCache<NSString, NSImage>()

  private init() {
    // NSWorkspace application icons commonly carry large multi-resolution image
    // representations. Retaining those originals for every process/app row can
    // keep tens of MiB resident after the UI closes. Cache only a bounded 2x
    // raster thumbnail; the full workspace icon is transient.
    cache.countLimit = 64
    cache.totalCostLimit = 64 * Self.approximateCost
  }

  func icon(for appKey: String) -> NSImage? {
    guard appKey.hasPrefix("app:") else { return nil }
    let path = String(appKey.dropFirst(4))
    guard !path.isEmpty else { return nil }
    let key = path as NSString
    if let cached = cache.object(forKey: key) { return cached }

    let thumbnail: NSImage? = autoreleasepool {
      let source = NSWorkspace.shared.icon(forFile: path)
      var proposed = NSRect(
        x: 0, y: 0, width: CGFloat(Self.pointSize), height: CGFloat(Self.pointSize))
      guard let sourceCG = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: nil, width: Self.backingPixels, height: Self.backingPixels,
          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }

      context.interpolationQuality = .high
      context.draw(
        sourceCG,
        in: CGRect(x: 0, y: 0, width: Self.backingPixels, height: Self.backingPixels))
      guard let cgImage = context.makeImage() else { return nil }
      return NSImage(
        cgImage: cgImage,
        size: NSSize(width: Self.pointSize, height: Self.pointSize))
    }

    guard let thumbnail else { return nil }
    cache.setObject(thumbnail, forKey: key, cost: Self.approximateCost)
    return thumbnail
  }

  func purge() { cache.removeAllObjects() }
}

struct HeliosAppIdentityIcon: View {
  let appKey: String
  var size: CGFloat = 24

  var body: some View {
    Group {
      if let image = HeliosAppIconCache.shared.icon(for: appKey) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
      } else {
        Image(systemName: "app.fill")
          .resizable()
          .scaledToFit()
          .padding(size * 0.18)
          .foregroundStyle(.secondary)
          .background(
            Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.22))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
