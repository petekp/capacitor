@testable import Capacitor
import XCTest

@MainActor
final class RuntimeRefreshOrchestratorTests: XCTestCase {
    func testActiveWorktreePathsIncludeWorkingSessionsAndActiveProject() {
        let sessionStateManager = SessionStateManager()
        let activeTracking = ActiveProjectTrackingState(projectSessionReader: sessionStateManager)
        let projectListState = ProjectListState(projectListPreferencesGateway: RuntimeRefreshNoopProjectListPreferencesGateway())
        let projectStatusCacheState = ProjectStatusCacheState()
        let runtimeSessionRefreshController = RuntimeSessionRefreshController(
            runtimeSupervisor: RuntimeSupervisor(runtimeGateway: RuntimeRefreshStubGateway()),
            sessionStateProjector: sessionStateManager,
            shellStateProjector: ShellStateStore(),
            didUpdateContext: {},
        )

        let project = makeProject(path: "/tmp/capacitor")
        activeTracking.updateProjects([project])
        activeTracking.activate(project)
        sessionStateManager.setSessionStatesForTesting([
            "/tmp/working": ProjectSessionState(
                state: .working,
                stateChangedAt: nil,
                updatedAt: nil,
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        let orchestrator = RuntimeRefreshOrchestrator(
            projectStatusCacheState: projectStatusCacheState,
            runtimeSessionRefreshController: runtimeSessionRefreshController,
            activeProjectTrackingState: activeTracking,
            projectListState: projectListState,
            sessionStateProjector: sessionStateManager,
            projectsProvider: { [project.shellProjectReference] },
        )

        let paths = orchestrator.activeWorktreePathsForGuardrails()

        XCTAssertTrue(paths.contains("/tmp/working"))
        XCTAssertTrue(paths.contains("/tmp/capacitor"))
    }

    private func makeProject(path: String) -> Project {
        Project(
            name: "Capacitor",
            path: path,
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }
}

private struct RuntimeRefreshNoopProjectListPreferencesGateway: ProjectListPreferencesGateway {
    func loadDormantProjectPaths() -> Set<String> {
        []
    }

    func saveDormantProjectPaths(_: Set<String>) {}
    func loadProjectOrder() -> [String] {
        []
    }

    func saveProjectOrder(_: [String]) {}
}

private struct RuntimeRefreshStubGateway: RuntimeGateway {
    func fetchObservation(correlationId _: String?) async throws -> ShellRuntimeObservation {
        ShellRuntimeObservation(projectStates: [], sessions: [], shellState: ShellCwdState(version: 1, shells: [:]))
    }

    func fetchHealthStatus() async throws -> ShellRuntimeHealthStatus {
        ShellRuntimeHealthStatus(
            isEnabled: false,
            isHealthy: false,
            message: "offline",
            pid: nil,
            version: nil,
            routingRollout: nil,
        )
    }

    func fetchProjection(correlationId _: String?) async throws -> ShellRuntimeProjection {
        ShellRuntimeProjection(
            generatedAt: Date(),
            activeProject: nil,
            projects: [],
            sessionsInFlight: 0,
            healthSummary: "stub",
        )
    }
}
