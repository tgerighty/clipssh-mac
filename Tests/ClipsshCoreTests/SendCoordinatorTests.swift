import Darwin
import Foundation
import Testing
@testable import ClipsshCore

private final class FakePasteboard: PasteboardReading {
    var image: Data?
    private(set) var written: [String] = []

    init(image: Data? = Data([0x89, 0x50, 0x4E, 0x47])) {
        self.image = image
    }

    func pngData() -> Data? { image }
    func write(string: String) { written.append(string) }
}

private final class StubRunner: ProcessRunning, @unchecked Sendable {
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

private struct MadeCoordinator {
    let coordinator: SendCoordinator
    let pasteboard: FakePasteboard
    let runner: StubRunner
}

private func makeCoordinator(
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

@Test func addTargetMakesTheFirstTargetTheDefault() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let first = coordinator.addTarget(destination: "one.example.com")
    let second = coordinator.addTarget(destination: "two.example.com")

    #expect(coordinator.config.defaultTargetID == first.id)
    #expect(coordinator.config.targets.map(\.id) == [first.id, second.id])
}

@Test func setDefaultChangesTheDefaultTarget() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    _ = coordinator.addTarget(destination: "one.example.com")
    let second = coordinator.addTarget(destination: "two.example.com")

    coordinator.setDefault(second)

    #expect(coordinator.config.defaultTargetID == second.id)
}

@Test func removingTheDefaultTargetPromotesAnother() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let first = coordinator.addTarget(destination: "one.example.com")
    let second = coordinator.addTarget(destination: "two.example.com")

    coordinator.removeTarget(first)

    #expect(coordinator.config.targets.map(\.id) == [second.id])
    #expect(coordinator.config.defaultTargetID == second.id)
}

@Test func removingTheLastTargetLeavesNoDefault() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let only = coordinator.addTarget(destination: "one.example.com")

    coordinator.removeTarget(only)

    #expect(coordinator.config.targets.isEmpty)
    #expect(coordinator.config.defaultTargetID == nil)
}

@Test func updateTargetPersistsTheEdit() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    var target = coordinator.addTarget(destination: "one.example.com")
    target.label = "renamed"
    target.port = 2222

    coordinator.updateTarget(target)

    #expect(coordinator.config.targets.first?.label == "renamed")
    #expect(coordinator.config.targets.first?.port == 2222)
}

@Test func changesSurviveAReload() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator
    let target = coordinator.addTarget(destination: "one.example.com")
    coordinator.setHotkey("cmd+shift+2")

    let reopened = makeCoordinator(directory: directory).coordinator

    #expect(reopened.config.targets.map(\.id) == [target.id])
    #expect(reopened.config.hotkey == "cmd+shift+2")
}

@Test func aliasesAreImportedOnFirstRunOnly() throws {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("box=admin@box.example.com".utf8)
        .write(to: directory.appendingPathComponent("aliases"))

    let first = makeCoordinator(directory: directory).coordinator
    #expect(first.config.targets.map(\.label) == ["box"])

    first.removeTarget(first.config.targets[0])

    // Reopening must not resurrect a target the user deleted.
    let second = makeCoordinator(directory: directory).coordinator
    #expect(second.config.targets.isEmpty)
}

@Test func corruptConfigIsReportedAndNeverOverwritten() throws {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let junk = Data("{ not json".utf8)
    try junk.write(to: directory.appendingPathComponent("clipssh-mac.json"))

    let coordinator = makeCoordinator(directory: directory).coordinator

    #expect(coordinator.configIsCorrupt)
    #expect(coordinator.config.targets.isEmpty)
    #expect(try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json")) == junk)
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

@Test func mutatingAfterACorruptLoadPreservesTheOriginalFile() throws {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let junk = Data("{ not json".utf8)
    try junk.write(to: directory.appendingPathComponent("clipssh-mac.json"))

    let coordinator = makeCoordinator(directory: directory).coordinator
    #expect(coordinator.configIsCorrupt)

    coordinator.addTarget(destination: "box.example.com")

    let backupURL = directory.appendingPathComponent("clipssh-mac.json.corrupt")
    #expect(try Data(contentsOf: backupURL) == junk)

    let configData = try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json"))
    let config = try JSONDecoder().decode(Config.self, from: configData)
    #expect(config.targets.map(\.destination) == ["box.example.com"])

    #expect(!coordinator.configIsCorrupt)
}

@Test func asecondCorruptBackupDoesNotClobberTheFirst() throws {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let existingBackup = Data("previous backup contents".utf8)
    try existingBackup.write(to: directory.appendingPathComponent("clipssh-mac.json.corrupt"))

    let junk = Data("{ still not json".utf8)
    try junk.write(to: directory.appendingPathComponent("clipssh-mac.json"))

    let coordinator = makeCoordinator(directory: directory).coordinator
    #expect(coordinator.configIsCorrupt)

    coordinator.addTarget(destination: "box.example.com")

    #expect(try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json.corrupt")) == existingBackup)
    #expect(try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json.corrupt.1")) == junk)
}

@Test func anUnreadableExistingConfigIsNeverOverwritten() throws {
    guard getuid() != 0 else { return } // root ignores permission bits.
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = Data("{ unreadable but present".utf8)
    let configURL = directory.appendingPathComponent("clipssh-mac.json")
    try original.write(to: configURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: configURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path) }

    let coordinator = makeCoordinator(directory: directory).coordinator
    #expect(coordinator.configIsCorrupt)

    coordinator.addTarget(destination: "box.example.com")

    // The mutation must have been backed up rather than silently destroying
    // the unreadable original.
    let backupURL = directory.appendingPathComponent("clipssh-mac.json.corrupt")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    #expect(try Data(contentsOf: backupURL) == original)
}

@Test func backupPicksTheNextFreeSuffixWhenSeveralBackupsAlreadyExist() throws {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("first".utf8).write(to: directory.appendingPathComponent("clipssh-mac.json.corrupt"))
    try Data("second".utf8).write(to: directory.appendingPathComponent("clipssh-mac.json.corrupt.1"))
    try Data("third".utf8).write(to: directory.appendingPathComponent("clipssh-mac.json.corrupt.2"))
    let junk = Data("{ still not json".utf8)
    try junk.write(to: directory.appendingPathComponent("clipssh-mac.json"))

    let coordinator = makeCoordinator(directory: directory).coordinator
    #expect(coordinator.configIsCorrupt)

    coordinator.addTarget(destination: "box.example.com")

    // Regression coverage for switching backUpCorruptFile from a
    // check-then-move sequence (a TOCTOU race: another process could create
    // the backup path between the check and the move) to a move-and-retry
    // loop that reacts to an "already exists" failure instead of predicting
    // it. A real concurrent race is not reproducible deterministically in a
    // unit test, but this pins the same externally observable outcome —
    // several pre-existing backups still leave the earlier ones untouched
    // and land the new one at the next free suffix.
    #expect(try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json.corrupt")) == Data("first".utf8))
    #expect(try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json.corrupt.1")) == Data("second".utf8))
    #expect(try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json.corrupt.2")) == Data("third".utf8))
    #expect(try Data(contentsOf: directory.appendingPathComponent("clipssh-mac.json.corrupt.3")) == junk)
    #expect(!coordinator.configIsCorrupt)
}

@Test func saveFailureIsRecorded() {
    // /dev/null is a device file, not a directory, so any path under it
    // fails FileManager's createDirectory with ENOTDIR — a reliable way to
    // force a save failure without depending on filesystem permissions.
    let badDirectory = URL(fileURLWithPath: "/dev/null/clipssh-cannot-create")
    let coordinator = makeCoordinator(directory: badDirectory).coordinator

    coordinator.addTarget(destination: "box.example.com")

    #expect(coordinator.lastSaveError != nil)
}

@Test func successfulSaveLeavesNoSaveError() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = makeCoordinator(directory: directory).coordinator

    coordinator.addTarget(destination: "box.example.com")

    #expect(coordinator.lastSaveError == nil)
}

/// A config file whose permissions TargetStore could not tighten to 0600 on
/// load must not stay a silent, in-memory-only warning: it needs to reach the
/// coordinator so the menu can surface it. `chflags(UF_IMMUTABLE)` makes
/// `chmod` fail even for the file's owner, which deterministically forces the
/// tightening step in TargetStore.load() to fail without depending on running
/// as a different user.
@Test func loadPermissionWarningReachesTheCoordinator() throws {
    guard getuid() != 0 else { return } // root ignores the immutable flag.
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TargetStore(directory: directory)
    try store.save(Config.empty)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.configURL.path)
    chflags(store.configURL.path, UInt32(UF_IMMUTABLE))
    defer { chflags(store.configURL.path, 0) }

    let coordinator = SendCoordinator(
        store: store, pasteboard: FakePasteboard(), uploader: Uploader(runner: StubRunner())
    )

    #expect(coordinator.lastLoadWarning != nil)
}

@Test func noPermissionWarningWhenTheConfigFileIsAlreadyTight() throws {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A missing config file never reaches the permission-inspection path at
    // all, so it would pass this assertion regardless of whether that path
    // works. Save a real 0600 file through TargetStore first so the
    // "already tight, no warning" branch is the one actually exercised.
    let store = TargetStore(directory: directory)
    try store.save(Config.empty)

    let coordinator = SendCoordinator(
        store: store, pasteboard: FakePasteboard(), uploader: Uploader(runner: StubRunner())
    )

    #expect(coordinator.lastLoadWarning == nil)
}
