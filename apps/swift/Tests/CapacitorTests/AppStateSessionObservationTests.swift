@testable import Capacitor
import Observation
import XCTest

@MainActor
final class AppStateSessionObservationTests: XCTestCase {
    func testAppStateSessionReadInvalidatesWhenSessionStateChanges() {
        let appState = AppState()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")

        let invalidated = expectation(description: "observation invalidated")
        withObservationTracking {
            _ = appState.getSessionState(for: project)
        } onChange: {
            invalidated.fulfill()
        }

        appState.sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: "2026-02-11T17:35:32.479916+00:00",
                updatedAt: "2026-02-11T17:35:32.479916+00:00",
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        wait(for: [invalidated], timeout: 0.5)
    }

    func testOrderedGroupedProjectsInvalidatesWhenSessionStateChanges() {
        let appState = AppState()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projects = [project]

        let invalidated = expectation(description: "grouped projects invalidated")
        withObservationTracking {
            _ = appState.orderedGroupedProjects(appState.projects)
        } onChange: {
            invalidated.fulfill()
        }

        appState.sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: "2026-02-11T17:35:32.479916+00:00",
                updatedAt: "2026-02-11T17:35:32.479916+00:00",
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        wait(for: [invalidated], timeout: 0.5)
    }

    func testSessionStateRevisionIncrementsWhenSessionStateChanges() {
        let appState = AppState()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        let initialRevision = appState.sessionStateRevision

        appState.sessionStateManager.setSessionStatesForTesting([
            project.path: ProjectSessionState(
                state: .working,
                stateChangedAt: "2026-02-11T17:35:32.479916+00:00",
                updatedAt: "2026-02-11T17:35:32.479916+00:00",
                sessionId: "session-1",
                workingOn: nil,
                context: nil,
                thinking: nil,
                hasSession: true,
            ),
        ])

        XCTAssertEqual(appState.sessionStateRevision, initialRevision + 1)
    }

    private func makeProject(name: String, path: String) -> Project {
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
