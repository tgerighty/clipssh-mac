import Foundation

public enum StoreError: Error, Equatable {
    case corrupt
}

public final class TargetStore {
    public let configURL: URL
    private let aliasesURL: URL
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        self.configURL = directory.appendingPathComponent("clipssh-mac.json")
        self.aliasesURL = directory.appendingPathComponent("aliases")
    }

    /// The config directory. CLIPSSH_MAC_CONFIG_DIR overrides it, which lets the
    /// UI tests run against a scratch directory and lets a user keep config
    /// somewhere else.
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLIPSSH_MAC_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clipssh")
    }

    /// Set when tightening a loose config file's permissions on `load` fails.
    /// Never fails the load itself — the config is still returned.
    public private(set) var lastLoadWarning: String?

    public func load() throws -> Config {
        lastLoadWarning = nil
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain,
                  nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError else {
                // A permission or I/O error is not "no config yet". Propagate
                // it so the caller treats it like the corrupt case and never
                // overwrites a file it could not read.
                throw error
            }
            return .empty
        }
        // The file may already exist from an older version, a restore, or a
        // manual edit with permissions looser than `save` ever writes. It
        // holds the hosts the user connects to, so tighten it here too rather
        // than waiting for the next mutation.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path),
           let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value,
           perms & ~UInt16(0o600) != 0 {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            } catch {
                lastLoadWarning = "Could not tighten config file permissions: \(error.localizedDescription)"
            }
        }
        let decoded: Config
        do {
            decoded = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            // Never overwrite or delete here. The caller decides what to do.
            throw StoreError.corrupt
        }
        // A version newer than this build understands means a future build
        // wrote fields this one does not know about. Treat it like the
        // corrupt case: never overwrite the file, or those fields are lost
        // the moment this build next saves.
        guard decoded.version <= Config.currentVersion else {
            throw StoreError.corrupt
        }
        return decoded
    }

    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory only applies the attributes when it creates the
        // directory. If it already existed (e.g. created by the CLI) with a
        // looser mode, that mode survives unless tightened explicitly.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        // Write with 0600 already applied, then rename over the previous
        // config, so the file holding SSH usernames and hostnames is never
        // briefly readable at the default (world-readable) mode.
        let staging = directory.appendingPathComponent("clipssh-mac.json.tmp-\(UUID().uuidString)")
        // If anything below fails (e.g. an immutable destination file), the
        // staging file must not be left behind — repeated failures would
        // otherwise accumulate them in the config directory. On the success
        // path replaceItemAt has already consumed/renamed it away, so this
        // is a no-op then.
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(
            atPath: staging.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // .usingNewMetadataOnly: without it, replaceItemAt preserves the
        // *original* file's permissions instead of the staged file's 0600,
        // which would silently undo the point of staging with the right
        // mode in the first place.
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: staging, options: .usingNewMetadataOnly)
    }

    /// Reads the CLI's alias file. Read only — the CLI keeps ownership of it.
    public func importedAliases() -> [Target] {
        guard let text = try? String(contentsOf: aliasesURL, encoding: .utf8) else { return [] }
        // `\.isNewline` (not `separator: "\n"`) because Swift treats "\r\n"
        // as a single Character: splitting on a bare "\n" never matches
        // inside a CRLF file, so the whole file comes back as one line.
        return text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else { return nil }
            let name = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !destination.isEmpty else { return nil }
            return Target(label: name, destination: destination)
        }
    }
}
