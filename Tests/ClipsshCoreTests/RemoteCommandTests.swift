import Foundation
import Testing
@testable import ClipsshCore

@Test func filenameFollowsTheAgreedPattern() {
    #expect(RemoteCommand.filename(epoch: 1754000000, suffix: "a3f9") == "clipboard-1754000000-a3f9.png")
}

@Test func remotePathIsAlwaysUnderTmp() {
    #expect(RemoteCommand.remotePath(filename: "clipboard-1-ab12.png") == "/tmp/clipboard-1-ab12.png")
}

@Test func uploadCommandMatchesTheGoldenString() {
    let command = RemoteCommand.uploadCommand(filename: "clipboard-1754000000-a3f9.png")
    #expect(command == "/bin/sh -c 'umask 077; set -C; cat > \"$1\"' sh '/tmp/clipboard-1754000000-a3f9.png'")
}

@Test func uploadCommandRefusesToClobberAnExistingPath() {
    let command = RemoteCommand.uploadCommand(filename: "clipboard-1-ab12.png")
    // set -C (noclobber) makes the write fail instead of following a
    // pre-created file or symlink at the target path.
    #expect(command.contains("set -C"))
}

@Test func uploadCommandNeverDeletesAnything() {
    let command = RemoteCommand.uploadCommand(filename: "clipboard-1-ab12.png")
    // The app must never run a destructive command on a remote host.
    #expect(!command.contains("rm"))
    #expect(!command.contains("find"))
    #expect(!command.contains("-delete"))
}

@Test func randomSuffixIsFourLowercaseHexCharacters() {
    for _ in 0..<200 {
        let suffix = RemoteCommand.randomSuffix()
        #expect(suffix.count == 4)
        #expect(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}

@Test func randomSuffixVaries() {
    let suffixes = Set((0..<200).map { _ in RemoteCommand.randomSuffix() })
    // 200 draws from 65536 values collide sometimes; they must not all be equal.
    #expect(suffixes.count > 100)
}

/// `filename` always comes from `newFilename()` today, so no metacharacter
/// reaches the shell in practice. This pins the contract for any future
/// caller by actually running the generated command through `/bin/sh` — a
/// plain substring check would not tell quoted-safe from injectable, since
/// escaping a quote still leaves the quote character in the string.
@Test func uploadCommandDoesNotLetAnEmbeddedQuoteEscapeItsShellWord() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipssh-remote-command-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appendingPathComponent("marker").path

    let filename = "x'; touch '\(marker)"
    let command = RemoteCommand.uploadCommand(filename: filename)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    // If the embedded quote had broken out of the shell word, `touch` would
    // have run as a second command and created this file.
    #expect(!FileManager.default.fileExists(atPath: marker))
}
