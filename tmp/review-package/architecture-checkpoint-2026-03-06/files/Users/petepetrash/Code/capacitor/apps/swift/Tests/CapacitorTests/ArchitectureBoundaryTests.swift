import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    func testAppStateDoesNotStoreProjectMutationGateway() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("private let projectMutationGateway"))
        XCTAssertFalse(source.contains("self.projectMutationGateway ="))
    }

    func testProjectCreationCoordinatorDoesNotDependOnProjectMutationGatewayType() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift")

        XCTAssertFalse(source.contains("ProjectMutationGateway"))
        XCTAssertFalse(source.contains("projectMutationGatewayProvider"))
    }

    func testAppStateDoesNotExposeProjectMutationFacadeMethods() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func connectSelectedSuggestions()"))
        XCTAssertFalse(source.contains("func removeProject(_ path: String)"))
        XCTAssertFalse(source.contains("func createClaudeMd(for path: String) -> Bool"))
        XCTAssertFalse(source.contains("func addProjectsFromDrop("))
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
        XCTAssertFalse(source.contains("private var hookHealthCheckCounter"))
        XCTAssertFalse(source.contains("private var hookServerHealthCounter"))
        XCTAssertFalse(source.contains("private var statsRefreshCounter"))
        XCTAssertFalse(source.contains("private var runtimeHealthCheckCounter"))
        XCTAssertFalse(source.contains("private func scheduleRuntimeBootstrap()"))
        XCTAssertFalse(source.contains("private func setupRefreshTimer()"))
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

    func testAppStateDoesNotExposeSetupMutationFacadeMethods() throws {
        let source = try loadSourceFile(at: "apps/swift/Sources/Capacitor/Models/AppState.swift")

        XCTAssertFalse(source.contains("func checkHookDiagnostic()"))
        XCTAssertFalse(source.contains("func fixHooks()"))
        XCTAssertFalse(source.contains("func testHooks() -> HookTestResult"))
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
