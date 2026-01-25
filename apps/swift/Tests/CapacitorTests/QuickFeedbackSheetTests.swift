import AppKit
@testable import Capacitor
import XCTest

final class QuickFeedbackSheetTests: XCTestCase {
    func testDraftCanSubmitRequiresNonEmptySummary() {
        let empty = QuickFeedbackDraft(
            category: .other,
            impact: .medium,
            reproducibility: .notApplicable,
            summary: "   \n\t  ",
            details: "",
            expectedBehavior: "",
            stepsToReproduce: "",
        )
        XCTAssertFalse(empty.canSubmit)

        let nonEmpty = QuickFeedbackDraft(
            category: .other,
            impact: .medium,
            reproducibility: .notApplicable,
            summary: "Found a bug in focus handling",
            details: "",
            expectedBehavior: "",
            stepsToReproduce: "",
        )
        XCTAssertTrue(nonEmpty.canSubmit)
    }

    func testQuickFeedbackTextViewTabAndBacktabUseKeyViewNavigation() {
        let textView = QuickFeedbackTextView()
        textView.string = "before"

        var nextInvoked = false
        var previousInvoked = false
        textView.onSelectNextKeyView = { nextInvoked = true }
        textView.onSelectPreviousKeyView = { previousInvoked = true }

        textView.insertTab(nil)
        XCTAssertTrue(nextInvoked)
        XCTAssertEqual(textView.string, "before")

        textView.insertBacktab(nil)
        XCTAssertTrue(previousInvoked)
        XCTAssertEqual(textView.string, "before")
    }
}
