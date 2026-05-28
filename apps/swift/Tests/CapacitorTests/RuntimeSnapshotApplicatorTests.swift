@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class RuntimeSnapshotApplicatorTests: XCTestCase {
    func testStaleGenerationDoesNotMutateRuntimeDerivedState() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")
        let baselineRun = makeRun(projectPath: project.path, runID: "run-baseline")
        let staleRun = makeRun(projectPath: project.path, runID: "run-stale")

        let baselineContext = fixture.applicator.beginFetch(projects: [project])
        _ = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
                runs: [baselineRun],
                changeVersion: 4,
            ),
            context: baselineContext,
        )

        let staleContext = fixture.applicator.beginFetch(projects: [project])
        _ = fixture.applicator.beginFetch(projects: [project])

        let outcome = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "stale-session",
                shellCwd: "/stale",
                shellPid: "111",
                runs: [staleRun],
                changeVersion: 99,
            ),
            context: staleContext,
        )

        XCTAssertEqual(outcome.decision, .ignoredStaleGeneration)
        XCTAssertTrue(outcome.effects.isEmpty)
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.sessionId, "baseline-session")
        XCTAssertEqual(fixture.shellStateStore.state?.shells["111"]?.cwd, "/baseline")
        XCTAssertEqual(
            fixture.routingStateStore.routingView(projectPath: project.path, workspaceId: nil)?.target.sessionName,
            "baseline-session",
        )
        XCTAssertEqual(fixture.runState.runStatesByID[RuntimeRunKey(run: baselineRun)], baselineRun)
        XCTAssertNil(fixture.runState.runStatesByID[RuntimeRunKey(run: staleRun)])
        XCTAssertEqual(fixture.applicator.nextLongPollSinceVersion(), 4)
    }

    func testFreshSnapshotUpdatesRunStateAndSelectsPostApplyEffects() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")
        let run = makeRun(projectPath: project.path, runID: "run-1")
        let delegation = makeDelegation(projectPath: project.path)

        let outcome = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "fresh-session",
                shellCwd: "/fresh",
                shellPid: "111",
                delegations: [delegation],
                runs: [run],
            ),
            context: fixture.applicator.beginFetch(projects: [project]),
        )

        XCTAssertEqual(outcome.decision, .applied)
        XCTAssertEqual(outcome.effects, [
            .reconcileDelegations([delegation]),
            .reconcileRunCaptures([run]),
            .updatePostSessionRefreshContext,
        ])
        XCTAssertEqual(fixture.runState.runStatesByID.count, 1)
        XCTAssertEqual(fixture.runState.runStatesByID[RuntimeRunKey(run: run)], run)
    }

    func testFreshSnapshotPassesLiveClaudeProcessEvidenceToSessionProjection() {
        let project = makeProject(path: "/tmp/capacitor")
        let fixture = Fixture(liveClaudeProcessEvidenceProvider: { projects in
            XCTAssertEqual(projects.map(\.path), [project.path])
            return [
                project.path: LiveClaudeProjectProcessEvidence(
                    processCount: 1,
                    sessionIDs: ["live-session"],
                ),
            ]
        })

        let outcome = fixture.applicator.apply(
            RuntimeSnapshot(
                projectStates: [
                    RuntimeProjectState(
                        projectId: nil,
                        workspaceId: nil,
                        projectPath: project.path,
                        state: "idle",
                        updatedAt: "2026-03-05T00:00:00Z",
                        stateChangedAt: "2026-03-05T00:00:00Z",
                        sessionId: "runtime-session",
                        latestSessionId: "runtime-session",
                        sessionCount: 1,
                        activeCount: 0,
                        hasSession: true,
                    ),
                ],
                sessions: [],
                shellState: ShellCwdState(version: 1, shells: [:]),
                routingViews: [],
                delegations: [],
                runs: [],
                changeVersion: 0,
            ),
            context: fixture.applicator.beginFetch(projects: [project]),
        )

        XCTAssertEqual(outcome.decision, .applied)
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.state, .ready)
    }

    func testFreshSnapshotUsesCompositeRunKey() {
        let fixture = Fixture()
        let sharedRunID = "run-shared"
        let runA = makeRun(projectPath: "/tmp/Workspace/Project-A", runID: sharedRunID)
        let runB = makeRun(projectPath: "/tmp/workspace/project-b", runID: sharedRunID)

        let outcome = fixture.applicator.apply(
            RuntimeSnapshot(
                projectStates: [],
                sessions: [],
                shellState: ShellCwdState(version: 1, shells: [:]),
                routingViews: [],
                delegations: [],
                runs: [runA, runB],
                changeVersion: 0,
            ),
            context: fixture.applicator.beginFetch(projects: []),
        )

        XCTAssertEqual(outcome.decision, .applied)
        XCTAssertEqual(fixture.runState.runStatesByID.count, 2)
        XCTAssertEqual(fixture.runState.runStatesByID[RuntimeRunKey(run: runA)], runA)
        XCTAssertEqual(fixture.runState.runStatesByID[RuntimeRunKey(run: runB)], runB)
    }

    func testRepeatedFailuresClearRuntimeDerivedStateAfterThreshold() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")
        let delegation = makeDelegation(projectPath: project.path)

        let context = fixture.applicator.beginFetch(projects: [project])
        _ = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "stale-session",
                shellCwd: "/stale",
                shellPid: "111",
                delegations: [delegation],
            ),
            context: context,
        )
        fixture.uiState.runCheckpointWindowTarget = RunCheckpointWindowTarget(
            projectPath: project.path,
            runID: "run-1",
            checkpointID: "checkpoint-1",
        )

        let firstFailure = fixture.applicator.recordFailure(
            context: context,
            errorDescription: "unavailable",
        )

        XCTAssertEqual(firstFailure.decision, .failureHeld)
        XCTAssertEqual(firstFailure.effects, [.updatePostSessionRefreshContext])
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.sessionId, "stale-session")
        XCTAssertEqual(fixture.shellStateStore.state?.shells["111"]?.cwd, "/stale")
        XCTAssertFalse(fixture.runState.delegationStates.isEmpty)
        XCTAssertNotNil(fixture.uiState.runCheckpointWindowTarget)

        let secondFailure = fixture.applicator.recordFailure(
            context: context,
            errorDescription: "unavailable",
        )

        XCTAssertEqual(secondFailure.decision, .failureCleared)
        XCTAssertEqual(secondFailure.effects, [.updatePostSessionRefreshContext])
        XCTAssertNil(fixture.sessionStateManager.getSessionState(for: project))
        XCTAssertNil(fixture.shellStateStore.state)
        XCTAssertTrue(fixture.routingStateStore.routesByWorkspaceID.isEmpty)
        XCTAssertTrue(fixture.runState.delegationStates.isEmpty)
        XCTAssertNil(fixture.uiState.runCheckpointWindowTarget)
    }

    func testSuccessfulSnapshotResetsFailureHysteresis() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")
        let context = fixture.applicator.beginFetch(projects: [project])

        _ = fixture.applicator.recordFailure(
            context: context,
            errorDescription: "unavailable",
        )
        _ = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "fresh-session",
                shellCwd: "/fresh",
                shellPid: "111",
            ),
            context: context,
        )

        let failureAfterSuccess = fixture.applicator.recordFailure(
            context: context,
            errorDescription: "unavailable",
        )

        XCTAssertEqual(failureAfterSuccess.decision, .failureHeld)
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.sessionId, "fresh-session")
        XCTAssertEqual(fixture.shellStateStore.state?.shells["111"]?.cwd, "/fresh")
        XCTAssertEqual(
            fixture.routingStateStore.routingView(projectPath: project.path, workspaceId: nil)?.target.sessionName,
            "fresh-session",
        )
    }

    func testRepeatedNonzeroSnapshotVersionIsNoop() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")
        let baselineRun = makeRun(projectPath: project.path, runID: "run-baseline")
        let updatedRun = makeRun(projectPath: project.path, runID: "run-updated")

        let context = fixture.applicator.beginFetch(projects: [project])
        _ = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
                runs: [baselineRun],
                changeVersion: 9,
            ),
            context: context,
        )

        var observedLines: [String] = []
        DebugLog.setTestObserver { line in
            observedLines.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        let outcome = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "updated-session",
                shellCwd: "/updated",
                shellPid: "111",
                runs: [updatedRun],
                changeVersion: 9,
            ),
            context: context,
        )

        XCTAssertEqual(outcome.decision, .duplicateVersionNoop)
        XCTAssertEqual(outcome.effects, [.updatePostSessionRefreshContext])
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.sessionId, "baseline-session")
        XCTAssertEqual(fixture.shellStateStore.state?.shells["111"]?.cwd, "/baseline")
        XCTAssertEqual(fixture.runState.runStatesByID[RuntimeRunKey(run: baselineRun)], baselineRun)
        XCTAssertNil(fixture.runState.runStatesByID[RuntimeRunKey(run: updatedRun)])
        XCTAssertTrue(
            observedLines.contains {
                $0.contains("source=runtime_snapshot_volatile_refresh") && $0.contains("version=9")
            },
            "expected volatile refresh log for repeated nonzero snapshot version",
        )
    }

    func testRepeatedNonzeroSnapshotVersionRefreshesLiveProcessEvidence() {
        let project = makeProject(path: "/tmp/capacitor")
        var liveEvidence: [String: LiveClaudeProjectProcessEvidence] = [
            project.path: LiveClaudeProjectProcessEvidence(
                processCount: 1,
                sessionIDs: ["live-session"],
            ),
        ]
        let fixture = Fixture(liveClaudeProcessEvidenceProvider: { _ in liveEvidence })

        let context = fixture.applicator.beginFetch(projects: [project])
        _ = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "runtime-session",
                shellCwd: "/baseline",
                shellPid: "111",
                changeVersion: 9,
                state: "idle",
                activeCount: 0,
            ),
            context: context,
        )

        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.state, .ready)

        liveEvidence = [:]
        let firstOutcome = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "changed-session-ignored",
                shellCwd: "/changed-ignored",
                shellPid: "111",
                changeVersion: 9,
                state: "working",
            ),
            context: context,
        )

        XCTAssertEqual(firstOutcome.decision, .duplicateVersionNoop)
        XCTAssertEqual(firstOutcome.effects, [.updatePostSessionRefreshContext])
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.state, .ready)

        let secondOutcome = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "changed-session-ignored",
                shellCwd: "/changed-ignored",
                shellPid: "111",
                changeVersion: 9,
                state: "working",
            ),
            context: context,
        )

        XCTAssertEqual(secondOutcome.decision, .duplicateVersionNoop)
        XCTAssertEqual(secondOutcome.effects, [.updatePostSessionRefreshContext])
        let projectedState = fixture.sessionStateManager.getSessionState(for: project)
        XCTAssertEqual(projectedState?.state, .idle)
        XCTAssertEqual(projectedState?.sessionId, "runtime-session")
        XCTAssertEqual(fixture.shellStateStore.state?.shells["111"]?.cwd, "/baseline")
    }

    func testOlderSnapshotVersionCannotOverrideNewerAppliedVersion() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")
        let baselineRun = makeRun(projectPath: project.path, runID: "run-baseline")
        let staleRun = makeRun(projectPath: project.path, runID: "run-stale")

        let context = fixture.applicator.beginFetch(projects: [project])
        _ = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
                runs: [baselineRun],
                changeVersion: 12,
            ),
            context: context,
        )

        var observedLines: [String] = []
        DebugLog.setTestObserver { line in
            observedLines.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        let outcome = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "stale-session",
                shellCwd: "/stale",
                shellPid: "111",
                runs: [staleRun],
                changeVersion: 11,
            ),
            context: context,
        )

        XCTAssertEqual(outcome.decision, .ignoredStaleVersion)
        XCTAssertTrue(outcome.effects.isEmpty)
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.sessionId, "baseline-session")
        XCTAssertEqual(fixture.shellStateStore.state?.shells["111"]?.cwd, "/baseline")
        XCTAssertEqual(fixture.runState.runStatesByID[RuntimeRunKey(run: baselineRun)], baselineRun)
        XCTAssertNil(fixture.runState.runStatesByID[RuntimeRunKey(run: staleRun)])
        XCTAssertTrue(
            observedLines.contains {
                $0.contains("source=runtime_snapshot_drop_stale_version") && $0.contains("version=11")
            },
            "expected stale-version log when an older snapshot arrives after a newer one",
        )
    }

    func testSnapshotVersionZeroNeverShortCircuitsFanout() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")
        let baselineRun = makeRun(projectPath: project.path, runID: "run-baseline")
        let updatedRun = makeRun(projectPath: project.path, runID: "run-updated")

        let context = fixture.applicator.beginFetch(projects: [project])
        _ = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "baseline-session",
                shellCwd: "/baseline",
                shellPid: "111",
                runs: [baselineRun],
                changeVersion: 0,
            ),
            context: context,
        )

        var observedLines: [String] = []
        DebugLog.setTestObserver { line in
            observedLines.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        let outcome = fixture.applicator.apply(
            makeRuntimeSnapshot(
                projectPath: project.path,
                sessionId: "updated-session",
                shellCwd: "/updated",
                shellPid: "111",
                runs: [updatedRun],
                changeVersion: 0,
            ),
            context: context,
        )

        XCTAssertEqual(outcome.decision, .applied)
        XCTAssertEqual(fixture.sessionStateManager.getSessionState(for: project)?.sessionId, "updated-session")
        XCTAssertEqual(fixture.shellStateStore.state?.shells["111"]?.cwd, "/updated")
        XCTAssertEqual(fixture.runState.runStatesByID[RuntimeRunKey(run: updatedRun)], updatedRun)
        XCTAssertNil(fixture.runState.runStatesByID[RuntimeRunKey(run: baselineRun)])
        XCTAssertFalse(
            observedLines.contains { $0.contains("source=runtime_snapshot_noop") },
            "unknown snapshot versions must never short-circuit projection",
        )
    }

    func testFreshSnapshotLogsGcReasonSessions() {
        let fixture = Fixture()
        let project = makeProject(path: "/tmp/capacitor")

        var observedLines: [String] = []
        DebugLog.setTestObserver { line in
            observedLines.append(line)
        }
        defer { DebugLog.setTestObserver(nil) }

        let outcome = fixture.applicator.apply(
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
                changeVersion: 12,
            ),
            context: fixture.applicator.beginFetch(projects: [project]),
        )

        XCTAssertEqual(outcome.decision, .applied)
        XCTAssertTrue(
            observedLines.contains { $0.contains("AppState.gc_reason sessions=session-gc:pid_reaped") },
            "expected gc_reason log when runtime snapshot includes gc-tagged sessions",
        )
    }

    @MainActor
    private struct Fixture {
        let sessionStateManager = SessionStateManager()
        let shellStateStore = ShellStateStore()
        let routingStateStore = RoutingStateStore()
        let runState = RunStateStore()
        let uiState = UIState()
        let applicator: RuntimeSnapshotApplicator

        init(
            isDelegationLoopEnabled: Bool = true,
            liveClaudeProcessEvidenceProvider: RuntimeSnapshotApplicator.LiveClaudeProcessEvidenceProvider? = nil,
        ) {
            applicator = RuntimeSnapshotApplicator(
                sessionStateManager: sessionStateManager,
                shellStateStore: shellStateStore,
                routingStateStore: routingStateStore,
                runState: runState,
                uiState: uiState,
                isDelegationLoopEnabled: { isDelegationLoopEnabled },
                liveClaudeProcessEvidenceProvider: liveClaudeProcessEvidenceProvider ?? { _ in [:] },
            )
        }
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

    private func makeRuntimeSnapshot(
        projectPath: String,
        sessionId: String,
        shellCwd: String,
        shellPid: String,
        delegations: [RuntimeDelegationState] = [],
        runs: [RuntimeRunState] = [],
        runtimeSessions: [RuntimeSession] = [],
        changeVersion: UInt64 = 0,
        state: String = "working",
        activeCount: Int = 1,
    ) -> RuntimeSnapshot {
        let timestamp = "2026-03-05T00:00:00Z"
        return RuntimeSnapshot(
            projectStates: [
                RuntimeProjectState(
                    projectId: nil,
                    workspaceId: nil,
                    projectPath: projectPath,
                    state: state,
                    updatedAt: timestamp,
                    stateChangedAt: timestamp,
                    sessionId: sessionId,
                    latestSessionId: sessionId,
                    sessionCount: 1,
                    activeCount: activeCount,
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
            delegations: delegations,
            runs: runs,
            changeVersion: changeVersion,
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
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
            gcReason: gcReason,
            isAlive: true,
        )
    }

    private func makeDelegation(projectPath: String) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: projectPath,
            workerId: "worker-1",
            ideaId: nil,
            worktreeName: "worker-1",
            worktreePath: "\(projectPath)-worker-1",
            sessionId: "session-1",
            status: "active",
            startedAt: "2026-03-05T00:00:00Z",
            updatedAt: "2026-03-05T00:00:00Z",
            currentReview: nil,
        )
    }

    private func makeRun(projectPath: String, runID: String) -> RuntimeRunState {
        RuntimeRunState(
            id: runID,
            projectPath: projectPath,
            methodId: "checkpoint-review",
            methodName: "Checkpoint Review",
            status: "paused",
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: "2026-03-05T00:00:00Z",
            updatedAt: "2026-03-05T00:00:00Z",
            activeCheckpoint: nil,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}
