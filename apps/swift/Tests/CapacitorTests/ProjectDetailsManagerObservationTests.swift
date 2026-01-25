@testable import Capacitor
import Observation
import XCTest

@MainActor
final class ProjectDetailsManagerObservationTests: XCTestCase {
    func testGetIdeasObservationInvalidatesWhenIdeasReordered() {
        let manager = ProjectDetailsManager()
        let project = makeProject(name: "Test", path: "/tmp/test")
        let reorderedIdeas = [
            Idea(
                id: "01JEXAMPLE00000000000000000",
                title: "Idea",
                description: "Desc",
                added: "2026-02-10T00:00:00Z",
                effort: "small",
                status: "open",
                triage: "pending",
                related: nil,
            ),
        ]

        let invalidated = expectation(description: "observation invalidated")
        withObservationTracking {
            _ = manager.getIdeas(for: project)
        } onChange: {
            invalidated.fulfill()
        }

        manager.reorderIdeas(reorderedIdeas, for: project)

        wait(for: [invalidated], timeout: 0.1)
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
