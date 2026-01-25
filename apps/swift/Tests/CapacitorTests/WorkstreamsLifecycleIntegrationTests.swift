@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class WorkstreamsLifecycleIntegrationTests: XCTestCase {
    func testCreateAttributionAndDestroyGuardrailFlow() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let repoRoot = tempDir.appendingPathComponent("repo")
        let repoGit = repoRoot.appendingPathComponent(".git")
        let pinnedPath = repoRoot.appendingPathComponent("apps/docs")
        try fileManager.createDirectory(at: repoGit, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: pinnedPath, withIntermediateDirectories: true)

        var gitCalls: [[String]] = []
        let service = WorktreeService(runGit: { args, _ in
            gitCalls.append(args)
            switch args {
            case ["worktree", "add", ".capacitor/worktrees/workstream-1", "-b", "workstream-1"]:
                return .init(exitCode: 0, stdout: "", stderr: "")
            default:
                XCTFail("Unexpected git command: \(args)")
                return .init(exitCode: 1, stdout: "", stderr: "")
            }
        })

        let worktree = try service.createManagedWorktree(in: repoRoot.path, name: "workstream-1")
        let shellPath = PathNormalizer.normalize(worktree.path + "/apps/docs")
        try fileManager.createDirectory(atPath: shellPath, withIntermediateDirectories: true)

        do {
            try service.removeManagedWorktree(
                in: repoRoot.path,
                name: "workstream-1",
                activeWorktreePaths: [shellPath],
            )
            XCTFail("Expected guardrail to block destroy for active worktree")
        } catch let error as WorktreeService.Error {
            switch error {
            case let .activeSessionWorktree(path):
                XCTAssertEqual(path, worktree.path)
            default:
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertEqual(gitCalls, [
            ["worktree", "add", ".capacitor/worktrees/workstream-1", "-b", "workstream-1"],
        ])
    }
}
