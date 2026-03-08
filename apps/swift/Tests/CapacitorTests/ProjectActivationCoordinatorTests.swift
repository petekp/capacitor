@testable import Capacitor
import XCTest

@MainActor
final class ProjectActivationCoordinatorTests: XCTestCase {
    func testActivateUpdatesTrackingStateAndTriggersActivation() {
        let project = makeProject(path: "/tmp/capacitor")
        var steps: [String] = []

        let coordinator = ProjectActivationCoordinator(
            activateTracking: { receivedProject in
                steps.append("track:\(receivedProject.path)")
            },
            activateProject: { receivedProject in
                steps.append("activate:\(receivedProject.path)")
            },
        )

        coordinator.activate(project)

        XCTAssertEqual(
            steps,
            [
                "track:/tmp/capacitor",
                "activate:/tmp/capacitor",
            ],
        )
    }

    func testActivateSupportsShellProjectCatalogEntries() {
        let project = ShellProjectCatalogEntry(displayName: "Capacitor", path: "/tmp/capacitor")
        var steps: [String] = []

        let coordinator = ProjectActivationCoordinator(
            activateTracking: { receivedProject in
                steps.append("track:\(receivedProject.path)")
            },
            activateProject: { receivedProject in
                steps.append("activate:\(receivedProject.path)")
            },
        )

        coordinator.activate(project)

        XCTAssertEqual(
            steps,
            [
                "track:/tmp/capacitor",
                "activate:/tmp/capacitor",
            ],
        )
    }

    private func makeProject(path: String) -> Project {
        Project(
            name: "Capacitor",
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
