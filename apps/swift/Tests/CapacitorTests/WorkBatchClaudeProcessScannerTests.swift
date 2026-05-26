@testable import Capacitor
import XCTest

final class WorkBatchClaudeProcessScannerTests: XCTestCase {
    func testFindsClaudeSessionIDsInsideBatchWorktree() {
        let scanner = WorkBatchClaudeProcessScanner(processListProvider: {
            [
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 10,
                    command: "/Users/test/.local/bin/claude --session-id session-a --permission-mode dontAsk",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                ),
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 11,
                    command: "/Users/test/.local/bin/claude --resume session-b Read context",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile/src",
                ),
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 12,
                    command: "/Users/test/.local/bin/claude --session-id session-root",
                    cwd: "/tmp/project",
                ),
            ]
        })

        XCTAssertEqual(
            scanner.sessionIDs(inWorktree: "/tmp/project/.capacitor/worktrees/batch-mobile"),
            ["session-a", "session-b"],
        )
    }

    func testIgnoresNonClaudeAndProcessesWithoutSessionIDs() {
        let scanner = WorkBatchClaudeProcessScanner(processListProvider: {
            [
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 10,
                    command: "rg --session-id session-a",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                ),
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 11,
                    command: "claude",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                ),
            ]
        })

        XCTAssertEqual(
            scanner.sessionIDs(inWorktree: "/tmp/project/.capacitor/worktrees/batch-mobile"),
            [],
        )
    }

    func testProjectEvidenceAssignsProcessesToDeepestProject() {
        let scanner = WorkBatchClaudeProcessScanner(processListProvider: {
            [
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 10,
                    command: "/Users/test/.local/bin/claude --session-id session-root",
                    cwd: "/Users/test/Code",
                ),
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 11,
                    command: "/Users/test/.local/bin/claude --session-id session-app",
                    cwd: "/Users/test/Code/app/.capacitor/worktrees/batch-mobile",
                ),
                WorkBatchClaudeProcessScanner.ProcessRecord(
                    pid: 12,
                    command: "claude",
                    cwd: "/Users/test/Code/app",
                ),
            ]
        })

        let root = makeProject("Code", path: "/Users/test/Code")
        let app = makeProject("App", path: "/Users/test/Code/app")

        let evidence = scanner.processEvidenceByProjectPath(for: [root, app])

        XCTAssertEqual(evidence[root.path]?.processCount, 1)
        XCTAssertEqual(evidence[root.path]?.sessionIDs, ["session-root"])
        XCTAssertEqual(evidence[app.path]?.processCount, 2)
        XCTAssertEqual(evidence[app.path]?.sessionIDs, ["session-app"])
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
}
