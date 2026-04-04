@testable import Capacitor
import Observation
import XCTest

@MainActor
final class AppStateSubstateObservationTests: XCTestCase {
    func testProjectStateReadInvalidatesWhenProjectsChange() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(name: "Capacitor", path: "/Users/petepetrash/Code/capacitor")

        let invalidated = expectation(description: "project state invalidated")
        withObservationTracking {
            _ = appState.projectState.projects
        } onChange: {
            invalidated.fulfill()
        }

        appState.projectState.projects = [project]

        wait(for: [invalidated], timeout: 0.5)
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
