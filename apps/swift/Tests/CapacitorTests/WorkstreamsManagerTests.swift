@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class WorkstreamsManagerTests: XCTestCase {
    func testLoadPopulatesWorktreesOnSuccess() {
        let project = makeProject(path: "/tmp/repo")
        let expected = [
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-2"),
        ]

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in expected },
        )

        manager.load(for: project)
        let state = manager.state(for: project)

        XCTAssertEqual(state.worktrees, expected)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.errorMessage)
    }

    func testLoadStoresErrorMessageOnFailure() {
        let project = makeProject(path: "/tmp/repo")
        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                throw WorktreeService.Error.gitCommandFailed(
                    arguments: ["worktree", "list", "--porcelain"],
                    exitCode: 128,
                    output: "fatal: not a git repository",
                )
            },
        )

        manager.load(for: project)
        let state = manager.state(for: project)

        XCTAssertTrue(state.worktrees.isEmpty)
        XCTAssertFalse(state.isLoading)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(state.errorMessage?.contains("worktree list") == true)
    }

    func testCreateUsesNextAvailableNameAndRefreshesList() {
        let project = makeProject(path: "/tmp/repo")
        let initial = [
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/repo-workstream-1"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/repo-workstream-3"),
        ]
        let refreshed = [
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/repo-workstream-1"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/repo-workstream-2"),
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/repo-workstream-3"),
        ]

        var listCallCount = 0
        var createdName: String?

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                defer { listCallCount += 1 }
                return listCallCount == 0 ? initial : refreshed
            },
            createManagedWorktree: { _, name in
                createdName = name
                return Self.makeWorktree(path: "/tmp/repo/.capacitor/worktrees/\(name)")
            },
        )

        manager.load(for: project)
        manager.create(for: project)
        let state = manager.state(for: project)

        XCTAssertEqual(createdName, "repo-workstream-2")
        XCTAssertEqual(
            state.worktrees.map(\.name),
            ["repo-workstream-1", "repo-workstream-2", "repo-workstream-3"],
        )
        XCTAssertFalse(state.isCreating)
        XCTAssertNil(state.errorMessage)
    }

    func testCreateRetriesWithNextNameWhenBranchAlreadyExists() {
        let project = makeProject(path: "/tmp/repo")
        let refreshed = [
            makeWorktree(path: "/tmp/repo/.capacitor/worktrees/repo-workstream-2"),
        ]

        var attemptedNames: [String] = []
        var listCallCount = 0

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                defer { listCallCount += 1 }
                return listCallCount == 0 ? [] : refreshed
            },
            createManagedWorktree: { _, name in
                attemptedNames.append(name)
                if name == "repo-workstream-1" {
                    throw WorktreeService.Error.gitCommandFailed(
                        arguments: [
                            "worktree",
                            "add",
                            ".capacitor/worktrees/repo-workstream-1",
                            "-b",
                            "repo-workstream-1",
                        ],
                        exitCode: 255,
                        output: "fatal: a branch named 'repo-workstream-1' already exists",
                    )
                }
                return Self.makeWorktree(path: "/tmp/repo/.capacitor/worktrees/\(name)")
            },
        )

        manager.load(for: project)
        manager.create(for: project)
        let state = manager.state(for: project)

        XCTAssertEqual(attemptedNames, ["repo-workstream-1", "repo-workstream-2"])
        XCTAssertEqual(state.worktrees.map(\.name), ["repo-workstream-2"])
        XCTAssertFalse(state.isCreating)
        XCTAssertNil(state.errorMessage)
    }

    func testCreateSanitizesProjectNameIntoPrefix() {
        let project = Project(
            name: "Agentic Canvas!",
            path: "/tmp/agentic-canvas",
            displayPath: "/tmp/agentic-canvas",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
        var createdName: String?

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in [] },
            createManagedWorktree: { _, name in
                createdName = name
                return Self.makeWorktree(path: "/tmp/agentic-canvas/.capacitor/worktrees/\(name)")
            },
        )

        manager.load(for: project)
        manager.create(for: project)

        XCTAssertEqual(createdName, "agentic-canvas-workstream-1")
    }

    func testDestroyPassesActivePathsAndSurfacesActiveSessionError() {
        let project = makeProject(path: "/tmp/repo")
        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1")
        let activePaths: Set<String> = [worktree.path]
        var receivedActivePaths: Set<String> = []

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in [worktree] },
            removeManagedWorktree: { _, _, _, active in
                receivedActivePaths = active
                throw WorktreeService.Error.activeSessionWorktree(path: worktree.path)
            },
            activeWorktreePathsProvider: { activePaths },
        )

        manager.load(for: project)
        manager.destroy(worktreeName: worktree.name, for: project)
        let state = manager.state(for: project)

        XCTAssertEqual(receivedActivePaths, activePaths)
        XCTAssertTrue(state.errorMessage?.contains("active session") == true)
        XCTAssertFalse(state.destroyingNames.contains(worktree.name))
    }

    func testDestroyRefreshesListOnSuccess() {
        let project = makeProject(path: "/tmp/repo")
        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1")
        var listCallCount = 0

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                defer { listCallCount += 1 }
                return listCallCount == 0 ? [worktree] : []
            },
            removeManagedWorktree: { _, _, _, _ in },
        )

        manager.load(for: project)
        manager.destroy(worktreeName: worktree.name, for: project)
        let state = manager.state(for: project)

        XCTAssertTrue(state.worktrees.isEmpty)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.destroyingNames.contains(worktree.name))
    }

    func testDestroyTracksForceDestroyableWhenBlockedByActiveSession() {
        let project = makeProject(path: "/tmp/repo")
        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1")

        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in [worktree] },
            removeManagedWorktree: { _, _, force, _ in
                if !force {
                    throw WorktreeService.Error.activeSessionWorktree(path: worktree.path)
                }
            },
            activeWorktreePathsProvider: { [worktree.path] },
        )

        manager.load(for: project)
        manager.destroy(worktreeName: worktree.name, for: project)
        let state = manager.state(for: project)

        // The name should be tracked as force-destroyable
        XCTAssertTrue(state.forceDestroyableNames.contains(worktree.name))
        // Generic error message should still be shown
        XCTAssertNotNil(state.errorMessage)
    }

    func testForceDestroySucceedsAndClearsForceDestroyableState() {
        let project = makeProject(path: "/tmp/repo")
        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1")
        var removeCalls: [(name: String, force: Bool)] = []

        var listCallCount = 0
        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                defer { listCallCount += 1 }
                return listCallCount == 0 ? [worktree] : []
            },
            removeManagedWorktree: { _, name, force, _ in
                removeCalls.append((name: name, force: force))
                if !force {
                    throw WorktreeService.Error.activeSessionWorktree(path: worktree.path)
                }
            },
            activeWorktreePathsProvider: { [worktree.path] },
        )

        manager.load(for: project)

        // First attempt: blocked
        manager.destroy(worktreeName: worktree.name, for: project)
        XCTAssertTrue(manager.state(for: project).forceDestroyableNames.contains(worktree.name))

        // Second attempt: force destroy
        manager.destroy(worktreeName: worktree.name, for: project, force: true)
        let state = manager.state(for: project)

        XCTAssertEqual(removeCalls.count, 2)
        XCTAssertTrue(removeCalls[1].force)
        XCTAssertTrue(state.worktrees.isEmpty)
        XCTAssertTrue(state.forceDestroyableNames.isEmpty)
        XCTAssertNil(state.errorMessage)
    }

    func testForceDestroyableIsClearedOnSuccessfulNonForceDestroy() {
        let project = makeProject(path: "/tmp/repo")
        let worktree1 = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-1")
        let worktree2 = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-2")
        let shouldBlockWorktree1 = true

        var listCallCount = 0
        let manager = WorkstreamsManager(
            listManagedWorktrees: { _ in
                defer { listCallCount += 1 }
                return listCallCount <= 1 ? [worktree1, worktree2] : [worktree1]
            },
            removeManagedWorktree: { _, name, force, _ in
                if name == worktree1.name, !force, shouldBlockWorktree1 {
                    throw WorktreeService.Error.activeSessionWorktree(path: worktree1.path)
                }
            },
            activeWorktreePathsProvider: { [worktree1.path] },
        )

        manager.load(for: project)

        // Block worktree-1
        manager.destroy(worktreeName: worktree1.name, for: project)
        XCTAssertTrue(manager.state(for: project).forceDestroyableNames.contains(worktree1.name))

        // Successfully destroy worktree-2 (not blocked)
        _ = shouldBlockWorktree1 // suppress unused warning
        manager.destroy(worktreeName: worktree2.name, for: project)
        let state = manager.state(for: project)

        // worktree-1 should still be force-destroyable (its blocker wasn't resolved)
        XCTAssertTrue(state.forceDestroyableNames.contains(worktree1.name))
    }

    func testOpenSendsWorktreeShapedProjectToTerminalLauncher() {
        var openedProject: Project?
        let manager = WorkstreamsManager(
            openWorktree: { project in
                openedProject = project
            },
        )

        let worktree = makeWorktree(path: "/tmp/repo/.capacitor/worktrees/workstream-9")
        manager.open(worktree)

        XCTAssertEqual(openedProject?.name, "workstream-9")
        XCTAssertEqual(openedProject?.path, worktree.path)
        XCTAssertEqual(openedProject?.displayPath, worktree.path)
    }

    private static func makeProject(path: String) -> Project {
        Project(
            name: "repo",
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

    private func makeProject(path: String) -> Project {
        Self.makeProject(path: path)
    }

    private static func makeWorktree(path: String) -> WorktreeService.Worktree {
        WorktreeService.Worktree(
            path: PathNormalizer.normalize(path),
            branchRef: nil,
            head: nil,
            isDetached: false,
            isLocked: false,
            isPrunable: false,
        )
    }

    private func makeWorktree(path: String) -> WorktreeService.Worktree {
        Self.makeWorktree(path: path)
    }
}
