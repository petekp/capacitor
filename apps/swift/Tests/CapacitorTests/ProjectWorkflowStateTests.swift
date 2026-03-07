@testable import Capacitor
import XCTest

@MainActor
final class ProjectWorkflowStateTests: XCTestCase {
    func testRefreshLoadsShellCatalogEntriesAndSuggestedCandidatesFromGateway() {
        let project = makeProjectCatalogEntry(name: "Capacitor", path: "/tmp/capacitor")
        let suggestion = makeSuggestedProjectCandidate(name: "Intent", path: "/tmp/intent")
        let workflowState = ProjectWorkflowState(
            projectCatalogGateway: StubProjectCatalogGateway(
                projects: [project],
                suggestedProjects: [suggestion],
            ),
        )

        workflowState.refresh()

        XCTAssertEqual(workflowState.projectCatalog, [project])
        XCTAssertEqual(workflowState.suggestedProjectCatalog, [suggestion])
        XCTAssertEqual(
            workflowState.projects,
            [ShellProjectReference(displayName: project.displayName, path: project.path)],
        )
        XCTAssertEqual(
            workflowState.suggestedProjects,
            [ShellProjectReference(displayName: suggestion.displayName, path: suggestion.path)],
        )
        XCTAssertEqual(
            workflowState.legacyProjects,
            [makeProject(name: "Capacitor", path: "/tmp/capacitor")],
        )
        XCTAssertEqual(
            workflowState.legacySuggestedProjects,
            [makeSuggestedProject(name: "Intent", path: "/tmp/intent")],
        )
    }

    func testAppStateRefreshSuggestedProjectsUsesSharedWorkflowState() {
        let suggestion = makeSuggestedProjectCandidate(name: "Capacitor", path: "/tmp/capacitor")
        let workflowState = ProjectWorkflowState(
            projectCatalogGateway: StubProjectCatalogGateway(
                projects: [],
                suggestedProjects: [suggestion],
            ),
        )
        let appState = AppState(
            navigationState: NavigationState(),
            projectWorkflowState: workflowState,
        )
        appState.cancelRuntimeAutomationForTesting()

        appState.projectWorkflowState.refreshSuggestedProjects()

        XCTAssertTrue(appState.projectWorkflowState === workflowState)
        XCTAssertEqual(workflowState.suggestedProjectCatalog, [suggestion])
        XCTAssertEqual(appState.projectWorkflowState.legacySuggestedProjects, [makeSuggestedProject(name: "Capacitor", path: "/tmp/capacitor")])
        XCTAssertEqual(
            workflowState.suggestedProjects,
            [ShellProjectReference(displayName: suggestion.displayName, path: suggestion.path)],
        )
    }

    func testReplaceProjectCatalogPreservesLegacyProjectDetailsForDashboardBridgeEntries() {
        let project = makeProject(name: "Capacitor", path: "/tmp/capacitor", stats: makeProjectStats())
        let workflowState = ProjectWorkflowState(
            projectCatalogGateway: StubProjectCatalogGateway(
                projects: [],
                suggestedProjects: [],
            ),
        )

        workflowState.replaceProjectCatalog(
            with: ProjectCatalogBridge.projectCatalogEntries(from: [project]),
        )

        XCTAssertEqual(workflowState.legacyProjects, [project])
        XCTAssertEqual(
            workflowState.projectCatalog,
            [makeProjectCatalogEntry(name: "Capacitor", path: "/tmp/capacitor", stats: makeShellProjectStats())],
        )
        XCTAssertEqual(
            workflowState.projects,
            [ShellProjectReference(displayName: project.name, path: project.path)],
        )
    }

    func testReplaceSuggestedProjectCatalogPreservesLegacySuggestionDetailsForBridgeCandidates() {
        let suggestion = makeSuggestedProject(name: "Intent", path: "/tmp/intent")
        let workflowState = ProjectWorkflowState(
            projectCatalogGateway: StubProjectCatalogGateway(
                projects: [],
                suggestedProjects: [],
            ),
        )

        workflowState.replaceSuggestedProjectCatalog(
            with: ProjectCatalogBridge.suggestedProjectCandidates(from: [suggestion]),
        )

        XCTAssertEqual(workflowState.legacySuggestedProjects, [suggestion])
        XCTAssertEqual(
            workflowState.suggestedProjectCatalog,
            [makeSuggestedProjectCandidate(name: "Intent", path: "/tmp/intent")],
        )
        XCTAssertEqual(
            workflowState.suggestedProjects,
            [ShellProjectReference(displayName: suggestion.name, path: suggestion.path)],
        )
    }

    func testSuggestedProjectSelectionBelongsToWorkflowState() {
        let first = makeSuggestedProjectCandidate(name: "Capacitor", path: "/tmp/capacitor")
        let second = makeSuggestedProjectCandidate(name: "Intent", path: "/tmp/intent")
        let workflowState = ProjectWorkflowState(
            projectCatalogGateway: StubProjectCatalogGateway(
                projects: [],
                suggestedProjects: [],
            ),
        )

        workflowState.replaceSuggestedProjectCatalog(with: [first, second])

        workflowState.toggleSuggestedProjectSelection(path: first.path)
        workflowState.toggleSuggestedProjectSelection(path: second.path)

        XCTAssertEqual(workflowState.selectedSuggestedPaths, [first.path, second.path])
        XCTAssertEqual(workflowState.selectedSuggestedProjectCount, 2)
        XCTAssertEqual(
            workflowState.selectedLegacySuggestedProjects,
            [
                makeSuggestedProject(name: "Capacitor", path: "/tmp/capacitor"),
                makeSuggestedProject(name: "Intent", path: "/tmp/intent"),
            ],
        )

        workflowState.toggleSuggestedProjectSelection(path: first.path)

        XCTAssertEqual(workflowState.selectedSuggestedPaths, [second.path])
        XCTAssertEqual(workflowState.selectedSuggestedProjectCount, 1)
    }

    func testReplacingSuggestedCatalogPrunesStaleSelection() {
        let first = makeSuggestedProjectCandidate(name: "Capacitor", path: "/tmp/capacitor")
        let second = makeSuggestedProjectCandidate(name: "Intent", path: "/tmp/intent")
        let third = makeSuggestedProjectCandidate(name: "Claude HUD", path: "/tmp/claude-hud")
        let workflowState = ProjectWorkflowState(
            projectCatalogGateway: StubProjectCatalogGateway(
                projects: [],
                suggestedProjects: [],
            ),
        )

        workflowState.replaceSuggestedProjectCatalog(with: [first, second])
        workflowState.toggleSuggestedProjectSelection(path: first.path)
        workflowState.toggleSuggestedProjectSelection(path: second.path)

        workflowState.replaceSuggestedProjectCatalog(with: [second, third])

        XCTAssertEqual(workflowState.selectedSuggestedPaths, [second.path])
        XCTAssertEqual(
            workflowState.selectedLegacySuggestedProjects,
            [makeSuggestedProject(name: "Intent", path: "/tmp/intent")],
        )

        workflowState.clearSuggestedProjects()

        XCTAssertTrue(workflowState.selectedSuggestedPaths.isEmpty)
        XCTAssertEqual(workflowState.selectedSuggestedProjectCount, 0)
    }

    private func makeProject(name: String, path: String, stats: ProjectStats? = nil) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: stats,
            isMissing: false,
        )
    }

    private func makeSuggestedProject(name: String, path: String) -> SuggestedProject {
        SuggestedProject(
            path: path,
            displayPath: path,
            name: name,
            taskCount: 0,
            hasClaudeMd: false,
            hasProjectIndicators: true,
        )
    }

    private func makeProjectCatalogEntry(
        name: String,
        path: String,
        stats: ShellProjectStats? = nil,
    ) -> ShellProjectCatalogEntry {
        ShellProjectCatalogEntry(
            displayName: name,
            path: path,
            displayPath: path,
            lastActiveAt: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: stats,
            isMissing: false,
        )
    }

    private func makeSuggestedProjectCandidate(name: String, path: String) -> ShellSuggestedProjectCandidate {
        ShellSuggestedProjectCandidate(
            displayName: name,
            path: path,
            displayPath: path,
            taskCount: 0,
            hasClaudeMd: false,
            hasProjectIndicators: true,
        )
    }

    private func makeProjectStats() -> ProjectStats {
        ProjectStats(
            totalInputTokens: 10,
            totalOutputTokens: 20,
            totalCacheReadTokens: 30,
            totalCacheCreationTokens: 40,
            opusMessages: 1,
            sonnetMessages: 2,
            haikuMessages: 3,
            sessionCount: 4,
            latestSummary: "Latest",
            firstActivity: "2026-03-01T00:00:00Z",
            lastActivity: "2026-03-05T00:00:00Z",
        )
    }

    private func makeShellProjectStats() -> ShellProjectStats {
        ShellProjectStats(
            totalInputTokens: 10,
            totalOutputTokens: 20,
            totalCacheReadTokens: 30,
            totalCacheCreationTokens: 40,
            opusMessages: 1,
            sonnetMessages: 2,
            haikuMessages: 3,
            sessionCount: 4,
            latestSummary: "Latest",
            firstActivity: "2026-03-01T00:00:00Z",
            lastActivity: "2026-03-05T00:00:00Z",
        )
    }
}

private struct StubProjectCatalogGateway: ProjectCatalogGateway {
    let projects: [ShellProjectCatalogEntry]
    let suggestedProjects: [ShellSuggestedProjectCandidate]

    func loadProjects() throws -> [ShellProjectCatalogEntry] {
        projects
    }

    func loadSuggestedProjects() throws -> [ShellSuggestedProjectCandidate] {
        suggestedProjects
    }
}
