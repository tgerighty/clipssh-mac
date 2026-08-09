import Foundation
import Testing
import ClipsshCore

final class FakePasteboard: PasteboardReading {
    var image: Data? = Data([0x89, 0x50, 0x4E, 0x47])
    func pngData() -> Data? { image }
    func write(string: String) {}
}

final class StubRunner: ProcessRunning, @unchecked Sendable {
    var result = ProcessResult(exitCode: 0, stderr: "")
    func run(executable: String, arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
        result
    }
}

/// Creates a scratch directory for a test to own. Mirrors the helper in
/// ClipsshCoreTests: directory creation under the system temporary directory
/// is not expected to fail. If it does, this records an Issue rather than
/// calling fatalError, which would abort the whole test process (and every
/// other test in the run) over one directory that failed to create; the
/// caller's own operations on this URL will fail with their own errors.
func makeTempDir(sourceLocation: SourceLocation = #_sourceLocation) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipssh-mac-ui-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        Issue.record("Could not create temp directory: \(error)", sourceLocation: sourceLocation)
    }
    return url
}

func makeCoordinator(directory: URL) -> SendCoordinator {
    SendCoordinator(
        store: TargetStore(directory: directory),
        pasteboard: FakePasteboard(),
        uploader: Uploader(runner: StubRunner())
    )
}

/// True when a real window server is expected to be available.
///
/// A handful of tests construct real AppKit objects that need one:
/// `NSStatusItem` (MenuBarController) and `NSWindow`/`NSHostingController`
/// (TargetsWindowController.show()). GitHub Actions' macOS runners have no
/// logged-in GUI session, so CoreGraphics aborts the whole test process with
/// a fatal assertion in `CGSConnectionByID` the moment one of those objects
/// is created — not a normal, catchable test failure.
///
/// This deliberately does not *probe* CoreGraphics to detect a window server
/// (e.g. by asking CGS for a connection): that probe is exactly the call
/// that aborts the process in CI, so doing it defeats the purpose. Instead
/// it trusts the `CI` environment variable GitHub Actions always sets. Gated
/// tests still run normally with `swift test` on a developer machine, which
/// has a real window server and no `CI` variable.
var hasWindowServer: Bool {
    ProcessInfo.processInfo.environment["CI"] == nil
}
