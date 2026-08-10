import Foundation
import Testing
@testable import ClipsshCore

// Covers destination forms that `isValidDestination`'s allowlist grammar must
// reject before ever handing them to ssh — OPTION injection, malformed
// bracketed IPv6, OpenSSH token expansion, and shell metacharacters.
//
// A destination beginning with "-" is parsed by ssh as an OPTION, not a host
// (e.g. "-oProxyCommand=touch /tmp/pwned" runs an arbitrary LOCAL command).
// These pin both that the malicious/malformed forms are rejected before the
// runner ever sees them.

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

@Test func testConnectionRejectsAMaliciousDestinationWithoutInvokingTheRunner() {
    let runner = FakeRunner()
    let malicious = Target(label: "evil", destination: "-oProxyCommand=touch /tmp/pwned")
    #expect(throws: UploadError.invalidDestination) {
        try Uploader(runner: runner).testConnection(malicious)
    }
    #expect(runner.lastExecutable.isEmpty)
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
