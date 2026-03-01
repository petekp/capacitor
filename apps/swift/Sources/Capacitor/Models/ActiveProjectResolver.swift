import Foundation
import os.log

// MARK: - Active Source

enum ActiveSource: Equatable {
    case claude(sessionId: String)
    case none
}

// MARK: - Active Project Resolver

@MainActor
@Observable
final class ActiveProjectResolver {
    private let logger = Logger(subsystem: "com.capacitor.app", category: "ActiveProjectResolver")
    private let sessionStateManager: SessionStateManager

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    private var projects: [Project] = []
    private var manualOverride: Project?

    init(sessionStateManager: SessionStateManager) {
        self.sessionStateManager = sessionStateManager
    }

    // MARK: - Public API

    func updateProjects(_ projects: [Project]) {
        self.projects = projects
    }

    /// Set a manual override for the active project.
    /// The override persists until:
    /// - User clicks on a different project
    /// - User navigates to a project directory that has an active Claude session
    func setManualOverride(_ project: Project) {
        manualOverride = project
        logger.info("Manual override set: \(project.path, privacy: .public)")
        Telemetry.emit("active_project_override", "Manual override set", payload: [
            "project": project.name,
            "path": project.path,
        ])
    }

    func resolve() {
        let overridePath = manualOverride?.path ?? "none"
        logger.info("Resolve start: manualOverride=\(overridePath, privacy: .public)")
        DebugLog.write("ActiveProjectResolver.resolve start manualOverride=\(overridePath)")

        // Priority 0: Manual override (from clicking a project).
        if let override = manualOverride {
            activeProject = override
            activeSource = .none
            logger.info("Resolve result: activeProject=\(override.path, privacy: .public) source=manualOverride")
            DebugLog.write("ActiveProjectResolver.result activeProject=\(override.path) source=manualOverride")
            Telemetry.emit("active_project_resolution", "Manual override active", payload: [
                "project": override.name,
                "path": override.path,
                "source": "manualOverride",
            ])
            return
        }

        // Priority 1: Most recent Claude session (accurate timestamps from hook events)
        if let (project, sessionId) = findActiveClaudeSession() {
            activeProject = project
            activeSource = .claude(sessionId: sessionId)
            logger.info("Resolve result: activeProject=\(project.path, privacy: .public) source=claude session=\(sessionId, privacy: .public)")
            DebugLog.write("ActiveProjectResolver.result activeProject=\(project.path) source=claude session=\(sessionId)")
            Telemetry.emit("active_project_resolution", "Claude session active", payload: [
                "project": project.name,
                "path": project.path,
                "source": "claude",
                "session_id": sessionId,
            ])
            return
        }

        activeProject = nil
        activeSource = .none
        logger.info("Resolve result: activeProject=nil source=none")
        DebugLog.write("ActiveProjectResolver.result activeProject=nil source=none")
        Telemetry.emit("active_project_resolution", "No active project", payload: [
            "source": "none",
        ])
    }

    // MARK: - Private Resolution

    private func findActiveClaudeSession() -> (Project, String)? {
        var activeSessions: [(Project, String, Date)] = []
        var readySessions: [(Project, String, Date)] = []
        var sessionSummary: [String] = []
        for project in projects {
            guard let sessionState = sessionStateManager.getSessionState(for: project),
                  sessionState.hasSession,
                  let sessionId = sessionStateManager.getPreferredSessionId(for: project)
            else {
                continue
            }

            // Use updated_at (updates on every hook event) for accurate activity tracking.
            // Falls back to stateChangedAt, then Date.distantPast.
            let updatedAt: Date = if let dateStr = sessionState.updatedAt,
                                     let parsed = parseISO8601Date(dateStr)
            {
                parsed
            } else if let dateStr = sessionState.stateChangedAt,
                      let parsed = parseISO8601Date(dateStr)
            {
                parsed
            } else {
                Date.distantPast
            }

            // Separate active (Working/Waiting/Compacting) from passive (Ready) sessions.
            // Active sessions always take priority - a session you're using shouldn't
            // lose focus to one that just finished.
            let isActive = sessionState.state == .working ||
                sessionState.state == .waiting ||
                sessionState.state == .compacting

            if isActive {
                activeSessions.append((project, sessionId, updatedAt))
            } else {
                readySessions.append((project, sessionId, updatedAt))
            }

            sessionSummary.append(
                "\(project.path) state=\(String(describing: sessionState.state)) updated=\(updatedAt)",
            )
        }

        // Prefer active sessions over ready sessions, then sort by recency
        let candidates = activeSessions.isEmpty ? readySessions : activeSessions
        if sessionSummary.isEmpty {
            logger.info("Claude session scan: none")
            DebugLog.write("ActiveProjectResolver.claudeSessions none")
        } else {
            let joined = sessionSummary.joined(separator: " | ")
            logger.info("Claude session scan: \(joined, privacy: .public)")
            DebugLog.write("ActiveProjectResolver.claudeSessions \(joined)")
        }
        return candidates.max(by: { $0.2 < $1.2 }).map { ($0.0, $0.1) }
    }
}
