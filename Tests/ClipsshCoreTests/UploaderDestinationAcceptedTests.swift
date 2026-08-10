import Foundation
import Testing
@testable import ClipsshCore

// Covers destination forms that `isValidDestination`'s allowlist grammar must
// keep accepting: plain hosts, user@host, IPv4, bracketed IPv6, and aliases
// with dots/dashes/underscores.

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

@Test func aliasWithDotsDashesAndUnderscoresIsAccepted() throws {
    let runner = FakeRunner()
    let target = Target(label: "t", destination: "my-host_name.example")
    _ = try Uploader(runner: runner).upload(Data([0x89]), to: target)
    #expect(runner.lastExecutable == "/usr/bin/ssh")
}
