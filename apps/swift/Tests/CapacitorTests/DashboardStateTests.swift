@testable import Capacitor
import XCTest

@MainActor
final class DashboardStateTests: XCTestCase {
    func testLoadStoresDashboardAndClearsLoading() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: DashboardStateNoopProjectCatalogGateway())
        let loader = DashboardLoader(
            loadDashboardData: {
                DashboardData(
                    global: GlobalConfig(
                        settingsPath: "/tmp/settings.json",
                        settingsExists: false,
                        instructionsPath: nil,
                        skillsDir: nil,
                        commandsDir: nil,
                        agentsDir: nil,
                        skillCount: 0,
                        commandCount: 0,
                        agentCount: 0,
                    ),
                    plugins: [],
                    projects: [],
                )
            },
            projectWorkflowState: workflowState,
            updateActiveProjects: { _ in },
            refreshRuntimeSessions: {},
            loadIdeas: { _ in },
            refreshSuggestedProjects: {},
        )
        var lastError: String?
        let state = DashboardState(
            dashboardLoader: loader,
            ideaCaptureEnabled: { false },
            writeError: { lastError = $0 },
        )

        state.load()

        XCTAssertNotNil(state.dashboard)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(lastError)
    }
}

private struct DashboardStateNoopProjectCatalogGateway: ProjectCatalogGateway {
    func loadProjects() throws -> [ShellProjectCatalogEntry] {
        []
    }

    func loadSuggestedProjects() throws -> [ShellSuggestedProjectCandidate] {
        []
    }
}
