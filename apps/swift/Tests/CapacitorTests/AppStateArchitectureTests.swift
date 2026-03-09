import XCTest

final class AppStateArchitectureTests: XCTestCase, ArchitectureAssertions {
    func testAppStateDoesNotStoreProjectMutationGateway() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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

    func testAppStateDoesNotOwnProjectCreationState() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
            omits: [
                "didSet { syncNavigationState() }",
                "private func syncNavigationState()",
            ],
        )
    }

    func testAppStateDoesNotOwnRuntimeBootstrapTimerLifecycle() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
            omits: [
                "func loadDashboard(",
                "dashboard = try engine.loadDashboard()",
                "projectWorkflowState.replaceProjectCatalog(\n                with: ProjectCatalogBridge.projectCatalogEntries(from: dashboard?.projects ?? [])",
                "projectDetailsManager.loadAllIdeas(for: projects)",
            ],
        )
    }

    func testAppStateDoesNotFetchRuntimeSnapshotDirectly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
            omits: [
                "RuntimeClient.shared.fetchRuntimeSnapshot(",
                "RuntimeClient.shared.fetchHealth(",
                "engine.getHookDiagnostic(",
                "engine.runHookTest(",
            ],
        )
    }

    func testAppStateDoesNotExposeSetupMutationFacadeMethods() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
            omits: [
                "func checkHookDiagnostic()",
                "func fixHooks()",
                "func testHooks() -> HookTestResult",
            ],
        )
    }

    func testAppStateDoesNotOwnTerminalActivationPolicy() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
            omits: [
                "private(set) var projectStatuses",
                "private func refreshProjectStatuses()",
            ],
        )
    }

    func testAppStateDoesNotExposeSessionOrCreationPassthroughHelpers() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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

    func testAppStateConvenienceInitializerCountDoesNotIncrease() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Composition/AppState.swift")

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
            expectedFiles: [
                "apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Tests/CapacitorTests",
            containing: "= AppState(",
            expectedFiles: [
                "apps/swift/Tests/CapacitorTests/AppStateTestSupport.swift",
                "apps/swift/Tests/CapacitorTests/AppStateArchitectureTests.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
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

    func testAppStateDoesNotAssembleCollaboratorsDirectly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
            omits: [
                "configureCollaborators(",
                "WindowAnchoringController()",
                "ShellStateStore()",
                "SessionStateManager()",
                "Support.HookServerManager()",
                "ProjectDetailsManager()",
                "ProjectMutationService(",
                "ProjectActionState(",
                "ProjectActivationCoordinator(",
                "ProjectImportCoordinator(",
                "QuickFeedbackWorkflow(",
                "SetupActionState(",
                "DashboardLoader(",
                "ProjectCreationCoordinator(",
                "ProjectPresentationState(",
                "DashboardState(",
                "ProjectStatusCacheState()",
                "RuntimeHealthState(",
                "RuntimeRefreshOrchestrator(",
                "RuntimeSessionRefreshController(",
                "RuntimeAutomationComposer.makeController(",
                "projectCreationCoordinator.loadCreations()",
                "runtimeAutomationController.startBootstrap()",
            ],
        )
    }

    func testAppStateRuntimeTestingHookIsNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Composition/AppState.swift",
            omits: [
                "projects: [Project],",
            ],
        )
    }
}
