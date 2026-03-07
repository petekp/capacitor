@testable import Capacitor
import XCTest

@MainActor
final class ProjectStatusCacheStateTests: XCTestCase {
    func testRefreshWithNoEngineLeavesCacheEmpty() {
        let project = makeProject(path: "/tmp/capacitor")
        let state = ProjectStatusCacheState()

        state.refresh(projects: [project], engine: nil)

        XCTAssertTrue(state.statuses.isEmpty)
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
