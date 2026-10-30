import Foundation
import RedeployCore

enum Paths {
    /// build.sh writes the repo location into Info.plist, since the app runs from ~/Applications.
    static let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "RedeployRoot") as? String
        ?? "\(NSHomeDirectory())/code/projects/iOS-App-Deploy")
    static let config = root.appending(path: "config.json")
    static let deployScript = root.appending(path: "scripts/deploy-ios.sh")
    static let logs = URL.libraryDirectory.appending(path: "Logs/Redeploy")
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    static let pymobiledevice3 = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/bin/pymobiledevice3")

    static func newLog(for appID: String, at date: Date = .now) -> URL {
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return logs.appending(path: "\(appID)-\(formatter.string(from: date)).log")
    }

    static func pruneLogs(for appID: String, keep: Int = 10) {
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? []
        let mine = files.filter { $0.lastPathComponent.hasPrefix("\(appID)-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in mine.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    static let crashes = logs.appending(path: "Crashes")

    static func icon(for app: Config.App) -> URL? {
        let url = app.builtAppURL.appending(path: "AppIcon60x60@2x.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Crash reports are named after the executable, so this covers the app and its extensions.
    static func executables(for app: Config.App) -> [String] {
        func executable(_ bundle: URL) -> String? {
            NSDictionary(contentsOf: bundle.appending(path: "Info.plist"))?["CFBundleExecutable"] as? String
        }
        let plugins = (try? FileManager.default.contentsOfDirectory(
            at: app.builtAppURL.appending(path: "PlugIns"), includingPropertiesForKeys: nil
        )) ?? []
        return [executable(app.builtAppURL) ?? app.scheme] + plugins.compactMap(executable)
    }
}
