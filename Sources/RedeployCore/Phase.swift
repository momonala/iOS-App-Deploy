import Foundation

public enum Phase: Equatable, Sendable {
    case idle
    case waitingForPhone
    case deploying(step: Int, total: Int, title: String, startedAt: Date)
    case failed(message: String, at: Date)

    public var isDeploying: Bool {
        if case .deploying = self { true } else { false }
    }

    /// A deploy in progress or a wait for the phone is live; anything else is redrawn from the saved failure.
    public func merging(persisted failure: Failure?) -> Phase {
        switch self {
        case .deploying, .waitingForPhone:
            self
        case .idle, .failed:
            if case .deployFailed(let message, let at) = failure { .failed(message: message, at: at) } else { .idle }
        }
    }
}
