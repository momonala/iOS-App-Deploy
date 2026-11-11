import Foundation

public struct RunState: Codable, Sendable, Equatable {
    public var lastLog: String?
    public var health: AppHealth

    public init(lastLog: String? = nil, health: AppHealth = .healthy) {
        self.lastLog = lastLog
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case lastError, lastErrorAt, lastLog, failureNotified, urgentNotifiedExpiry
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastLog = try container.decodeIfPresent(String.self, forKey: .lastLog)
        let failure: Failure? = if let message = try container.decodeIfPresent(String.self, forKey: .lastError) {
            .deployFailed(message: message, at: try container.decodeIfPresent(Date.self, forKey: .lastErrorAt) ?? .now)
        } else if try container.decodeIfPresent(Bool.self, forKey: .failureNotified) == true {
            .phoneUnreachable
        } else {
            nil
        }
        health = if let expiry = try container.decodeIfPresent(Date.self, forKey: .urgentNotifiedExpiry) {
            .urgent(notifiedExpiry: expiry, failure: failure)
        } else {
            failure.map(AppHealth.failing) ?? .healthy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(lastLog, forKey: .lastLog)
        if case .deployFailed(let message, let at) = health.failure {
            try container.encode(message, forKey: .lastError)
            try container.encode(at, forKey: .lastErrorAt)
        }
        try container.encode(health.failure != nil, forKey: .failureNotified)
        try container.encodeIfPresent(health.urgentNotifiedExpiry, forKey: .urgentNotifiedExpiry)
    }
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
