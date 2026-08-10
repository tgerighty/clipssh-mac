import Foundation

/// Decides what the menu contains. Pure: no AppKit, no file access, no clock.
public struct MenuModel: Equatable {
    public enum Header: Equatable {
        case none
        case corruptConfig
        case saveFailed(String)
        case permissionWarning(String)
        case lastPath(String)
        case lastError(String)
    }

    public struct TargetItem: Equatable {
        public let id: UUID
        public let label: String
        public let isDefault: Bool
    }

    public var header: Header
    public var targets: [TargetItem]
    public var discoverable: [String]
    public var showsIncludeNote: Bool

    /// Groups the inputs to `build(_:)` — introduced so that function stays
    /// at a single, readable parameter.
    public struct Input {
        public var config: Config
        public var lastOutcome: SendOutcome?
        public var configIsCorrupt: Bool
        public var lastSaveError: String?
        public var lastLoadWarning: String?
        public var sshConfig: SSHConfigParser.Result?

        public init(
            config: Config,
            lastOutcome: SendOutcome? = nil,
            configIsCorrupt: Bool = false,
            lastSaveError: String? = nil,
            lastLoadWarning: String? = nil,
            sshConfig: SSHConfigParser.Result? = nil
        ) {
            self.config = config
            self.lastOutcome = lastOutcome
            self.configIsCorrupt = configIsCorrupt
            self.lastSaveError = lastSaveError
            self.lastLoadWarning = lastLoadWarning
            self.sshConfig = sshConfig
        }
    }

    public static func build(_ input: Input) -> MenuModel {
        MenuModel(
            header: header(
                lastOutcome: input.lastOutcome,
                configIsCorrupt: input.configIsCorrupt,
                lastSaveError: input.lastSaveError,
                lastLoadWarning: input.lastLoadWarning
            ),
            targets: input.config.targets.map {
                TargetItem(id: $0.id, label: $0.label, isDefault: $0.id == input.config.defaultTargetID)
            },
            discoverable: discoverable(config: input.config, sshConfig: input.sshConfig),
            showsIncludeNote: input.sshConfig?.hasUnsupportedInclude ?? false
        )
    }

    private static func header(
        lastOutcome: SendOutcome?,
        configIsCorrupt: Bool,
        lastSaveError: String?,
        lastLoadWarning: String?
    ) -> Header {
        // An unreadable config outranks everything. A failed save outranks the
        // last send, because otherwise the user believes a change persisted
        // when it did not, and it silently reverts on the next launch. A
        // permission warning outranks the last send too, but not a save
        // failure, which is about the change the user just made.
        if configIsCorrupt { return .corruptConfig }
        if let lastSaveError { return .saveFailed(lastSaveError) }
        if let lastLoadWarning { return .permissionWarning(lastLoadWarning) }
        switch lastOutcome {
        case .none: return .none
        case .sent(let path): return .lastPath(path)
        case .failed(let error): return .lastError(error.message)
        }
    }

    private static func discoverable(config: Config, sshConfig: SSHConfigParser.Result?) -> [String] {
        guard let sshConfig else { return [] }
        // A host is "already added" when it is some target's destination. The
        // label is free text and cannot be used for this.
        let existing = Set(config.targets.map(\.destination))
        return sshConfig.hosts.filter { !existing.contains($0) }.sorted()
    }
}
