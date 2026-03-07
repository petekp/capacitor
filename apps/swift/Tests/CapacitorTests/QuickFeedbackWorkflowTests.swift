@testable import Capacitor
import XCTest

@MainActor
final class QuickFeedbackWorkflowTests: XCTestCase {
    func testSubmitWritesSuccessToastAndEmitsSubmitResult() {
        var recordedToast: ToastMessage?
        var recordedTelemetryEvent: String?
        var recordedFunnelFeedbackID: String?
        let toastWritten = expectation(description: "toast written")
        let telemetryEmitted = expectation(description: "telemetry emitted")
        let funnelEmitted = expectation(description: "funnel emitted")

        let workflow = QuickFeedbackWorkflow(
            submitFeedback: { _, _, _, _ in
                QuickFeedbackSubmissionOutcome(
                    feedbackID: "feedback-1",
                    issueURL: URL(string: "https://example.com/issues/1")!,
                    issueOpened: true,
                    endpointAttempted: true,
                    endpointSucceeded: true,
                    endpointError: nil,
                )
            },
            contextProvider: { .empty },
            writeToast: {
                recordedToast = $0
                toastWritten.fulfill()
            },
            emitTelemetry: { event, _, _ in
                recordedTelemetryEvent = event
                telemetryEmitted.fulfill()
            },
            emitSubmitResult: { _, feedbackID, _, _, _, _, _, _ in
                recordedFunnelFeedbackID = feedbackID
                funnelEmitted.fulfill()
            },
        )

        workflow.submit(
            QuickFeedbackDraft.defaults,
            preferences: QuickFeedbackPreferences.defaults,
            formSessionID: "session-1",
            openGitHubIssue: true,
        )

        wait(for: [toastWritten, telemetryEmitted, funnelEmitted], timeout: 1.0)

        XCTAssertEqual(recordedToast?.message, "Opened GitHub issue and sent telemetry")
        XCTAssertEqual(recordedTelemetryEvent, "quick_feedback_submitted")
        XCTAssertEqual(recordedFunnelFeedbackID, "feedback-1")
    }

    func testSubmitWritesNoEndpointErrorForShareOnlyFailure() {
        var recordedToast: ToastMessage?
        let toastWritten = expectation(description: "toast written")

        let workflow = QuickFeedbackWorkflow(
            submitFeedback: { _, _, _, _ in
                QuickFeedbackSubmissionOutcome(
                    feedbackID: "feedback-2",
                    issueURL: URL(string: "https://example.com/issues/2")!,
                    issueOpened: false,
                    endpointAttempted: false,
                    endpointSucceeded: false,
                    endpointError: nil,
                )
            },
            contextProvider: { .empty },
            writeToast: {
                recordedToast = $0
                toastWritten.fulfill()
            },
        )

        workflow.submit(
            QuickFeedbackDraft.defaults,
            preferences: QuickFeedbackPreferences.defaults,
            formSessionID: String?.none,
            openGitHubIssue: false,
        )

        wait(for: [toastWritten], timeout: 1.0)

        XCTAssertEqual(recordedToast?.message, "Couldn’t share feedback (no endpoint configured)")
        XCTAssertTrue(recordedToast?.isError == true)
    }
}
