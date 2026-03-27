import Foundation

struct SessionClock {
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
    /// If a session has been "working" with no events for this long, treat it as ready.
    /// Claude Code doesn't always fire a Stop hook when the user interrupts a response.
    /// 30s is well beyond the longest normal gap between tool-use events (~5-15s)
    /// but short enough to feel responsive after an interrupt.
    static let workingStaleThreshold: TimeInterval = 30

    /// Paused checkpoint reviews can linger much longer than active work, but they should
    /// eventually stop driving project-card state if the run has gone cold.
    static let pausedCheckpointStaleThreshold: TimeInterval = 30 * 60

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

    static func isPausedCheckpointStale(updatedAt: String?, now: Date = Date()) -> Bool {
        guard let updatedAt,
              let date = parseISO8601Date(updatedAt)
        else {
            return false
        }
        return now.timeIntervalSince(date) > pausedCheckpointStaleThreshold
    }
}
