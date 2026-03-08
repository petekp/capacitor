import Foundation

@MainActor
struct DashboardLoader {
    private let loadDashboardData: () throws -> DashboardData
    private let projectWorkflowState: ProjectWorkflowState
    private let updateActiveProjects: ([ShellProjectCatalogEntry]) -> Void
    private let refreshRuntimeSessions: () -> Void
    private let loadIdeas: ([ShellProjectCatalogEntry]) -> Void
    private let refreshSuggestedProjects: () -> Void

    init(
        loadDashboardData: @escaping () throws -> DashboardData,
        projectWorkflowState: ProjectWorkflowState,
        updateActiveProjects: @escaping ([ShellProjectCatalogEntry]) -> Void,
        refreshRuntimeSessions: @escaping () -> Void,
        loadIdeas: @escaping ([ShellProjectCatalogEntry]) -> Void,
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
            with: dashboard.projects,
        )

        let projects = projectWorkflowState.projectCatalog
        let suggestedProjects = projectWorkflowState.suggestedProjectCatalog

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
