import Darwin
import Foundation
import Testing
@testable import ClipsshCore

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipssh-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func loadReturnsEmptyConfigWhenFileIsMissing() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    #expect(try store.load() == Config.empty)
}

@Test func saveThenLoadRoundTrips() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    let target = Target(label: "box", destination: "box.example.com", port: 2222)
    let config = Config(version: 1, defaultTargetID: target.id, hotkey: "cmd+shift+2", targets: [target])

    try store.save(config)

    #expect(try store.load() == config)
}

@Test func saveWritesFileWithMode600() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    try store.save(Config.empty)

    let attrs = try FileManager.default.attributesOfItem(atPath: store.configURL.path)
    let perms = attrs[.posixPermissions] as? NSNumber
    #expect(perms?.int16Value == 0o600)
}

@Test func resaveTightensPermissionsOnAPreexistingLooseConfigFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    try store.save(Config.empty)
    // Simulates a config file that somehow ended up world-readable (e.g. an
    // older binary, or manual editing) before the next save.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.configURL.path)

    try store.save(Config.empty)

    let attrs = try FileManager.default.attributesOfItem(atPath: store.configURL.path)
    let perms = attrs[.posixPermissions] as? NSNumber
    #expect(perms?.int16Value == 0o600)
}

@Test func saveTightensPermissionsOnAPreexistingLooseDirectory() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Simulates the CLI (or an old version of this app) having already
    // created the directory with the default, looser mode.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    let store = TargetStore(directory: dir)

    try store.save(Config.empty)

    let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
    let perms = attrs[.posixPermissions] as? NSNumber
    #expect(perms?.int16Value == 0o700)
}

@Test func loadTightensAPreexistingLooseConfigFileTo600() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    let target = Target(label: "box", destination: "box.example.com")
    let config = Config(version: 1, defaultTargetID: target.id, hotkey: nil, targets: [target])
    try store.save(config)
    // Simulates a config file that ended up world-readable (older binary,
    // restore, manual edit) before the app ever loads it again.
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.configURL.path)

    let loaded = try store.load()

    #expect(loaded == config)
    let attrs = try FileManager.default.attributesOfItem(atPath: store.configURL.path)
    let perms = attrs[.posixPermissions] as? NSNumber
    #expect(perms?.int16Value == 0o600)
}

@Test func loadLeavesAnAlreadyTightConfigFileUntouched() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    try store.save(Config.empty)

    _ = try store.load()

    let attrs = try FileManager.default.attributesOfItem(atPath: store.configURL.path)
    let perms = attrs[.posixPermissions] as? NSNumber
    #expect(perms?.int16Value == 0o600)
}

@Test func loadPropagatesAnUnreadableFileInsteadOfReturningEmpty() throws {
    guard getuid() != 0 else { return } // root ignores permission bits.
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    try Data("{}".utf8).write(to: store.configURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.configURL.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.configURL.path) }

    #expect(throws: (any Error).self) {
        _ = try store.load()
    }
}

// A failed atomic replace (e.g. an immutable destination file) must not
// leave the `clipssh-mac.json.tmp-<UUID>` staging file behind — repeated
// failures would otherwise accumulate them in the config directory.
@Test func failedSaveLeavesNoStagingFileBehind() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    try store.save(Config.empty)
    #expect(chflags(store.configURL.path, UInt32(UF_IMMUTABLE)) == 0)
    defer { _ = chflags(store.configURL.path, 0) }

    #expect(throws: (any Error).self) {
        try store.save(Config.empty)
    }

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.contains(".tmp-") }
    #expect(leftovers.isEmpty)
}

// MARK: - Schema version

@Test func loadAcceptsTheCurrentlySupportedVersion() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    let target = Target(label: "box", destination: "box.example.com")
    let config = Config(version: Config.currentVersion, targets: [target])
    try store.save(config)

    #expect(try store.load() == config)
}

@Test func loadRejectsAFutureSchemaVersionAndLeavesTheFileIntact() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    let future = Config(version: Config.currentVersion + 1, targets: [Target(label: "box", destination: "box.example.com")])
    let data = try JSONEncoder().encode(future)
    try data.write(to: store.configURL)

    // Treated exactly like the corrupt case: never overwritten, never
    // silently stripped of fields this build does not understand.
    #expect(throws: StoreError.corrupt) {
        _ = try store.load()
    }
    #expect(try Data(contentsOf: store.configURL) == data)
}

@Test func loadThrowsOnCorruptJSONAndLeavesTheFileIntact() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TargetStore(directory: dir)
    let junk = Data("{ this is not json".utf8)
    try junk.write(to: store.configURL)

    #expect(throws: StoreError.corrupt) {
        _ = try store.load()
    }
    // The file must survive. Losing a target list to a parse error is unacceptable.
    #expect(try Data(contentsOf: store.configURL) == junk)
}

@Test func importedAliasesReadsTheCLIAliasFile() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let aliases = """
    # a comment
    box=admin@box.example.com

    other=other.example.com
    """
    try Data(aliases.utf8).write(to: dir.appendingPathComponent("aliases"))

    let imported = TargetStore(directory: dir).importedAliases()

    #expect(imported.map(\.label) == ["box", "other"])
    #expect(imported.map(\.destination) == ["admin@box.example.com", "other.example.com"])
}

@Test func importedAliasesStripsCarriageReturnsFromCRLFLineEndings() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let aliases = "box=admin@box.example.com\r\nother=other.example.com\r\n"
    try Data(aliases.utf8).write(to: dir.appendingPathComponent("aliases"))

    let imported = TargetStore(directory: dir).importedAliases()

    #expect(imported.map(\.destination) == ["admin@box.example.com", "other.example.com"])
}

@Test func importedAliasesTrimsSpacesAroundTheSeparator() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("box = admin@box.example.com\n".utf8).write(to: dir.appendingPathComponent("aliases"))

    let imported = TargetStore(directory: dir).importedAliases()

    #expect(imported.map(\.label) == ["box"])
    #expect(imported.map(\.destination) == ["admin@box.example.com"])
}

@Test func importedAliasesReturnsEmptyWhenNoAliasFileExists() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(TargetStore(directory: dir).importedAliases().isEmpty)
}

// Both tests mutate the process-wide CLIPSSH_MAC_CONFIG_DIR environment
// variable. Swift Testing runs tests in parallel by default, so without
// .serialized they can interleave: the fallback test could observe the
// override test's value and silently skip its own assertion instead of
// failing.
@Suite(.serialized)
struct DefaultDirectoryEnvironmentTests {
    @Test func defaultDirectoryHonoursTheConfigDirOverride() throws {
        let scratch = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("CLIPSSH_MAC_CONFIG_DIR", scratch.path, 1)
        defer { unsetenv("CLIPSSH_MAC_CONFIG_DIR") }

        #expect(TargetStore.defaultDirectory == URL(fileURLWithPath: scratch.path, isDirectory: true))
    }

    @Test func defaultDirectoryFallsBackToTheHomeDirectory() {
        // The override is read from the environment at call time, so it is
        // cleared here rather than merely checked, to guarantee the fallback
        // path actually runs instead of silently skipping the assertion.
        unsetenv("CLIPSSH_MAC_CONFIG_DIR")
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clipssh")
        #expect(TargetStore.defaultDirectory == expected)
    }
}
