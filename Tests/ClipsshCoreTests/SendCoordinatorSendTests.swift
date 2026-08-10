import Foundation
import Testing
@testable import ClipsshCore

// Covers SendCoordinator.performSend, copyLastPath, and testConnection —
// the parts of the coordinator that talk to the clipboard and the uploader.

@Test func sendFailsWhenClipboardHasNoImage() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let made = makeCoordinator(directory: directory, pasteboard: FakePasteboard(image: nil))
    let coordinator = made.coordinator
    let runner = made.runner
    coordinator.addTarget(destination: "box.example.com")

    #expect(coordinator.performSend() == .failed(.noImageInClipboard))
    // It must not connect to anything when there is nothing to send.
    #expect(runner.callCount == 0)
}

@Test func sendFailsWhenNoTargetIsConfigured() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let made = makeCoordinator(directory: directory)
    let coordinator = made.coordinator
    let runner = made.runner

    #expect(coordinator.performSend() == .failed(.noTargetConfigured))
    #expect(runner.callCount == 0)
}

@Test func successfulSendReturnsThePathAndCopiesIt() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let made = makeCoordinator(directory: directory)
    let coordinator = made.coordinator
    let pasteboard = made.pasteboard
    coordinator.addTarget(destination: "box.example.com")

    guard case .sent(let path) = coordinator.performSend() else {
        Issue.record("expected a successful send")
        return
    }
    #expect(path.hasPrefix("/tmp/clipboard-"))
    #expect(pasteboard.written == [path])
}

@Test func successfulSendIsRecordedAsTheLastOutcome() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    coordinator.addTarget(destination: "box.example.com")

    let outcome = coordinator.performSend()
    #expect(coordinator.lastOutcome == outcome)
}

@Test func failedSendSurfacesTheUploaderError() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = StubRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Host key verification failed.")
    let made = makeCoordinator(directory: directory, runner: runner)
    let coordinator = made.coordinator
    let pasteboard = made.pasteboard
    coordinator.addTarget(destination: "box.example.com")

    #expect(coordinator.performSend() == .failed(.hostKeyNotTrusted))
    // A failure must never overwrite the clipboard.
    #expect(pasteboard.written.isEmpty)
}

@Test func copyLastPathRewritesTheSuccessfulPath() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let made = makeCoordinator(directory: directory)
    let coordinator = made.coordinator
    let pasteboard = made.pasteboard
    coordinator.addTarget(destination: "box.example.com")
    guard case .sent(let path) = coordinator.performSend() else {
        Issue.record("expected a successful send")
        return
    }

    coordinator.copyLastPath()

    #expect(pasteboard.written == [path, path])
}

@Test func copyLastPathDoesNothingAfterAFailure() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let made = makeCoordinator(directory: directory, pasteboard: FakePasteboard(image: nil))
    let coordinator = made.coordinator
    let pasteboard = made.pasteboard
    coordinator.addTarget(destination: "box.example.com")
    _ = coordinator.performSend()

    coordinator.copyLastPath()

    #expect(pasteboard.written.isEmpty)
}

@Test func testConnectionReportsSuccess() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let target = coordinator.addTarget(destination: "box.example.com", label: "box")

    #expect(coordinator.testConnection(target) == "Connected to box")
}

@Test func testConnectionReportsTheError() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = StubRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Permission denied (publickey).")
    let coordinator = makeCoordinator(directory: directory, runner: runner).coordinator
    let target = coordinator.addTarget(destination: "box.example.com", label: "box")

    #expect(coordinator.testConnection(target) == UploadError.keyUnavailable.message)
}
