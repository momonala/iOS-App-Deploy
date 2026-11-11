/// What the model is busy with. A check or Deploy All is a batch; a single deploy can run on its own
/// or inside a batch, and at most one deploy runs at a time.
public enum Run: Equatable, Sendable {
    case idle
    case deploying(appID: String)
    case checking(deploying: String?)
    case deployingAll(deploying: String?)

    public enum Event: Equatable, Sendable {
        case check
        case deployAll
        case deploy(appID: String)
        case deployFinished
        case batchFinished
    }

    public var isChecking: Bool {
        switch self {
        case .checking, .deployingAll: true
        case .idle, .deploying: false
        }
    }

    public var isDeploying: Bool {
        switch self {
        case .deploying: true
        case .checking(let id), .deployingAll(let id): id != nil
        case .idle: false
        }
    }

    /// Nil when the event is refused.
    public func applying(_ event: Event) -> Run? {
        switch (event, self) {
        case (.check, .idle): .checking(deploying: nil)
        case (.check, .deploying(let id)): .checking(deploying: id)
        case (.check, _): nil

        case (.deployAll, .idle): .deployingAll(deploying: nil)
        case (.deployAll, _): nil

        case (.deploy(let id), .idle): .deploying(appID: id)
        case (.deploy(let id), .checking(nil)): .checking(deploying: id)
        case (.deploy(let id), .deployingAll(nil)): .deployingAll(deploying: id)
        case (.deploy, _): nil

        case (.deployFinished, .deploying), (.deployFinished, .idle): .idle
        case (.deployFinished, .checking): .checking(deploying: nil)
        case (.deployFinished, .deployingAll): .deployingAll(deploying: nil)

        case (.batchFinished, .checking(let id)), (.batchFinished, .deployingAll(let id)):
            id.map { .deploying(appID: $0) } ?? .idle
        case (.batchFinished, _): self
        }
    }
}
