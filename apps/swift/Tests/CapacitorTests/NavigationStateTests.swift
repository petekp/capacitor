@testable import Capacitor
import Observation
import XCTest

@MainActor
final class NavigationStateTests: XCTestCase {
    func testDestinationObservationInvalidatesWhenShowingProjectDetail() {
        let navigationState = NavigationState()
        let invalidated = expectation(description: "destination invalidated")

        withObservationTracking {
            _ = navigationState.destination
        } onChange: {
            invalidated.fulfill()
        }

        navigationState.showProjectDetail(
            ShellProjectReference(
                displayName: "Capacitor",
                path: "/tmp/capacitor",
            ),
        )

        wait(for: [invalidated], timeout: 0.5)
        XCTAssertEqual(navigationState.destination, .projectDetail(projectID: "/tmp/capacitor"))
    }
}
