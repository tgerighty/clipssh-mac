import Foundation
import Testing
@testable import ClipsshCore

final class FakeRunner: ProcessRunning, @unchecked Sendable {
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

let uploaderTestTarget = Target(label: "box", destination: "box.example.com")
