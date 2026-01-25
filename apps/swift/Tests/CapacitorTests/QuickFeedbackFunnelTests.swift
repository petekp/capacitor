@testable import Capacitor
import XCTest

final class QuickFeedbackFunnelTests: XCTestCase {
    func testFieldCompletedPayloadIncludesSessionAndField() {
        let payload = QuickFeedbackFunnelPayloadBuilder.fieldCompleted(
            sessionID: "qf-session-1",
            field: "summary",
            draft: makeDraft(),
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
            completionCount: 1,
        )

        XCTAssertEqual(payload["form_session_id"] as? String, "qf-session-1")
        XCTAssertEqual(payload["field"] as? String, "summary")
        XCTAssertEqual(payload["completion_count"] as? Int, 1)
        XCTAssertEqual(payload["category"] as? String, "bug")
        XCTAssertEqual(payload["impact"] as? String, "high")
        XCTAssertEqual(payload["telemetry_enabled"] as? Bool, true)
    }

    func testSubmitResultPayloadIncludesFeedbackIDAndOutcome() {
        let payload = QuickFeedbackFunnelPayloadBuilder.submitResult(
            sessionID: "qf-session-2",
            feedbackID: "fb-abc",
            draft: makeDraft(),
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
            issueRequested: false,
            issueOpened: true,
            endpointAttempted: true,
            endpointSucceeded: false,
        )

        XCTAssertEqual(payload["form_session_id"] as? String, "qf-session-2")
        XCTAssertEqual(payload["feedback_id"] as? String, "fb-abc")
        XCTAssertEqual(payload["issue_requested"] as? Bool, false)
        XCTAssertEqual(payload["issue_opened"] as? Bool, true)
        XCTAssertEqual(payload["endpoint_attempted"] as? Bool, true)
        XCTAssertEqual(payload["endpoint_succeeded"] as? Bool, false)
        XCTAssertEqual(payload["reproducibility"] as? String, "often")
    }

    func testAbandonedPayloadIncludesCompletionAndSummaryLength() {
        let payload = QuickFeedbackFunnelPayloadBuilder.abandoned(
            sessionID: "qf-session-3",
            draft: makeDraft(),
            preferences: QuickFeedbackPreferences(includeTelemetry: false, includeProjectPaths: false),
            completionCount: 2,
        )

        XCTAssertEqual(payload["form_session_id"] as? String, "qf-session-3")
        XCTAssertEqual(payload["completion_count"] as? Int, 2)
        XCTAssertEqual(payload["summary_length"] as? Int, 39)
        XCTAssertEqual(payload["telemetry_enabled"] as? Bool, false)
    }

    private func makeDraft() -> QuickFeedbackDraft {
        QuickFeedbackDraft(
            category: .bug,
            impact: .high,
            reproducibility: .often,
            summary: "App gets stuck after switching projects",
            details: "Spinner stays visible after project switch.",
            expectedBehavior: "",
            stepsToReproduce: "",
        )
    }
}
