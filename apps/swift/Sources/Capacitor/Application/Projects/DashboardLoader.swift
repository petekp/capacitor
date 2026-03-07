import Foundation

@MainActor
struct DashboardLoader {
    private let loadDashboardData: () throws -> DashboardData
    private let projectWorkflowState: ProjectWorkflowState
    private let updateActiveProjects: ([Project]) -> Void
    private let refreshRuntimeSessions: () -> Void
    private let loadIdeas: ([Project]) -> Void
    private let refreshSuggestedProjects: () -> Void

    init(
        loadDashboardData: @escaping () throws -> DashboardData,
        projectWorkflowState: ProjectWorkflowState,
        updateActiveProjects: @escaping ([Project]) -> Void,
        refreshRuntimeSessions: @escaping () -> Void,
        loadIdeas: @escaping ([Project]) -> Void,
        refreshSuggestedProjects: @escaping () -> Void,
    ) {
        self.loadDashboardData = loadDashboardData
        self.projectWorkflowState = projectWorkflowState
        self.updateActiveProjects = updateActiveProjects
        self.refreshRuntimeSessions = refreshRuntimeSessions
        self.loadIdeas = loadIdeas
        self.refreshSuggestedProjects = refreshSuggestedProjects
    }

    func load(hydrateIdeas: Bool) throws -> DashboardData {
        let dashboard = try loadDashboardData()
        projectWorkflowState.replaceProjectCatalog(
            with: ProjectCatalogBridge.projectCatalogEntries(from: dashboard.projects),
        )

        let projects = projectWorkflowState.legacyProjects
        let suggestedProjects = projectWorkflowState.legacySuggestedProjects

        if projects.isEmpty, suggestedProjects.isEmpty {
            refreshSuggestedProjects()
        } else if !projects.isEmpty, !suggestedProjects.isEmpty {
            projectWorkflowState.clearSuggestedProjects()
        }

        updateActiveProjects(projects)
        refreshRuntimeSessions()

        if hydrateIdeas {
            loadIdeas(projects)
        }

        return dashboard
    }
}
