@testable import Capacitor
import XCTest

@MainActor
final class DashboardLoaderTests: XCTestCase {
    func testLoadReplacesProjectCatalog() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: NoopProjectCatalogGateway())
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
                    projects: [
                        Project(
                            name: "Capacitor",
                            path: "/tmp/capacitor",
                            displayPath: "/tmp/capacitor",
                            lastActive: nil,
                            claudeMdPath: nil,
                            claudeMdPreview: nil,
                            hasLocalSettings: false,
                            taskCount: 0,
                            stats: nil,
                            isMissing: false,
                        ),
                    ],
                )
            },
            projectWorkflowState: workflowState,
            updateActiveProjects: { _ in },
            refreshRuntimeSessions: {},
            loadIdeas: { _ in },
            refreshSuggestedProjects: {},
        )

        let dashboard = try? loader.load(hydrateIdeas: false)

        XCTAssertEqual(dashboard?.projects.count, 1)
        XCTAssertEqual(workflowState.legacyProjects.first?.path, "/tmp/capacitor")
    }
}

private struct NoopProjectCatalogGateway: ProjectCatalogGateway {
    func loadProjects() throws -> [ShellProjectCatalogEntry] {
        []
    }

    func loadSuggestedProjects() throws -> [ShellSuggestedProjectCandidate] {
        []
    }
}
