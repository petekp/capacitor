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
    /// Fallback threshold for when PID liveness is unavailable.
    ///
    /// The primary working-stale gate is PID liveness (`kill(pid, 0)`).
    /// This timestamp threshold is the safety net for edge cases where
    /// the PID is zero, unavailable, or a zombie that outlives reaping.
    /// 5 minutes is generous — it should almost never be the deciding factor.
    static let workingStaleThreshold: TimeInterval = 300

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
