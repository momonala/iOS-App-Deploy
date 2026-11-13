import Foundation

public struct Config: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public let name: String
        public let udid: String
    }

    public struct App: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let repo: String
        public let project: String
        public let scheme: String
        public let bundleId: String

        public var repoURL: URL {
            URL(fileURLWithPath: (repo as NSString).expandingTildeInPath, isDirectory: true)
        }

        public var projectURL: URL { repoURL.appending(path: project) }

        /// The Release or Debug build, whichever deploy-ios.sh produced last.
        public var builtAppURL: URL {
            let products = repoURL.appending(path: "build/DerivedData-device/Build/Products")
            let builds = ["Release", "Debug"].map { products.appending(path: "\($0)-iphoneos/\(scheme).app") }
            func builtAt(_ app: URL) -> Date {
                (try? app.appending(path: "Info.plist").resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
            return builds.max { builtAt($0) < builtAt($1) } ?? builds[0]
        }
    }

    public let device: Device
    public let thresholdDays: Int
    public let apps: [App]

    public static func load(from url: URL) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }
}
