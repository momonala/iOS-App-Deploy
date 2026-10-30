import Foundation

/// A value read off the phone, kept with the time it was read so the last good reading can be shown
/// while the phone is out of reach.
public struct Reading<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let readAt: Date
    public let value: Value

    public init(readAt: Date, value: Value) {
        self.readAt = readAt
        self.value = value
    }
}

/// One entry of `pymobiledevice3 provision list`.
public struct InstalledProfile: Codable, Sendable, Equatable {
    public let bundleId: String
    public let uuid: String
    public let creationDate: Date
    public let expirationDate: Date

    private struct Raw: Decodable {
        struct Entitlements: Decodable {
            let applicationIdentifier: String

            enum CodingKeys: String, CodingKey { case applicationIdentifier = "application-identifier" }
        }
        let UUID: String
        let CreationDate: String
        let ExpirationDate: String
        let Entitlements: Entitlements
    }

    public static func decode(_ json: Data) throws -> [InstalledProfile] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return try JSONDecoder().decode([Raw].self, from: json).compactMap { raw in
            guard let created = formatter.date(from: raw.CreationDate),
                  let expires = formatter.date(from: raw.ExpirationDate),
                  let dot = raw.Entitlements.applicationIdentifier.firstIndex(of: ".")
            else { return nil }
            return InstalledProfile(
                bundleId: String(raw.Entitlements.applicationIdentifier[dot...].dropFirst()),
                uuid: raw.UUID,
                creationDate: created,
                expirationDate: expires
            )
        }
    }
}

extension [InstalledProfile] {
    /// iOS keeps superseded profiles until they expire, so only the newest per bundle ID counts.
    public func newest(for bundleId: String) -> InstalledProfile? {
        filter { $0.bundleId == bundleId }.max { $0.creationDate < $1.creationDate }
    }

    /// The newest profile of each app extension under `bundleId`, by bundle ID.
    public func newestExtensions(of bundleId: String) -> [InstalledProfile] {
        Set(map(\.bundleId).filter { $0.hasPrefix(bundleId + ".") })
            .sorted()
            .compactMap { newest(for: $0) }
    }
}

/// A crash report on the phone, named `<executable>-yyyy-MM-dd-HHmmss.ips`.
public struct CrashReport: Codable, Sendable, Equatable {
    public let fileName: String
    public let process: String
    public let date: Date

    private struct Envelope: Decodable {
        struct Result: Decodable {
            struct File: Decodable { let name: String }
            let files: [File]
        }
        let result: Result
    }

    /// Reads `devicectl device info files --domain-type systemCrashLogs`, keeping reports from
    /// `processes`, newest first. File names carry the phone's local time.
    public static func decode(_ json: Data, processes: Set<String>, timeZone: TimeZone = .current) throws -> [CrashReport] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return try JSONDecoder().decode(Envelope.self, from: json).result.files.compactMap { file in
            guard let match = file.name.wholeMatch(of: #/(.+)-(\d{4}-\d{2}-\d{2}-\d{6})\.ips/#),
                  processes.contains(String(match.1)),
                  let date = formatter.date(from: String(match.2))
            else { return nil }
            return CrashReport(fileName: file.name, process: String(match.1), date: date)
        }
        .sorted { $0.date > $1.date }
    }
}
