import Foundation
import Testing
@testable import ClipsshCore

private final class FakeRunner: ProcessRunning, @unchecked Sendable {
    var result: ProcessResult = ProcessResult(exitCode: 0, stderr: "")
    var errorToThrow: Error?
    private(set) var lastArguments: [String] = []
    private(set) var lastStdin: Data?
    private(set) var lastExecutable: String = ""

    func run(executable: String, arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
        lastExecutable = executable
        lastArguments = arguments
        lastStdin = stdin
        if let errorToThrow { throw errorToThrow }
        return result
    }
}

private let target = Target(label: "box", destination: "box.example.com")

@Test func uploadUsesTheAbsoluteSSHPath() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    // A GUI app has a minimal PATH, so "ssh" alone would not be found.
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func uploadAlwaysSetsBatchModeAndConnectTimeout() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    let args = runner.lastArguments
    // Without BatchMode a GUI app hangs forever on a password prompt.
    #expect(args.contains("BatchMode=yes"))
    #expect(args.contains("ConnectTimeout=8"))
}

@Test func uploadAlwaysSetsStrictHostKeyCheckingYes() throws {
    let runner = FakeRunner()
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
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
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
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
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(!runner.lastArguments.contains("-p"))
}

@Test func uploadSendsThePNGOnStandardInput() throws {
    let runner = FakeRunner()
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    _ = try Uploader(runner: runner).upload(png, to: target)
    #expect(runner.lastStdin == png)
}

@Test func uploadReturnsThePathItAskedTheRemoteToWrite() throws {
    let runner = FakeRunner()
    let path = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastArguments.last == "/bin/sh -c 'umask 077; set -C; cat > \"$1\"' sh '\(path)'")
    #expect(path.hasPrefix("/tmp/clipboard-"))
    #expect(path.hasSuffix(".png"))
}

@Test func hostKeyFailureMapsToHostKeyNotTrusted() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Host key verification failed.")
    #expect(throws: UploadError.hostKeyNotTrusted) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

@Test func permissionDeniedAtConnectionLevelMapsToKeyUnavailable() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Permission denied (publickey).")
    #expect(throws: UploadError.keyUnavailable) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

@Test func connectionTimeoutMapsToTimedOut() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "ssh: connect to host ... Operation timed out")
    #expect(throws: UploadError.timedOut("box")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

@Test func watchdogTimeoutMapsToTimedOut() {
    let runner = FakeRunner()
    runner.errorToThrow = ProcessRunnerError.timedOut
    #expect(throws: UploadError.timedOut("box")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

@Test func nonConnectionExitCodeMapsToRemoteWriteFailed() {
    let runner = FakeRunner()
    // Exit code 1 comes from the remote command, not from ssh itself.
    runner.result = ProcessResult(exitCode: 1, stderr: "bash: line 1: /tmp/x.png: Permission denied")
    #expect(throws: UploadError.remoteWriteFailed("box")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

@Test func unrecognisedConnectionErrorMapsToOther() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "kex_exchange_identification: banner line")
    #expect(throws: UploadError.other("kex_exchange_identification: banner line")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

// `LogLevel QUIET` in the user's ssh config can make ssh exit 255 with
// completely empty stderr, which must not surface as a blank, wordless
// error in the menu.
@Test func emptyStderrOnConnectionFailureMapsToAClearFallbackMessage() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "")
    #expect(throws: UploadError.other("SSH connection failed")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

@Test func whitespaceOnlyStderrOnConnectionFailureMapsToAClearFallbackMessage() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "  \n")
    #expect(throws: UploadError.other("SSH connection failed")) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    }
}

@Test func testConnectionRunsTrueAndSendsNoData() throws {
    let runner = FakeRunner()
    try Uploader(runner: runner).testConnection(target)
    #expect(runner.lastArguments.last == "true")
    #expect(runner.lastStdin == nil)
}

@Test func testConnectionSurfacesTheSameErrors() {
    let runner = FakeRunner()
    runner.result = ProcessResult(exitCode: 255, stderr: "Host key verification failed.")
    #expect(throws: UploadError.hostKeyNotTrusted) {
        try Uploader(runner: runner).testConnection(target)
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

// MARK: - Destination validation
//
// A destination beginning with "-" is parsed by ssh as an OPTION, not a host
// (e.g. "-oProxyCommand=touch /tmp/pwned" runs an arbitrary LOCAL command).
// These pin both that the malicious/malformed forms are rejected before the
// runner ever sees them, and that legitimate forms keep working.

@Test func destinationBeginningWithADashIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "-oProxyCommand=touch /tmp/pwned")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func emptyDestinationIsRejected() {
    let runner = FakeRunner()
    let empty = Target(label: "empty", destination: "")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: empty)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func destinationWithAnEmbeddedSpaceIsRejected() {
    let runner = FakeRunner()
    let spaced = Target(label: "spaced", destination: "ho st")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: spaced)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func destinationWithAnEmbeddedNULIsRejected() {
    let runner = FakeRunner()
    let nulled = Target(label: "nulled", destination: "ho\0st")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: nulled)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func plainHostDestinationIsStillAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "plain", destination: "host.example.com")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func userAtHostDestinationIsStillAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "userhost", destination: "user@host.example.com")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func testConnectionRejectsAMaliciousDestinationWithoutInvokingTheRunner() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "-oProxyCommand=touch /tmp/pwned")
    #expect(throws: UploadError.invalidDestination) {
        try Uploader(runner: runner).testConnection(malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func hostExampleComDestinationIsAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "host.example.com")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func ipv4DestinationIsAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "192.0.2.1")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func userAtIPv4DestinationIsAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "user@192.0.2.1")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func bracketedIPv6DestinationIsAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "[2001:db8::1]")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

@Test func bracketedLoopbackIPv6DestinationIsAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "[::1]")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

// MARK: - Bracketed IPv6 is parsed, not just character-matched
//
// The allowed character set inside brackets (hex digits, ":", ".") also
// matches strings that are not valid IPv6 addresses at all. Without actually
// parsing the address, these would reach ssh and fail with a confusing
// connection error instead of UploadError.invalidDestination.

@Test func bracketedNonHexLetterIsRejected() {
    let runner = FakeRunner()
    let malformed = Target(label: "evil", destination: "[a]")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malformed)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func bracketedRepeatedColonsAreRejected() {
    let runner = FakeRunner()
    let malformed = Target(label: "evil", destination: "[::::]")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malformed)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func bracketedOutOfRangeIPv4MappedOctetIsRejected() {
    let runner = FakeRunner()
    let malformed = Target(label: "evil", destination: "[1.2.3.999]")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malformed)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func emptyBracketsAreRejected() {
    let runner = FakeRunner()
    let malformed = Target(label: "evil", destination: "[]")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malformed)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func aliasWithDotsDashesAndUnderscoresIsAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "my-host_name.example")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}

// MARK: - Allowlist rejects OpenSSH token expansion and shell metacharacters
//
// OpenSSH expands %h/%r tokens into ProxyCommand/LocalCommand/Match exec in
// the user's own ~/.ssh/config even when "--" blocks OPTION injection.
// OpenSSH only added hostname sanity checks for this in 9.6; macOS Ventura
// (a supported OS here) ships 9.0. The allowlist grammar closes this by
// rejecting anything outside [A-Za-z0-9._-] (or a bracketed IPv6 literal)
// before ssh ever sees the destination.

@Test func percentHTokenPayloadIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "host%h")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func commandSubstitutionPayloadIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "host$(id)")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func backtickPayloadIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "host`id`")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func semicolonPayloadIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "host;rm -rf /")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func pipePayloadIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "host|cat")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func quotedPayloadIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "\"host\"")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
}

@Test func commaPayloadIsRejected() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "host,other")
    #expect(throws: UploadError.invalidDestination) {
        _ = try Uploader(runner: runner).upload(Data([0x89]), to: malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
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
