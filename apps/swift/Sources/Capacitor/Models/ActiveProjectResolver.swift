import Foundation

// MARK: - Active Source

enum ActiveSource: Equatable {
    case claude(sessionId: String)
    case shell(pid: String, app: String?)
    case none
}

// MARK: - Active Project Resolver

@MainActor
@Observable
final class ActiveProjectResolver {
    private let sessionStateManager: SessionStateManager
    private let shellStateStore: ShellStateStore

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    private var projects: [Project] = []
    private var manualOverride: Project?
    private var overrideExpiry: Date?

    private enum Constants {
        static let overrideDurationSeconds: TimeInterval = 10
    }

    init(sessionStateManager: SessionStateManager, shellStateStore: ShellStateStore) {
        self.sessionStateManager = sessionStateManager
        self.shellStateStore = shellStateStore
    }

    // MARK: - Public API

    func updateProjects(_ projects: [Project]) {
        self.projects = projects
    }

    func setManualOverride(_ project: Project) {
        manualOverride = project
        overrideExpiry = Date().addingTimeInterval(Constants.overrideDurationSeconds)
    }

    func resolve() {
        // Priority 0: Manual override (from clicking a project, expires after 10s)
        if let override = manualOverride,
           let expiry = overrideExpiry,
           Date() < expiry
        {
            activeProject = override
            activeSource = .none
            return
        } else {
            manualOverride = nil
            overrideExpiry = nil
        }

        // Priority 1: Shell CWD (terminal navigation is most immediate signal)
        if let (project, pid, app) = findActiveShellProject() {
            activeProject = project
            activeSource = .shell(pid: pid, app: app)
            return
        }

        // Priority 2: Most recent Claude session (fallback when not in a tracked project dir)
        if let (project, sessionId) = findActiveClaudeSession() {
            activeProject = project
            activeSource = .claude(sessionId: sessionId)
            return
        }

        activeProject = nil
        activeSource = .none
    }

    // MARK: - Private Resolution

    private func findActiveClaudeSession() -> (Project, String)? {
        var mostRecent: (Project, String, Date)?
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for project in projects {
            guard let sessionState = sessionStateManager.getSessionState(for: project),
                  sessionState.isLocked,
                  let sessionId = sessionState.sessionId else {
                continue
            }

            let stateChangedAt: Date
            if let dateStr = sessionState.stateChangedAt,
               let parsed = formatter.date(from: dateStr) {
                stateChangedAt = parsed
            } else {
                stateChangedAt = Date.distantPast
            }

            if mostRecent == nil || stateChangedAt > mostRecent!.2 {
                mostRecent = (project, sessionId, stateChangedAt)
            }
        }

        return mostRecent.map { ($0.0, $0.1) }
    }

    private func findActiveShellProject() -> (Project, String, String?)? {
        guard let (pid, shell) = shellStateStore.mostRecentShell else {
            return nil
        }

        guard let project = projectContaining(path: shell.cwd) else {
            return nil
        }

        return (project, pid, shell.parentApp)
    }

    private func projectContaining(path: String) -> Project? {
        for project in projects {
            if path == project.path || path.hasPrefix(project.path + "/") {
                return project
            }
        }
        return nil
    }
}
