@testable import Capacitor
import XCTest

final class DockProjectCardPresentationTests: XCTestCase {
    func testTrackedWorkingRunVisualOverridesSessionStateAndSuppliesContextLine() {
        let presentation = DockProjectCardPresentation.resolve(
            sessionState: makeSessionState(.ready),
            trackedRunVisualState: .working(statusMessage: "Generating implementation plan"),
        )

        XCTAssertEqual(presentation.currentState, .working)
        XCTAssertEqual(presentation.contextLine, "Generating implementation plan")
    }

    func testSessionStateDrivesPresentationWhenNoRunVisualIsTracked() {
        let presentation = DockProjectCardPresentation.resolve(
            sessionState: makeSessionState(.waiting),
            trackedRunVisualState: .none,
        )

        XCTAssertEqual(presentation.currentState, .waiting)
        XCTAssertNil(presentation.contextLine)
    }

    private func makeSessionState(_ state: SessionState) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: nil,
            updatedAt: nil,
            sessionId: nil,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: state != .idle,
        )
    }
}
