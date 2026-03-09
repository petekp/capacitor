import Foundation
import Observation
import os.log

enum ActiveSource: Equatable {
    case claude(sessionId: String)
    case none
}

@MainActor
@Observable
final class ActiveProjectTrackingState {
    private let logger = Logger(subsystem: "com.capacitor.app", category: "ActiveProjectTrackingState")
    @ObservationIgnored
    private let projectSessionReader: any ProjectSessionReading

    private(set) var activeProject: ShellProjectReference?
    private(set) var activeSource: ActiveSource = .none

    @ObservationIgnored
    private var projects: [ShellProjectReference] = []
    @ObservationIgnored
    private var manualOverride: ShellProjectReference?

    var activeProjectPath: String? {
        activeProject?.path
    }

    init(projectSessionReader: any ProjectSessionReading) {
        self.projectSessionReader = projectSessionReader
    }

    func updateProjects(_ projects: [some ShellProjectReferenceProviding]) {
        self.projects = projects.map(\.shellProjectReference)
    }

    func activate(_ project: some ShellProjectReferenceProviding) {
        let projectReference = project.shellProjectReference
        manualOverride = projectReference
        logger.info("Manual override set: \(projectReference.path, privacy: .public)")
        Telemetry.emit("active_project_override", "Manual override set", payload: [
            "project": projectReference.displayName,
            "path": projectReference.path,
        ])
        resolve()
    }

    func refreshAfterSessionUpdate() {
        resolve()
        DiagnosticsSnapshotLogger.updateContext(
            activeProjectPath: activeProjectPath,
            activeSource: activeSource,
        )
        DebugLog.write(
            "ActiveProjectTrackingState.refresh activeProject=\(activeProject?.path ?? "nil") source=\(String(describing: activeSource))",
        )
        if let activeProject {
            Telemetry.emit("active_project_resolution", "Resolved active project", payload: [
                "project": activeProject.displayName,
                "path": activeProject.path,
                "source": String(describing: activeSource),
            ])
        } else {
            Telemetry.emit("active_project_resolution", "No active project", payload: [
                "source": String(describing: activeSource),
            ])
        }
    }

    private func resolve() {
        let overridePath = manualOverride?.path ?? "none"
        logger.info("Resolve start: manualOverride=\(overridePath, privacy: .public)")
        DebugLog.write("ActiveProjectTrackingState.resolve start manualOverride=\(overridePath)")

        if let override = manualOverride {
            activeProject = override
            activeSource = .none
            logger.info("Resolve result: activeProject=\(override.path, privacy: .public) source=manualOverride")
            DebugLog.write("ActiveProjectTrackingState.result activeProject=\(override.path) source=manualOverride")
            Telemetry.emit("active_project_resolution", "Manual override active", payload: [
                "project": override.displayName,
                "path": override.path,
                "source": "manualOverride",
            ])
            return
        }

        if let (project, sessionID) = findActiveClaudeSession() {
            activeProject = project
            activeSource = .claude(sessionId: sessionID)
            logger.info("Resolve result: activeProject=\(project.path, privacy: .public) source=claude session=\(sessionID, privacy: .public)")
            DebugLog.write("ActiveProjectTrackingState.result activeProject=\(project.path) source=claude session=\(sessionID)")
            Telemetry.emit("active_project_resolution", "Claude session active", payload: [
                "project": project.displayName,
                "path": project.path,
                "source": "claude",
                "session_id": sessionID,
            ])
            return
        }

        activeProject = nil
        activeSource = .none
        logger.info("Resolve result: activeProject=nil source=none")
        DebugLog.write("ActiveProjectTrackingState.result activeProject=nil source=none")
        Telemetry.emit("active_project_resolution", "No active project", payload: [
            "source": "none",
        ])
    }

    private func findActiveClaudeSession() -> (ShellProjectReference, String)? {
        var activeSessions: [(ShellProjectReference, String, Date)] = []
        var readySessions: [(ShellProjectReference, String, Date)] = []
        var sessionSummary: [String] = []

        for project in projects {
            guard let sessionState = projectSessionReader.sessionState(for: project.path),
                  sessionState.hasSession,
                  let sessionID = projectSessionReader.preferredSessionID(for: project.path)
            else {
                continue
            }

            let updatedAt: Date = if let updatedAt = sessionState.updatedAt,
                                     let parsed = parseISO8601Date(updatedAt)
            {
                parsed
            } else if let changedAt = sessionState.stateChangedAt,
                      let parsed = parseISO8601Date(changedAt)
            {
                parsed
            } else {
                Date.distantPast
            }

            let isActive = sessionState.state == .working ||
                sessionState.state == .waiting ||
                sessionState.state == .compacting

            if isActive {
                activeSessions.append((project, sessionID, updatedAt))
            } else {
                readySessions.append((project, sessionID, updatedAt))
            }

            sessionSummary.append(
                "\(project.path) state=\(String(describing: sessionState.state)) updated=\(updatedAt)",
            )
        }

        let candidates = activeSessions.isEmpty ? readySessions : activeSessions
        if sessionSummary.isEmpty {
            logger.info("Claude session scan: none")
            DebugLog.write("ActiveProjectTrackingState.claudeSessions none")
        } else {
            let joined = sessionSummary.joined(separator: " | ")
            logger.info("Claude session scan: \(joined, privacy: .public)")
            DebugLog.write("ActiveProjectTrackingState.claudeSessions \(joined)")
        }

        return candidates.max(by: { $0.2 < $1.2 }).map { ($0.0, $0.1) }
    }
}
