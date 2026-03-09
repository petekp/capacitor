import Foundation

@MainActor
final class RuntimeRefreshOrchestrator {
    private let projectStatusCacheState: ProjectStatusCacheState
    private let runtimeSessionRefreshController: RuntimeSessionRefreshController
    private let activeProjectTrackingState: ActiveProjectTrackingState
    private let projectListState: ProjectListState
    private let sessionStateProjector: any RuntimeSessionStateProjecting
    private let projectsProvider: () -> [ShellProjectReference]

    init(
        projectStatusCacheState: ProjectStatusCacheState,
        runtimeSessionRefreshController: RuntimeSessionRefreshController,
        activeProjectTrackingState: ActiveProjectTrackingState,
        projectListState: ProjectListState,
        sessionStateProjector: any RuntimeSessionStateProjecting,
        projectsProvider: @escaping () -> [ShellProjectReference],
    ) {
        self.projectStatusCacheState = projectStatusCacheState
        self.runtimeSessionRefreshController = runtimeSessionRefreshController
        self.activeProjectTrackingState = activeProjectTrackingState
        self.projectListState = projectListState
        self.sessionStateProjector = sessionStateProjector
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
            sessionStates: sessionStateProjector.sessionStates,
        )
    }

    func activeWorktreePathsForGuardrails() -> Set<String> {
        var paths: Set<String> = []

        for (projectPath, state) in sessionStateProjector.sessionStates where state.state == .working {
            paths.insert(PathNormalizer.normalize(projectPath))
        }

        if let activePath = activeProjectTrackingState.activeProjectPath {
            paths.insert(PathNormalizer.normalize(activePath))
        }

        return paths
    }
}
