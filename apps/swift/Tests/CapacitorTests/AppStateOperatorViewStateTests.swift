@testable import Capacitor
import XCTest

@MainActor
final class AppStateOperatorViewStateTests: XCTestCase {
    func testLoadsPreviousOperatorViewStateAndRecordsCurrentOpen() async throws {
        let stateURL = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let previousOpen = Date(timeIntervalSince1970: 1_800_000_420)
        let currentOpen = Date(timeIntervalSince1970: 1_800_000_840)
        let store = OperatorViewStateStore(stateURL: stateURL)
        try await store.recordAppOpened(at: previousOpen)

        let appState = AppState(
            runtimeClient: RuntimeClient(isEnabledOverride: false),
            operatorViewStateStore: store,
            operatorViewOpenedAt: currentOpen,
        )

        try await waitForOperatorViewState(on: appState, openedAt: previousOpen)
        XCTAssertEqual(appState.operatorViewStateSnapshot.lastAppOpenedAt, previousOpen)

        let persistedSnapshot = try await waitForPersistedOperatorViewState(
            stateURL: stateURL,
            openedAt: currentOpen,
        )
        XCTAssertEqual(persistedSnapshot.lastAppOpenedAt, currentOpen)
    }

    func testMarkProjectCaseFileSeenPersistsNarrowSeenStateWithoutMutatingLoadedSnapshot() async throws {
        let stateURL = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let previousOpen = Date(timeIntervalSince1970: 1_800_000_420)
        let seenAt = Date(timeIntervalSince1970: 1_800_000_900)
        let store = OperatorViewStateStore(stateURL: stateURL)
        try await store.recordAppOpened(at: previousOpen)
        let appState = AppState(
            runtimeClient: RuntimeClient(isEnabledOverride: false),
            operatorViewStateStore: store,
        )
        try await waitForOperatorViewState(on: appState, openedAt: previousOpen)

        appState.markProjectCaseFileSeen(
            projectPath: "/tmp/project/",
            runID: "run-1",
            checkpointIDs: ["checkpoint-1", "checkpoint-2"],
            at: seenAt,
        )

        let persistedSnapshot = try await waitForPersistedCaseFileSeen(
            stateURL: stateURL,
            projectPath: "/tmp/project",
            runID: "run-1",
            checkpointID: "checkpoint-2",
            seenAt: seenAt,
        )

        XCTAssertEqual(persistedSnapshot.lastSeenProjects[PathNormalizer.normalize("/tmp/project")], seenAt)
        XCTAssertEqual(persistedSnapshot.lastSeenRuns["run-1"], seenAt)
        XCTAssertEqual(persistedSnapshot.lastSeenCheckpoints["checkpoint-1"], seenAt)
        XCTAssertEqual(persistedSnapshot.lastSeenCheckpoints["checkpoint-2"], seenAt)
        XCTAssertNil(appState.operatorViewStateSnapshot.lastSeenProjects[PathNormalizer.normalize("/tmp/project")])
    }

    private func waitForOperatorViewState(
        on appState: AppState,
        openedAt: Date,
    ) async throws {
        for _ in 0 ..< 20 {
            if appState.operatorViewStateSnapshot.lastAppOpenedAt == openedAt {
                return
            }
            try await _Concurrency.Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForPersistedOperatorViewState(
        stateURL: URL,
        openedAt: Date,
    ) async throws -> OperatorViewStateStore.Snapshot {
        for _ in 0 ..< 20 {
            let snapshot = try await OperatorViewStateStore(stateURL: stateURL).load()
            if snapshot.lastAppOpenedAt == openedAt {
                return snapshot
            }
            try await _Concurrency.Task.sleep(nanoseconds: 10_000_000)
        }
        return try await OperatorViewStateStore(stateURL: stateURL).load()
    }

    private func waitForPersistedCaseFileSeen(
        stateURL: URL,
        projectPath: String,
        runID: String,
        checkpointID: String,
        seenAt: Date,
    ) async throws -> OperatorViewStateStore.Snapshot {
        let normalizedProjectPath = PathNormalizer.normalize(projectPath)
        for _ in 0 ..< 20 {
            let snapshot = try await OperatorViewStateStore(stateURL: stateURL).load()
            if snapshot.lastSeenProjects[normalizedProjectPath] == seenAt,
               snapshot.lastSeenRuns[runID] == seenAt,
               snapshot.lastSeenCheckpoints[checkpointID] == seenAt
            {
                return snapshot
            }
            try await _Concurrency.Task.sleep(nanoseconds: 10_000_000)
        }
        return try await OperatorViewStateStore(stateURL: stateURL).load()
    }

    private func temporaryStateURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateOperatorViewStateTests-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("operator-view-state.json")
    }
}
