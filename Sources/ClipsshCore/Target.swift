import Foundation

public struct Target: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    /// Either `host` or `user@host`. A bare host is resolved through ~/.ssh/config.
    public var destination: String
    public var port: Int?

    public init(id: UUID = UUID(), label: String, destination: String, port: Int? = nil) {
        self.id = id
        self.label = label
        self.destination = destination
        self.port = port
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var version: Int
    public var defaultTargetID: UUID?
    public var hotkey: String?
    public var targets: [Target]

    public init(version: Int = Config.currentVersion, defaultTargetID: UUID? = nil, hotkey: String? = nil, targets: [Target] = []) {
        self.version = version
        self.defaultTargetID = defaultTargetID
        self.hotkey = hotkey
        self.targets = targets
    }

    /// The schema version this build understands. TargetStore rejects a
    /// loaded file with a higher version rather than risk silently dropping
    /// fields a newer build wrote that this one does not know about.
    public static let currentVersion = 1

    public static let empty = Config()

    public var defaultTarget: Target? {
        guard let id = defaultTargetID else { return nil }
        return targets.first { $0.id == id }
    }
}
