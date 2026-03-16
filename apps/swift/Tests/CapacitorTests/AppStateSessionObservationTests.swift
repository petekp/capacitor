@testable import Capacitor
import Observation
import XCTest

@MainActor
final class AppStateSessionObservationTests: XCTestCase {
    func testAppStateSessionReadInvalidatesWhenSessionStateChanges() {
        let appState = AppState()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")

        let invalidated = expectation(description: "observation invalidated")
        withObservationTracking {
            _ = appState.getSessionState(for: project)
        } onChange: {
            invalidated.fulfill()
        }

        appState.sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: "2026-02-11T17:35:32.479916+00:00",
                updatedAt: "2026-02-11T17:35:32.479916+00:00",
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        wait(for: [invalidated], timeout: 0.5)
    }

    func testOrderedGroupedProjectsInvalidatesWhenSessionStateChanges() {
        let appState = AppState()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projects = [project]

        let invalidated = expectation(description: "grouped projects invalidated")
        withObservationTracking {
            _ = appState.orderedGroupedProjects(appState.projects)
        } onChange: {
            invalidated.fulfill()
        }

        appState.sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: "2026-02-11T17:35:32.479916+00:00",
                updatedAt: "2026-02-11T17:35:32.479916+00:00",
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        wait(for: [invalidated], timeout: 0.5)
    }

    func testSessionStateRevisionIncrementsWhenSessionStateChanges() {
        let appState = AppState()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let initialRevision = appState.sessionStateRevision

        appState.sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: "2026-02-11T17:35:32.479916+00:00",
                updatedAt: "2026-02-11T17:35:32.479916+00:00",
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        XCTAssertEqual(appState.sessionStateRevision, initialRevision + 1)
    }

    func testStaleRuntimeSnapshotDoesNotApplyShellState() async {
        let appState = AppState()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projects = [project]

        let baselineSnapshot = makeRuntimeSnapshot(
            projectPath: project.path,
            sessionId: "baseline-session",
            shellCwd: "/baseline",
            shellPid: "111",
        )
        appState.shellStateStore.applyRuntimeShellState(
            baselineSnapshot.shellState,
            correlationId: "baseline",
        )
        appState.routingStateStore.applyRuntimeRoutingViews(
            baselineSnapshot.routingViews,
            correlationId: "baseline",
        )

        appState.setRuntimeSnapshotGenerationForTesting(2)

        let staleSnapshot = makeRuntimeSnapshot(
            projectPath: project.path,
            sessionId: "stale-session",
            shellCwd: "/stale",
            shellPid: "111",
        )
        await appState.applyRuntimeSnapshotForTesting(
            staleSnapshot,
            refreshGeneration: 1,
            correlationId: "stale",
            projects: [project],
        )

        XCTAssertEqual(
            appState.shellStateStore.state?.shells["111"]?.cwd,
            "/baseline",
            "stale generation should not mutate shell state",
        )
        XCTAssertEqual(
            appState.routingStateStore.routingView(projectPath: project.path, workspaceId: nil)?.target.sessionName,
            "baseline-session",
            "stale generation should not mutate routing state",
        )
    }

    func testRepeatedRuntimeSnapshotFailuresClearStaleActivityAfterThreshold() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projects = [project]
        appState.sessionStateManager.setSessionStatesForTesting([
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
        appState.shellStateStore.applyRuntimeShellState(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "stale-session",
                shellCwd: "/stale",
                shellPid: "111",
            ).shellState,
            correlationId: "baseline",
        )
        appState.setRuntimeSnapshotGenerationForTesting(1)

        appState.handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: 1,
            correlationId: "failure-1",
            errorDescription: "unavailable",
        )

        XCTAssertEqual(appState.getSessionState(for: project)?.sessionId, "stale-session")
        XCTAssertEqual(appState.shellStateStore.state?.shells["111"]?.cwd, "/stale")

        appState.handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: 1,
            correlationId: "failure-2",
            errorDescription: "unavailable",
        )

        XCTAssertNil(
            appState.getSessionState(for: project),
            "second consecutive fresh failure should clear stale runtime-derived session state",
        )
        XCTAssertNil(
            appState.shellStateStore.state,
            "second consecutive fresh failure should clear stale runtime-derived shell state",
        )
        XCTAssertTrue(
            appState.routingStateStore.routesByWorkspaceID.isEmpty,
            "second consecutive fresh failure should clear stale runtime-derived routing state",
        )
    }

    func testSuccessfulFreshSnapshotResetsRuntimeFailureHysteresis() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(5)

        appState.handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: 5,
            correlationId: "failure-before-success",
            errorDescription: "unavailable",
        )

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "fresh-session",
                shellCwd: "/fresh",
                shellPid: "111",
            ),
            refreshGeneration: 5,
            correlationId: "success",
            projects: [project],
        )

        XCTAssertEqual(appState.getSessionState(for: project)?.sessionId, "fresh-session")
        XCTAssertEqual(appState.shellStateStore.state?.shells["111"]?.cwd, "/fresh")

        appState.handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: 5,
            correlationId: "failure-after-success",
            errorDescription: "unavailable",
        )

        XCTAssertEqual(
            appState.getSessionState(for: project)?.sessionId,
            "fresh-session",
            "a fresh snapshot should reset failure hysteresis so the next failure is held again",
        )
        XCTAssertEqual(appState.shellStateStore.state?.shells["111"]?.cwd, "/fresh")
        XCTAssertEqual(
            appState.routingStateStore.routingView(projectPath: project.path, workspaceId: nil)?.target.sessionName,
            "fresh-session",
        )
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
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
            routingViews: [
                RuntimeRoutingView(
                    workspaceId: projectPath,
                    projectPath: projectPath,
                    status: "attached",
                    target: CoreRoutingTarget(kind: "tmux_session", sessionName: sessionId),
                    reasonCode: "TMUX_SESSION_ATTACHED",
                    reason: "Attached tmux session",
                    updatedAt: timestamp,
                ),
            ],
            delegations: [],
        )
    }
}
