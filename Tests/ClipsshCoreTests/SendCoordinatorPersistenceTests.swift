import Darwin
import Foundation
import Testing
@testable import ClipsshCore

// Covers SendCoordinator's interaction with TargetStore's load/save edge
// cases: a corrupt config file, backup naming, save failures, and
// permission warnings surfaced from the underlying config file.

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
