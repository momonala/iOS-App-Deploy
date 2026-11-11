import Foundation

public enum Failure: Equatable, Sendable {
    case phoneUnreachable
    case deployFailed(message: String, at: Date)
}

/// Each failure run and each urgent expiry is announced once; a successful deploy starts over.
public enum AppHealth: Equatable, Sendable {
    case healthy
    case failing(Failure)
    case urgent(notifiedExpiry: Date, failure: Failure?)

    public enum Event: Equatable, Sendable {
        case deploySucceeded
        case deployFailed(message: String, at: Date)
        case phoneUnreachable
        case expiryChecked(expiresAt: Date, now: Date)
    }

    public var failure: Failure? {
        switch self {
        case .healthy: nil
        case .failing(let failure): failure
        case .urgent(_, let failure): failure
        }
    }

    public var urgentNotifiedExpiry: Date? {
        if case .urgent(let expiry, _) = self { expiry } else { nil }
    }

    public func applying(_ event: Event) -> (health: AppHealth, notify: Bool) {
        switch event {
        case .deploySucceeded:
            return (.healthy, false)
        case .deployFailed(let message, let at):
            return (with(failure: .deployFailed(message: message, at: at)), failure == nil)
        case .phoneUnreachable:
            guard failure == nil else { return (self, false) }
            return (with(failure: .phoneUnreachable), true)
        case .expiryChecked(let expiresAt, let now):
            guard Policy.isUrgent(expiresAt: expiresAt, now: now), urgentNotifiedExpiry != expiresAt else {
                return (self, false)
            }
            return (.urgent(notifiedExpiry: expiresAt, failure: failure), true)
        }
    }

    private func with(failure: Failure) -> AppHealth {
        urgentNotifiedExpiry.map { .urgent(notifiedExpiry: $0, failure: failure) } ?? .failing(failure)
    }
}
