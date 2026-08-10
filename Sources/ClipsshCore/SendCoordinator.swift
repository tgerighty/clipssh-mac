import Foundation

public enum SendOutcome: Equatable {
    case sent(String)
    case failed(UploadError)
}

/// Owns the send flow and the target list. Contains no UI framework code, so it
/// is driven directly by tests.
///
/// `@unchecked Sendable`: every mutable stored property is one of the four
/// `_`-prefixed fields below, all `private`, and every read or write of them
/// goes through `withLock`/the `lock` guard. That invariant — no unguarded
/// stored property, ever — is what makes concurrent use of this class safe;
/// adding a new stored property without routing it through the lock silently
/// breaks it.
public final class SendCoordinator: @unchecked Sendable {
    private let store: TargetStore
    private let pasteboard: PasteboardReading
    private let uploader: Uploader

    // performSend() runs on a background queue (it can block for up to 30
    // seconds) while the menu reads these same properties on the main thread
    // every time it opens. The lock guards only the five fields below — it is
    // never held across uploader.upload/testConnection, so a send in flight
    // never freezes the menu; it only ever races briefly for a property read.
    private let lock = NSLock()
    private var _config: Config = .empty
    private var _lastOutcome: SendOutcome?
    private var _configIsCorrupt = false
    private var _lastSaveError: String?
    private var _lastLoadWarning: String?

    public var config: Config {
        withLock { _config }
    }
    public var lastOutcome: SendOutcome? {
        withLock { _lastOutcome }
    }
    /// True when a config file exists but could not be parsed.
    public var configIsCorrupt: Bool {
        withLock { _configIsCorrupt }
    }
    /// Set when the most recent save attempt failed; nil after a successful save.
    public var lastSaveError: String? {
        withLock { _lastSaveError }
    }
    /// Set when the config file was loaded but its permissions were looser
    /// than 0600 and TargetStore could not tighten them. Nil once the file is
    /// tight, or before the first load completes.
    public var lastLoadWarning: String? {
        withLock { _lastLoadWarning }
    }

    public init(store: TargetStore, pasteboard: PasteboardReading, uploader: Uploader) {
        self.store = store
        self.pasteboard = pasteboard
        self.uploader = uploader
        reloadConfig()
    }

    func reloadConfig() {
        do {
            let loaded = try store.load()
            withLock {
                _config = loaded
                _configIsCorrupt = false
                _lastLoadWarning = store.lastLoadWarning
            }
            importAliasesOnFirstRun()
        } catch {
            // Never overwrite a file that could not be read.
            withLock {
                _config = .empty
                _configIsCorrupt = true
                _lastLoadWarning = nil
            }
        }
    }

    /// Synchronous by design. The app layer runs this off the main thread.
    @discardableResult
    public func performSend() -> SendOutcome {
        let outcome = attemptSend()
        withLock { _lastOutcome = outcome }
        if case .sent(let path) = outcome {
            pasteboard.write(string: path)
        }
        return outcome
    }

    private func attemptSend() -> SendOutcome {
        guard let png = pasteboard.pngData() else { return .failed(.noImageInClipboard) }
        guard let target = withLock({ _config.defaultTarget }) else { return .failed(.noTargetConfigured) }
        do {
            // Not locked: this can block for up to Uploader.watchdog (30s), and
            // holding the lock across it would freeze menu reads instead of
            // merely racing with them.
            return .sent(try uploader.upload(png, to: target))
        } catch let error as UploadError {
            return .failed(error)
        } catch {
            return .failed(.other(error.localizedDescription))
        }
    }

    public func copyLastPath() {
        guard case .sent(let path) = withLock({ _lastOutcome }) else { return }
        pasteboard.write(string: path)
    }

    /// Each mutator below reads `_config`, changes it and calls `apply` inside
    /// one `withLock` call, so the whole read-modify-write is a single atomic
    /// critical section — two concurrent calls can no longer race between the
    /// read and the write and lose one of them. `apply`/`backUpCorruptFile`
    /// touch `_config`/`_configIsCorrupt`/`_lastSaveError` directly (not
    /// through `withLock`) because the lock is not recursive: they only ever
    /// run from inside a `withLock` block already, and taking it again here
    /// would deadlock. `store.save` is a local file write, not the 30-second
    /// network call `uploader.upload`/`testConnection` make, so holding the
    /// lock across it does not risk freezing the menu the way holding it
    /// across an upload would.
    @discardableResult
    public func addTarget(destination: String, label: String? = nil) -> Target {
        let target = Target(label: label ?? destination, destination: destination)
        withLock {
            var updated = _config
            updated.targets.append(target)
            if updated.defaultTargetID == nil {
                updated.defaultTargetID = target.id
            }
            apply(updated)
        }
        return target
    }

    public func setDefault(_ target: Target) {
        withLock {
            var updated = _config
            updated.defaultTargetID = target.id
            apply(updated)
        }
    }

    public func removeTarget(_ target: Target) {
        withLock {
            var updated = _config
            updated.targets.removeAll { $0.id == target.id }
            if updated.defaultTargetID == target.id {
                updated.defaultTargetID = updated.targets.first?.id
            }
            apply(updated)
        }
    }

    public func updateTarget(_ target: Target) {
        withLock {
            var updated = _config
            guard let index = updated.targets.firstIndex(where: { $0.id == target.id }) else { return }
            updated.targets[index] = target
            apply(updated)
        }
    }

    public func setHotkey(_ spec: String?) {
        withLock {
            var updated = _config
            updated.hotkey = spec
            apply(updated)
        }
    }

    /// Returns a message for the Targets window. Blocks for up to the connect
    /// timeout, so the caller runs it off the main thread.
    public func testConnection(_ target: Target) -> String {
        do {
            // Not locked, for the same reason as attemptSend()'s upload call.
            try uploader.testConnection(target)
            return "Connected to \(target.label)"
        } catch let error as UploadError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Caller must already hold `lock` — see the comment on the mutators above.
    private func apply(_ newConfig: Config) {
        if _configIsCorrupt {
            // Preserve the unreadable file before the first save that follows a
            // corrupt load. If it cannot be preserved, do not save — that would
            // silently destroy bytes the user might still recover by hand.
            guard backUpCorruptFile() else { return }
            _configIsCorrupt = false
        }
        _config = newConfig
        // A save failure must not lose the in-memory change the user just made.
        do {
            try store.save(newConfig)
            _lastSaveError = nil
        } catch {
            _lastSaveError = error.localizedDescription
        }
    }

    /// Moves the unreadable config file aside to a `.corrupt` sibling, without
    /// ever clobbering an earlier backup. Returns false if the file could not
    /// be preserved.
    ///
    /// Attempts the move directly and retries on the next suffix only when it
    /// fails because that path already exists, rather than checking
    /// `fileExists` first and then moving: a separate check-then-move leaves
    /// a window where another process (or a second coordinator instance on
    /// the same config directory) can create the backup path in between,
    /// which would otherwise fail the whole backup instead of trying the
    /// next free suffix.
    ///
    /// Caller must already hold `lock` — see the comment on the mutators above.
    private func backUpCorruptFile() -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: store.configURL.path) else { return true }

        let maxAttempts = 1000
        for suffix in 0..<maxAttempts {
            let backupPath = suffix == 0
                ? store.configURL.path + ".corrupt"
                : store.configURL.path + ".corrupt.\(suffix)"
            do {
                try fileManager.moveItem(at: store.configURL, to: URL(fileURLWithPath: backupPath))
                return true
            } catch {
                let nsError = error as NSError
                let alreadyExists = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError
                guard alreadyExists else {
                    _lastSaveError = "Could not back up corrupt config: \(error.localizedDescription)"
                    return false
                }
            }
        }
        _lastSaveError = "Could not back up corrupt config: too many existing backups"
        return false
    }

    /// Runs once, when no config file has been written yet. A user who deletes
    /// an imported target must not see it return on the next launch.
    private func importAliasesOnFirstRun() {
        guard !FileManager.default.fileExists(atPath: store.configURL.path) else { return }
        let imported = store.importedAliases()
        guard !imported.isEmpty else { return }
        withLock {
            var updated = _config
            updated.targets = imported
            updated.defaultTargetID = imported.first?.id
            apply(updated)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
