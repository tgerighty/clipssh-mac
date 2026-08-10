import Foundation
import Testing
@testable import ClipsshCore

private final class FakePasteboard: PasteboardReading {
    var image: Data?

    init(image: Data? = Data([0x89, 0x50, 0x4E, 0x47])) {
        self.image = image
    }

    func pngData() -> Data? { image }
    func write(string: String) {}
}

private final class StubRunner: ProcessRunning, @unchecked Sendable {
    var result = ProcessResult(exitCode: 0, stderr: "")

    func run(executable: String, arguments: [String], stdin: Data?, timeout: TimeInterval) throws -> ProcessResult {
        result
    }
}

/// Reproduces the app's real access pattern: SendController calls performSend()
/// on a background queue while MenuRenderer reads config/lastOutcome/
/// configIsCorrupt/lastSaveError on the main queue every time the menu opens.
/// Neither side waits for the other, so this is a genuine race, not a timing
/// coincidence. ThreadSanitizer cannot confirm that on this machine: Apple's
/// `xctest` strips `DYLD_INSERT_LIBRARIES`, so TSan's interceptors never
/// install and it silently detects nothing, even for a deliberately planted
/// race. Its absence of a report is therefore not evidence of absence — this
/// test instead pins the end state under real concurrent access (see the
/// assertions after `done.wait` below) so a regression here fails loudly.
@Test func concurrentSendAndMenuReadsDoNotRace() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = SendCoordinator(
        store: TargetStore(directory: directory),
        pasteboard: FakePasteboard(),
        uploader: Uploader(runner: StubRunner())
    )
    coordinator.addTarget(destination: "box.example.com")

    let iterations = 500
    let start = DispatchSemaphore(value: 0)
    // Signalled once the writer's loop finishes. performSend() does far more
    // work per call than a single property read, so a reader with a matching
    // fixed iteration count would finish almost immediately and never
    // overlap the writer; spinning until this fires keeps the reader running
    // for the writer's entire lifetime instead.
    let writerFinished = DispatchSemaphore(value: 0)
    let done = DispatchGroup()

    let writer = Thread {
        start.wait()
        for _ in 0..<iterations {
            coordinator.performSend()
        }
        writerFinished.signal()
        done.leave()
    }
    // Safety net for the reader loop below: if the writer thread blocks or
    // crashes and never signals writerFinished, the done.wait timeout still
    // fails the test, but without this deadline the reader would spin a CPU
    // core reading properties for the rest of the process's life. 10 seconds
    // comfortably exceeds the writer's expected runtime on any machine, and
    // it must stay below the done.wait timeout below so the reader thread
    // never outlives the test body and the scratch-directory teardown.
    let readerDeadline = Date().addingTimeInterval(10)
    let reader = Thread {
        start.wait()
        // Check the "writer is done" flag only once per burst — checking a
        // semaphore on every single iteration turns each iteration into a
        // kernel call, which starves out the actual property reads this test
        // needs to overlap the writer.
        while writerFinished.wait(timeout: .now()) == .timedOut && Date() < readerDeadline {
            for _ in 0..<500 {
                _ = coordinator.config.targets.count
                _ = coordinator.lastOutcome
                _ = coordinator.configIsCorrupt
                _ = coordinator.lastSaveError
            }
        }
        done.leave()
    }

    done.enter()
    done.enter()
    writer.start()
    reader.start()
    // Release both threads at (as close as possible to) the same instant, so
    // they genuinely overlap instead of running back-to-back.
    start.signal()
    start.signal()

    // Bounded wait so a real hang (e.g. a future deadlock in a lock-based fix)
    // fails the test instead of hanging the suite.
    let outcome = done.wait(timeout: .now() + 15)
    #expect(outcome == .success)
    guard outcome == .success else { return }

    // The end state, not just "no crash": exactly the one target added
    // before the race started, a config no reader ever saw as corrupt, and
    // the writer's last call landing as a successful send.
    #expect(coordinator.config.targets.count == 1)
    #expect(coordinator.configIsCorrupt == false)
    guard case .sent = coordinator.lastOutcome else {
        Issue.record("expected a final .sent outcome, got \(String(describing: coordinator.lastOutcome))")
        return
    }
}

/// addTarget (and setDefault/removeTarget/updateTarget/setHotkey) each used to
/// read `_config` under the lock, release it, mutate a copy, then save — a
/// classic read-modify-write race. Two concurrent `addTarget` calls could
/// interleave between the read and the write and lose one target entirely.
/// This pins that ALL concurrent adds survive; before the fix, this test
/// flakes (fewer than `concurrentAdds` targets end up stored).
@Test func concurrentAddTargetCallsLoseNone() {
    let directory = makeTempDir()
    defer { try? FileManager.default.removeItem(at: directory) }

    let coordinator = SendCoordinator(
        store: TargetStore(directory: directory),
        pasteboard: FakePasteboard(),
        uploader: Uploader(runner: StubRunner())
    )

    let concurrentAdds = 100
    let done = DispatchGroup()
    // `i` is a plain loop counter used only to build a unique hostname below;
    // a longer name would add nothing. Judged as noise for this codebase.
    // swiftlint:disable:next identifier_name
    for i in 0..<concurrentAdds {
        done.enter()
        DispatchQueue.global().async {
            coordinator.addTarget(destination: "host\(i).example.com")
            done.leave()
        }
    }

    // Bounded wait so a deadlock regression fails the test instead of hanging
    // the suite.
    let outcome = done.wait(timeout: .now() + 15)
    #expect(outcome == .success)
    guard outcome == .success else { return }

    #expect(coordinator.config.targets.count == concurrentAdds)
    let uniqueDestinations = Set(coordinator.config.targets.map(\.destination))
    #expect(uniqueDestinations.count == concurrentAdds)
}
