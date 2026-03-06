import Foundation

struct SessionClock: Sendable {
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    static let live = SessionClock()

    static func fixed(_ date: Date) -> SessionClock {
        SessionClock { date }
    }
}

enum SessionStaleness {
    static let readyStaleThreshold: TimeInterval = 86400

    /// If a session has been "working" with no events for this long, treat it as ready.
    /// Claude Code doesn't always fire a Stop hook when the user interrupts a response.
    /// 30s is well beyond the longest normal gap between tool-use events (~5-15s)
    /// but short enough to feel responsive after an interrupt.
    static let workingStaleThreshold: TimeInterval = 30

    static func isReadyStale(state: SessionState?, stateChangedAt: String?, now: Date = Date()) -> Bool {
        guard state == .ready,
              let stateChangedAt,
              let date = parseISO8601Date(stateChangedAt)
        else {
            return false
        }
        return now.timeIntervalSince(date) > readyStaleThreshold
    }

    static func isReadyStale(state: SessionState?, stateChangedAt: String?, clock: SessionClock) -> Bool {
        isReadyStale(state: state, stateChangedAt: stateChangedAt, now: clock.now())
    }

    static func isWorkingStale(state: SessionState?, updatedAt: String?, now: Date = Date()) -> Bool {
        guard state == .working,
              let updatedAt,
              let date = parseISO8601Date(updatedAt)
        else {
            return false
        }
        return now.timeIntervalSince(date) > workingStaleThreshold
    }

    static func isWorkingStale(state: SessionState?, updatedAt: String?, clock: SessionClock) -> Bool {
        isWorkingStale(state: state, updatedAt: updatedAt, now: clock.now())
    }
}
