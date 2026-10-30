import Foundation

public enum Policy {
    public static let urgentInterval: TimeInterval = 24 * 3600

    /// Nil when nothing is installed, which is due straight away.
    public static func deployDueAt(expiresAt: Date?, thresholdDays: Int) -> Date? {
        expiresAt?.addingTimeInterval(-TimeInterval(thresholdDays) * 86400)
    }

    public static func needsDeploy(expiresAt: Date?, now: Date, thresholdDays: Int) -> Bool {
        guard let due = deployDueAt(expiresAt: expiresAt, thresholdDays: thresholdDays) else { return true }
        return due <= now
    }

    public static func isUrgent(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= urgentInterval
    }

    public static func automaticCheckDue(lastSuccess: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastSuccess else { return true }
        return !calendar.isDate(lastSuccess, inSameDayAs: now)
    }

    /// "4d 23h 12m", or "Expired" once the date has passed.
    public static func remainingText(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "Expired" }
        return "\(seconds / 86400)d \(seconds % 86400 / 3600)h \(seconds % 3600 / 60)m"
    }

    /// "1m 52s" or "48s".
    public static func durationText(seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
