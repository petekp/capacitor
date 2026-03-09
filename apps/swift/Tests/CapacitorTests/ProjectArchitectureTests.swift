import XCTest

final class ProjectArchitectureTests: XCTestCase, ArchitectureAssertions {
    func testProjectCreationCoordinatorDoesNotDependOnProjectMutationGatewayType() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectCreationCoordinator.swift",
            omits: [
                "ProjectMutationGateway",
                "projectMutationGatewayProvider",
            ],
        )
    }

    func testProjectViewsDoNotCallProjectMutationThroughAppState() throws {
        try assertFiles(
            [
                "apps/swift/Sources/Capacitor/Views/Footer/FooterView.swift",
                "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift",
                "apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift",
                "apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift",
                "apps/swift/Sources/Capacitor/ContentView.swift",
                "apps/swift/Sources/Capacitor/Debug/AppDebugSupport.swift",
            ],
            omits: [
                "appState.removeProject(",
                "appState.connectSelectedSuggestions()",
                "appState.createClaudeMd(",
                "appState.addProjectsFromDrop(",
            ],
        )
    }

    func testProjectViewsDoNotCallSetupMutationThroughAppState() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift",
            omits: [
                "appState.fixHooks()",
                "appState.testHooks()",
                "appState.checkHookDiagnostic()",
            ],
        )
    }

    func testProjectViewsDoNotCallProjectFeatureThroughAppStateFacade() throws {
        try assertFiles(
            [
                "apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift",
                "apps/swift/Sources/Capacitor/Views/Projects/NewIdeaView.swift",
                "apps/swift/Sources/Capacitor/Views/Navigation/NavigationContainer.swift",
                "apps/swift/Sources/Capacitor/Views/Header/HeaderView.swift",
                "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift",
                "apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift",
                "apps/swift/Sources/Capacitor/ContentView.swift",
            ],
            omits: [
                "appState.showProjectList()",
                "appState.showProjectDetail(",
                "appState.showIdeaCaptureModal(",
                "appState.captureIdea(",
                "appState.getIdeas(",
                "appState.generateDescription(",
                "appState.createProjectFromIdea(",
            ],
        )
    }

    func testLegacyProjectBridgeUsageIsConfinedToAllowlistedFiles() throws {
        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "projectWorkflowState.legacyProjects",
            allowedFiles: [],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "projectWorkflowState.legacySuggestedProjects",
            allowedFiles: [],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "selectedLegacySuggestedProjects",
            allowedFiles: [],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "ProjectCatalogBridge",
            allowedFiles: [],
        )
    }

    func testProjectWorkflowStateDoesNotExposeUnusedShellReferenceSurface() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectWorkflowState.swift",
            omits: [
                "private(set) var projects: [ShellProjectReference]",
                "private(set) var suggestedProjects: [ShellProjectReference]",
                "private(set) var selectedProject: ShellProjectReference?",
                "func select(project: ShellProjectReference?)",
                "private static func projectReference(",
                "private static func suggestedProjectReference(",
            ],
        )
    }

    func testProjectWorkflowStateDoesNotExposeLegacyProjectMirrors() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectWorkflowState.swift",
            omits: [
                "private(set) var legacyProjects: [Project] = []",
                "private static func legacyProject(",
                "private static func legacyProjectStats(",
            ],
        )
    }

    func testOrderingAndListStateAreNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectListState.swift",
            omits: [
                "func visibleProjects(from projects: [Project]) -> [Project]",
                "func pausedProjects(from projects: [Project]) -> [Project]",
                "func orderedProjects(\n        _ projects: [Project],",
                "func moveProject(\n        from source: IndexSet,\n        to destination: Int,\n        in projectList: [Project],",
                "func moveToDormant(_ project: Project)",
                "func moveToRecent(_ project: Project)",
                "func isManuallyDormant(_ project: Project) -> Bool",
            ],
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Utilities/ProjectOrdering.swift",
            omits: [
                "static func orderedProjects(_ projects: [Project], customOrder: [String]) -> [Project]",
                "static func movedOrder(from source: IndexSet, to destination: Int, in projectList: [Project]) -> [String]",
                "static func movedGlobalOrder(\n        from source: IndexSet,\n        to destination: Int,\n        in projectList: [Project],",
            ],
        )
    }

    func testProjectStatusCacheStateDoesNotRequireProjectModels() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectStatusCacheState.swift",
            omits: [
                "func refresh(projects: [Project], engine: CoreRuntime?)",
                "updated[project.path] = status",
            ],
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repositoryRootURL().appendingPathComponent("apps/swift/Sources/Capacitor/Models/ProjectIngestionWorker.swift").path),
            "ProjectIngestionWorker.swift should be deleted once project mutation owns import batching directly.",
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectMutationService.swift",
            omits: [
                "ProjectIngestionWorker",
            ],
        )
    }

    func testProjectDetailsAndFeatureIdeaSurfaceAreNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectDetailsManager.swift",
            omits: [
                "func captureIdea(for project: Project, text: String) -> Result<Void, Error>",
                "func loadIdeas(for project: Project)",
                "func loadAllIdeas(for projects: [Project])",
                "func loadAllIdeasIncrementally(\n        for projects: [Project],",
                "func checkIdeasFileChanges(for projects: [Project])",
                "func getIdeas(for project: Project) -> [Idea]",
                "func updateIdeaStatus(for project: Project, idea: Idea, newStatus: String) throws",
                "func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project)",
                "func getDescription(for project: Project) -> String?",
                "func isGeneratingDescription(for project: Project) -> Bool",
                "func generateDescription(for project: Project)",
            ],
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repositoryRootURL().appendingPathComponent("apps/swift/Sources/Capacitor/Features/ProjectFeatureCoordinator.swift").path),
            "ProjectFeatureCoordinator.swift should be deleted once the canonical application-owned presentation state exists.",
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Projects/ProjectPresentationState.swift",
            omits: [
                "private let captureIdeaHandler: @MainActor (Project, String) -> Result<Void, Error>",
                "private let checkIdeasFileChangesHandler: @MainActor ([Project]) -> Void",
                "private let getIdeasHandler: @MainActor (Project) -> [Idea]",
                "private let dismissIdeaHandler: @MainActor (Idea, Project) throws -> Void",
                "private let reorderIdeasHandler: @MainActor ([Idea], Project) -> Void",
                "private let getDescriptionHandler: @MainActor (Project) -> String?",
                "private let isGeneratingDescriptionHandler: @MainActor (Project) -> Bool",
                "private let generateDescriptionHandler: @MainActor (Project) -> Void",
                "func captureIdea(for project: Project, text: String) -> Result<Void, Error>",
                "func checkIdeasFileChanges(for projects: [Project])",
                "func ideas(for project: Project) -> [Idea]",
                "func dismissIdea(_ idea: Idea, for project: Project)",
                "func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project)",
                "func description(for project: Project) -> String?",
                "func isGeneratingDescription(for project: Project) -> Bool",
                "func generateDescription(for project: Project)",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "ProjectFeatureCoordinator",
            allowedFiles: [],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "projectFeatureCoordinator",
            allowedFiles: [],
        )
    }
}
