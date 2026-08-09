import Darwin
import Foundation
import Testing
@testable import ClipsshCore

@Test func runReturnsExitCodeAndStderr() throws {
    let runner = SubprocessRunner()
    let result = try runner.run(
        executable: "/bin/sh",
        arguments: ["-c", "echo oops >&2; exit 3"],
        stdin: nil,
        timeout: 5
    )
    #expect(result.exitCode == 3)
    #expect(result.stderr.contains("oops"))
}

@Test func runPipesStdinToTheProcess() throws {
    let runner = SubprocessRunner()
    let result = try runner.run(
        executable: "/bin/sh",
        arguments: ["-c", "test \"$(cat)\" = hello"],
        stdin: Data("hello".utf8),
        timeout: 5
    )
    // A silently-closed stdin would make `cat` read empty input, so `test`
    // would fail with a non-zero exit code — unlike the old version of this
    // test, which used /bin/cat directly and only checked the exit code, so
    // it passed even when no bytes ever arrived.
    #expect(result.exitCode == 0)
}

// Regression test: a hostile or broken SSH server could emit unbounded
// stderr, which the old readDataToEndOfFile() retained in full — exhausting
// memory. This asserts the retained text is capped, the child still exits
// normally (the pipe keeps draining rather than filling and blocking the
// child), and the call returns promptly instead of hanging.
@Test func capsRetainedStderrButStillDrainsAndExitsNormally() throws {
    let runner = SubprocessRunner()
    let start = Date()
    // 8 MiB of stderr output: comfortably larger than both the cap and the
    // kernel pipe buffer, so an implementation that stopped reading early
    // would leave the child blocked on a full pipe instead of exiting on
    // its own.
    let result = try runner.run(
        executable: "/bin/sh",
        arguments: ["-c", "head -c 8388608 /dev/zero | tr '\\0' 'x' >&2; exit 7"],
        stdin: nil,
        timeout: 10
    )
    #expect(result.exitCode == 7)
    #expect(result.stderr.utf8.count <= 64 * 1024 + 256)
    #expect(Date().timeIntervalSince(start) < 10)
}

@Test func timesOutWhenTheProcessNeverExits() throws {
    let runner = SubprocessRunner()
    let start = Date()
    #expect(throws: ProcessRunnerError.timedOut) {
        _ = try runner.run(executable: "/bin/sleep", arguments: ["30"], stdin: nil, timeout: 1)
    }
    #expect(Date().timeIntervalSince(start) < 5)
}

// Regression test for the critical bug: writing stdin synchronously before the
// poll loop starts. /bin/sleep never reads stdin, so a payload bigger than the
// kernel pipe buffer (~64KB) cannot be fully written. Before the fix this test
// hangs instead of failing cleanly.
@Test func timesOutWhenStdinCannotBeFullyWritten() throws {
    let runner = SubprocessRunner()
    let bigPayload = Data(repeating: 0x41, count: 1024 * 1024)
    let start = Date()
    #expect(throws: ProcessRunnerError.timedOut) {
        _ = try runner.run(executable: "/bin/sleep", arguments: ["30"], stdin: bigPayload, timeout: 1)
    }
    #expect(Date().timeIntervalSince(start) < 5)
}

// Covers the success path for the same size of payload: the child reads all
// of it before exiting. This exercises the join between the stdin queue and
// waitUntilExit and would catch a silent truncation that a timeout-only test
// cannot.
@Test func writesAPayloadLargerThanThePipeBufferInFull() throws {
    let runner = SubprocessRunner()
    let bigPayload = Data(repeating: 0x41, count: 1024 * 1024)
    let result = try runner.run(
        executable: "/bin/sh",
        arguments: ["-c", "test \"$(wc -c)\" -eq 1048576"],
        stdin: bigPayload,
        timeout: 20
    )
    #expect(result.exitCode == 0)
}

// Regression test: the deadline loop only bounds `process.isRunning`. Once
// the immediate child has exited, draining stderr to EOF previously had no
// deadline at all — if a DESCENDANT process inherited the stderr pipe's
// write end, the read never sees EOF and the call hangs forever, even
// though the child ssh (or ssh's own remote command) is long gone. This
// spawns a child that exits immediately while `sleep 30 &` keeps the
// inherited pipe open.
//
// The guarantee under test is not merely that `run` returns promptly — a
// prior version of this test only checked timing, which stayed green even
// if the descendant survived (closing the read end alone unblocks the
// drain). The descendant writes its own pid to a file so the test can
// assert, after `run` returns, that the pid is actually gone: `run`'s
// killpg reaches it because Foundation's Process places the child in a new
// process group of its own, so the descendant (still in that group) is
// killed along with it, not merely orphaned. A short poll allows for the
// kernel's asynchronous reparenting/reaping of the killed descendant; it is
// bounded well under the descendant's 30s lifetime so a regression fails
// outright instead of hanging the suite, and cleans up the descendant
// itself if the assertion is about to fail so no stray process is left.
@Test func returnsPromptlyAndReapsADescendantHoldingStderrOpenAfterTheChildExits() throws {
    let runner = SubprocessRunner()
    let pidFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipssh-descendant-pid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: pidFile) }

    let start = Date()
    let result = try runner.run(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 30 & echo $! > \(pidFile.path); exit 0"],
        stdin: nil,
        timeout: 3
    )
    #expect(result.exitCode == 0)
    #expect(Date().timeIntervalSince(start) < 10)

    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let descendantPID = pid_t(pidText) ?? 0
    #expect(descendantPID > 0)

    var stillAlive = true
    let pollDeadline = Date().addingTimeInterval(3)
    while Date() < pollDeadline {
        if kill(descendantPID, 0) != 0 && errno == ESRCH {
            stillAlive = false
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if stillAlive {
        kill(descendantPID, SIGKILL) // Don't leave a stray sleep behind even on failure.
    }
    #expect(!stillAlive)
}

// Regression test: a child that reads only part of stdin and then exits 0
// (e.g. ssh's remote command dying mid-transfer without a nonzero exit) must
// not be reported as success. `try?` around the stdin write previously
// discarded the resulting EPIPE, and the child's exitCode == 0 alone was
// treated as "the upload completed" — which would let the app copy a remote
// path pointing at a truncated image.
@Test func throwsWhenTheChildExitsBeforeReadingAllOfStdin() throws {
    let runner = SubprocessRunner()
    let bigPayload = Data(repeating: 0x41, count: 1024 * 1024)
    #expect(throws: (any Error).self) {
        _ = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 100 > /dev/null; exit 0"],
            stdin: bigPayload,
            timeout: 5
        )
    }
}
