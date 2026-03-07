import Foundation

@MainActor
@Observable
final class ActiveProjectTrackingState {
    @ObservationIgnored
    private let resolver: ActiveProjectResolver

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    var activeProjectPath: String? {
        activeProject?.path
    }

    init(sessionStateManager: SessionStateManager) {
        resolver = ActiveProjectResolver(sessionStateManager: sessionStateManager)
        activeProject = resolver.activeProject
        activeSource = resolver.activeSource
    }

    func updateProjects(_ projects: [Project]) {
        resolver.updateProjects(projects)
    }

    func activate(_ project: Project) {
        resolver.setManualOverride(project)
        resolver.resolve()
        syncFromResolver()
    }

    func refreshAfterSessionUpdate() {
        resolver.resolve()
        syncFromResolver()
        DiagnosticsSnapshotLogger.updateContext(
            activeProjectPath: activeProjectPath,
            activeSource: activeSource,
        )
        DebugLog.write(
            "ActiveProjectTrackingState.refresh activeProject=\(activeProject?.path ?? "nil") source=\(String(describing: activeSource))",
        )
        if let activeProject {
            Telemetry.emit("active_project_resolution", "Resolved active project", payload: [
                "project": activeProject.name,
                "path": activeProject.path,
                "source": String(describing: activeSource),
            ])
        } else {
            Telemetry.emit("active_project_resolution", "No active project", payload: [
                "source": String(describing: activeSource),
            ])
        }
    }

    private func syncFromResolver() {
        activeProject = resolver.activeProject
        activeSource = resolver.activeSource
    }
}
