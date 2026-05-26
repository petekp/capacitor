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
}
