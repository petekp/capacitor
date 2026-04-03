@testable import Capacitor
import Observation
import XCTest

@MainActor
final class AppStateSessionObservationTests: XCTestCase {
    func testAppStateSessionReadInvalidatesWhenSessionStateChanges() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
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
        appState.cancelRuntimeAutomationForTesting()
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
        appState.cancelRuntimeAutomationForTesting()
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
        appState.cancelRuntimeAutomationForTesting()
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

    func testStaleRuntimeSnapshotDoesNotMutateRunSink() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let baselineRun = makeRun(projectPath: project.path, runID: "run-baseline")
        appState.projects = [project]

        // Apply a fresh snapshot with a run to establish baseline
        appState.setRuntimeSnapshotGenerationForTesting(2)
        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
                runs: [baselineRun],
            ),
            refreshGeneration: 2,
            correlationId: "baseline-runs",
            projects: [project],
        )
        XCTAssertEqual(appState.runStatesByID.count, 1, "baseline should have one run")

        // Apply a stale snapshot (generation 1 < current 2) with a different run
        let staleRun = makeRun(projectPath: project.path, runID: "run-stale")
        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "stale-session",
                shellCwd: "/stale",
                shellPid: "111",
                runs: [staleRun],
            ),
            refreshGeneration: 1,
            correlationId: "stale-runs",
            projects: [project],
        )

        XCTAssertEqual(appState.runStatesByID.count, 1, "stale generation should not mutate run sink")
        XCTAssertEqual(
            appState.runStatesByID[RuntimeRunKey(run: baselineRun)],
            baselineRun,
            "stale generation should preserve baseline run, not replace with stale",
        )
    }

    func testFreshRuntimeSnapshotUpdatesRunSink() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let run = makeRun(projectPath: project.path, runID: "run-1")
        appState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "fresh-session",
                shellCwd: "/fresh",
                shellPid: "111",
                runs: [run],
            ),
            refreshGeneration: 1,
            correlationId: "fresh-runs",
            projects: [project],
        )

        XCTAssertEqual(appState.runStatesByID.count, 1)
        XCTAssertEqual(appState.runStatesByID[RuntimeRunKey(run: run)], run)
    }

    func testFreshRuntimeSnapshotUsesCompositeRunKey() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        appState.setRuntimeSnapshotGenerationForTesting(1)
        let sharedRunID = "run-shared"
        let runA = makeRun(projectPath: "/tmp/Workspace/Project-A", runID: sharedRunID)
        let runB = makeRun(projectPath: "/tmp/workspace/project-b", runID: sharedRunID)

        await appState.applyRuntimeSnapshotForTesting(
            RuntimeSnapshot(
                projectStates: [],
                sessions: [],
                shellState: ShellCwdState(version: 1, shells: [:]),
                routingViews: [],
                delegations: [],
                runs: [runA, runB],
                snapshotVersion: 0,
            ),
            refreshGeneration: 1,
            correlationId: "composite-runs",
            projects: [],
        )

        XCTAssertEqual(appState.runStatesByID.count, 2)
        XCTAssertEqual(appState.runStatesByID[RuntimeRunKey(run: runA)], runA)
        XCTAssertEqual(appState.runStatesByID[RuntimeRunKey(run: runB)], runB)
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

    func testRepeatedRuntimeSnapshotFailuresPreserveRunSinkAfterThreshold() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let run = makeRun(projectPath: project.path, runID: "run-1")
        appState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "fresh-session",
                shellCwd: "/fresh",
                shellPid: "111",
                runs: [run],
            ),
            refreshGeneration: 1,
            correlationId: "baseline-run-sink",
            projects: [project],
        )

        XCTAssertEqual(appState.runStatesByID[RuntimeRunKey(run: run)], run)

        appState.handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: 1,
            correlationId: "failure-1",
            errorDescription: "unavailable",
        )
        XCTAssertEqual(appState.runStatesByID[RuntimeRunKey(run: run)], run)

        appState.handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: 1,
            correlationId: "failure-2",
            errorDescription: "unavailable",
        )

        XCTAssertEqual(
            appState.runStatesByID[RuntimeRunKey(run: run)],
            run,
            "second consecutive fresh failure should preserve the last known run snapshot",
        )
    }

    func testRepeatedNonZeroSnapshotVersionSkipsProjectionFanOut() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let baselineRun = makeRun(projectPath: project.path, runID: "run-baseline")
        let updatedRun = makeRun(projectPath: project.path, runID: "run-updated")
        appState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
                runs: [baselineRun],
                snapshotVersion: 9,
            ),
            refreshGeneration: 1,
            correlationId: "baseline-versioned",
            projects: [project],
        )

        var observedLines: [String] = []
        DebugLog.setTestObserver { line in
            observedLines.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "updated-session",
                shellCwd: "/updated",
                shellPid: "111",
                runs: [updatedRun],
                snapshotVersion: 9,
            ),
            refreshGeneration: 1,
            correlationId: "same-version",
            projects: [project],
        )

        XCTAssertEqual(appState.getSessionState(for: project)?.sessionId, "baseline-session")
        XCTAssertEqual(appState.shellStateStore.state?.shells["111"]?.cwd, "/baseline")
        XCTAssertEqual(
            appState.routingStateStore.routingView(projectPath: project.path, workspaceId: nil)?.target.sessionName,
            "baseline-session",
        )
        XCTAssertEqual(appState.runStatesByID[RuntimeRunKey(run: baselineRun)], baselineRun)
        XCTAssertNil(appState.runStatesByID[RuntimeRunKey(run: updatedRun)])
        XCTAssertTrue(
            observedLines.contains { $0.contains("source=runtime_snapshot_noop") && $0.contains("version=9") },
            "expected no-op log for repeated nonzero snapshot version",
        )
    }

    func testSnapshotVersionZeroNeverSkipsProjectionFanOut() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let baselineRun = makeRun(projectPath: project.path, runID: "run-baseline")
        let updatedRun = makeRun(projectPath: project.path, runID: "run-updated")
        appState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
                runs: [baselineRun],
                snapshotVersion: 0,
            ),
            refreshGeneration: 1,
            correlationId: "baseline-unknown-version",
            projects: [project],
        )

        var observedLines: [String] = []
        DebugLog.setTestObserver { line in
            observedLines.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "updated-session",
                shellCwd: "/updated",
                shellPid: "111",
                runs: [updatedRun],
                snapshotVersion: 0,
            ),
            refreshGeneration: 1,
            correlationId: "unknown-version",
            projects: [project],
        )

        XCTAssertEqual(appState.getSessionState(for: project)?.sessionId, "updated-session")
        XCTAssertEqual(appState.shellStateStore.state?.shells["111"]?.cwd, "/updated")
        XCTAssertEqual(
            appState.routingStateStore.routingView(projectPath: project.path, workspaceId: nil)?.target.sessionName,
            "updated-session",
        )
        XCTAssertEqual(appState.runStatesByID[RuntimeRunKey(run: updatedRun)], updatedRun)
        XCTAssertNil(appState.runStatesByID[RuntimeRunKey(run: baselineRun)])
        XCTAssertFalse(
            observedLines.contains { $0.contains("source=runtime_snapshot_noop") },
            "unknown snapshot versions must never short-circuit projection",
        )
    }

    func testFreshRuntimeSnapshotLogsGcReasonSessions() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projects = [project]
        appState.setRuntimeSnapshotGenerationForTesting(1)

        var observedLines: [String] = []
        DebugLog.setTestObserver { line in
            observedLines.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        await appState.applyRuntimeSnapshotForTesting(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "fresh-session",
                shellCwd: "/fresh",
                shellPid: "111",
                runtimeSessions: [
                    makeRuntimeSession(
                        sessionId: "session-gc",
                        projectPath: project.path,
                        gcReason: "pid_reaped",
                    ),
                ],
                snapshotVersion: 12,
            ),
            refreshGeneration: 1,
            correlationId: "gc-log",
            projects: [project],
        )

        XCTAssertTrue(
            observedLines.contains { $0.contains("AppState.gc_reason sessions=session-gc:pid_reaped") },
            "expected gc_reason log when runtime snapshot includes gc-tagged sessions",
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
        runs: [RuntimeRunState] = [],
        runtimeSessions: [RuntimeSession] = [],
        snapshotVersion: UInt64 = 0,
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
            sessions: runtimeSessions,
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
            runs: runs,
            snapshotVersion: snapshotVersion,
        )
    }

    private func makeRuntimeSession(
        sessionId: String,
        projectPath: String,
        gcReason: String? = nil,
    ) -> RuntimeSession {
        let timestamp = "2026-03-05T00:00:00Z"
        return RuntimeSession(
            sessionId: sessionId,
            pid: 4242,
            state: "working",
            cwd: projectPath,
            projectId: nil,
            workspaceId: nil,
            projectPath: projectPath,
            updatedAt: timestamp,
            stateChangedAt: timestamp,
            lastEvent: nil,
            lastActivityAt: timestamp,
            toolsInFlight: 0,
            readyReason: nil,
            gcReason: gcReason,
            isAlive: true,
        )
    }

    private func makeRun(projectPath: String, runID: String) -> RuntimeRunState {
        let timestamp = "2026-03-05T00:00:00Z"
        return RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "checkpoint-review",
            methodName: "Checkpoint Review",
            status: "paused",
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            activeCheckpoint: nil,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}
