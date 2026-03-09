@testable import Capacitor
import XCTest

@MainActor
final class RuntimeSessionRefreshControllerTests: XCTestCase {
    func testStaleObservationDoesNotApplyShellState() async {
        let sessionStateManager = SessionStateManager()
        let shellStateStore = ShellStateStore()
        let project = ShellProjectReference(displayName: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let controller = RuntimeSessionRefreshController(
            runtimeSupervisor: RuntimeSupervisor(runtimeGateway: StubRuntimeGateway()),
            sessionStateProjector: sessionStateManager,
            shellStateProjector: shellStateStore,
            didUpdateContext: {},
        )

        await shellStateStore.applyRuntimeShellState(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
            ).shellState,
            correlationId: "baseline",
        )

        controller.setGenerationForTesting(2)

        await controller.applyObservationForTesting(
            ShellRuntimeObservation(
                projectStates: [
                    RuntimeProjectState(
                        projectId: nil,
                        workspaceId: nil,
                        projectPath: project.path,
                        state: "working",
                        updatedAt: "2026-03-05T00:00:00Z",
                        stateChangedAt: "2026-03-05T00:00:00Z",
                        sessionId: "stale-session",
                        latestSessionId: "stale-session",
                        sessionCount: 1,
                        activeCount: 1,
                        hasSession: true,
                    ),
                ],
                sessions: [],
                shellState: ShellCwdState(
                    version: 1,
                    shells: [
                        "111": ShellEntry(
                            cwd: "/stale",
                            tty: "/dev/ttys001",
                            parentApp: "Ghostty",
                            tmuxSession: nil,
                            tmuxClientTty: nil,
                            updatedAt: Date(timeIntervalSince1970: 1_741_132_800),
                        ),
                    ],
                ),
            ),
            refreshGeneration: 1,
            correlationId: "stale",
            projects: [project],
        )

        XCTAssertEqual(shellStateStore.state?.shells["111"]?.cwd, "/baseline")
    }

    func testSecondFreshFailureClearsRuntimeDerivedState() async {
        let sessionStateManager = SessionStateManager()
        let shellStateStore = ShellStateStore()
        let project = ShellProjectReference(displayName: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let controller = RuntimeSessionRefreshController(
            runtimeSupervisor: RuntimeSupervisor(runtimeGateway: StubRuntimeGateway()),
            sessionStateProjector: sessionStateManager,
            shellStateProjector: shellStateStore,
            didUpdateContext: {},
        )

        sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: "2026-03-05T00:00:00Z",
                updatedAt: "2026-03-05T00:00:00Z",
                sessionId: "stale-session",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])
        await shellStateStore.applyRuntimeShellState(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "stale-session",
                shellCwd: "/stale",
                shellPid: "111",
            ).shellState,
            correlationId: "baseline",
        )
        controller.setGenerationForTesting(1)

        controller.handleFailureForTesting(
            refreshGeneration: 1,
            correlationId: "failure-1",
            errorDescription: "unavailable",
        )
        XCTAssertEqual(sessionStateManager.getSessionState(for: project)?.sessionId, "stale-session")
        XCTAssertEqual(shellStateStore.state?.shells["111"]?.cwd, "/stale")

        controller.handleFailureForTesting(
            refreshGeneration: 1,
            correlationId: "failure-2",
            errorDescription: "unavailable",
        )

        XCTAssertNil(sessionStateManager.getSessionState(for: project))
        XCTAssertNil(shellStateStore.state)
    }

    private func makeRuntimeSnapshot(
        projectPath: String,
        sessionId: String,
        shellCwd: String,
        shellPid: String,
    ) -> RuntimeSnapshot {
        let timestamp = "2026-03-05T00:00:00Z"
        return RuntimeSnapshot(
            projectStates: [
                RuntimeProjectState(
                    projectId: nil,
                    workspaceId: nil,
                    projectPath: projectPath,
                    state: "working",
                    updatedAt: timestamp,
                    stateChangedAt: timestamp,
                    sessionId: sessionId,
                    latestSessionId: sessionId,
                    sessionCount: 1,
                    activeCount: 1,
                    hasSession: true,
                ),
            ],
            sessions: [],
            shellState: ShellCwdState(
                version: 1,
                shells: [
                    shellPid: ShellEntry(
                        cwd: shellCwd,
                        tty: "/dev/ttys001",
                        parentApp: "Ghostty",
                        tmuxSession: nil,
                        tmuxClientTty: nil,
                        updatedAt: Date(timeIntervalSince1970: 1_741_132_800),
                    ),
                ],
            ),
        )
    }
}

private struct StubRuntimeGateway: RuntimeGateway {
    func fetchObservation(correlationId _: String?) async throws -> ShellRuntimeObservation {
        throw RuntimeClientError.timeout
    }

    func fetchHealthStatus() async throws -> ShellRuntimeHealthStatus {
        ShellRuntimeHealthStatus(
            isEnabled: true,
            isHealthy: true,
            message: "ok",
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
