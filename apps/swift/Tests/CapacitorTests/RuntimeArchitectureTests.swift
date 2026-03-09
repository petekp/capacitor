import XCTest

final class RuntimeArchitectureTests: XCTestCase, ArchitectureAssertions {
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

    func testSetupWorkflowStateOwnsSetupWithoutLegacyManagerFile() throws {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repositoryRootURL().appendingPathComponent("apps/swift/Sources/Capacitor/Models/SetupRequirements.swift").path),
            "SetupRequirements.swift should be deleted once setup ownership moves fully into Application.",
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Setup/SetupWorkflowState.swift",
            omits: [
                "engine.checkSetupStatus(",
                "engine.checkDependency(",
                "engine.getHookStatus(",
                "HookInstaller.ensureHooksInstalled(",
                "SetupRequirementsManager",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor",
            containing: "SetupRequirementsManager",
            allowedFiles: [],
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

    func testActiveProjectAndSessionLookupSurfaceAreNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Runtime/SessionStateManager.swift",
            omits: [
                "func isFlashing(_ project: Project) -> SessionState?",
                "func getSessionState(for project: Project) -> ProjectSessionState?",
                "func getSessionAttribution(for project: Project) -> SessionAttribution?",
                "func getPreferredSessionId(for project: Project) -> String?",
                "func applyRuntimeProjectStates(\n        _ runtimeProjects: [RuntimeProjectState],\n        for projects: [Project],",
            ],
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: repositoryRootURL().appendingPathComponent("apps/swift/Sources/Capacitor/Models/ActiveProjectResolver.swift").path),
            "ActiveProjectResolver.swift should be deleted once tracking owns its own resolution behavior.",
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Activation/ActiveProjectTrackingState.swift",
            omits: [
                "private(set) var activeProject: Project?",
                "func updateProjects(_ projects: [Project])",
                "func activate(_ project: Project)",
                "ActiveProjectResolver",
                "SessionStateManager",
            ],
        )
    }

    func testRuntimeSessionRefreshControllerIsNotProjectOnly() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Runtime/RuntimeSessionRefreshController.swift",
            omits: [
                "func refresh(projects: [Project])",
                "projects: [Project],",
                "SessionStateManager",
                "ShellStateStore",
            ],
        )

        try assertFile(
            "apps/swift/Sources/Capacitor/Application/Runtime/RuntimeRefreshOrchestrator.swift",
            omits: [
                "SessionStateManager",
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
            "apps/swift/Sources/Capacitor/Application/Projects/WorkstreamsManager.swift",
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

    func testTerminalActivationBoundaryDoesNotReconstructLegacyProjects() throws {
        try assertFile(
            "apps/swift/Sources/Capacitor/Support/TerminalLauncher.swift",
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
                "TerminalLauncher",
            ],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor/Composition",
            containing: "TerminalLauncher",
            allowedFiles: [],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor/Adapters",
            containing: "RuntimeClient",
            allowedFiles: [],
        )

        try assertSwiftFiles(
            under: "apps/swift/Sources/Capacitor/Utilities",
            containing: "RuntimeClient",
            allowedFiles: [],
        )
    }
}
