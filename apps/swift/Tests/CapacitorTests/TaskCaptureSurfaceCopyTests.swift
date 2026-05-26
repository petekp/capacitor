@testable import Capacitor
import XCTest

final class TaskCaptureSurfaceCopyTests: XCTestCase {
    func testCaptureSurfaceUsesTaskLanguage() {
        XCTAssertEqual(TaskCaptureSurfaceCopy.cardActionTitle, "Task")
        XCTAssertEqual(TaskCaptureSurfaceCopy.cardActionAccessibilityLabel, "Add task to this project")
        XCTAssertEqual(TaskCaptureSurfaceCopy.cardActionHelp, "Add task")
        XCTAssertEqual(TaskCaptureSurfaceCopy.submitTitle, "Add Task")
        XCTAssertEqual(TaskCaptureSurfaceCopy.emptyQueueTitle, "No tasks queued")
    }

    func testCaptureSurfaceDoesNotUseIdeaLanguageInVisibleCopy() {
        for value in TaskCaptureSurfaceCopy.userFacingStrings {
            XCTAssertFalse(
                value.localizedCaseInsensitiveContains("idea"),
                "Visible capture copy should say Task, not Idea: \(value)",
            )
        }
    }
}
