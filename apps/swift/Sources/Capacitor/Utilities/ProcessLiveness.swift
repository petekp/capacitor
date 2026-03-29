import Darwin

/// Checks whether a process is alive using POSIX `kill(pid, 0)`.
///
/// Production code uses the default `live` checker. Tests inject a closure
/// to control liveness without depending on real process state.
enum ProcessLiveness {
    /// Returns true if the process with the given PID exists.
    ///
    /// Handles both same-user (result == 0) and cross-user (EPERM) cases.
    /// Returns false for pid == 0 or when the process does not exist (ESRCH).
    static func isAlive(pid: UInt32) -> Bool {
        guard pid > 0 else { return false }
        let result = kill(Int32(pid), 0)
        return result == 0 || errno == EPERM
    }
}

/// Injectable checker for testability. Mirrors the `SessionClock` pattern.
typealias ProcessLivenessChecker = @Sendable (UInt32) -> Bool

extension ProcessLiveness {
    /// Default liveness checker suitable for use as a default parameter.
    static let checker: ProcessLivenessChecker = { isAlive(pid: $0) }
}
