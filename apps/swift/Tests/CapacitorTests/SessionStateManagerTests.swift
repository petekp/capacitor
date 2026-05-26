@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class SessionStateManagerTests: XCTestCase {
    func testApplyRuntimeProjectStatesMatchingIgnoresCaseDifferences() {
        let manager = makeManager()
        let project = makeProject("Project", path: "/Users/pete/code/project")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: "/Users/Pete/Code/Project", state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "apply-case",
        )

        XCTAssertNotNil(manager.getSessionState(for: project))
    }

    func testApplyRuntimeProjectStatesPrefersMostSpecificProject() {
        let manager = makeManager()
        let rootProject = makeProject("assistant-ui", path: "/Users/pete/Code/assistant-ui")
        let packageProject = makeProject("assistant-ui-web", path: "/Users/pete/Code/assistant-ui/packages/web")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: packageProject.path, state: "working", sessionId: "session-1")],
            for: [rootProject, packageProject],
            correlationId: "apply-specific",
        )

        XCTAssertNotNil(manager.getSessionState(for: packageProject))
        XCTAssertNil(manager.getSessionState(for: rootProject))
    }

    func testApplyRuntimeProjectStatesUsesChildWhenOnlyRootPinned() {
        let manager = makeManager()
        let rootProject = makeProject("assistant-ui", path: "/Users/pete/Code/assistant-ui")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: "/Users/pete/Code/assistant-ui/packages/web", state: "working", sessionId: "session-1")],
            for: [rootProject],
            correlationId: "apply-child",
        )

        XCTAssertNotNil(manager.getSessionState(for: rootProject))
    }

    func testApplyRuntimeProjectStatesDoesNotMatchParentToChild() {
        let manager = makeManager()
        let packageProject = makeProject("assistant-ui-web", path: "/Users/pete/Code/assistant-ui/packages/web")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: "/Users/pete/Code/assistant-ui", state: "working", sessionId: "session-1")],
            for: [packageProject],
            correlationId: "apply-parent",
        )

        XCTAssertNil(manager.getSessionState(for: packageProject))
    }

    func testApplyRuntimeProjectStatesMatchesWorktreeToPinnedPath() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repoRoot = tempDir.appendingPathComponent("assistant-ui")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")
        try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinnedPath, withIntermediateDirectories: true)

        let worktreeRoot = tempDir.appendingPathComponent("assistant-ui-wt")
        let worktreePath = worktreeRoot.appendingPathComponent("apps/docs")
        try FileManager.default.createDirectory(at: worktreePath, withIntermediateDirectories: true)

        let worktreeGitDir = repoGit.appendingPathComponent("worktrees/feat-docs")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try "../..".write(to: worktreeGitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(worktreeGitDir.path)\n".write(
            to: worktreeRoot.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8,
        )

        let manager = makeManager()
        let project = makeProject("assistant-ui-docs", path: pinnedPath.path)
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: worktreePath.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "apply-worktree",
        )

        XCTAssertNotNil(manager.getSessionState(for: project))
    }

    func testApplyRuntimeProjectStatesUpdatesLatestSessionId() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")
        let daemonProjects = [
            RuntimeProjectState(
                projectId: "/tmp/core-project/.git",
                workspaceId: "workspace-core",
                projectPath: "/tmp/core-project",
                state: "working",
                updatedAt: fixtureStateTimestamp,
                stateChangedAt: fixtureStateTimestamp,
                sessionId: "session-representative",
                latestSessionId: "session-latest",
                sessionCount: 2,
                activeCount: 1,
                hasSession: true,
            ),
        ]

        manager.applyRuntimeProjectStates(daemonProjects, for: [project], correlationId: "apply-latest")

        XCTAssertEqual(manager.getSessionState(for: project)?.sessionId, "session-representative")
        XCTAssertEqual(manager.getPreferredSessionId(for: project), "session-latest")
    }

    func testApplyRuntimeProjectStatesPrefersMoreRecentReadyOverStaleWorkingCandidate() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "working",
                    sessionId: "session-old-working",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-610)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-610)),
                ),
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "ready",
                    sessionId: "session-new-ready",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-10)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-10)),
                ),
            ],
            for: [project],
            correlationId: "apply-recency-over-stale-activity",
        )

        XCTAssertEqual(manager.getSessionState(for: project)?.state, .ready)
        XCTAssertEqual(
            manager.getSessionState(for: project)?.sessionId,
            "session-new-ready",
            "A more recent ready state should beat an older working state that will be downgraded to ready.",
        )
        XCTAssertEqual(manager.getPreferredSessionId(for: project), "session-new-ready")
    }

    func testProjectionPreservesStateSourceWhenPresent() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")
        let session = makeRuntimeSession(
            sessionId: "session-1",
            pid: 1234,
            state: "working",
            stateSource: RuntimeStateSource(
                eventKind: "session_start",
                authority: "definitive_terminal",
                observedAt: "2026-04-15T12:00:00Z",
            ),
        )

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: session.sessionId)],
            sessions: [session],
            for: [project],
            correlationId: "projection-state-source",
        )

        let projected = manager.getSessionState(for: project)
        XCTAssertEqual(projected?.stateSource?.eventKind, .sessionStart)
        XCTAssertEqual(projected?.stateSource?.authority, .definitiveTerminal)
    }

    func testProjectionPreservesTranscriptActivityStateSource() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")
        let session = makeRuntimeSession(
            sessionId: "session-1",
            pid: 1234,
            state: "idle",
            stateSource: RuntimeStateSource(
                eventKind: "transcript_activity",
                authority: "inferential",
                observedAt: "2026-04-15T12:00:00Z",
            ),
        )

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: session.sessionId)],
            sessions: [session],
            for: [project],
            correlationId: "projection-transcript-activity",
        )

        let projected = manager.getSessionState(for: project)
        XCTAssertEqual(projected?.stateSource?.eventKind, .transcriptActivity)
        XCTAssertEqual(projected?.stateSource?.authority, .inferential)
    }

    func testProjectionPreservesNilStateSourceForLegacySessions() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")
        let session = makeRuntimeSession(sessionId: "session-1", pid: 1234, state: "working")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: session.sessionId)],
            sessions: [session],
            for: [project],
            correlationId: "projection-state-source-nil",
        )

        XCTAssertNil(manager.getSessionState(for: project)?.stateSource)
    }

    func testLiveClaudeProcessEvidenceProjectsIdleRuntimeStateAsReady() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: "session-1")],
            liveClaudeProcessesByProjectPath: [
                project.path: LiveClaudeProjectProcessEvidence(
                    processCount: 1,
                    sessionIDs: ["session-1"],
                ),
            ],
            for: [project],
            correlationId: "projection-live-process-ready",
        )

        let projected = manager.getSessionState(for: project)
        XCTAssertEqual(projected?.state, .ready)
        XCTAssertEqual(projected?.sessionId, "session-1")
        XCTAssertEqual(manager.getPreferredSessionId(for: project), "session-1")
    }

    func testLiveClaudeProcessEvidenceCreatesSyntheticReadyStateForManualSession() {
        let manager = makeManager()
        let project = makeProject("manual-project", path: "/tmp/manual-project")

        manager.applyRuntimeProjectStates(
            [],
            liveClaudeProcessesByProjectPath: [
                project.path: LiveClaudeProjectProcessEvidence(
                    processCount: 1,
                    sessionIDs: [],
                ),
            ],
            for: [project],
            correlationId: "projection-manual-process-ready",
        )

        let projected = manager.getSessionState(for: project)
        XCTAssertEqual(projected?.state, .ready)
        XCTAssertTrue(projected?.hasSession == true)
        XCTAssertNil(projected?.sessionId)
    }

    func testProjectionPreservesLastAuthoritativeEventAt() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")
        let session = makeRuntimeSession(
            sessionId: "session-1",
            pid: 1234,
            state: "working",
            lastAuthoritativeEventAt: "2026-04-15T12:00:00Z",
        )

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: session.sessionId)],
            sessions: [session],
            for: [project],
            correlationId: "projection-last-authoritative",
        )

        XCTAssertEqual(
            manager.getSessionState(for: project)?.lastAuthoritativeEventAt,
            "2026-04-15T12:00:00Z",
        )
    }

    func testApplyRuntimeProjectStatesHoldsSingleEmptySnapshotThenCommitsSecond() {
        let manager = makeManager()
        let project = makeProject("core-project", path: "/tmp/core-project")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "apply-non-empty",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .working)

        manager.applyRuntimeProjectStates([], for: [project], correlationId: "apply-empty-1")
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .working,
            "First empty snapshot should be held to prevent transient flicker.",
        )

        manager.applyRuntimeProjectStates([], for: [project], correlationId: "apply-empty-2")
        XCTAssertNil(manager.getSessionState(for: project))
    }

    // MARK: - Idle Stabilization (Hysteresis)

    func testIdleStabilizationCommitsAfterThreshold() {
        let manager = makeManager()
        let project = makeProject("my-project", path: "/tmp/my-project")

        // Establish active state
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "idle-commit-1",
        )

        // First idle — held
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: nil)],
            for: [project],
            correlationId: "idle-commit-2",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .working)

        // Second idle — committed
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: nil)],
            for: [project],
            correlationId: "idle-commit-3",
        )
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .idle,
            "Second consecutive idle snapshot should commit the idle transition.",
        )
    }

    func testIdleStabilizationResetsOnActive() {
        let manager = makeManager()
        let project = makeProject("my-project", path: "/tmp/my-project")

        // Establish active state
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "idle-reset-1",
        )

        // First idle — held
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: nil)],
            for: [project],
            correlationId: "idle-reset-2",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .working)

        // Active again — counter should reset
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "waiting", sessionId: "session-2")],
            for: [project],
            correlationId: "idle-reset-3",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .waiting)

        // First idle again after reset — should be held (counter was reset)
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: nil)],
            for: [project],
            correlationId: "idle-reset-4",
        )
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .waiting,
            "After reset, the first idle snapshot should be held again.",
        )
    }

    func testIdleStabilizationPassesThroughAlreadyIdle() {
        let manager = makeManager()
        let project = makeProject("my-project", path: "/tmp/my-project")

        // First apply is idle (no previous active state)
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: nil)],
            for: [project],
            correlationId: "idle-passthrough-1",
        )
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .idle,
            "Idle should pass through immediately when there's no previous active state to hold.",
        )

        // Second idle — still idle, no hold
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: nil)],
            for: [project],
            correlationId: "idle-passthrough-2",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .idle)
    }

    func testIdleHoldOnlyPreservesMetadataForHeldProject() {
        let manager = makeManager()
        let projectA = makeProject("project-a", path: "/tmp/project-a")
        let projectB = makeProject("project-b", path: "/tmp/project-b")
        let projects = [projectA, projectB]

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(projectPath: projectA.path, state: "working", sessionId: "a-1"),
                makeRuntimeProjectState(projectPath: projectB.path, state: "working", sessionId: "b-1"),
            ],
            for: projects,
            correlationId: "metadata-baseline",
        )
        XCTAssertEqual(manager.getPreferredSessionId(for: projectA), "a-1")
        XCTAssertEqual(manager.getPreferredSessionId(for: projectB), "b-1")

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(projectPath: projectA.path, state: "idle", sessionId: nil),
                makeRuntimeProjectState(projectPath: projectB.path, state: "working", sessionId: "b-2"),
            ],
            for: projects,
            correlationId: "metadata-hold",
        )

        XCTAssertEqual(
            manager.getSessionState(for: projectA)?.state,
            .working,
            "Project A should remain held in active state during first idle snapshot.",
        )
        XCTAssertEqual(
            manager.getPreferredSessionId(for: projectB),
            "b-2",
            "Project B metadata should continue to update even when Project A is held.",
        )
    }

    // MARK: - Working→Ready Stabilization (Hysteresis)

    func testReadyStabilizationCommitsAfterThreshold() {
        let manager = makeManager()
        let project = makeProject("my-project", path: "/tmp/my-project")

        // Establish Working state
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-commit-1",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .working)

        // First Ready — held
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "ready", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-commit-2",
        )
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .working,
            "First Ready snapshot after Working should be held.",
        )

        // Second Ready — committed
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "ready", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-commit-3",
        )
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .ready,
            "Second consecutive Ready snapshot should commit the transition.",
        )
    }

    func testReadyStabilizationResetsOnWorking() {
        let manager = makeManager()
        let project = makeProject("my-project", path: "/tmp/my-project")

        // Establish Working state
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-reset-1",
        )

        // First Ready — held
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "ready", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-reset-2",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .working)

        // Back to Working — counter should reset
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-reset-3",
        )
        XCTAssertEqual(manager.getSessionState(for: project)?.state, .working)

        // First Ready again — should be held (counter was reset)
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "ready", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-reset-4",
        )
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .working,
            "After reset, the first Ready snapshot should be held again.",
        )
    }

    func testReadyStabilizationOnlyAppliesFromWorking() {
        let manager = makeManager()
        let project = makeProject("my-project", path: "/tmp/my-project")

        // Establish idle state (not Working)
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "idle", sessionId: nil)],
            for: [project],
            correlationId: "ready-noop-1",
        )

        // Ready — should commit immediately (previous state was idle, not working)
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: project.path, state: "ready", sessionId: "session-1")],
            for: [project],
            correlationId: "ready-noop-2",
        )
        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .ready,
            "Ready should commit immediately when previous state was not Working.",
        )
    }

    func testReadyStabilizationDoesNotAffectOtherProjects() {
        let manager = makeManager()
        let projectA = makeProject("project-a", path: "/tmp/project-a")
        let projectB = makeProject("project-b", path: "/tmp/project-b")
        let projects = [projectA, projectB]

        // Both Working
        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(projectPath: projectA.path, state: "working", sessionId: "a-1"),
                makeRuntimeProjectState(projectPath: projectB.path, state: "working", sessionId: "b-1"),
            ],
            for: projects,
            correlationId: "ready-multi-1",
        )

        // A goes Ready (held), B stays Working
        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(projectPath: projectA.path, state: "ready", sessionId: "a-1"),
                makeRuntimeProjectState(projectPath: projectB.path, state: "working", sessionId: "b-1"),
            ],
            for: projects,
            correlationId: "ready-multi-2",
        )
        XCTAssertEqual(
            manager.getSessionState(for: projectA)?.state,
            .working,
            "Project A's Ready should be held.",
        )
        XCTAssertEqual(
            manager.getSessionState(for: projectB)?.state,
            .working,
            "Project B should remain unaffected.",
        )
    }

    func testGetSessionStateFallsBackToNormalizedPathLookup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let realProjectPath = tempDir.appendingPathComponent("workspace")
        let symlinkPath = tempDir.appendingPathComponent("workspace-link")
        try FileManager.default.createDirectory(at: realProjectPath, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: realProjectPath.path)

        let manager = makeManager()
        manager.setSessionStatesForTesting([
            symlinkPath.path + "/": makeSessionState(state: .ready, sessionId: "session-symlink"),
        ])

        let project = makeProject("workspace", path: realProjectPath.path.uppercased())
        let state = manager.getSessionState(for: project)

        XCTAssertNotNil(state, "Equivalent normalized paths should resolve to existing session state.")
        XCTAssertEqual(state?.sessionId, "session-symlink")
    }

    func testGetSessionStateDirectLookupHasPriorityOverNormalizedFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let realProjectPath = tempDir.appendingPathComponent("workspace")
        let symlinkPath = tempDir.appendingPathComponent("workspace-link")
        try FileManager.default.createDirectory(at: realProjectPath, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: realProjectPath.path)

        let manager = makeManager()
        manager.setSessionStatesForTesting([
            symlinkPath.path + "/": makeSessionState(state: .ready, sessionId: "session-fallback"),
            realProjectPath.path: makeSessionState(state: .working, sessionId: "session-direct"),
        ])

        let project = makeProject("workspace", path: realProjectPath.path)
        let state = manager.getSessionState(for: project)

        XCTAssertEqual(state?.sessionId, "session-direct")
        XCTAssertEqual(state?.state, .working)
    }

    // MARK: - PID-Liveness Gated Downgrade

    func testStaleWorkingSessionStaysWorkingWhenProcessAlive() {
        let manager = SessionStateManager(
            clock: .fixed(fixtureNow),
            processLiveness: { _ in true },
        )
        let project = makeProject("pid-project", path: "/tmp/pid-project")
        let session = makeRuntimeSession(sessionId: "session-alive", pid: 12345, state: "working")

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "working",
                    sessionId: "session-alive",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                ),
            ],
            sessions: [session],
            for: [project],
            correlationId: "pid-alive-test",
        )

        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .working,
            "A stale working session must remain working when its process is alive.",
        )
    }

    func testStaleWorkingSessionDowngradesToReadyWhenProcessDead() {
        let manager = SessionStateManager(
            clock: .fixed(fixtureNow),
            processLiveness: { _ in false },
        )
        let project = makeProject("pid-project", path: "/tmp/pid-project")
        let session = makeRuntimeSession(sessionId: "session-dead", pid: 99999, state: "working")

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "working",
                    sessionId: "session-dead",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                ),
            ],
            sessions: [session],
            for: [project],
            correlationId: "pid-dead-test",
        )

        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .ready,
            "A stale working session must downgrade to ready when its process is dead.",
        )
    }

    func testStaleWorkingSessionDowngradesWhenNoSessionDataProvided() {
        let manager = SessionStateManager(
            clock: .fixed(fixtureNow),
            processLiveness: { _ in true },
        )
        let project = makeProject("pid-project", path: "/tmp/pid-project")

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "working",
                    sessionId: "session-no-lookup",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                ),
            ],
            sessions: [],
            for: [project],
            correlationId: "no-session-test",
        )

        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .ready,
            "When session lookup fails (empty sessions list), stale working must fall back to ready.",
        )
    }

    func testFreshWorkingSessionUnaffectedByLivenessCheck() {
        let manager = SessionStateManager(
            clock: .fixed(fixtureNow),
            processLiveness: { _ in false },
        )
        let project = makeProject("pid-project", path: "/tmp/pid-project")
        let session = makeRuntimeSession(sessionId: "session-fresh", pid: 99999, state: "working")

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "working",
                    sessionId: "session-fresh",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-10)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-10)),
                ),
            ],
            sessions: [session],
            for: [project],
            correlationId: "fresh-working-test",
        )

        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .working,
            "A fresh working session must stay working even if the process appears dead — staleness threshold not reached.",
        )
    }

    func testShouldReplaceRespectsLivenessForPriority() {
        let manager = SessionStateManager(
            clock: .fixed(fixtureNow),
            processLiveness: { _ in true },
        )
        let project = makeProject("priority-project", path: "/tmp/priority-project")
        let session = makeRuntimeSession(sessionId: "session-old-working", pid: 12345, state: "working")

        manager.applyRuntimeProjectStates(
            [
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "working",
                    sessionId: "session-old-working",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-400)),
                ),
                makeRuntimeProjectState(
                    projectPath: project.path,
                    state: "ready",
                    sessionId: "session-new-ready",
                    updatedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-10)),
                    stateChangedAt: formatISO8601Timestamp(fixtureNow.addingTimeInterval(-10)),
                ),
            ],
            sessions: [session],
            for: [project],
            correlationId: "priority-test",
        )

        XCTAssertEqual(
            manager.getSessionState(for: project)?.state,
            .working,
            "An alive working session must win priority over a newer ready session.",
        )
    }

    private func makeRuntimeSession(
        sessionId: String,
        pid: UInt32,
        state: String,
        stateSource: RuntimeStateSource? = nil,
        lastAuthoritativeEventAt: String? = nil,
    ) -> RuntimeSession {
        RuntimeSession(
            sessionId: sessionId,
            pid: pid,
            state: state,
            cwd: "/tmp",
            projectId: nil,
            workspaceId: nil,
            projectPath: "/tmp",
            updatedAt: fixtureStateTimestamp,
            stateChangedAt: fixtureStateTimestamp,
            lastEvent: nil,
            lastActivityAt: nil,
            toolsInFlight: nil,
            stateSource: stateSource,
            lastAuthoritativeEventAt: lastAuthoritativeEventAt,
            gcReason: nil,
            isAlive: nil,
        )
    }

    private func makeSessionState(state: SessionState, sessionId: String?) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: nil,
            updatedAt: nil,
            sessionId: sessionId,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: true,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
        )
    }

    private var fixtureNow: Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 2
        components.day = 28
        components.hour = 19
        components.minute = 0
        components.second = 10
        return components.date!
    }

    private var fixtureStateTimestamp: String {
        formatISO8601Timestamp(fixtureNow.addingTimeInterval(-10))
    }

    private func makeManager(now: Date? = nil) -> SessionStateManager {
        let resolvedNow = now ?? fixtureNow
        return SessionStateManager(clock: .fixed(resolvedNow))
    }

    private func makeProject(_ name: String, path: String) -> Project {
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

    private func makeRuntimeProjectState(
        projectPath: String,
        state: String,
        sessionId: String?,
        updatedAt: String? = nil,
        stateChangedAt: String? = nil,
    ) -> RuntimeProjectState {
        RuntimeProjectState(
            projectId: nil,
            workspaceId: nil,
            projectPath: projectPath,
            state: state,
            updatedAt: updatedAt ?? fixtureStateTimestamp,
            stateChangedAt: stateChangedAt ?? fixtureStateTimestamp,
            sessionId: sessionId,
            latestSessionId: sessionId,
            sessionCount: sessionId == nil ? 0 : 1,
            activeCount: state == "working" ? 1 : 0,
            hasSession: sessionId != nil,
        )
    }
}
