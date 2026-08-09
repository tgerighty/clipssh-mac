import Foundation

/// Keeps AppKit out of ClipsshCore, so no test needs a window server.
public protocol PasteboardReading {
    func pngData() -> Data?
    func write(string: String)
}
