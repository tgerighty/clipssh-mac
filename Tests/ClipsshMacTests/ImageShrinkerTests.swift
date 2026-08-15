import AppKit
import Foundation
import Testing
@testable import ClipsshMac

/// The app used to send whatever the pasteboard held, verbatim. A 24-megapixel
/// 16-bit photo therefore arrived on the remote host as a 69 MB PNG, which is
/// far past what a reader on the far end can ingest — Claude Code, for one,
/// caps an image at 5 MB of base64, i.e. ~3.75 MB of actual bytes. These tests
/// hold `ImageShrinker` to the two rules that fix it: cap the long edge, and
/// never exceed the byte budget. A normal screenshot must pass through
/// untouched.

/// Builds a PNG in memory. `noisy` fills the pixels pseudo-randomly so the
/// encoder cannot compress them away — the byte-budget test needs an image
/// that is still oversized *after* the long edge has been capped.
private func makePNG(
    width: Int,
    height: Int,
    bitsPerSample: Int = 8,
    noisy: Bool = false
) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: bitsPerSample,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    if let pixels = rep.bitmapData {
        let count = rep.bytesPerRow * height
        if noisy {
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            for index in 0..<count {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                pixels[index] = UInt8(truncatingIfNeeded: seed >> 33)
            }
        } else {
            pixels.update(repeating: 128, count: count)
        }
    }
    return rep.representation(using: .png, properties: [:])!
}

private func rep(of data: Data) -> NSBitmapImageRep {
    NSBitmapImageRep(data: data)!
}

@Test func smallEightBitScreenshotIsReturnedUnchanged() {
    let original = makePNG(width: 800, height: 600)

    #expect(ImageShrinker.shrink(original) == original)
}

@Test func imageExactlyAtTheLongEdgeCapIsReturnedUnchanged() {
    let original = makePNG(width: 1568, height: 900)

    #expect(ImageShrinker.shrink(original) == original)
}

@Test func portraitImageOverTheCapIsScaledSoItsHeightIs1568() throws {
    let shrunk = rep(of: try #require(ImageShrinker.shrink(makePNG(width: 1600, height: 2000))))

    #expect(shrunk.pixelsHigh == 1568)
    #expect(shrunk.pixelsWide == 1254)
}

@Test func landscapeImageOverTheCapIsScaledSoItsWidthIs1568() throws {
    let shrunk = rep(of: try #require(ImageShrinker.shrink(makePNG(width: 2400, height: 1200))))

    #expect(shrunk.pixelsWide == 1568)
    #expect(shrunk.pixelsHigh == 784)
}

@Test func sixteenBitImageIsFlattenedToEightBit() throws {
    let original = makePNG(width: 1600, height: 2000, bitsPerSample: 16)
    #expect(rep(of: original).bitsPerSample == 16)

    #expect(rep(of: try #require(ImageShrinker.shrink(original))).bitsPerSample == 8)
}

@Test func noisyImageStillOversizedAfterTheFirstPassIsHalvedUntilItFits() throws {
    let original = makePNG(width: 2000, height: 2000, noisy: true)
    #expect(original.count > ImageShrinker.byteBudget)

    let shrunk = try #require(ImageShrinker.shrink(original))

    #expect(shrunk.count <= ImageShrinker.byteBudget)
    #expect(rep(of: shrunk).pixelsWide < 1568)
}

/// `ClipboardReader.pngData()` shrinks outside its main-thread hop, so the whole
/// redraw runs on whatever queue `performSend()` is using. This guards the
/// premise that change rests on: off-screen `NSBitmapImageRep` drawing does not
/// need the main thread. It is a check on the threading model, not a red-green
/// regression test — it passed before that change too.
@Test func shrinkingWorksOffTheMainThread() async throws {
    let original = makePNG(width: 1600, height: 2000, bitsPerSample: 16)

    let (shrunk, ranOffMain): (Data?, Bool) = await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: (ImageShrinker.shrink(original), !Thread.isMainThread))
        }
    }

    #expect(ranOffMain)
    let converted = rep(of: try #require(shrunk))
    #expect(converted.pixelsHigh == 1568)
    #expect(converted.bitsPerSample == 8)
}

@Test func dataThatIsNotAnImageIsReturnedUnchanged() {
    let garbage = Data("not an image at all".utf8)

    #expect(ImageShrinker.shrink(garbage) == garbage)
}

@Test func emptyDataIsReturnedUnchanged() {
    #expect(ImageShrinker.shrink(Data()) == Data())
}
