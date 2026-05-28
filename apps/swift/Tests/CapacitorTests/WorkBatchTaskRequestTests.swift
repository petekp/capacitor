@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchTaskRequestTests: XCTestCase {
    func testTaskRequestStoreWritesAndLoadsRequestsFromBatchWorktree() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let requestedAt = Date(timeIntervalSince1970: 1_775_000_000)
        let store = WorkBatchTaskRequestStore(worktreePath: tempDir.path, fileManager: fileManager)
        let request = WorkBatchTaskRequest(
            taskID: "Task/Empty State Copy",
            title: "Fix empty state copy",
            body: "The user asked for clearer copy in the empty state.",
            source: "manual_user_instruction",
            requestedAt: requestedAt,
        )

        let url = try store.write(request)
        let loaded = try store.loadRequests()

        XCTAssertTrue(url.path.hasSuffix(".capacitor/work-batch-task-requests/task-empty-state-copy.json"))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.request, request)
        XCTAssertEqual(loaded.first?.url.lastPathComponent, "task-empty-state-copy.json")
        XCTAssertEqual(loaded.first?.canonicalTaskID, "task-empty-state-copy")
    }

    func testTaskRequestStoreIgnoresBlankAndMalformedRequests() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directoryURL = tempDir.appendingPathComponent(
            WorkBatchTaskRequestStore.relativeDirectory,
            isDirectory: true,
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: tempDir)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(WorkBatchTaskRequest(
            taskID: "task-blank",
            title: "   ",
            body: "\n",
            source: "manual_user_instruction",
            requestedAt: nil,
        ))
        .write(to: directoryURL.appendingPathComponent("task-blank.json"), options: .atomic)
        try Data("{not-json".utf8)
            .write(to: directoryURL.appendingPathComponent("broken.json"), options: .atomic)

        let loaded = try WorkBatchTaskRequestStore(
            worktreePath: tempDir.path,
            fileManager: fileManager,
        ).loadRequests()

        XCTAssertEqual(loaded, [])
    }
}
