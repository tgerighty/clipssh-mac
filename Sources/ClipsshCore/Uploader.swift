import Darwin
import Foundation

public enum UploadError: Error, Equatable {
    case noImageInClipboard
    case noTargetConfigured
    case keyUnavailable
    case hostKeyNotTrusted
    case timedOut(String)
    case remoteWriteFailed(String)
    case other(String)
    case invalidDestination

    public var message: String {
        switch self {
        case .noImageInClipboard:
            return "No image in clipboard — take a screenshot first"
        case .noTargetConfigured:
            return "No target configured"
        case .keyUnavailable:
            return "Key unavailable — run ssh-add"
        case .hostKeyNotTrusted:
            return "Host not trusted — connect once in Terminal first"
        case .timedOut(let label):
            return "\(label) unreachable (timed out)"
        case .remoteWriteFailed(let label):
            return "Cannot write to /tmp on \(label)"
        case .other(let text):
            return text
        case .invalidDestination:
            return "Invalid destination"
        }
    }
}

public struct Uploader {
    static let sshPath = "/usr/bin/ssh"
    static let watchdog: TimeInterval = 30

    private let runner: ProcessRunning

    public init(runner: ProcessRunning) {
        self.runner = runner
    }

    /// A GUI app has no terminal. BatchMode turns any prompt into an immediate
    /// error instead of a permanent hang. StrictHostKeyChecking=yes is forced
    /// on every invocation so an unknown host always fails rather than being
    /// silently trusted — this holds regardless of the user's own
    /// ~/.ssh/config (e.g. StrictHostKeyChecking=no or accept-new there would
    /// otherwise override it).
    ///
    /// The remaining options make every invocation binary-safe regardless of
    /// what the user's own ~/.ssh/config says: `-T` and `SessionType=default`
    /// stop `RequestTTY force`/`SessionType none` from corrupting the pipe or
    /// suppressing the session; `StdinNull=no` stops `StdinNull yes` from
    /// making ssh never read the PNG at all (the remote `cat` would still
    /// create an empty file and exit 0, so the app would report success over
    /// an empty image); `ForkAfterAuthentication=no` stops ssh from
    /// backgrounding before the pipe is done; `RemoteCommand=none` stops a
    /// configured `RemoteCommand` from replacing the command below.
    ///
    /// "--" immediately before the destination is defence in depth: it tells
    /// ssh to stop parsing options from that point on, so even a destination
    /// that slipped past `isValidDestination` cannot be read as an option
    /// (confirmed with `ssh -o BatchMode=yes -- -notahost true`, which reports
    /// an invalid *hostname* rather than an unknown option).
    public func sshArguments(for target: Target, command: String?) -> [String] {
        var args = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "StdinNull=no",
            "-o", "ForkAfterAuthentication=no",
            "-o", "RemoteCommand=none",
            "-o", "SessionType=default",
        ]
        if let port = target.port {
            args += ["-p", String(port)]
        }
        args.append("--")
        args.append(Self.sshDestination(target.destination))
        if let command {
            args.append(command)
        }
        return args
    }

    /// The stored/validated destination keeps brackets around an IPv6
    /// literal (`[::1]`, `user@[2001:db8::1]`) because that is what makes
    /// the grammar unambiguous. ssh itself, however, rejects that exact
    /// bracketed form as a hostname ("Could not resolve hostname [::1]") —
    /// it only accepts the bare literal on its own command line. So the
    /// brackets are stripped here, right before the value reaches ssh's
    /// argument list, preserving any `user@` prefix.
    static func sshDestination(_ destination: String) -> String {
        let parts = destination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPrefix: String
        let host: Substring
        if parts.count == 2 {
            userPrefix = "\(parts[0])@"
            host = parts[1]
        } else {
            userPrefix = ""
            host = parts[0]
        }
        guard host.hasPrefix("["), host.hasSuffix("]") else { return destination }
        return userPrefix + host.dropFirst().dropLast()
    }

    /// Allowlists a destination in the `[user@]host` form ssh itself accepts,
    /// rejecting everything else. This is stricter than blocking known-bad
    /// characters: OpenSSH expands `%h`/`%r` tokens into `ProxyCommand`,
    /// `LocalCommand` and `Match exec` directives in the user's own
    /// ~/.ssh/config, which achieves local command execution without ever
    /// being parsed as an ssh OPTION — so "--" alone does not stop it.
    /// OpenSSH only added hostname sanity checks for this class of bug in
    /// 9.6; macOS Ventura (macOS 13, which this app supports) ships 9.0.
    ///
    /// A leading "-" is rejected even though "-" is otherwise an allowed
    /// character, because ssh reads a leading "-" as an OPTION (e.g.
    /// "-oProxyCommand=..." runs an arbitrary LOCAL command) rather than as
    /// part of a hostname.
    public static func isValidDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty, !destination.hasPrefix("-") else { return false }

        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        let host: Substring
        switch parts.count {
        case 1:
            host = parts[0]
        case 2:
            let user = parts[0]
            guard !user.isEmpty, user.allSatisfy(isUserOrHostCharacter) else { return false }
            host = parts[1]
        default:
            return false // more than one "@" is not a valid [user@]host destination.
        }
        guard !host.isEmpty, !host.hasPrefix("-") else { return false }

        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return false }
            let literal = host.dropFirst().dropLast()
            guard !literal.isEmpty else { return false }
            // The character check is defence in depth, cheap to satisfy
            // before ever calling into libc. It alone is not sufficient —
            // "[a]", "[::::]" and "[1.2.3.999]" all pass it without being a
            // real IPv6 address — so the literal is also actually parsed.
            guard literal.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
            return isValidIPv6Literal(literal)
        }
        return host.allSatisfy(isUserOrHostCharacter)
    }

    /// The allowlisted alphabet for a username or a bare hostname/alias:
    /// ASCII letters, digits, ".", "_" and "-". Notably excludes "%", "$",
    /// ";", "|", backticks, quotes, "\", "," and any whitespace or control
    /// character.
    private static func isUserOrHostCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "." || character == "_" || character == "-")
    }

    /// Parses `literal` as an IPv6 address with `inet_pton`, rather than
    /// merely checking its characters. `inet_pton` returns 1 only for a
    /// syntactically valid address, so "a", "::::" and an IPv4-mapped octet
    /// out of range (e.g. "1.2.3.999") are all rejected even though every
    /// character in them is individually allowed.
    private static func isValidIPv6Literal(_ literal: Substring) -> Bool {
        var buffer = in6_addr()
        return String(literal).withCString { cString in
            inet_pton(AF_INET6, cString, &buffer) == 1
        }
    }

    @discardableResult
    public func upload(_ png: Data, to target: Target) throws -> String {
        guard Self.isValidDestination(target.destination) else { throw UploadError.invalidDestination }
        let filename = RemoteCommand.newFilename()
        let command = RemoteCommand.uploadCommand(filename: filename)
        try execute(arguments: sshArguments(for: target, command: command), stdin: png, target: target)
        return RemoteCommand.remotePath(filename: filename)
    }

    public func testConnection(_ target: Target) throws {
        guard Self.isValidDestination(target.destination) else { throw UploadError.invalidDestination }
        try execute(arguments: sshArguments(for: target, command: "true"), stdin: nil, target: target)
    }

    private func execute(arguments: [String], stdin: Data?, target: Target) throws {
        let result: ProcessResult
        do {
            result = try runner.run(
                executable: Self.sshPath,
                arguments: arguments,
                stdin: stdin,
                timeout: Self.watchdog
            )
        } catch ProcessRunnerError.timedOut {
            throw UploadError.timedOut(target.label)
        }

        guard result.exitCode != 0 else { return }
        throw Self.mapError(result: result, target: target)
    }

    /// Exit code 255 is ssh itself failing to connect or authenticate. Any other
    /// non-zero code came from the remote command.
    static func mapError(result: ProcessResult, target: Target) -> UploadError {
        guard result.exitCode == 255 else {
            return .remoteWriteFailed(target.label)
        }
        let stderr = result.stderr
        if stderr.contains("Host key verification failed") {
            return .hostKeyNotTrusted
        }
        if stderr.contains("Permission denied") {
            return .keyUnavailable
        }
        if stderr.contains("timed out") || stderr.contains("Connection timed out") {
            return .timedOut(target.label)
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // `LogLevel QUIET` in the user's ssh config can make ssh exit 255
        // with no stderr at all. An empty message would show the user
        // nothing, so fall back to a message that at least says what failed.
        return .other(trimmed.isEmpty ? "SSH connection failed" : trimmed)
    }
}
