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
    /// Fallback threshold for when Rust-side `is_alive` is unavailable.
    ///
    /// The primary liveness signal is now `is_alive` from the Rust snapshot,
    /// computed via shell corroboration. This timestamp threshold is the
    /// safety net for edge cases where `is_alive` is nil (e.g., the runtime
    /// service path, or stale snapshots from before the field was added).
    static let workingStaleThreshold: TimeInterval = 300

    /// Paused checkpoint reviews can linger much longer than active work, but they should
    /// eventually stop driving project-card state if the run has gone cold.
    static let pausedCheckpointStaleThreshold: TimeInterval = 30 * 60

    /// Determines whether a session should be considered effectively dead.
    ///
    /// Uses `isAlive` from the Rust snapshot as the primary signal (shell
    /// corroboration). Falls back to timestamp-based staleness when
    /// `isAlive` is nil (runtime service path or pre-migration snapshots).
    static func isSessionEffectivelyDead(
        isAlive: Bool?,
        state: SessionState?,
        updatedAt: String?,
        now: Date = Date(),
    ) -> Bool {
        guard let state, state == .working || state == .waiting || state == .compacting else {
            return false
        }
        // Primary signal: Rust-computed liveness via shell corroboration
        if let isAlive {
            return !isAlive
        }
        // Fallback: timestamp-based staleness when is_alive is unavailable
        guard let updatedAt, let date = parseISO8601Date(updatedAt) else {
            return false
        }
        return now.timeIntervalSince(date) > workingStaleThreshold
    }

    static func isSessionEffectivelyDead(
        isAlive: Bool?,
        state: SessionState?,
        updatedAt: String?,
        clock: SessionClock,
    ) -> Bool {
        isSessionEffectivelyDead(isAlive: isAlive, state: state, updatedAt: updatedAt, now: clock.now())
    }

    /// Determines whether a run's displayed state should be considered stale.
    ///
    /// This is a pure timestamp check — runs don't have PIDs or shell
    /// corroboration. Used by `ProjectRunVisualStateResolver` to age out
    /// stale run indicators on project cards.
    static func isRunFreshnessExpired(updatedAt: String?, now: Date = Date()) -> Bool {
        guard let updatedAt, let date = parseISO8601Date(updatedAt) else {
            return false
        }
        return now.timeIntervalSince(date) > workingStaleThreshold
    }

    /// Keep the old API for backwards compat during transition — delegates to
    /// isSessionEffectivelyDead with isAlive: nil (timestamp-only fallback).
    static func isActiveSessionStale(state: SessionState?, updatedAt: String?, now: Date = Date()) -> Bool {
        isSessionEffectivelyDead(isAlive: nil, state: state, updatedAt: updatedAt, now: now)
    }

    static func isActiveSessionStale(state: SessionState?, updatedAt: String?, clock: SessionClock) -> Bool {
        isActiveSessionStale(state: state, updatedAt: updatedAt, now: clock.now())
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
