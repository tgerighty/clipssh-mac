import Darwin
import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stderr: String

    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut
}

public protocol ProcessRunning: Sendable {
    func run(
        executable: String, arguments: [String], stdin: Data?, timeout: TimeInterval
    ) throws -> ProcessResult
}

/// Runs a real subprocess. No test uses this type.
public struct SubprocessRunner: ProcessRunning {
    /// An ssh error message never needs more than this; a hostile or broken
    /// server emitting unbounded stderr must not be retained past it.
    private static let stderrCapBytes = 64 * 1024

    public init() {}

    public func run(
        executable: String, arguments: [String], stdin: Data?, timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        // Without this, writing to the pipe after the child has exited (e.g. a
        // killed watchdog target) raises SIGPIPE and crashes this process
        // outright, instead of the write simply failing with EPIPE.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        try process.run()

        let stdinWriter = startWritingStdin(stdin, to: inputPipe)
        let drain = startDrainingStderr(errorPipe)

        let deadline = Date().addingTimeInterval(timeout)
        try waitForExitOrKill(process, deadline: deadline)

        process.waitUntilExit()
        reapStderrHolders(process: process, errorPipe: errorPipe, deadline: deadline, drain: drain)

        stdinWriter.queue.sync {}
        // A child that exits 0 after reading only part of stdin (e.g. its
        // remote command died mid-transfer without a nonzero exit) must not
        // be reported as success — the caller would otherwise treat a
        // truncated upload as complete. A nonzero exit already carries its
        // own, more specific error via exitCode/stderr, so it is left alone.
        if process.terminationStatus == 0, let failure = stdinWriter.failure.value {
            throw failure
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            // We deliberately use String(decoding:as:) rather than the failable
            // String(bytes:encoding:): ssh stderr may contain invalid UTF-8, and
            // lossy decoding is correct here. The failable initialiser would
            // return nil on invalid input and we would lose the error message
            // entirely, which is worse for the user.
            // swiftlint:disable:next optional_data_string_conversion
            stderr: String(decoding: drain.buffer.value, as: UTF8.self)
        )
    }

    /// Writes stdin on its own background queue. A clipboard PNG comfortably
    /// exceeds the kernel pipe buffer, so this write must never block the
    /// poll loop in `waitForExitOrKill` — that would defeat the watchdog
    /// entirely. Once the child is terminated (the timeout path), the write
    /// correctly fails with EPIPE and that is expected, so it is not
    /// surfaced there. On the normal-exit path, though, an incomplete write
    /// means the child got only part of its input, so that failure is
    /// recorded and checked once the child has exited.
    private func startWritingStdin(_ stdin: Data?, to pipe: Pipe) -> StdinWriter {
        let failure = UnsafeErrorBox()
        let queue = DispatchQueue(label: "clipssh.stdin")
        queue.async {
            if let stdin {
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: stdin)
                } catch {
                    failure.value = error
                }
            }
            try? pipe.fileHandleForWriting.close()
        }
        return StdinWriter(queue: queue, failure: failure)
    }

    /// Reads stderr on a background queue so a full pipe buffer cannot deadlock
    /// the wait in `run`. Reads in chunks and keeps only the first
    /// stderrCapBytes: a hostile or broken SSH server can emit unbounded
    /// output, and retaining all of it (the old readDataToEndOfFile())
    /// would exhaust memory. The pipe is drained to EOF regardless — never
    /// stopping early — because a full pipe would block the child process
    /// and reintroduce the hang class this runner exists to avoid.
    ///
    /// Progress is published to the buffer after every chunk (not just at
    /// the end) so that if the drain is later abandoned mid-flight (see
    /// `reapStderrHolders`), whatever was actually captured is not lost.
    private func startDrainingStderr(_ pipe: Pipe) -> StderrDrain {
        let errorData = UnsafeErrorBuffer()
        let drainSemaphore = DispatchSemaphore(value: 0)
        let stderrQueue = DispatchQueue(label: "clipssh.stderr")
        stderrQueue.async {
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            var totalRead = 0
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                totalRead += chunk.count
                if buffer.count < Self.stderrCapBytes {
                    buffer.append(chunk.prefix(Self.stderrCapBytes - buffer.count))
                }
                errorData.value = buffer
            }
            if totalRead > buffer.count {
                buffer.append(Data("\n…[truncated]".utf8))
            }
            errorData.value = buffer
            drainSemaphore.signal()
        }
        return StderrDrain(buffer: errorData, semaphore: drainSemaphore)
    }

    /// Polls until the process exits or `deadline` passes. On timeout, escalates
    /// terminate -> SIGKILL, reaps the child, and throws `.timedOut`.
    private func waitForExitOrKill(_ process: Process, deadline: Date) throws {
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return }
        process.terminate()
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // Not stdinQueue.sync — a blocked write is exactly what this path
        // handles, and it unblocks (with EPIPE) once the child is gone.
        process.waitUntilExit()
        throw ProcessRunnerError.timedOut
    }

    /// The child itself has exited, but if a DESCENDANT it spawned inherited
    /// the stderr pipe's write end (e.g. `sleep 30 &` before `exit 0`), the
    /// read loop in `startDrainingStderr` never sees EOF and would block
    /// forever — this is the same defect class as the stdin bug this runner
    /// already guards against, just one step later. Bound the wait by
    /// whatever remains of the overall watchdog deadline instead of waiting
    /// unboundedly.
    private func reapStderrHolders(process: Process, errorPipe: Pipe, deadline: Date, drain: StderrDrain) {
        let remaining = deadline.timeIntervalSinceNow
        guard drain.semaphore.wait(timeout: .now() + max(remaining, 0)) == .timedOut else { return }
        // The pipe is still being held open by something other than our
        // own child. Foundation's Process places each child in a new
        // process group of its own (pgid == the child's pid) — an
        // undocumented but long-standing trait of NSTask/Process on
        // Darwin, confirmed empirically for this exact Process/Pipe
        // configuration — so killpg on the child's pid also reaches a
        // descendant that inherited the pipe (e.g. a backgrounded
        // `sleep &`) and is still sitting in that same group. That
        // trait is not part of any documented contract, though, so the
        // return value is checked: if it ever fails (e.g. ESRCH — no
        // such process group), fall back to killing just the immediate
        // child so this path can never itself hang. Closing our own
        // read end then unblocks the read() the background queue is
        // blocked in regardless. Proceed with whatever stderr was
        // captured so far rather than waiting any longer.
        if killpg(process.processIdentifier, SIGKILL) != 0 {
            kill(process.processIdentifier, SIGKILL)
        }
        try? errorPipe.fileHandleForReading.close()
        _ = drain.semaphore.wait(timeout: .now() + 0.5)
    }
}

private struct StdinWriter {
    let queue: DispatchQueue
    let failure: UnsafeErrorBox
}

private struct StderrDrain {
    let buffer: UnsafeErrorBuffer
    let semaphore: DispatchSemaphore
}

private final class UnsafeErrorBuffer: @unchecked Sendable {
    var value = Data()
}

private final class UnsafeErrorBox: @unchecked Sendable {
    var value: Error?
}
