import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testAppStateDoesNotStoreProjectMutationGateway() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("private let projectMutationGateway"))
        XCTAssertFalse(source.contains("self.projectMutationGateway ="))
        XCTAssertFalse(source.contains("LiveProjectCatalogGateway("))
        XCTAssertFalse(source.contains("LiveProjectListPreferencesGateway("))
        XCTAssertFalse(source.contains("LiveProjectMutationGateway("))
        XCTAssertFalse(source.contains("LiveRuntimeGateway("))
        XCTAssertFalse(source.contains("LiveSetupGateway("))
    }

    func testProjectCreationCoordinatorDoesNotDependOnProjectMutationGatewayType() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift")

        XCTAssertFalse(source.contains("ProjectMutationGateway"))
        XCTAssertFalse(source.contains("projectMutationGatewayProvider"))
    }

    func testAppStateDoesNotOwnProjectCreationState() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("var activeCreations: [ProjectCreation]"))
        XCTAssertFalse(source.contains("func cancelCreation(_ id: String)"))
        XCTAssertFalse(source.contains("func resumeCreation(_ id: String)"))
        XCTAssertFalse(source.contains("func canResumeCreation(_ id: String) -> Bool"))
    }

    func testAppStateDoesNotExposeProjectMutationFacadeMethods() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("var projects: [Project]"))
        XCTAssertFalse(source.contains("var suggestedProjects: [SuggestedProject]"))
        XCTAssertFalse(source.contains("func connectSelectedSuggestions()"))
        XCTAssertFalse(source.contains("func removeProject(_ path: String)"))
        XCTAssertFalse(source.contains("func createClaudeMd(for path: String) -> Bool"))
        XCTAssertFalse(source.contains("func addProjectsFromDrop("))
        XCTAssertFalse(source.contains("func refreshSuggestedProjects()"))
        XCTAssertFalse(source.contains("private static func formatMixedResultsToast("))
    }

    func testAppStateDoesNotExposeProjectFeatureFacadeMethods() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func showProjectDetail(_ project: Project)"))
        XCTAssertFalse(source.contains("func showProjectList()"))
        XCTAssertFalse(source.contains("func showNewIdea()"))
        XCTAssertFalse(source.contains("func showIdeaCaptureModal("))
        XCTAssertFalse(source.contains("func captureIdea(for project: Project, text: String)"))
        XCTAssertFalse(source.contains("func getIdeas(for project: Project)"))
        XCTAssertFalse(source.contains("func generateDescription(for project: Project)"))
        XCTAssertFalse(source.contains("func createProjectFromIdea("))
    }

    func testAppStateDoesNotSynchronizeNavigationInDidSet() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("didSet { syncNavigationState() }"))
        XCTAssertFalse(source.contains("private func syncNavigationState()"))
    }

    func testAppStateDoesNotOwnRuntimeBootstrapTimerLifecycle() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("private var refreshTimer"))
        XCTAssertFalse(source.contains("private var runtimeBootstrapTask"))
        XCTAssertFalse(source.contains("RuntimeBootstrapCoordinator.live("))
        XCTAssertFalse(source.contains("RuntimeAutomationController("))
        XCTAssertFalse(source.contains("private var hookHealthCheckCounter"))
        XCTAssertFalse(source.contains("private var hookServerHealthCounter"))
        XCTAssertFalse(source.contains("private var statsRefreshCounter"))
        XCTAssertFalse(source.contains("private var runtimeHealthCheckCounter"))
        XCTAssertFalse(source.contains("private func scheduleRuntimeBootstrap()"))
        XCTAssertFalse(source.contains("private func setupRefreshTimer()"))
        XCTAssertFalse(source.contains("try CoreRuntime()"))
    }

    func testAppStateDoesNotOwnRuntimeSessionRefreshPolicyState() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func refreshSessionStates()"))
        XCTAssertFalse(source.contains("private func updatePostSessionRefreshContext()"))
        XCTAssertFalse(source.contains("private func activeWorktreePathsForGuardrails()"))
        XCTAssertFalse(source.contains("private var runtimeSnapshotTask"))
        XCTAssertFalse(source.contains("private var runtimeSnapshotGeneration"))
        XCTAssertFalse(source.contains("private var runtimeSnapshotCorrelationCounter"))
        XCTAssertFalse(source.contains("private var consecutiveRuntimeSnapshotFailures"))
        XCTAssertFalse(source.contains("private func nextRuntimeSnapshotCorrelationId()"))
        XCTAssertFalse(source.contains("private func applyRuntimeObservationIfFresh("))
        XCTAssertFalse(source.contains("private func handleRuntimeSnapshotFailureIfFresh("))
    }

    func testAppStateDoesNotOwnRuntimeHealthPolicy() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func ensureRuntimeReady()"))
        XCTAssertFalse(source.contains("func checkRuntimeHealth()"))
        XCTAssertFalse(source.contains("private func refreshAERoutingRuntimeFlags("))
        XCTAssertFalse(source.contains("Telemetry.emit(\"runtime_health\""))
    }

    func testAppStateDoesNotInlineDashboardProjectionWorkflow() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func loadDashboard("))
        XCTAssertFalse(source.contains("dashboard = try engine.loadDashboard()"))
        XCTAssertFalse(source.contains("projectWorkflowState.replaceProjectCatalog(\n                with: ProjectCatalogBridge.projectCatalogEntries(from: dashboard?.projects ?? [])"))
        XCTAssertFalse(source.contains("projectDetailsManager.loadAllIdeas(for: projects)"))
    }

    func testProjectViewsDoNotCallProjectMutationThroughAppState() throws {
        let files = [
            "apps/swift/Sources/Capacitor/Views/Footer/FooterView.swift",
            "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift",
            "apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift",
            "apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift",
            "apps/swift/Sources/Capacitor/ContentView.swift",
            "apps/swift/Sources/Capacitor/Debug/AppDebugSupport.swift",
        ]

        for path in files {
            let source = try loadSourceFile(at: path)
            XCTAssertFalse(source.contains("appState.removeProject("), path)
            XCTAssertFalse(source.contains("appState.connectSelectedSuggestions()"), path)
            XCTAssertFalse(source.contains("appState.createClaudeMd("), path)
            XCTAssertFalse(source.contains("appState.addProjectsFromDrop("), path)
        }
    }

    func testAppStateDoesNotFetchRuntimeSnapshotDirectly() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("RuntimeClient.shared.fetchRuntimeSnapshot("))
        XCTAssertFalse(source.contains("RuntimeClient.shared.fetchHealth("))
        XCTAssertFalse(source.contains("engine.getHookDiagnostic("))
        XCTAssertFalse(source.contains("engine.runHookTest("))
    }

    func testAppDoesNotRunStartupSetupDirectlyAgainstCoreRuntime() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/App.swift")

        XCTAssertFalse(source.contains("checkSetupStatus("))
        XCTAssertFalse(source.contains("HookInstaller.ensureHooksInstalled("))
        XCTAssertFalse(source.contains("try? CoreRuntime()"))
    }

    func testSetupRequirementsManagerDoesNotTalkToCoreRuntimeDirectly() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/SetupRequirements.swift")

        XCTAssertFalse(source.contains("engine.checkSetupStatus("))
        XCTAssertFalse(source.contains("engine.checkDependency("))
        XCTAssertFalse(source.contains("engine.getHookStatus("))
        XCTAssertFalse(source.contains("HookInstaller.ensureHooksInstalled("))
    }

    func testHookInstallerDoesNotReadHookStatusDirectly() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Helpers/HookInstaller.swift")

        XCTAssertFalse(source.contains("func getHookStatus()"))
        XCTAssertFalse(source.contains("engine.getHookStatus("))
        XCTAssertFalse(source.contains("let status ="))
    }

    func testAppStateDoesNotExposeSetupMutationFacadeMethods() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func checkHookDiagnostic()"))
        XCTAssertFalse(source.contains("func fixHooks()"))
        XCTAssertFalse(source.contains("func testHooks() -> HookTestResult"))
    }

    func testAppStateDoesNotOwnTerminalActivationPolicy() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("let terminalLauncher = TerminalLauncher()"))
        XCTAssertFalse(source.contains("terminalLauncher.preferredTerminalAppResolver ="))
        XCTAssertFalse(source.contains("terminalLauncher.onActivationResult ="))
        XCTAssertFalse(source.contains("private static func makeLiveActivateProjectTerminal()"))
        XCTAssertFalse(source.contains("ActivateProjectTerminalUseCase(activationGateway: LiveActivationGateway())"))
        XCTAssertFalse(source.contains("func launchTerminal(for project: Project)"))
        XCTAssertFalse(source.contains("activeProjectResolver.setManualOverride("))
        XCTAssertFalse(source.contains("terminalLauncher.launchTerminal(for:"))
    }

    func testAppStateDoesNotOwnActiveProjectResolverPolicy() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("private(set) var activeProjectResolver"))
        XCTAssertFalse(source.contains("ActiveProjectResolver("))
        XCTAssertFalse(source.contains("activeProjectResolver.updateProjects("))
        XCTAssertFalse(source.contains("activeProjectResolver.resolve()"))
    }

    func testAppStateDoesNotInlineQuickFeedbackWorkflow() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func submitQuickFeedback("))
        XCTAssertFalse(source.contains("QuickFeedbackSubmitter("))
        XCTAssertFalse(source.contains("Telemetry.emit(\"quick_feedback_submitted\""))
        XCTAssertFalse(source.contains("QuickFeedbackFunnel.emitSubmitResult("))
        XCTAssertFalse(source.contains("URLSession.shared.data(for:"))
    }

    func testAppStateDoesNotOwnProjectImportIngress() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func connectProjectViaFileBrowser()"))
        XCTAssertFalse(source.contains("func handleFileURLDrop(_ providers: [NSItemProvider])"))
        XCTAssertFalse(source.contains("private func collectDroppedFileURLs("))
        XCTAssertFalse(source.contains("NSOpenPanel()"))
    }

    func testAppStateDoesNotOwnProjectStatusCache() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("private(set) var projectStatuses"))
        XCTAssertFalse(source.contains("private func refreshProjectStatuses()"))
    }

    func testAppStateDoesNotExposeSessionOrCreationPassthroughHelpers() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func getSessionState(for project: Project)"))
        XCTAssertFalse(source.contains("func isFlashing(_ project: Project)"))
        XCTAssertFalse(source.contains("func getProjectStatus(for project: Project)"))
        XCTAssertFalse(source.contains("func collectDroppedFileURLsForTesting("))
        XCTAssertFalse(source.contains("func applyDiscoveredSessionToCreationForTesting("))
        XCTAssertFalse(source.contains("func setCreationMonitorTasksForTesting("))
        XCTAssertFalse(source.contains("func hasCreationMonitorTasksForTesting("))
    }

    func testProjectViewsDoNotCallSetupMutationThroughAppState() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift")

        XCTAssertFalse(source.contains("appState.fixHooks()"))
        XCTAssertFalse(source.contains("appState.testHooks()"))
        XCTAssertFalse(source.contains("appState.checkHookDiagnostic()"))
    }

    func testProjectViewsDoNotCallProjectFeatureThroughAppStateFacade() throws {
        let files = [
            "apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift",
            "apps/swift/Sources/Capacitor/Views/Projects/NewIdeaView.swift",
            "apps/swift/Sources/Capacitor/Views/Navigation/NavigationContainer.swift",
            "apps/swift/Sources/Capacitor/Views/Header/HeaderView.swift",
            "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift",
            "apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift",
            "apps/swift/Sources/Capacitor/ContentView.swift",
        ]

        for path in files {
            let source = try loadSourceFile(at: path)
            XCTAssertFalse(source.contains("appState.showProjectList()"), path)
            XCTAssertFalse(source.contains("appState.showProjectDetail("), path)
            XCTAssertFalse(source.contains("appState.showIdeaCaptureModal("), path)
            XCTAssertFalse(source.contains("appState.captureIdea("), path)
            XCTAssertFalse(source.contains("appState.getIdeas("), path)
            XCTAssertFalse(source.contains("appState.generateDescription("), path)
            XCTAssertFalse(source.contains("appState.createProjectFromIdea("), path)
        }
    }

    func testWelcomeViewDoesNotConstructSetupManagerDirectly() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Views/Setup/WelcomeView.swift")

        XCTAssertFalse(source.contains("SetupRequirementsManager()"))
        XCTAssertFalse(source.contains("manager ="))
    }

    private func loadSourceFile(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let fileURL = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
