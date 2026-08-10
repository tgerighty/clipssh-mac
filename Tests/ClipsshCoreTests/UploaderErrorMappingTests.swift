import Foundation
import Testing
@testable import ClipsshCore

// Covers how Uploader maps a runner's exit code/stderr (or a thrown
// ProcessRunnerError) into a specific UploadError, for both upload() and
// testConnection().

@Test func hostKeyFailureMapsToHostKeyNotTrusted() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Host key verification failed.")
    #expect(throws: UploadError.hostKeyNotTrusted) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

@Test func permissionDeniedAtConnectionLevelMapsToKeyUnavailable() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Permission denied (publickey).")
    #expect(throws: UploadError.keyUnavailable) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

@Test func connectionTimeoutMapsToTimedOut() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "ssh: connect to host ... Operation timed out")
    #expect(throws: UploadError.timedOut("box")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

@Test func watchdogTimeoutMapsToTimedOut() {
    let runner = FakeRunner()
    runner.errorToThrow = ProcessRunnerError.timedOut
    #expect(throws: UploadError.timedOut("box")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

@Test func nonConnectionExitCodeMapsToRemoteWriteFailed() {
    let runner = FakeRunner()
    // Exit code 1 comes from the remote command, not from ssh itself.
    runner.result = ProcessResult(exitCode: 1, stderr: "bash: line 1: /tmp/x.png: Permission denied")
    #expect(throws: UploadError.remoteWriteFailed("box")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

@Test func unrecognisedConnectionErrorMapsToOther() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "kex_exchange_identification: banner line")
    #expect(throws: UploadError.other("kex_exchange_identification: banner line")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

// `LogLevel QUIET` in the user's ssh config can make ssh exit 255 with
// completely empty stderr, which must not surface as a blank, wordless
// error in the menu.
@Test func emptyStderrOnConnectionFailureMapsToAClearFallbackMessage() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "")
    #expect(throws: UploadError.other("SSH connection failed")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

@Test func whitespaceOnlyStderrOnConnectionFailureMapsToAClearFallbackMessage() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "  \n")
    #expect(throws: UploadError.other("SSH connection failed")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    }
}

@Test func testConnectionSurfacesTheSameErrors() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Host key verification failed.")
    #expect(throws: UploadError.hostKeyNotTrusted) {
        try Uploader(runner: runner).testConnection(uploaderTestTarget)
    }
}

@Test func everyErrorHasANonEmptyMessage() {
    let errors: [UploadError] = [
        .noImageInClipboard, .noTargetConfigured, .keyUnavailable,
        .hostKeyNotTrusted, .timedOut("box"), .remoteWriteFailed("box"), .other("x"),
        .invalidDestination
    ]
    #expect(errors.allSatisfy { !$0.message.isEmpty })
}
