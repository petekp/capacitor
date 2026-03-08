import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testAppStateDoesNotStoreProjectMutationGateway() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "private let projectMutationGateway",
                "self.projectMutationGateway =",
                "LiveProjectCatalogGateway(",
                "LiveProjectListPreferencesGateway(",
                "LiveProjectMutationGateway(",
                "LiveRuntimeGateway(",
                "LiveSetupGateway(",
            ],
        )
    }

    func testProjectCreationCoordinatorDoesNotDependOnProjectMutationGatewayType() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift",
            omits: [
                "ProjectMutationGateway",
                "projectMutationGatewayProvider",
            ],
        )
    }

    func testAppStateDoesNotOwnProjectCreationState() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "var activeCreations: [ProjectCreation]",
                "func cancelCreation(_ id: String)",
                "func resumeCreation(_ id: String)",
                "func canResumeCreation(_ id: String) -> Bool",
            ],
        )
    }

    func testAppStateDoesNotExposeProjectMutationFacadeMethods() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "var projects: [Project]",
                "var suggestedProjects: [SuggestedProject]",
                "func connectSelectedSuggestions()",
                "func removeProject(_ path: String)",
                "func createClaudeMd(for path: String) -> Bool",
                "func addProjectsFromDrop(",
                "func refreshSuggestedProjects()",
                "private static func formatMixedResultsToast(",
            ],
        )
    }

    func testAppStateDoesNotExposeProjectFeatureFacadeMethods() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func showProjectDetail(_ project: Project)",
                "func showProjectList()",
                "func showNewIdea()",
                "func showIdeaCaptureModal(",
                "func captureIdea(for project: Project, text: String)",
                "func getIdeas(for project: Project)",
                "func generateDescription(for project: Project)",
                "func createProjectFromIdea(",
            ],
        )
    }

    func testAppStateDoesNotSynchronizeNavigationInDidSet() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "didSet { syncNavigationState() }",
                "private func syncNavigationState()",
            ],
        )
    }

    func testAppStateDoesNotOwnRuntimeBootstrapTimerLifecycle() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "private var refreshTimer",
                "private var runtimeBootstrapTask",
                "RuntimeBootstrapCoordinator.live(",
                "RuntimeAutomationController(",
                "private var hookHealthCheckCounter",
                "private var hookServerHealthCounter",
                "private var statsRefreshCounter",
                "private var runtimeHealthCheckCounter",
                "private func scheduleRuntimeBootstrap()",
                "private func setupRefreshTimer()",
                "try CoreRuntime()",
            ],
        )
    }

    func testAppStateDoesNotOwnRuntimeSessionRefreshPolicyState() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func refreshSessionStates()",
                "private func updatePostSessionRefreshContext()",
                "private func activeWorktreePathsForGuardrails()",
                "private var runtimeSnapshotTask",
                "private var runtimeSnapshotGeneration",
                "private var runtimeSnapshotCorrelationCounter",
                "private var consecutiveRuntimeSnapshotFailures",
                "private func nextRuntimeSnapshotCorrelationId()",
                "private func applyRuntimeObservationIfFresh(",
                "private func handleRuntimeSnapshotFailureIfFresh(",
            ],
        )
    }

    func testAppStateDoesNotOwnRuntimeHealthPolicy() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func ensureRuntimeReady()",
                "func checkRuntimeHealth()",
                "private func refreshAERoutingRuntimeFlags(",
                "Telemetry.emit(\"runtime_health\"",
            ],
        )
    }

    func testAppStateDoesNotInlineDashboardProjectionWorkflow() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func loadDashboard(",
                "dashboard = try engine.loadDashboard()",
                "projectWorkflowState.replaceProjectCatalog(\n                with: ProjectCatalogBridge.projectCatalogEntries(from: dashboard?.projects ?? [])",
                "projectDetailsManager.loadAllIdeas(for: projects)",
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

    func testAppStateDoesNotFetchRuntimeSnapshotDirectly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "RuntimeClient.shared.fetchRuntimeSnapshot(",
                "RuntimeClient.shared.fetchHealth(",
                "engine.getHookDiagnostic(",
                "engine.runHookTest(",
            ],
        )
    }

    func testAppDoesNotRunStartupSetupDirectlyAgainstCoreRuntime() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/App.swift",
            omits: [
                "checkSetupStatus(",
                "HookInstaller.ensureHooksInstalled(",
                "try? CoreRuntime()",
            ],
        )
    }

    func testSetupRequirementsManagerDoesNotTalkToCoreRuntimeDirectly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/SetupRequirements.swift",
            omits: [
                "engine.checkSetupStatus(",
                "engine.checkDependency(",
                "engine.getHookStatus(",
                "HookInstaller.ensureHooksInstalled(",
            ],
        )
    }

    func testHookInstallerDoesNotReadHookStatusDirectly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Helpers/HookInstaller.swift",
            omits: [
                "func getHookStatus()",
                "engine.getHookStatus(",
                "let status =",
            ],
        )
    }

    func testAppStateDoesNotExposeSetupMutationFacadeMethods() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func checkHookDiagnostic()",
                "func fixHooks()",
                "func testHooks() -> HookTestResult",
            ],
        )
    }

    func testAppStateDoesNotOwnTerminalActivationPolicy() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "let terminalLauncher = TerminalLauncher()",
                "terminalLauncher.preferredTerminalAppResolver =",
                "terminalLauncher.onActivationResult =",
                "private static func makeLiveActivateProjectTerminal()",
                "ActivateProjectTerminalUseCase(activationGateway: LiveActivationGateway())",
                "func launchTerminal(for project: Project)",
                "activeProjectResolver.setManualOverride(",
                "terminalLauncher.launchTerminal(for:",
            ],
        )
    }

    func testAppStateDoesNotOwnActiveProjectResolverPolicy() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "private(set) var activeProjectResolver",
                "ActiveProjectResolver(",
                "activeProjectResolver.updateProjects(",
                "activeProjectResolver.resolve()",
            ],
        )
    }

    func testAppStateDoesNotInlineQuickFeedbackWorkflow() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func submitQuickFeedback(",
                "QuickFeedbackSubmitter(",
                "Telemetry.emit(\"quick_feedback_submitted\"",
                "QuickFeedbackFunnel.emitSubmitResult(",
                "URLSession.shared.data(for:",
            ],
        )
    }

    func testAppStateDoesNotOwnProjectImportIngress() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func connectProjectViaFileBrowser()",
                "func handleFileURLDrop(_ providers: [NSItemProvider])",
                "private func collectDroppedFileURLs(",
                "NSOpenPanel()",
            ],
        )
    }

    func testAppStateDoesNotOwnProjectStatusCache() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "private(set) var projectStatuses",
                "private func refreshProjectStatuses()",
            ],
        )
    }

    func testAppStateDoesNotExposeSessionOrCreationPassthroughHelpers() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "func getSessionState(for project: Project)",
                "func isFlashing(_ project: Project)",
                "func getProjectStatus(for project: Project)",
                "func collectDroppedFileURLsForTesting(",
                "func applyDiscoveredSessionToCreationForTesting(",
                "func setCreationMonitorTasksForTesting(",
                "func hasCreationMonitorTasksForTesting(",
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

    func testWelcomeViewDoesNotConstructSetupManagerDirectly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Views/Setup/WelcomeView.swift",
            omits: [
                "SetupRequirementsManager()",
                "manager =",
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

    func testLiveCompositionSurfaceIsConfinedToKnownFiles() throws {
        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "LiveRuntimeGateway(",
            allowedFiles: [
                "apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "LiveProjectCatalogGateway(",
            allowedFiles: [
                "apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "LiveProjectListPreferencesGateway(",
            allowedFiles: [
                "apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "LiveProjectMutationGateway(",
            allowedFiles: [
                "apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "self.init(dependencies: .live(",
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
    }

    func testActiveProjectAndSessionLookupSurfaceAreNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/SessionStateManager.swift",
            omits: [
                "func isFlashing(_ project: Project) -> SessionState?",
                "func getSessionState(for project: Project) -> ProjectSessionState?",
                "func getSessionAttribution(for project: Project) -> SessionAttribution?",
                "func getPreferredSessionId(for project: Project) -> String?",
                "func applyRuntimeProjectStates(\n        _ runtimeProjects: [RuntimeProjectState],\n        for projects: [Project],",
            ],
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Models/ActiveProjectResolver.swift",
            omits: [
                "private(set) var activeProject: Project?",
                "private var projects: [Project] = []",
                "private var manualOverride: Project?",
                "func updateProjects(_ projects: [Project])",
                "func setManualOverride(_ project: Project)",
                "private func findActiveClaudeSession() -> (Project, String)?",
            ],
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Activation/ActiveProjectTrackingState.swift",
            omits: [
                "private(set) var activeProject: Project?",
                "func updateProjects(_ projects: [Project])",
                "func activate(_ project: Project)",
            ],
        )
    }

    func testRuntimeSessionRefreshControllerIsNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Runtime/RuntimeSessionRefreshController.swift",
            omits: [
                "func refresh(projects: [Project])",
                "projects: [Project],",
            ],
        )
    }

    func testActivationAndWorkstreamsSurfaceAreNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Activation/ProjectActivationCoordinator.swift",
            omits: [
                "private let activateTracking: (Project) -> Void",
                "private let activateProject: (Project) -> Void",
                "func activate(_ project: Project)",
            ],
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Models/WorkstreamsManager.swift",
            omits: [
                "typealias OpenWorktree = (_ project: Project) -> Void",
                "func state(for project: Project) -> State",
                "func load(for project: Project)",
                "func create(for project: Project)",
                "func destroy(worktreeName: String, for project: Project, force: Bool = false)",
                "private static func nextWorktreeName(for project: Project, from names: Set<String>) -> String",
                "private static func worktreePrefix(for project: Project) -> String",
            ],
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Support/Accessibility/AccessibilityIdentifiers.swift",
            omits: [
                "static func projectCardIdentifier(for project: Project) -> String",
                "static func projectDetailsIdentifier(for project: Project) -> String",
                "static func slug(for project: Project) -> String",
            ],
        )
    }

    func testProjectDetailsAndFeatureIdeaSurfaceAreNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift",
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

        try assertFile(
            "apps/swift/Sources/Capacitor/Features/ProjectFeatureCoordinator.swift",
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
                "func getIdeas(for project: Project) -> [Idea]",
                "func dismissIdea(_ idea: Idea, for project: Project)",
                "func reorderIdeas(_ reorderedIdeas: [Idea], for project: Project)",
                "func getDescription(for project: Project) -> String?",
                "func isGeneratingDescription(for project: Project) -> Bool",
                "func generateDescription(for project: Project)",
            ],
        )
    }

    func testAppStateConvenienceInitializerCountDoesNotIncrease() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertEqual(
            countOccurrences(of: "convenience init(", in: source),
            0,
            "AppState convenience-init surface should be zero; construct dependencies explicitly in composition/tests.",
        )
    }

    func testAppStateConstructionIsConfinedToCompositionAndTestSupport() throws {
        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "= AppState(",
            allowedFiles: [
                "apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Tests/CapacitorTests",
            containing: "return AppState(",
            allowedFiles: [
                "apps/swift/Tests/CapacitorTests/AppStateTestSupport.swift",
                "apps/swift/Tests/CapacitorTests/ArchitectureBoundaryTests.swift",
            ],
        )
    }

    func testAppStateDependenciesDoesNotConstructLiveWorld() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppStateDependencies.swift",
            omits: [
                "static func live(",
                "LiveRuntimeGateway()",
                "LiveProjectCatalogGateway()",
                "LiveProjectListPreferencesGateway()",
                "LiveSetupGateway()",
                "LiveProjectMutationGateway()",
            ],
        )
    }

    func testAppStateDoesNotKeepDeadProfileOrTrackingFlags() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "private(set) var profile: AppProfile = .stable",
                "profile = config.profile",
                "profile=\\(profile.rawValue)",
                "private(set) var didStartShellTrackingForTesting = false",
                "didStartShellTrackingForTesting = true",
            ],
        )
    }

    func testAppStateDoesNotPersistLayoutModeLocally() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "didSet { saveLayoutMode() }",
                "private let layoutModeKey = \"layoutMode\"",
                "loadLayoutMode()",
                "saveLayoutMode()",
                "UserDefaults.standard.string(forKey:",
                "UserDefaults.standard.set(",
            ],
        )
    }

    func testTerminalActivationBoundaryDoesNotReconstructLegacyProjects() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift",
            omits: [
                "func launchTerminal(for project: Project)",
                "private func launchTerminalAsync(for project: Project",
                "private func resolveSessionName(for project: Project)",
                "\"project\": project.name",
                "projectName: project.name",
            ],
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Adapters/Shell/LiveActivationGateway.swift",
            omits: [
                "let project = Project(",
                "terminalLauncher.launchTerminal(for: project)",
            ],
        )
    }

    func testAppStateRuntimeTestingHookIsNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Models/AppState.swift",
            omits: [
                "projects: [Project],",
            ],
        )
    }

    private func assertFile(
        _ relativePath: String,
        omits forbiddenSnippets: [String],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        let source = try loadSourceFile(at: relativePath)
        assertSource(
            source,
            omits: forbiddenSnippets,
            relativePath: relativePath,
            file: file,
            line: line,
        )
    }

    private func assertFiles(
        _ relativePaths: [String],
        omits forbiddenSnippets: [String],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        for relativePath in relativePaths {
            try assertFile(
                relativePath,
                omits: forbiddenSnippets,
                file: file,
                line: line,
            )
        }
    }

    private func assertSource(
        _ source: String,
        omits forbiddenSnippets: [String],
        relativePath: String,
        file: StaticString,
        line: UInt,
    ) {
        for forbiddenSnippet in forbiddenSnippets {
            XCTAssertNil(
                source.range(of: forbiddenSnippet),
                "Unexpected architecture boundary leak in \(relativePath): \(forbiddenSnippet)",
                file: file,
                line: line,
            )
        }
    }

    private func assertSwiftFiles(
        under relativeDirectory: String,
        containing snippet: String,
        allowedFiles: [String],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        var matchingFiles: [String] = []

        for relativePath in try swiftFiles(under: relativeDirectory) {
            let source = try loadSourceFile(at: relativePath)
            if source.range(of: snippet) != nil {
                matchingFiles.append(relativePath)
            }
        }

        XCTAssertEqual(
            matchingFiles.sorted(),
            allowedFiles.sorted(),
            "Unexpected file set containing \(snippet)",
            file: file,
            line: line,
        )
    }

    private func swiftFiles(under relativeDirectory: String) throws -> [String] {
        let baseURL = repositoryRootURL().appendingPathComponent(relativeDirectory)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: nil,
        ) else {
            XCTFail("Could not enumerate Swift files under \(relativeDirectory)")
            return []
        }

        var result: [String] = []
        let repositoryRoot = repositoryRootURL()

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let relativePath = fileURL.path.replacingOccurrences(
                of: repositoryRoot.path + "/",
                with: "",
            )
            result.append(relativePath)
        }

        return result
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchRange = haystack.startIndex ..< haystack.endIndex

        while let matchRange = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = matchRange.upperBound ..< haystack.endIndex
        }

        return count
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadSourceFile(at relativePath: String) throws -> String {
        let fileURL = repositoryRootURL().appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
