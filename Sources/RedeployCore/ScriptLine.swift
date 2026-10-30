import Foundation

/// The lines of deploy-ios.sh output the app reacts to. The script prints `[n/N] Title` per step and
/// `error <message>` when it dies; everything else only goes to the log.
public enum ScriptLine: Equatable, Sendable {
    case step(index: Int, total: Int, title: String)
    case error(String)
    case other

    public init(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if let match = line.wholeMatch(of: #/\[(\d+)/(\d+)\] (.+)/#),
           let index = Int(match.1), let total = Int(match.2) {
            self = .step(index: index, total: total, title: String(match.3))
        } else if let match = line.wholeMatch(of: #/error (.+)/#) {
            self = .error(String(match.1))
        } else {
            self = .other
        }
    }
}
