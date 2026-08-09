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

    public static func build(
        config: Config,
        lastOutcome: SendOutcome?,
        configIsCorrupt: Bool,
        lastSaveError: String?,
        lastLoadWarning: String?,
        sshConfig: SSHConfigParser.Result?
    ) -> MenuModel {
        MenuModel(
            header: header(
                lastOutcome: lastOutcome,
                configIsCorrupt: configIsCorrupt,
                lastSaveError: lastSaveError,
                lastLoadWarning: lastLoadWarning
            ),
            targets: config.targets.map {
                TargetItem(id: $0.id, label: $0.label, isDefault: $0.id == config.defaultTargetID)
            },
            discoverable: discoverable(config: config, sshConfig: sshConfig),
            showsIncludeNote: sshConfig?.hasUnsupportedInclude ?? false
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
