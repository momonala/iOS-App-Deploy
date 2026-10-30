import Foundation

public struct RunState: Codable, Sendable, Equatable {
    public var lastError: String?
    public var lastErrorAt: Date?
    public var lastLog: String?
    public var failureNotified = false
    public var urgentNotifiedExpiry: Date?

    public init() {}
}

public struct PersistedState: Codable, Sendable, Equatable {
    public var lastCheck: Date?
    public var lastSuccessfulCheck: Date?
    public var apps: [String: RunState] = [:]
    public var battery: BatterySnapshot?
    public var installedProfiles: Reading<[InstalledProfile]>?
    public var crashes: Reading<[CrashReport]>?

    public init() {}
}

public struct StateStore: Sendable {
    public let url: URL

    public init(url: URL = URL.applicationSupportDirectory.appending(path: "Redeploy/state.json")) {
        self.url = url
    }

    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return PersistedState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    public func save(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
