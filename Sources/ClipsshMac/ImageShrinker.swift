import AppKit
import Foundation

/// Keeps a pasteboard image small enough for whatever reads it on the far end.
///
/// The app sends pasteboard PNG data as-is, so a 24-megapixel 16-bit photo used
/// to arrive as a 69 MB file. Nothing downstream can use that: Anthropic's API
/// caps an image at 5 MB of *base64*, and base64 is 4/3 the size of the bytes
/// it encodes, so the real ceiling is ~3.75 MB of PNG.
///
/// Pure `Data` in, `Data` out — no pasteboard, no I/O — so it is testable,
/// unlike `ClipboardReader`, which is why the logic lives here and not there.
enum ImageShrinker {
    /// Sits under the ~3.75 MB that a 5 MB base64 cap actually allows.
    static let byteBudget = 3_500_000

    /// The API scales anything bigger down to this before the model sees it, so
    /// pixels above the cap cost upload time and buy no detail.
    static let longEdgeCap = 1568

    /// Halving stops here. An image this small that still misses the budget is
    /// beyond saving, and looping to a one-pixel image helps nobody.
    private static let minimumLongEdge = 196

    /// Returns `data` untouched when it is already small enough, or when it is
    /// not an image at all — the caller cannot tell the difference and does not
    /// need to.
    static func shrink(_ data: Data) -> Data {
        guard let source = NSBitmapImageRep(data: data) else { return data }
        let width = source.pixelsWide
        let height = source.pixelsHigh
        guard width > 0, height > 0 else { return data }

        // A run-of-the-mill screenshot lands here and is never re-encoded.
        if max(width, height) <= longEdgeCap,
           source.bitsPerSample == 8,
           data.count <= byteBudget {
            return data
        }

        // Capping at the source's own long edge keeps an already-small 16-bit
        // image at its current size while still flattening it to 8-bit.
        var longEdge = min(longEdgeCap, max(width, height))
        while true {
            guard let candidate = redraw(source, width: width, height: height, longEdge: longEdge)
            else { return data }

            if candidate.count <= byteBudget || longEdge <= minimumLongEdge {
                return candidate
            }
            longEdge /= 2
        }
    }

    private static func redraw(
        _ source: NSBitmapImageRep,
        width: Int,
        height: Int,
        longEdge: Int
    ) -> Data? {
        let scale = Double(longEdge) / Double(max(width, height))
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))

        guard let destination = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        destination.size = NSSize(width: targetWidth, height: targetHeight)

        guard let context = NSGraphicsContext(bitmapImageRep: destination) else { return nil }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.flushGraphics()
        NSGraphicsContext.current = saved

        return destination.representation(using: .png, properties: [:])
    }
}
