@testable import Capacitor
import Foundation
import XCTest

final class QuickFeedbackSubmitterTests: XCTestCase {
    func testDraftNormalizationTrimsInputAndRequiresNonEmptySummary() {
        let draft = QuickFeedbackDraft(
            category: .bug,
            impact: .high,
            reproducibility: .often,
            summary: "   App stalls after opening project   ",
            details: "   Spinner never resolves.   ",
            expectedBehavior: "   Project should load in under 2s.   ",
            stepsToReproduce: "   1. Open app\n2. Select project   ",
        )

        XCTAssertTrue(draft.canSubmit)
        XCTAssertEqual(draft.normalized().summary, "App stalls after opening project")
        XCTAssertEqual(draft.normalized().details, "Spinner never resolves.")
        XCTAssertEqual(draft.normalized().expectedBehavior, "Project should load in under 2s.")
        XCTAssertEqual(draft.normalized().stepsToReproduce, "1. Open app\n2. Select project")

        let empty = QuickFeedbackDraft(
            category: .other,
            impact: .medium,
            reproducibility: .notApplicable,
            summary: "   ",
            details: "",
            expectedBehavior: "",
            stepsToReproduce: "",
        )
        XCTAssertFalse(empty.canSubmit)
    }

    func testBuildPayloadIncludesFormSnapshotAndRedactsPathsByDefault() {
        let projectPath = "/Users/pete/Code/capacitor"
        let context = makeContext(projectPath: projectPath)
        let draft = makeDraft()

        let payload = QuickFeedbackPayloadBuilder.build(
            feedbackID: "fb-test-001",
            draft: draft,
            context: context,
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
            now: fixedDate,
        )

        XCTAssertEqual(payload.feedbackID, "fb-test-001")
        XCTAssertEqual(payload.app.channel, "alpha")
        XCTAssertEqual(payload.projectContext.sessionSummary.working, 1)
        XCTAssertEqual(payload.projectContext.sessionSummary.ready, 1)
        XCTAssertEqual(payload.projectContext.sessionSummary.withAttachedSession, 2)
        XCTAssertEqual(payload.form.category, "bug")
        XCTAssertEqual(payload.form.impact, "high")
        XCTAssertEqual(payload.form.reproducibility, "often")
        XCTAssertEqual(payload.form.summary, "App gets stuck after switching projects")
        XCTAssertEqual(payload.form.expectedBehavior, "Project switch should resolve in under 2 seconds")

        let activeProject = try? XCTUnwrap(payload.projectContext.activeProjectPath)
        XCTAssertNotNil(activeProject)
        XCTAssertFalse(activeProject?.contains("/Users/") == true)

        XCTAssertTrue(
            payload.projectContext.projects.contains(where: { snapshot in
                snapshot.path.contains("#") && !snapshot.path.contains("/Users/")
            }),
        )
        XCTAssertTrue(payload.activationSignal.hasTrace)
        XCTAssertNotNil(payload.activationSignal.traceDigest)
    }

    func testBuildPayloadIncludesProjectPathsWhenOptedIn() throws {
        let projectPath = "/Users/pete/Code/capacitor"
        let context = makeContext(projectPath: projectPath)
        let draft = makeDraft()

        let payload = QuickFeedbackPayloadBuilder.build(
            feedbackID: "fb-test-002",
            draft: draft,
            context: context,
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: true),
            now: fixedDate,
        )

        XCTAssertEqual(payload.projectContext.activeProjectPath, projectPath)
        let tracked = try XCTUnwrap(payload.projectContext.projects.first(where: { $0.path == projectPath }))
        XCTAssertEqual(tracked.path, projectPath)
        XCTAssertEqual(payload.privacy.includeProjectPaths, true)
    }

    func testSubmitSendsEndpointPayloadAndOpensGitHubIssue() async throws {
        var capturedRequest: URLRequest?
        var openedURL: URL?

        let submitter = QuickFeedbackSubmitter(
            environment: [
                "CAPACITOR_FEEDBACK_API_URL": "https://feedback.example.com/intake",
                "CAPACITOR_INGEST_KEY": "ingest-secret",
            ],
            openURL: { url in
                openedURL = url
                return true
            },
            sendRequest: { request in
                capturedRequest = request
            },
            now: { self.fixedDate },
            feedbackIDProvider: { "fb-test-123" },
        )

        let outcome = await submitter.submit(
            draft: makeDraft(),
            context: makeContext(projectPath: "/Users/pete/Code/capacitor"),
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
        )

        XCTAssertTrue(outcome.endpointAttempted)
        XCTAssertTrue(outcome.endpointSucceeded)
        XCTAssertTrue(outcome.issueOpened)
        XCTAssertEqual(outcome.feedbackID, "fb-test-123")
        XCTAssertNil(outcome.endpointError)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://feedback.example.com/intake")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ingest-secret")

        let bodyData = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["feedback_id"] as? String, "fb-test-123")
        XCTAssertNil(json["feedback"])

        let form = try XCTUnwrap(json["form"] as? [String: Any])
        XCTAssertEqual(form["category"] as? String, "bug")
        XCTAssertEqual(form["impact"] as? String, "high")
        XCTAssertEqual(form["reproducibility"] as? String, "often")
        XCTAssertEqual(form["summary"] as? String, "App gets stuck after switching projects")

        let issueURL = try XCTUnwrap(openedURL)
        XCTAssertEqual(issueURL.host, "github.com")
        let queryItems = URLComponents(url: issueURL, resolvingAgainstBaseURL: false)?.queryItems
        let title = queryItems?.first(where: { $0.name == "title" })?.value
        let body = queryItems?.first(where: { $0.name == "body" })?.value
        XCTAssertNotNil(title)
        XCTAssertTrue(title?.contains("[fb-test-123]") == true)
        XCTAssertNotNil(body)
        XCTAssertTrue(body?.contains("Feedback ID: fb-test-123") == true)
        XCTAssertTrue(body?.contains("## Summary") == true)
        XCTAssertTrue(body?.contains("Telemetry Context") == true)
    }

    func testSubmitSkipsEndpointWhenTelemetryDisabled() async throws {
        var sentRequest = false
        var openedURL: URL?

        let submitter = QuickFeedbackSubmitter(
            environment: [
                "CAPACITOR_FEEDBACK_API_URL": "https://feedback.example.com/intake",
            ],
            openURL: { url in
                openedURL = url
                return true
            },
            sendRequest: { _ in
                sentRequest = true
            },
            now: { self.fixedDate },
            feedbackIDProvider: { "fb-test-456" },
        )

        let outcome = await submitter.submit(
            draft: makeDraft(category: .ux),
            context: makeContext(projectPath: "/Users/pete/Code/capacitor"),
            preferences: QuickFeedbackPreferences(includeTelemetry: false, includeProjectPaths: false),
        )

        XCTAssertFalse(sentRequest)
        XCTAssertFalse(outcome.endpointAttempted)
        XCTAssertTrue(outcome.issueOpened)

        let issueURL = try XCTUnwrap(openedURL)
        let queryItems = URLComponents(url: issueURL, resolvingAgainstBaseURL: false)?.queryItems
        let body = queryItems?.first(where: { $0.name == "body" })?.value
        XCTAssertNotNil(body)
        XCTAssertTrue(body?.contains("Feedback ID: fb-test-456") == true)
        XCTAssertTrue(body?.contains("Telemetry sharing is disabled") == true)
    }

    func testSubmitOpensIssueEvenWhenEndpointFails() async {
        var openedURL: URL?

        let submitter = QuickFeedbackSubmitter(
            environment: [
                "CAPACITOR_FEEDBACK_API_URL": "https://feedback.example.com/intake",
            ],
            openURL: { url in
                openedURL = url
                return true
            },
            sendRequest: { _ in
                throw URLError(.cannotConnectToHost)
            },
            now: { self.fixedDate },
            feedbackIDProvider: { "fb-test-789" },
        )

        let outcome = await submitter.submit(
            draft: makeDraft(),
            context: makeContext(projectPath: "/Users/pete/Code/capacitor"),
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
        )

        XCTAssertTrue(outcome.endpointAttempted)
        XCTAssertFalse(outcome.endpointSucceeded)
        XCTAssertNotNil(outcome.endpointError)
        XCTAssertTrue(outcome.issueOpened)
        XCTAssertNotNil(openedURL)
    }

    func testSubmitSkipsOpeningGitHubIssueWhenDisabled() async {
        var openedURL: URL?

        let submitter = QuickFeedbackSubmitter(
            environment: [
                "CAPACITOR_FEEDBACK_API_URL": "https://feedback.example.com/intake",
            ],
            openURL: { url in
                openedURL = url
                return true
            },
            sendRequest: { _ in },
            now: { self.fixedDate },
            feedbackIDProvider: { "fb-test-no-issue" },
        )

        let outcome = await submitter.submit(
            draft: makeDraft(),
            context: makeContext(projectPath: "/Users/pete/Code/capacitor"),
            preferences: QuickFeedbackPreferences(includeTelemetry: true, includeProjectPaths: false),
            openGitHubIssue: false,
        )

        XCTAssertFalse(outcome.issueOpened)
        XCTAssertTrue(outcome.endpointAttempted)
        XCTAssertTrue(outcome.endpointSucceeded)
        XCTAssertNil(openedURL)
    }

    private func makeContext(projectPath: String) -> QuickFeedbackContext {
        let otherPath = "/Users/pete/Code/website"
        return QuickFeedbackContext(
            appVersion: "0.2.0-alpha.1",
            buildNumber: "42",
            channel: .alpha,
            osVersion: "macOS 14.6",
            runtimeStatus: RuntimeStatus(
                isEnabled: true,
                isHealthy: true,
                message: "ok",
                pid: 4172,
                version: "0.2.0",
            ),
            activeProjectPath: projectPath,
            activeSource: "claude(session-123)",
            projectCount: 2,
            sessionStates: [
                projectPath: ProjectSessionState(
                    state: .working,
                    stateChangedAt: "2026-02-13T12:00:00Z",
                    updatedAt: "2026-02-13T12:00:00Z",
                    sessionId: "session-123",
                    workingOn: nil,
                    context: nil,
                    thinking: true,
                    hasSession: true,
                ),
                otherPath: ProjectSessionState(
                    state: .ready,
                    stateChangedAt: "2026-02-13T11:58:00Z",
                    updatedAt: "2026-02-13T11:58:00Z",
                    sessionId: "session-456",
                    workingOn: nil,
                    context: nil,
                    thinking: nil,
                    hasSession: true,
                ),
            ],
            activationTrace: "Ghostty activation succeeded for /Users/pete/Code/capacitor",
        )
    }

    private func makeDraft(category: QuickFeedbackCategory = .bug) -> QuickFeedbackDraft {
        QuickFeedbackDraft(
            category: category,
            impact: .high,
            reproducibility: .often,
            summary: "App gets stuck after switching projects",
            details: "When I switch projects from the dock, the ready spinner never clears.",
            expectedBehavior: "Project switch should resolve in under 2 seconds",
            stepsToReproduce: "1. Open app\n2. Switch projects from dock\n3. Observe spinner",
        )
    }

    private var fixedDate: Date {
        Date(timeIntervalSince1970: 1_708_000_000)
    }
}
