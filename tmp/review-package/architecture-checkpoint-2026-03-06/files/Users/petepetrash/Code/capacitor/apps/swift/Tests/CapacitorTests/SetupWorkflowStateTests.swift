@testable import Capacitor
import XCTest

@MainActor
final class SetupWorkflowStateTests: XCTestCase {
    func testRestoreLiveResetsPreviewModeAndCheckID() {
        let workflowState = SetupWorkflowState(manager: .preview(.allPending))
        let initialCheckID = workflowState.checkID

        workflowState.restoreLive()

        XCTAssertFalse(workflowState.isUsingPreviewMode)
        XCTAssertNotEqual(workflowState.checkID, initialCheckID)
    }

    #if DEBUG
        func testActivatePreviewSwapsManagerAndMarksPreviewMode() {
            let workflowState = SetupWorkflowState()

            workflowState.activatePreview(.allComplete)

            XCTAssertTrue(workflowState.isUsingPreviewMode)
            XCTAssertEqual(workflowState.steps.first(where: { $0.id == .claude })?.status, .completed(detail: "Installed"))
        }
    #endif
}
