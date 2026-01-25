@testable import Capacitor
import Foundation
import XCTest

final class WorktreeServiceTests: XCTestCase {
    private struct CommandCall: Equatable {
        let args: [String]
        let cwd: String
    }

    func testParseWorktreeListPorcelainBuildsTypedEntries() {
        let output = """
        worktree /tmp/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /tmp/repo/.capacitor/worktrees/workstream-1
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/workstream-1

        worktree /tmp/repo/.capacitor/worktrees/workstream-2
        HEAD 3333333333333333333333333333333333333333
        detached
        locked maintenance
        prunable gitdir file points to non-existent location
        """

        let worktrees = WorktreeService.parseWorktreeListPorcelain(output)

        XCTAssertEqual(worktrees.count, 3)
        XCTAssertEqual(worktrees[0].branchRef, "refs/heads/main")
        XCTAssertEqual(worktrees[1].name, "workstream-1")
        XCTAssertFalse(worktrees[1].isDetached)
        XCTAssertEqual(worktrees[2].name, "workstream-2")
        XCTAssertTrue(worktrees[2].isDetached)
        XCTAssertTrue(worktrees[2].isLocked)
        XCTAssertTrue(worktrees[2].isPrunable)
    }

    func testListManagedWorktreesFiltersOutNonManagedPaths() throws {
        let repoPath = "/tmp/repo"
        var receivedArgs: [String] = []
        var receivedCwd = ""

        let output = """
        worktree /tmp/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /tmp/repo/.capacitor/worktrees/workstream-1
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/workstream-1

        worktree /tmp/repo/sandbox
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/sandbox

        worktree /tmp/repo/.capacitor/worktrees/workstream-2
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/workstream-2
        """

        let service = WorktreeService(runGit: { args, cwd in
            receivedArgs = args
            receivedCwd = cwd
            return .init(exitCode: 0, stdout: output, stderr: "")
        })

        let managed = try service.listManagedWorktrees(in: repoPath)

        XCTAssertEqual(receivedArgs, ["worktree", "list", "--porcelain"])
        XCTAssertEqual(receivedCwd, repoPath)
        XCTAssertEqual(managed.map(\.name), ["workstream-1", "workstream-2"])
    }

    func testListManagedWorktreesPrunesBeforeListing() throws {
        var calls: [CommandCall] = []
        let repoPath = "/tmp/repo"

        let output = """
        worktree /tmp/repo/.capacitor/worktrees/workstream-1
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/workstream-1
        """

        let service = WorktreeService(runGit: { args, cwd in
            calls.append(CommandCall(args: args, cwd: cwd))
            switch args {
            case ["worktree", "prune"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["worktree", "list", "--porcelain"]:
                return .init(exitCode: 0, stdout: output, stderr: "")
            default:
                XCTFail("Unexpected command: \(args)")
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
        })

        _ = try service.listManagedWorktrees(in: repoPath)

        XCTAssertEqual(calls, [
            CommandCall(args: ["worktree", "prune"], cwd: repoPath),
            CommandCall(args: ["worktree", "list", "--porcelain"], cwd: repoPath),
        ])
    }

    func testCreateManagedWorktreeBuildsExpectedGitCommand() throws {
        let fileManager = FileManager.default
        let repoRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repoRoot) }

        var receivedArgs: [String] = []
        var receivedCwd = ""

        let service = WorktreeService(runGit: { args, cwd in
            receivedArgs = args
            receivedCwd = cwd
            return .init(exitCode: 0, stdout: "", stderr: "")
        })

        let created = try service.createManagedWorktree(in: repoRoot.path, name: "workstream-7")

        XCTAssertEqual(receivedArgs, ["worktree", "add", ".capacitor/worktrees/workstream-7", "-b", "workstream-7"])
        XCTAssertEqual(receivedCwd, repoRoot.path)
        XCTAssertEqual(created.name, "workstream-7")
        XCTAssertEqual(created.path, PathNormalizer.normalize(repoRoot.appendingPathComponent(".capacitor/worktrees/workstream-7").path))

        let managedRoot = repoRoot.appendingPathComponent(".capacitor/worktrees").path
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: managedRoot, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testRemoveManagedWorktreeBuildsExpectedGitCommand() throws {
        let repoPath = "/tmp/repo"
        var receivedArgs: [String] = []
        var receivedCwd = ""

        let service = WorktreeService(runGit: { args, cwd in
            receivedArgs = args
            receivedCwd = cwd
            return .init(exitCode: 0, stdout: "", stderr: "")
        })

        try service.removeManagedWorktree(in: repoPath, name: "workstream-4")

        XCTAssertEqual(receivedArgs, ["worktree", "remove", ".capacitor/worktrees/workstream-4"])
        XCTAssertEqual(receivedCwd, repoPath)
    }

    func testRemoveManagedWorktreePrunesThenChecksDirtyThenRemoves() throws {
        let repoPath = "/tmp/repo"
        let worktreePath = PathNormalizer.normalize("/tmp/repo/.capacitor/worktrees/workstream-4")
        var calls: [CommandCall] = []

        let service = WorktreeService(runGit: { args, cwd in
            calls.append(CommandCall(args: args, cwd: cwd))
            switch args {
            case ["worktree", "prune"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["status", "--porcelain"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["worktree", "remove", ".capacitor/worktrees/workstream-4"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            default:
                XCTFail("Unexpected command: \(args)")
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
        })

        try service.removeManagedWorktree(in: repoPath, name: "workstream-4")

        XCTAssertEqual(calls, [
            CommandCall(args: ["worktree", "prune"], cwd: repoPath),
            CommandCall(args: ["status", "--porcelain"], cwd: worktreePath),
            CommandCall(args: ["worktree", "remove", ".capacitor/worktrees/workstream-4"], cwd: repoPath),
        ])
    }

    func testRemoveManagedWorktreeBlocksWhenDirtyByDefault() throws {
        let repoPath = "/tmp/repo"
        let worktreePath = PathNormalizer.normalize("/tmp/repo/.capacitor/worktrees/workstream-4")
        var removeCalled = false

        let service = WorktreeService(runGit: { args, _ in
            switch args {
            case ["worktree", "prune"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["status", "--porcelain"]:
                return .init(exitCode: 0, stdout: " M edited.swift\n", stderr: "")
            case ["worktree", "remove", ".capacitor/worktrees/workstream-4"]:
                removeCalled = true
                return .init(exitCode: 0, stdout: "", stderr: "")
            default:
                XCTFail("Unexpected command: \(args)")
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
        })

        do {
            try service.removeManagedWorktree(in: repoPath, name: "workstream-4")
            XCTFail("Expected remove to throw")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .dirtyWorktree(path):
                XCTAssertEqual(path, worktreePath)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(removeCalled)
    }

    func testRemoveManagedWorktreeBlocksWhenActiveSessionExists() throws {
        let repoPath = "/tmp/repo"
        let worktreePath = PathNormalizer.normalize("/tmp/repo/.capacitor/worktrees/workstream-4")

        let service = WorktreeService(runGit: { args, _ in
            XCTFail("Expected no git commands, got: \(args)")
            return .init(exitCode: 1, stdout: "", stderr: "")
        })

        do {
            try service.removeManagedWorktree(
                in: repoPath,
                name: "workstream-4",
                activeWorktreePaths: [worktreePath],
            )
            XCTFail("Expected remove to throw")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .activeSessionWorktree(path):
                XCTAssertEqual(path, worktreePath)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRemoveManagedWorktreeBlocksWhenActivePathIsInsideWorktree() throws {
        let repoPath = "/tmp/repo"
        let worktreePath = PathNormalizer.normalize("/tmp/repo/.capacitor/worktrees/workstream-4")
        let activeChildPath = PathNormalizer.normalize("/tmp/repo/.capacitor/worktrees/workstream-4/apps/web")

        let service = WorktreeService(runGit: { args, _ in
            XCTFail("Expected no git commands, got: \(args)")
            return .init(exitCode: 1, stdout: "", stderr: "")
        })

        do {
            try service.removeManagedWorktree(
                in: repoPath,
                name: "workstream-4",
                activeWorktreePaths: [activeChildPath],
            )
            XCTFail("Expected remove to throw")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .activeSessionWorktree(path):
                XCTAssertEqual(path, worktreePath)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRemoveManagedWorktreeReturnsLockedErrorWhenGitReportsLocked() throws {
        let repoPath = "/tmp/repo"
        let worktreePath = PathNormalizer.normalize("/tmp/repo/.capacitor/worktrees/workstream-4")

        let service = WorktreeService(runGit: { args, _ in
            switch args {
            case ["worktree", "prune"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["status", "--porcelain"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["worktree", "remove", ".capacitor/worktrees/workstream-4"]:
                return .init(exitCode: 128, stdout: "", stderr: "fatal: cannot remove a locked working tree")
            default:
                XCTFail("Unexpected command: \(args)")
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
        })

        do {
            try service.removeManagedWorktree(in: repoPath, name: "workstream-4")
            XCTFail("Expected remove to throw")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .lockedWorktree(path, message):
                XCTAssertEqual(path, worktreePath)
                XCTAssertEqual(message, "fatal: cannot remove a locked working tree")
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testRemoveManagedWorktreeThrowsGitCommandFailure() throws {
        let service = WorktreeService(runGit: { args, _ in
            switch args {
            case ["worktree", "prune"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["status", "--porcelain"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            case ["worktree", "remove", ".capacitor/worktrees/workstream-4"]:
                return .init(exitCode: 128, stdout: "", stderr: "fatal: unknown remove error")
            default:
                XCTFail("Unexpected command: \(args)")
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
        })

        do {
            try service.removeManagedWorktree(in: "/tmp/repo", name: "workstream-4")
            XCTFail("Expected remove to throw")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .gitCommandFailed(arguments, exitCode, output):
                XCTAssertEqual(arguments, ["worktree", "remove", ".capacitor/worktrees/workstream-4"])
                XCTAssertEqual(exitCode, 128)
                XCTAssertEqual(output, "fatal: unknown remove error")
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
