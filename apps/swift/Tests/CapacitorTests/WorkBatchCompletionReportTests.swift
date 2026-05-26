@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchCompletionReportTests: XCTestCase {
    func testReportStoreWritesAndLoadsDoneReportsFromBatchWorktree() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let completedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let store = WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
        let report = WorkBatchCompletionReport(
            taskID: "Task/Green Border",
            status: "done",
            summary: "Added the green border",
            evidence: ["Updated mobile prototype styles", "Verified responsive state"],
            completedAt: completedAt,
        )

        let url = try store.write(report)
        let loaded = try store.loadReports()

        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-completions/task-green-border.json"))
        XCTAssertEqual(loaded.map(\.report), [report])
        XCTAssertEqual(loaded.map(\.url.lastPathComponent), ["task-green-border.json"])
        XCTAssertTrue(report.isDone)
    }

    func testReportStoreIgnoresMalformedJsonWithoutBlockingValidReports() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let store = WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
        let validReport = WorkBatchCompletionReport(
            taskID: "task-green",
            status: "done",
            summary: "Added border",
            evidence: ["Changed CSS"],
            completedAt: nil,
        )
        _ = try store.write(validReport)
        let directoryURL = tempDir.appendingPathComponent(WorkBatchCompletionReportStore.relativeDirectory, isDirectory: true)
        try "{not json".write(
            to: directoryURL.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8,
        )

        XCTAssertEqual(try store.loadReports().map(\.report), [validReport])
    }

    func testReportStoreLoadsAgentWrittenFractionalSecondDates() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let directoryURL = tempDir.appendingPathComponent(WorkBatchCompletionReportStore.relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try """
        {
          "task_id": "task-green",
          "status": "done",
          "summary": "Added border",
          "evidence": ["Changed CSS"],
          "completed_at": "2026-05-25T19:02:00.000Z"
        }
        """.write(
            to: directoryURL.appendingPathComponent("task-green.json"),
            atomically: true,
            encoding: .utf8,
        )

        let loaded = try WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager).loadReports()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].report.taskID, "task-green")
        XCTAssertEqual(loaded[0].report.completedAt, parseISO8601Date("2026-05-25T19:02:00.000Z"))
    }

    func testDeletingReportRemovesAnyLoadedReportForTheTaskID() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let store = WorkBatchCompletionReportStore(worktreePath: tempDir.path, fileManager: fileManager)
        let report = WorkBatchCompletionReport(
            taskID: "task-green",
            status: "done",
            summary: "Added border",
            evidence: ["Changed CSS"],
            completedAt: nil,
        )
        let canonicalURL = try store.write(report)
        let directoryURL = tempDir.appendingPathComponent(WorkBatchCompletionReportStore.relativeDirectory, isDirectory: true)
        let extraURL = directoryURL.appendingPathComponent("manual-name.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: extraURL, options: .atomic)

        try store.deleteReport(taskID: "task-green")

        XCTAssertFalse(fileManager.fileExists(atPath: canonicalURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: extraURL.path))
        XCTAssertTrue(try store.loadReports().isEmpty)
    }

    func testReportStoreInstallsLocalGitIgnoreForCapacitorMetadata() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktreeURL = tempDir.appendingPathComponent("worktree", isDirectory: true)
        let worktreeGitDirURL = tempDir.appendingPathComponent("worktree-gitdir", isDirectory: true)
        let commonGitDirURL = tempDir.appendingPathComponent("common-gitdir", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktreeGitDirURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: commonGitDirURL, withIntermediateDirectories: true)
        try "gitdir: ../worktree-gitdir\n".write(
            to: worktreeURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8,
        )
        try "../common-gitdir\n".write(
            to: worktreeGitDirURL.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8,
        )
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let store = WorkBatchCompletionReportStore(worktreePath: worktreeURL.path, fileManager: fileManager)
        let report = WorkBatchCompletionReport(
            taskID: "task-green",
            status: "done",
            summary: "Added border",
            evidence: ["Changed CSS"],
            completedAt: nil,
        )

        _ = try store.write(report)
        _ = try store.write(report)

        let exclude = try String(
            contentsOf: commonGitDirURL
                .appendingPathComponent("info", isDirectory: true)
                .appendingPathComponent("exclude"),
            encoding: .utf8,
        )
        XCTAssertEqual(exclude.components(separatedBy: ".capacitor/").count - 1, 1)
        XCTAssertTrue(exclude.contains("# Capacitor Work Batch metadata\n.capacitor/"))
    }
}
