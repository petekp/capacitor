@testable import Capacitor
import XCTest

@MainActor
final class AppShellContainerTests: XCTestCase {
    func testLiveContainerBuildsLegacyAppStateAndDefaultShellState() {
        let container = AppShellContainer.live()

        XCTAssertEqual(container.appState.activeProjectTrackingState.activeSource, .none)
        XCTAssertTrue(container.appState.projectWorkflowState === container.projectWorkflowState)
        XCTAssertTrue(container.appState.projectListState === container.projectListState)
        XCTAssertTrue(container.appState.runtimeSupervisor === container.runtimeSupervisor)
        XCTAssertTrue(container.appState.setupSupervisor === container.setupSupervisor)
        XCTAssertTrue(container.appState.setupActionState === container.setupActionState)
        XCTAssertFalse(container.setupWorkflowState.isUsingPreviewMode)
        XCTAssertTrue(container.appState.projectActionState === container.projectActionState)
        XCTAssertTrue(container.appState.navigationState === container.navigationState)
        XCTAssertNil(container.runtimeSupervisor.projection)
        XCTAssertNil(container.runtimeSupervisor.observation)
        XCTAssertEqual(container.projectWorkflowState.projectCatalog, [])
        XCTAssertEqual(container.projectWorkflowState.suggestedProjectCatalog, [])
        XCTAssertEqual(container.navigationState.destination, .projectList)
        XCTAssertNil(container.setupSupervisor.readiness)
    }
}
