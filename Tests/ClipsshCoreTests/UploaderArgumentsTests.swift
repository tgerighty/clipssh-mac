import Foundation
import Testing
@testable import ClipsshCore

// Covers the ssh command line Uploader builds: the executable path, the
// binary-safe options it always forces, the port flag, stdin, and how a
// bracketed IPv6 destination is stripped for ssh but kept in storage.

@Test func uploadUsesTheAbsoluteSSHPath() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    // A GUI app has a minimal PATH, so "ssh" alone would not be found.
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func uploadAlwaysSetsBatchModeAndConnectTimeout() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    let args = runner.lastArguments
    // Without BatchMode a GUI app hangs forever on a password prompt.
    #expect(args.contains("BatchMode=yes"))
    #expect(args.contains("ConnectTimeout=8"))
}

@Test func uploadAlwaysSetsStrictHostKeyCheckingYes() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    #expect(runner.lastArguments.contains("StrictHostKeyChecking=yes"))
}

// MARK: - Binary-safe pipe, regardless of the user's own ~/.ssh/config
//
// `StdinNull yes` in the user's ssh_config would make ssh never read the PNG
// from stdin at all — the remote `cat` still creates an empty file and exits
// 0, so the app would report success over an empty image. `RequestTTY force`
// can corrupt binary data across a pty. A configured `RemoteCommand` would
// replace our command, and `SessionType none` would open no session at all.
// Every one of these is forced explicitly so a future edit cannot silently
// drop one and reintroduce the hole.

@Test func uploadForcesEveryBinarySafeOption() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    let args = runner.lastArguments
    #expect(args.contains("-T"))
    #expect(args.contains("StdinNull=no"))
    #expect(args.contains("ForkAfterAuthentication=no"))
    #expect(args.contains("RemoteCommand=none"))
    #expect(args.contains("SessionType=default"))
}

@Test func uploadPassesThePortWhenSet() throws {
    let runner = FakeRunner()
    let ported = Target(label: "box", destination: "box.example.com", port: 2222)
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: ported)
    #expect(runner.lastArguments.contains("-p"))
    #expect(runner.lastArguments.contains("2222"))
}

@Test func uploadOmitsThePortFlagWhenUnset() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    #expect(!runner.lastArguments.contains("-p"))
}

@Test func uploadSendsThePNGOnStandardInput() throws {
    let runner = FakeRunner()
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    _ = try Uploader(runner: runner).upload(png, to: uploaderTestTarget)
    #expect(runner.lastStdin == png)
}

@Test func uploadReturnsThePathItAskedTheRemoteToWrite() throws {
    let runner = FakeRunner()
    let path = try Uploader(runner: runner).upload(Data([0x89]), to: uploaderTestTarget)
    #expect(runner.lastArguments.last == "/bin/sh -c 'umask 077; set -C; cat > \"$1\"' sh '\(path)'")
    #expect(path.hasPrefix("/tmp/clipboard-"))
    #expect(path.hasSuffix(".png"))
}

@Test func testConnectionRunsTrueAndSendsNoData() throws {
    let runner = FakeRunner()
    try Uploader(runner: runner).testConnection(uploaderTestTarget)
    #expect(runner.lastArguments.last == "true")
    #expect(runner.lastStdin == nil)
}

// MARK: - Bracketed IPv6 literals are stripped for ssh, kept in storage
//
// ssh itself rejects the bracketed form ("Could not resolve hostname
// [::1]") even though the grammar requires brackets to keep a stored
// destination unambiguous. The brackets must therefore be present in the
// validated/stored `Target.destination` but absent from the argument
// actually handed to ssh.

@Test func bareIPv6DestinationReachesSSHWithoutBrackets() {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "[::1]")
    let args = Uploader(runner: runner).sshArguments(for: target, command: "true")
    #expect(args.contains("::1"))
    #expect(!args.contains("[::1]"))
}

@Test func userAtIPv6DestinationReachesSSHWithoutBracketsButKeepsTheUser() {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "user@[2001:db8::1]")
    let args = Uploader(runner: runner).sshArguments(for: target, command: "true")
    #expect(args.contains("user@2001:db8::1"))
    #expect(!args.contains("user@[2001:db8::1]"))
}

@Test func hostnameDestinationIsUnchangedInSSHArguments() {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "host.example.com")
    let args = Uploader(runner: runner).sshArguments(for: target, command: "true")
    #expect(args.contains("host.example.com"))
}

@Test func ipv4DestinationIsUnchangedInSSHArguments() {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "192.0.2.1")
    let args = Uploader(runner: runner).sshArguments(for: target, command: "true")
    #expect(args.contains("192.0.2.1"))
}

@Test func uploadHandsTheRunnerTheBareIPv6FormSSHActuallyAccepts() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "[::1]")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastArguments.contains("::1"))
    #expect(!runner.lastArguments.contains("[::1]"))
}

/// Defence in depth alongside validation: even if a bad destination somehow
/// reached ssh's argument list, "--" stops ssh from parsing anything after it
/// as an option.
@Test func sshArgumentsInsertsDoubleDashImmediatelyBeforeTheDestination() {
    let runner = FakeRunner()
    let target = Target(label: "box", destination: "box.example.com")
    let args = Uploader(runner: runner).sshArguments(for: target, command: "true")
    guard let dashIndex = args.firstIndex(of: "--"), let destIndex = args.firstIndex(of: "box.example.com") else {
        Issue.record("expected both -- and the destination in \(args)")
        return
    }
    #expect(dashIndex == destIndex - 1)
}
