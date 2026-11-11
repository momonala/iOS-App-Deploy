/// One source read off the phone: its last outcome, and whether a read is under way.
public enum SourceState<Last: Sendable>: Sendable {
    case idle(Last)
    case reading(Last)

    public var last: Last {
        switch self {
        case .idle(let last), .reading(let last): last
        }
    }

    public var isReading: Bool {
        if case .reading = self { true } else { false }
    }

    /// Nil while a read is already under way.
    public func beginning() -> SourceState? {
        isReading ? nil : .reading(last)
    }
}

extension SourceState: Equatable where Last: Equatable {}

public enum WiFiSync: Equatable, Sendable {
    case unknown
    case visible
    case notVisible
    case missingTool

    public init(batteryRead: Bool, profilesRead: Bool) {
        self = batteryRead && profilesRead ? .visible : .notVisible
    }

    public var problem: String? {
        switch self {
        case .unknown, .visible: nil
        case .notVisible: "Not visible to Wi-Fi sync right now"
        case .missingTool: "Needs pymobiledevice3: uv tool install pymobiledevice3"
        }
    }
}
