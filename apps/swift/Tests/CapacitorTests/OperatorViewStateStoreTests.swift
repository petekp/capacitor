@testable import Capacitor
import XCTest

final class OperatorViewStateStoreTests: XCTestCase {
    func testDefaultURLUsesCapacitorNamespace() {
        XCTAssertTrue(
            OperatorViewStateStore.defaultURL.path.hasSuffix("/.capacitor/operator-view-state.json"),
            "Operator view state should persist in Capacitor's namespace.",
        )
    }

    func testLoadReturnsEmptySnapshotWhenFileIsMissing() async throws {
        let stateURL = try temporaryStateURL()
        let store = OperatorViewStateStore(stateURL: stateURL)

        let snapshot = try await store.load()

        XCTAssertEqual(snapshot, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testRecordAppOpenedPersistsTimestamp() async throws {
        let stateURL = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = OperatorViewStateStore(stateURL: stateURL)

        try await store.recordAppOpened(at: openedAt)

        let reloaded = try await OperatorViewStateStore(stateURL: stateURL).load()
        XCTAssertEqual(reloaded.lastAppOpenedAt, openedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testRecordsLastSeenProjectRunAndCheckpoint() async throws {
        let stateURL = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let seenAt = Date(timeIntervalSince1970: 1_800_000_120)
        let store = OperatorViewStateStore(stateURL: stateURL)

        try await store.markProjectSeen("/tmp/project/", at: seenAt)
        try await store.markRunSeen(runID: "run-123", at: seenAt)
        try await store.markCheckpointSeen(checkpointID: "checkpoint-456", at: seenAt)

        let snapshot = try await OperatorViewStateStore(stateURL: stateURL).load()
        XCTAssertEqual(snapshot.lastSeenProjects["/tmp/project"], seenAt)
        XCTAssertEqual(snapshot.lastSeenRuns["run-123"], seenAt)
        XCTAssertEqual(snapshot.lastSeenCheckpoints["checkpoint-456"], seenAt)
    }

    func testPersistsOnlyNarrowOperatorViewState() async throws {
        let stateURL = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let store = OperatorViewStateStore(stateURL: stateURL)

        try await store.recordAppOpened(at: Date(timeIntervalSince1970: 1_800_000_240))
        try await store.markProjectSeen("/tmp/project", at: Date(timeIntervalSince1970: 1_800_000_300))

        let data = try Data(contentsOf: stateURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Operator view state should be a JSON object.",
        )
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "schemaVersion",
                "lastAppOpenedAt",
                "lastSeenCheckpoints",
                "lastSeenProjects",
                "lastSeenRuns",
            ]),
        )

        let rawJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("reasoning"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("memory"))
        XCTAssertFalse(rawJSON.localizedCaseInsensitiveContains("history"))
    }

    private func temporaryStateURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperatorViewStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("operator-view-state.json")
    }
}
