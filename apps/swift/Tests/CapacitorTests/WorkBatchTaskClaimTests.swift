@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchTaskClaimTests: XCTestCase {
    func testClaimStoreWritesAndLoadsClaimsFromBatchWorktree() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let claimedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let contextUpdatedAt = Date(timeIntervalSince1970: 1_775_000_010)
        let store = WorkBatchTaskClaimStore(worktreePath: tempDir.path, fileManager: fileManager)
        let claim = WorkBatchTaskClaim(
            taskID: "Task/Green Border",
            status: "working",
            summary: "Adding the green border",
            claimedAt: claimedAt,
            contextUpdatedAt: contextUpdatedAt,
            deliveryGeneration: "batch-mobile:1775000010",
        )

        let url = try store.write(claim)
        let loaded = try store.loadClaims()

        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-claims/task-green-border.json"))
        XCTAssertEqual(loaded.map(\.claim), [claim])
        XCTAssertEqual(loaded.map(\.url.lastPathComponent), ["task-green-border.json"])
        XCTAssertTrue(claim.isWorking)
    }

    func testClaimStoreIgnoresMalformedJson() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let store = WorkBatchTaskClaimStore(worktreePath: tempDir.path, fileManager: fileManager)
        let validClaim = WorkBatchTaskClaim(
            taskID: "task-green",
            status: "working",
            summary: "Adding border",
            claimedAt: nil,
            contextUpdatedAt: nil,
            deliveryGeneration: nil,
        )
        _ = try store.write(validClaim)
        let directoryURL = tempDir.appendingPathComponent(WorkBatchTaskClaimStore.relativeDirectory, isDirectory: true)
        try "{not json".write(
            to: directoryURL.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8,
        )

        XCTAssertEqual(try store.loadClaims().map(\.claim), [validClaim])
    }

    func testClaimStoreLoadsAgentWrittenFractionalSecondDates() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let directoryURL = tempDir.appendingPathComponent(WorkBatchTaskClaimStore.relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try """
        {
          "task_id": "task-green",
          "status": "working",
          "summary": "Adding border",
          "claimed_at": "2026-05-25T19:02:00.000Z",
          "context_updated_at": "2026-05-25T19:01:41.352Z",
          "delivery_generation": "batch-mobile:2026-05-25T19:01:41.352Z"
        }
        """.write(
            to: directoryURL.appendingPathComponent("task-green.json"),
            atomically: true,
            encoding: .utf8,
        )

        let loaded = try WorkBatchTaskClaimStore(worktreePath: tempDir.path, fileManager: fileManager).loadClaims()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].claim.taskID, "task-green")
        XCTAssertEqual(loaded[0].claim.claimedAt, parseISO8601Date("2026-05-25T19:02:00.000Z"))
        XCTAssertEqual(loaded[0].claim.contextUpdatedAt, parseISO8601Date("2026-05-25T19:01:41.352Z"))
    }

    func testClaimStoreIgnoresUnsupportedStatus() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let store = WorkBatchTaskClaimStore(worktreePath: tempDir.path, fileManager: fileManager)
        _ = try store.write(WorkBatchTaskClaim(
            taskID: "task-green",
            status: "done",
            summary: "Not a pickup claim",
            claimedAt: nil,
            contextUpdatedAt: nil,
            deliveryGeneration: nil,
        ))

        XCTAssertTrue(try store.loadClaims().isEmpty)
    }

    func testClaimStoreInstallsLocalGitIgnoreForCapacitorMetadata() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let worktreeURL = tempDir.appendingPathComponent("worktree", isDirectory: true)
        let gitDirURL = tempDir.appendingPathComponent("gitdir", isDirectory: true)
        try fileManager.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitDirURL, withIntermediateDirectories: true)
        try "gitdir: ../gitdir\n".write(
            to: worktreeURL.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8,
        )
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let store = WorkBatchTaskClaimStore(worktreePath: worktreeURL.path, fileManager: fileManager)
        let claim = WorkBatchTaskClaim(
            taskID: "task-green",
            status: "working",
            summary: "Adding border",
            claimedAt: nil,
            contextUpdatedAt: nil,
            deliveryGeneration: nil,
        )

        _ = try store.write(claim)
        _ = try store.write(claim)

        let exclude = try String(
            contentsOf: gitDirURL
                .appendingPathComponent("info", isDirectory: true)
                .appendingPathComponent("exclude"),
            encoding: .utf8,
        )
        XCTAssertEqual(exclude.components(separatedBy: ".capacitor/").count - 1, 1)
        XCTAssertTrue(exclude.contains("# Capacitor Work Batch metadata\n.capacitor/"))
    }
}
