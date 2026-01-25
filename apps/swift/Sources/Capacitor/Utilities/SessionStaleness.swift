import Foundation

enum SessionStaleness {
    static let readyStaleThreshold: TimeInterval = 86400

    static func isReadyStale(state: SessionState?, stateChangedAt: String?, now: Date = Date()) -> Bool {
        guard state == .ready,
              let stateChangedAt,
              let date = parseISO8601Date(stateChangedAt)
        else {
            return false
        }
        return now.timeIntervalSince(date) > readyStaleThreshold
    }
}
