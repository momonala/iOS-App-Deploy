import Foundation

/// Written by deploy-ios.sh after every successful install, next to a copy of the installed profile.
public struct InstallRecord: Codable, Sendable, Equatable {
    public let installedAt: Date
    public let commit: String
    public let subject: String?
    public let branch: String
    public let dirty: Bool
    public let device: String
    public let configuration: String
    public let durationSeconds: Int
    public let version: String?

    public static func load(from url: URL) throws -> InstallRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InstallRecord.self, from: Data(contentsOf: url))
    }
}

public enum InstalledFiles {
    public static let directory = URL.applicationSupportDirectory.appending(path: "Redeploy/installed")

    public static func profileURL(bundleId: String) -> URL {
        directory.appending(path: "\(bundleId).mobileprovision")
    }

    public static func recordURL(bundleId: String) -> URL {
        directory.appending(path: "\(bundleId).json")
    }
}
