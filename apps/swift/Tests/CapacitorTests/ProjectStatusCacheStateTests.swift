@testable import Capacitor
import XCTest

@MainActor
final class ProjectStatusCacheStateTests: XCTestCase {
    func testRefreshWithNoEngineLeavesCacheEmpty() {
        let state = ProjectStatusCacheState()

        state.refresh(projectPaths: ["/tmp/capacitor"], engine: nil)

        XCTAssertTrue(state.statuses.isEmpty)
    }
}
