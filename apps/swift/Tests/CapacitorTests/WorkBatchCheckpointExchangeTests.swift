@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchCheckpointExchangeTests: XCTestCase {
    func testCheckpointRequestStoreWritesAndLoadsRequestsFromBatchWorktree() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let requestedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let store = WorkBatchCheckpointRequestStore(worktreePath: tempDir.path, fileManager: fileManager)
        let request = WorkBatchCheckpointRequest(
            checkpointID: "Task/Green Border/Question",
            taskID: "task-green",
            question: "Should this use the debug token or the production token?",
            reason: "The Task asks for a green border, but the product intent is unclear.",
            recommendedAction: "Choose production token unless this is debug-only.",
            requestedAt: requestedAt,
        )

        let url = try store.write(request)
        let loaded = try store.loadRequests()

        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-checkpoints/task-green-border-question.json"))
        XCTAssertEqual(loaded.map(\.request), [request])
        XCTAssertEqual(loaded.map(\.url.lastPathComponent), ["task-green-border-question.json"])
    }

    func testCheckpointRequestStoreIgnoresMalformedOrEmptyQuestionJson() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let store = WorkBatchCheckpointRequestStore(worktreePath: tempDir.path, fileManager: fileManager)
        let validRequest = WorkBatchCheckpointRequest(
            checkpointID: "checkpoint-green",
            taskID: "task-green",
            question: "Which green should I use?",
            reason: "There are multiple green tokens.",
            recommendedAction: nil,
            requestedAt: nil,
        )
        _ = try store.write(validRequest)
        let directoryURL = tempDir.appendingPathComponent(WorkBatchCheckpointRequestStore.relativeDirectory, isDirectory: true)
        try "{not json".write(
            to: directoryURL.appendingPathComponent("broken.json"),
            atomically: true,
            encoding: .utf8,
        )
        try """
        {
          "checkpoint_id": "empty-question",
          "task_id": "task-green",
          "question": "   ",
          "reason": "No useful question"
        }
        """.write(
            to: directoryURL.appendingPathComponent("empty-question.json"),
            atomically: true,
            encoding: .utf8,
        )

        XCTAssertEqual(try store.loadRequests().map(\.request), [validRequest])
    }

    func testCheckpointRequestStoreLoadsAgentWrittenFractionalSecondDates() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let directoryURL = tempDir.appendingPathComponent(WorkBatchCheckpointRequestStore.relativeDirectory, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try """
        {
          "checkpoint_id": "checkpoint-green",
          "task_id": "task-green",
          "question": "Which green should I use?",
          "reason": "The task did not say.",
          "requested_at": "2026-05-25T19:02:00.000Z"
        }
        """.write(
            to: directoryURL.appendingPathComponent("checkpoint-green.json"),
            atomically: true,
            encoding: .utf8,
        )

        let loaded = try WorkBatchCheckpointRequestStore(worktreePath: tempDir.path, fileManager: fileManager).loadRequests()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].request.checkpointID, "checkpoint-green")
        XCTAssertEqual(loaded[0].request.requestedAt, parseISO8601Date("2026-05-25T19:02:00.000Z"))
    }

    func testCheckpointResponseStoreWritesResponseBackToBatchWorktree() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let respondedAt = Date(timeIntervalSince1970: 1_775_000_100)
        let store = WorkBatchCheckpointResponseStore(worktreePath: tempDir.path, fileManager: fileManager)
        let response = WorkBatchCheckpointResponse(
            checkpointID: "checkpoint-green",
            taskID: "task-green",
            response: "Use the production green token.",
            respondedAt: respondedAt,
        )

        let url = try store.write(response)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-checkpoint-responses/checkpoint-green.json"))
        XCTAssertEqual(try decoder.decode(WorkBatchCheckpointResponse.self, from: data), response)
    }
}
