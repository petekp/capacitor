@testable import Capacitor
import XCTest

@MainActor
final class AppStateCreationTests: XCTestCase {
    func testDiscoveredSessionDoesNotReactivateCancelledCreation() {
        let appState = AppState()
        let creationId = "creation-cancelled"
        appState.projectState.activeCreations = [
            makeCreation(id: creationId, status: .cancelled),
        ]

        let applied = appState.applyDiscoveredSessionToCreationForTesting(
            creationId,
            sessionId: "late-session",
        )

        XCTAssertFalse(applied, "terminal creation must not be reactivated by late monitor callback")
        XCTAssertEqual(
            appState.projectState.activeCreations.first(where: { $0.id == creationId })?.status,
            .cancelled,
        )
    }

    func testCancelCreationCancelsTrackedMonitorTasks() {
        let appState = AppState()
        let creationId = "creation-in-progress"
        appState.projectState.activeCreations = [
            makeCreation(id: creationId, status: .inProgress),
        ]

        let sessionCancelled = expectation(description: "session monitor cancelled")
        let completionCancelled = expectation(description: "completion monitor cancelled")

        let sessionTask: _Concurrency.Task<Void, Never> = _Concurrency.Task {
            await withTaskCancellationHandler(operation: {
                while !_Concurrency.Task.isCancelled {
                    await _Concurrency.Task.yield()
                }
            }, onCancel: {
                sessionCancelled.fulfill()
            })
        }

        let completionTask: _Concurrency.Task<Void, Never> = _Concurrency.Task {
            await withTaskCancellationHandler(operation: {
                while !_Concurrency.Task.isCancelled {
                    await _Concurrency.Task.yield()
                }
            }, onCancel: {
                completionCancelled.fulfill()
            })
        }

        appState.setCreationMonitorTasksForTesting(
            creationId: creationId,
            sessionTask: sessionTask,
            completionTask: completionTask,
        )

        appState.cancelCreation(creationId)

        wait(for: [sessionCancelled, completionCancelled], timeout: 1.0)
        XCTAssertFalse(appState.hasCreationMonitorTasksForTesting(creationId: creationId))
    }

    private func makeCreation(id: String, status: CreationStatus) -> ProjectCreation {
        ProjectCreation(
            id: id,
            name: "Test",
            path: "/tmp/\(id)",
            description: "test",
            status: status,
            sessionId: nil,
            progress: nil,
            error: nil,
            createdAt: "2026-03-05T00:00:00Z",
            completedAt: nil,
        )
    }
}
