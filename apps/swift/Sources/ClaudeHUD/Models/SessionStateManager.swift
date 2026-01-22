import Foundation

@MainActor
final class SessionStateManager {
    private enum Constants {
        static let flashDurationSeconds: TimeInterval = 1.4
        static let readyStalenessThresholdSeconds: TimeInterval = 120
    }

    private(set) var sessionStates: [String: ProjectSessionState] = [:]
    private(set) var flashingProjects: [String: SessionState] = [:]
    private var previousSessionStates: [String: SessionState] = [:]

    private weak var engine: HudEngine?
    private let isoFormatter = ISO8601DateFormatter()

    func configure(engine: HudEngine?) {
        self.engine = engine
    }

    // MARK: - Refresh

    func refreshSessionStates(for projects: [Project]) {
        guard let engine else { return }
        var states = engine.getAllSessionStates(projects: projects)

        for (path, state) in states {
            states[path] = reconcileStateWithLock(state, at: path)
        }

        sessionStates = states
        checkForStateChanges()
    }

    // Internal for unit testing (the UI relies on this to avoid stale/incorrect statuses).
    func reconcileStateWithLock(_ state: ProjectSessionState, at path: String) -> ProjectSessionState {
        if state.isLocked {
            if state.state == .idle {
                return state.with(state: .ready, isLocked: true)
            }
        } else {
            // Important: We intentionally allow .working/.compacting without a lock.
            // Core already applies staleness / TTL when no lock exists; if we forcibly
            // downshift here, "Working" will never be visible for hook-only sessions
            // (e.g. when lock files are missing or unavailable).
            if state.state == .ready {
                if isStale(state.stateChangedAt, threshold: Constants.readyStalenessThresholdSeconds) {
                    return state.with(state: .idle, isLocked: false)
                }
            }
        }
        return state
    }

    private func isStale(_ timestamp: String?, threshold: TimeInterval) -> Bool {
        guard let timestamp,
              let date = isoFormatter.date(from: timestamp) else {
            return false
        }
        return Date().timeIntervalSince(date) > threshold
    }

    // MARK: - Flash Animation

    private func checkForStateChanges() {
        for (path, sessionState) in sessionStates {
            let current = sessionState.state
            if let previous = previousSessionStates[path], previous != current {
                triggerFlashIfNeeded(for: path, state: current)
            }
            previousSessionStates[path] = current
        }
    }

    private func triggerFlashIfNeeded(for path: String, state: SessionState) {
        switch state {
        case .ready, .waiting, .compacting:
            flashingProjects[path] = state
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.flashDurationSeconds) { [weak self] in
                self?.flashingProjects.removeValue(forKey: path)
            }
        case .working, .idle:
            break
        }
    }

    func isFlashing(_ project: Project) -> SessionState? {
        flashingProjects[project.path]
    }

    // MARK: - State Retrieval

    func getSessionState(for project: Project) -> ProjectSessionState? {
        guard var state = findMostRecentState(for: project.path) else {
            return nil
        }

        state = inheritLockIfNeeded(state, projectPath: project.path)

        return state
    }

    private func inheritLockIfNeeded(_ state: ProjectSessionState, projectPath: String) -> ProjectSessionState {
        guard !state.isLocked else { return state }

        if let parentState = sessionStates[projectPath], parentState.isLocked {
            return state.with(isLocked: true)
        }
        return state
    }

    private func findMostRecentState(for projectPath: String) -> ProjectSessionState? {
        var bestState: ProjectSessionState?
        var bestTimestamp: Date?

        for (path, state) in sessionStates {
            guard path == projectPath || path.hasPrefix(projectPath + "/") else { continue }

            let stateTimestamp = state.context?.updatedAt.flatMap(isoFormatter.date(from:))
                ?? state.stateChangedAt.flatMap(isoFormatter.date(from:))

            if let current = stateTimestamp {
                if bestTimestamp == nil || current > bestTimestamp! {
                    bestState = state
                    bestTimestamp = current
                }
            } else if bestState == nil {
                bestState = state
            }
        }

        return bestState
    }

}

// MARK: - ProjectSessionState Extension

private extension ProjectSessionState {
    func with(
        state: SessionState? = nil,
        isLocked: Bool? = nil
    ) -> ProjectSessionState {
        ProjectSessionState(
            state: state ?? self.state,
            stateChangedAt: stateChangedAt,
            sessionId: sessionId,
            workingOn: workingOn,
            context: context,
            isLocked: isLocked ?? self.isLocked
        )
    }
}
