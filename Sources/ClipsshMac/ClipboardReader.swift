import AppKit
import ClipsshCore

/// The only pasteboard code in the project. Deliberately thin: nothing tests it,
/// so nothing that matters may live here.
final class ClipboardReader: PasteboardReading {
    func pngData() -> Data? {
        onMain {
            let pasteboard = NSPasteboard.general
            if let png = pasteboard.data(forType: .png) {
                return ImageShrinker.shrink(png)
            }
            // A screenshot is often offered as TIFF only, so convert it.
            guard let tiff = pasteboard.data(forType: .tiff),
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            return ImageShrinker.shrink(png)
        }
    }

    func write(string: String) {
        onMain {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }
    }

    // performSend() runs on a background queue, so this hop is what keeps all
    // AppKit pasteboard access on the main thread. The Thread.isMainThread
    // check is essential: an unconditional DispatchQueue.main.sync would
    // deadlock if this were ever called while already on the main thread.
    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }
}
