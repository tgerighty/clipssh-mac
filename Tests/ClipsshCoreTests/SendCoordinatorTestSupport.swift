import Foundation
import Testing
@testable import ClipsshCore

final class FakePasteboard: PasteboardReading {
    var image: Data?
    private(set) var written: [String] = []

    init(image: Data? = Data([0x89, 0x50, 0x4E, 0x47])) {
        self.image = image
    }

    func pngData() -> Data? { image }
    func write(string: String) { written.append(string) }
}

final class StubRunner: ProcessRunning, @unchecked Sendable {
    var result = ProcessResult(exitCode: 0, stderr: "")
    private(set) var callCount = 0

    func run(executable: String, arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
        callCount += 1
        return result
    }
}

/// Creates a scratch directory for a test to own. Directory creation under the
/// system temporary directory is not expected to fail; if it does, the test
/// cannot proceed meaningfully, so this records an Issue and stops rather than
/// returning a URL backed by nothing.
func makeTempDir(sourceLocation: SourceLocation = #_sourceLocation) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipssh-send-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        // Report and continue: fatalError here would abort the whole test
        // process (and every other test in the run) over one directory that
        // failed to create. The caller's own operations on this URL will
        // fail with their own, more specific errors.
        Issue.record("Could not create temp directory: \(error)", sourceLocation: sourceLocation)
    }
    return url
}

struct MadeCoordinator {
    let coordinator: SendCoordinator
    let pasteboard: FakePasteboard
    let runner: StubRunner
}

func makeCoordinator(
    directory: URL,
    pasteboard: FakePasteboard = FakePasteboard(),
    runner: StubRunner = StubRunner()
) -> MadeCoordinator {
    let coordinator = SendCoordinator(
        store: TargetStore(directory: directory),
        pasteboard: pasteboard,
        uploader: Uploader(runner: runner)
    )
    return MadeCoordinator(coordinator: coordinator, pasteboard: pasteboard, runner: runner)
}
