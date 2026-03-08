@testable import Capacitor
import XCTest

@MainActor
final class DashboardLoaderTests: XCTestCase {
    func testLoadReplacesProjectCatalog() {
        let workflowState = ProjectWorkflowState(projectCatalogGateway: NoopProjectCatalogGateway())
        var activeProjects: [ShellProjectCatalogEntry] = []
        var ideaLoadProjects: [ShellProjectCatalogEntry] = []
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
                        ShellProjectCatalogEntry(
                            displayName: "Capacitor",
                            path: "/tmp/capacitor",
                            displayPath: "/tmp/capacitor",
                            lastActiveAt: nil,
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
            updateActiveProjects: { activeProjects = $0 },
            refreshRuntimeSessions: {},
            loadIdeas: { ideaLoadProjects = $0 },
            refreshSuggestedProjects: {},
        )

        let dashboard = try? loader.load(hydrateIdeas: true)

        XCTAssertEqual(dashboard?.projects.count, 1)
        XCTAssertEqual(workflowState.projectCatalog.first?.path, "/tmp/capacitor")
        XCTAssertEqual(activeProjects.map(\.path), ["/tmp/capacitor"])
        XCTAssertEqual(ideaLoadProjects.map(\.path), ["/tmp/capacitor"])
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
