import Foundation

@MainActor
final class RuntimeRefreshOrchestrator {
    private let projectStatusCacheState: ProjectStatusCacheState
    private let runtimeSessionRefreshController: RuntimeSessionRefreshController
    private let activeProjectTrackingState: ActiveProjectTrackingState
    private let projectListState: ProjectListState
    private let sessionStateManager: SessionStateManager
    private let projectsProvider: () -> [ShellProjectReference]

    init(
        projectStatusCacheState: ProjectStatusCacheState,
        runtimeSessionRefreshController: RuntimeSessionRefreshController,
        activeProjectTrackingState: ActiveProjectTrackingState,
        projectListState: ProjectListState,
        sessionStateManager: SessionStateManager,
        projectsProvider: @escaping () -> [ShellProjectReference],
    ) {
        self.projectStatusCacheState = projectStatusCacheState
        self.runtimeSessionRefreshController = runtimeSessionRefreshController
        self.activeProjectTrackingState = activeProjectTrackingState
        self.projectListState = projectListState
        self.sessionStateManager = sessionStateManager
        self.projectsProvider = projectsProvider
    }

    func refreshSessionStates(engine: CoreRuntime?) {
        let projects = projectsProvider()
        projectStatusCacheState.refresh(projectPaths: projects.map(\.path), engine: engine)
        runtimeSessionRefreshController.refresh(projects: projects)
    }

    func handlePostSessionUpdate() {
        let projects = projectsProvider()
        activeProjectTrackingState.refreshAfterSessionUpdate()
        projectListState.reconcileProjectGroups(
            projects: projects,
            sessionStates: sessionStateManager.sessionStates,
        )
    }

    func activeWorktreePathsForGuardrails() -> Set<String> {
        var paths: Set<String> = []

        for (projectPath, state) in sessionStateManager.sessionStates where state.state == .working {
            paths.insert(PathNormalizer.normalize(projectPath))
        }

        if let activePath = activeProjectTrackingState.activeProjectPath {
            paths.insert(PathNormalizer.normalize(activePath))
        }

        return paths
    }
}
