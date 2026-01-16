import Foundation

@MainActor
final class SessionStateManager {
    private enum Constants {
        static let flashDurationSeconds: TimeInterval = 1.4
        static let readyStalenessThresholdSeconds: TimeInterval = 120
        static let thinkingStalenessThresholdSeconds: TimeInterval = 30
        static let remoteStalenessThresholdSeconds: TimeInterval = 30
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

    private func reconcileStateWithLock(_ state: ProjectSessionState, at path: String) -> ProjectSessionState {
        if state.isLocked {
            if state.state == .idle {
                return state.with(state: .ready, thinking: nil, isLocked: true)
            }
        } else {
            if state.state == .working || state.state == .compacting {
                return state.with(state: .ready, thinking: false, isLocked: false)
            } else if state.state == .ready {
                if isStale(state.stateChangedAt, threshold: Constants.readyStalenessThresholdSeconds) {
                    return state.with(state: .idle, thinking: false, isLocked: false)
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

    func getSessionState(for project: Project, relayClient: RelayClient?, isRemoteMode: Bool) -> ProjectSessionState? {
        guard var state = findMostRecentState(for: project.path) else {
            return nil
        }

        state = inheritLockIfNeeded(state, projectPath: project.path)
        state = applyThinkingStateLogic(state)

        if isRemoteMode, let relayClient {
            state = applyRemoteStalenessLogic(state, project: project, relayClient: relayClient)
        }

        return state
    }

    private func inheritLockIfNeeded(_ state: ProjectSessionState, projectPath: String) -> ProjectSessionState {
        guard !state.isLocked else { return state }

        if let parentState = sessionStates[projectPath], parentState.isLocked {
            return state.with(isLocked: true)
        }
        return state
    }

    private func applyThinkingStateLogic(_ state: ProjectSessionState) -> ProjectSessionState {
        guard let thinking = state.thinking else { return state }

        let isThinkingStale = state.context?.updatedAt.flatMap { timestamp in
            isStale(timestamp, threshold: Constants.thinkingStalenessThresholdSeconds)
        } ?? false

        let effectiveThinking = isThinkingStale ? false : thinking

        if effectiveThinking {
            return state.with(state: .working, thinking: true)
        } else if state.state == .working && !state.isLocked {
            return state.with(state: .ready, thinking: false, isLocked: false)
        }

        return state
    }

    private func applyRemoteStalenessLogic(_ state: ProjectSessionState, project: Project, relayClient: RelayClient) -> ProjectSessionState {
        guard state.state == .working else { return state }

        let lastHeartbeat = relayClient.projectHeartbeats
            .filter { $0.key.hasPrefix(project.path) }
            .map(\.value)
            .max()

        let isStale: Bool
        if let heartbeat = lastHeartbeat {
            isStale = Date().timeIntervalSince(heartbeat) > Constants.remoteStalenessThresholdSeconds
        } else if let connectedAt = relayClient.connectedAt {
            isStale = Date().timeIntervalSince(connectedAt) > Constants.remoteStalenessThresholdSeconds
        } else {
            isStale = false
        }

        return isStale ? state.with(state: .waiting) : state
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

    // MARK: - Relay State

    func applyRelayState(_ state: RelayHudState) {
        for (path, projectState) in state.projects {
            let sessionState = parseSessionState(projectState.state)

            sessionStates[path] = ProjectSessionState(
                state: sessionState,
                stateChangedAt: projectState.lastUpdated,
                sessionId: nil,
                workingOn: projectState.workingOn,
                context: nil,
                thinking: nil,
                isLocked: false
            )

            if let previous = previousSessionStates[path], previous != sessionState {
                triggerFlashIfNeeded(for: path, state: sessionState)
            }
            previousSessionStates[path] = sessionState
        }
    }

    private func parseSessionState(_ raw: String) -> SessionState {
        switch raw {
        case "working": return .working
        case "ready": return .ready
        case "compacting": return .compacting
        case "waiting": return .waiting
        default: return .idle
        }
    }
}

// MARK: - ProjectSessionState Extension

private extension ProjectSessionState {
    func with(
        state: SessionState? = nil,
        thinking: Bool?? = .none,
        isLocked: Bool? = nil
    ) -> ProjectSessionState {
        ProjectSessionState(
            state: state ?? self.state,
            stateChangedAt: stateChangedAt,
            sessionId: sessionId,
            workingOn: workingOn,
            context: context,
            thinking: thinking == .none ? self.thinking : thinking!,
            isLocked: isLocked ?? self.isLocked
        )
    }
}
