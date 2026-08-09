import Foundation

public struct SSHConfigParser {
    public struct Result: Equatable, Sendable {
        public var hosts: [String]
        public var hasUnsupportedInclude: Bool

        public init(hosts: [String], hasUnsupportedInclude: Bool) {
            self.hosts = hosts
            self.hasUnsupportedInclude = hasUnsupportedInclude
        }
    }

    public static func parse(_ text: String) -> Result {
        var hosts: [String] = []
        var seen: Set<String> = []
        var hasInclude = false

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            // `\r\n` is a single Swift Character (grapheme cluster), so a plain
            // "\n" separator would not split it and a trailing `\r` would leak
            // into the host name. `isNewline` treats CRLF as one boundary.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                .prefix { !$0.hasPrefix("#") }
            guard let keyword = words.first?.lowercased() else { continue }

            if keyword == "include" {
                // Include is not supported. The menu shows a note instead.
                hasInclude = true
                continue
            }
            guard keyword == "host" else { continue }

            for name in words.dropFirst().map(String.init) {
                guard isConnectable(name), seen.insert(name).inserted else { continue }
                hosts.append(name)
            }
        }
        return Result(hosts: hosts, hasUnsupportedInclude: hasInclude)
    }

    /// A pattern is not a host you can connect to.
    private static func isConnectable(_ name: String) -> Bool {
        !name.contains("*") && !name.contains("?") && !name.hasPrefix("!")
    }
}
