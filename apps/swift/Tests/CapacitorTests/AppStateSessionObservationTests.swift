@testable import Capacitor
import Observation
import XCTest

@MainActor
final class AppStateSessionObservationTests: XCTestCase {
    func testAppStateSessionReadInvalidatesWhenSessionStateChanges() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
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
                stateSource: nil,
                lastAuthoritativeEventAt: nil,
            ),
        ])

        wait(for: [invalidated], timeout: 0.5)
    }

    func testOrderedGroupedProjectsInvalidatesWhenSessionStateChanges() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")
        appState.projectState.projects = [project]

        let invalidated = expectation(description: "grouped projects invalidated")
        withObservationTracking {
            _ = appState.orderedGroupedProjects(appState.projectState.projects)
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
                stateSource: nil,
                lastAuthoritativeEventAt: nil,
            ),
        ])

        wait(for: [invalidated], timeout: 0.5)
    }

    func testFlashingReadInvalidatesWhenFlashingStateChanges() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")

        // Proves the revision-counter deletion is safe: getSessionState /
        // isFlashing reads are observed purely through @Observable tracking of
        // SessionStateManager, with no manual sessionStateRevision bridge.
        let invalidated = expectation(description: "flashing read invalidated")
        withObservationTracking {
            _ = appState.getSessionState(for: project)
            _ = appState.isFlashing(project)
        } onChange: {
            invalidated.fulfill()
        }

        appState.sessionStateManager.setFlashingProjectsForTesting([
            project.path: .working,
        ])

        wait(for: [invalidated], timeout: 0.5)
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            workspaceId: WorkspaceIdentity.fromPath(path),
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
