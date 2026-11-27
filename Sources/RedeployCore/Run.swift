/// What the model is busy with. A check or Deploy All is a batch; deploys run on their own or inside
/// a batch, several at once, but never two of the same app.
public struct Run: Equatable, Sendable {
    public enum Batch: Equatable, Sendable {
        case check, deployAll
    }

    public private(set) var batch: Batch?
    public private(set) var deploying: Set<String>

    public init(batch: Batch? = nil, deploying: Set<String> = []) {
        self.batch = batch
        self.deploying = deploying
    }

    public static let idle = Run()

    public enum Event: Equatable, Sendable {
        case check
        case deployAll
        case deploy(appID: String)
        case deployFinished(appID: String)
        case batchFinished
    }

    public var isChecking: Bool { batch != nil }
    public var isDeploying: Bool { !deploying.isEmpty }

    /// Nil when the event is refused.
    public func applying(_ event: Event) -> Run? {
        var next = self
        switch event {
        case .check:
            guard batch == nil else { return nil }
            next.batch = .check
        case .deployAll:
            guard self == .idle else { return nil }
            next.batch = .deployAll
        case .deploy(let id):
            guard next.deploying.insert(id).inserted else { return nil }
        case .deployFinished(let id):
            next.deploying.remove(id)
        case .batchFinished:
            next.batch = nil
        }
        return next
    }
}
