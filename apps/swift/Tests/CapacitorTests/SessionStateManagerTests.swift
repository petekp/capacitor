@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class SessionStateManagerTests: XCTestCase {
    func testApplyRuntimeProjectStatesMatchingIgnoresCaseDifferences() {
        let manager = SessionStateManager()
        let project = makeProject("Project", path: "/Users/pete/code/project")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: "/Users/Pete/Code/Project", state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "apply-case",
        )

        XCTAssertNotNil(manager.getSessionState(for: project))
    }

    func testApplyRuntimeProjectStatesPrefersMostSpecificProject() {
        let manager = SessionStateManager()
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
        let manager = SessionStateManager()
        let rootProject = makeProject("assistant-ui", path: "/Users/pete/Code/assistant-ui")

        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: "/Users/pete/Code/assistant-ui/packages/web", state: "working", sessionId: "session-1")],
            for: [rootProject],
            correlationId: "apply-child",
        )

        XCTAssertNotNil(manager.getSessionState(for: rootProject))
    }

    func testApplyRuntimeProjectStatesDoesNotMatchParentToChild() {
        let manager = SessionStateManager()
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

        let manager = SessionStateManager()
        let project = makeProject("assistant-ui-docs", path: pinnedPath.path)
        manager.applyRuntimeProjectStates(
            [makeRuntimeProjectState(projectPath: worktreePath.path, state: "working", sessionId: "session-1")],
            for: [project],
            correlationId: "apply-worktree",
        )

        XCTAssertNotNil(manager.getSessionState(for: project))
    }

    func testApplyRuntimeProjectStatesUpdatesLatestSessionId() {
        let manager = SessionStateManager()
        let project = makeProject("core-project", path: "/tmp/core-project")
        let daemonProjects = [
            RuntimeProjectState(
                projectId: "/tmp/core-project/.git",
                workspaceId: "workspace-core",
                projectPath: "/tmp/core-project",
                state: "working",
                updatedAt: "2026-02-28T19:00:00Z",
                stateChangedAt: "2026-02-28T19:00:00Z",
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

    func testApplyRuntimeProjectStatesHoldsSingleEmptySnapshotThenCommitsSecond() {
        let manager = SessionStateManager()
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

    func testGetSessionStateFallsBackToNormalizedPathLookup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let realProjectPath = tempDir.appendingPathComponent("workspace")
        let symlinkPath = tempDir.appendingPathComponent("workspace-link")
        try FileManager.default.createDirectory(at: realProjectPath, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: realProjectPath.path)

        let manager = SessionStateManager()
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

        let manager = SessionStateManager()
        manager.setSessionStatesForTesting([
            symlinkPath.path + "/": makeSessionState(state: .ready, sessionId: "session-fallback"),
            realProjectPath.path: makeSessionState(state: .working, sessionId: "session-direct"),
        ])

        let project = makeProject("workspace", path: realProjectPath.path)
        let state = manager.getSessionState(for: project)

        XCTAssertEqual(state?.sessionId, "session-direct")
        XCTAssertEqual(state?.state, .working)
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
        )
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
    ) -> RuntimeProjectState {
        RuntimeProjectState(
            projectId: nil,
            workspaceId: nil,
            projectPath: projectPath,
            state: state,
            updatedAt: "2026-02-28T19:00:00Z",
            stateChangedAt: "2026-02-28T19:00:00Z",
            sessionId: sessionId,
            latestSessionId: sessionId,
            sessionCount: sessionId == nil ? 0 : 1,
            activeCount: state == "working" ? 1 : 0,
            hasSession: sessionId != nil,
        )
    }
}
