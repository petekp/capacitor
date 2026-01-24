import Foundation

/// Manages session state display for projects.
///
/// This is a "dumb" client that:
/// - Caches states from the Rust engine
/// - Detects state changes for flash animations
/// - Provides state to views (direct passthrough)
///
/// All state logic (staleness, lock detection, resolution) lives in Rust.
@MainActor
final class SessionStateManager {
    private enum Constants {
        static let flashDurationSeconds: TimeInterval = 1.4
    }

    private(set) var sessionStates: [String: ProjectSessionState] = [:]
    private(set) var flashingProjects: [String: SessionState] = [:]
    private var previousSessionStates: [String: SessionState] = [:]

    private weak var engine: HudEngine?

    func configure(engine: HudEngine?) {
        self.engine = engine
    }

    // MARK: - Refresh

    func refreshSessionStates(for projects: [Project]) {
        guard let engine else { return }

        // Direct passthrough from Rust - no client-side transformation
        sessionStates = engine.getAllSessionStates(projects: projects)
        checkForStateChanges()
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
        sessionStates[project.path]
    }
}
