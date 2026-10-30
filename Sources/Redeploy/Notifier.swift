import Foundation
@preconcurrency import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private enum Key {
        static let failureCategory = "failure"
        static let retryAction = "retry"
        static let openLogAction = "openLog"
        static let appID = "appID"
        static let log = "log"
    }

    var onRetry: (String) -> Void = { _ in }
    var onOpenLog: (URL) -> Void = { _ in }

    private let center = UNUserNotificationCenter.current()

    func setUp() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Key.failureCategory,
                actions: [
                    UNNotificationAction(identifier: Key.retryAction, title: "Retry"),
                    UNNotificationAction(identifier: Key.openLogAction, title: "Open log"),
                ],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, appID: String, log: URL?, icon: URL?, isFailure: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isFailure ? .default : nil
        content.userInfo = [Key.appID: appID, Key.log: log?.path ?? ""]
        if isFailure { content.categoryIdentifier = Key.failureCategory }
        if let attachment = icon.flatMap(Self.attachment) { content.attachments = [attachment] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// The system takes ownership of an attachment's file, so it gets a throwaway copy.
    private static func attachment(for icon: URL) -> UNNotificationAttachment? {
        let copy = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: icon, to: copy)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icon", url: copy)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let appID = info[Key.appID] as? String ?? ""
        let log = (info[Key.log] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Key.retryAction {
                onRetry(appID)
            } else if let log {
                onOpenLog(log)
            }
        }
    }
}
