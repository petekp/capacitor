@testable import Capacitor
import XCTest

@MainActor
final class AppStateReceiptLoopRunStateTests: XCTestCase {
    func testRecordsReceiptLoopStartCompletionAndFailureForProject() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/receipt")
        let idea = makeIdea()

        let started = appState.recordReceiptLoopStarted(
            for: idea,
            project: project,
            runID: "receipt-run-1",
            at: "2027-01-15T08:00:00Z",
        )

        XCTAssertEqual(started.status, .running)
        XCTAssertEqual(appState.receiptLoopRun(for: project)?.status, .running)
        XCTAssertEqual(appState.receiptLoopRuntimeRun(for: project)?.status, "active")
        XCTAssertEqual(appState.activeRun(for: idea, in: project)?.id, "receipt-run-1")
        XCTAssertEqual(appState.activeRun(for: project)?.id, "receipt-run-1")

        appState.recordReceiptLoopCompleted(
            project: project,
            runID: "receipt-run-1",
            at: "2027-01-15T08:03:00Z",
        )

        XCTAssertEqual(appState.receiptLoopRun(for: project)?.status, .completed)
        XCTAssertEqual(appState.receiptLoopRun(for: project)?.updatedAt, "2027-01-15T08:03:00Z")
        XCTAssertEqual(appState.receiptLoopRuntimeRun(for: project)?.status, "completed")
        XCTAssertNil(appState.activeRun(for: idea, in: project))

        appState.recordReceiptLoopFailed(
            project: project,
            runID: "receipt-run-1",
            reason: "Claude receipt loop failed",
            at: "2027-01-15T08:04:00Z",
        )

        XCTAssertEqual(appState.receiptLoopRun(for: project)?.status, .failed)
        XCTAssertEqual(appState.receiptLoopRun(for: project)?.failureReason, "Claude receipt loop failed")
        XCTAssertEqual(appState.receiptLoopRuntimeRun(for: project)?.status, "failed")
    }

    func testOlderReceiptCompletionDoesNotOverwriteNewerVisibleRun() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/receipt")
        let idea = makeIdea()

        appState.recordReceiptLoopStarted(
            for: idea,
            project: project,
            runID: "receipt-run-old",
            at: "2027-01-15T08:00:00Z",
        )
        appState.recordReceiptLoopStarted(
            for: idea,
            project: project,
            runID: "receipt-run-new",
            at: "2027-01-15T08:01:00Z",
        )

        appState.recordReceiptLoopCompleted(
            project: project,
            runID: "receipt-run-old",
            at: "2027-01-15T08:02:00Z",
        )

        XCTAssertEqual(appState.receiptLoopRun(for: project)?.id, "receipt-run-new")
        XCTAssertEqual(appState.receiptLoopRun(for: project)?.status, .running)
    }

    func testBeginReceiptLoopRunRejectsSecondRunningLoopForProject() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let project = makeProject(path: "/tmp/receipt")
        let firstIdea = makeIdea(id: "idea-1")
        let secondIdea = makeIdea(id: "idea-2")

        let firstStart = appState.beginReceiptLoopRun(
            for: firstIdea,
            project: project,
            runID: "receipt-run-first",
            at: "2027-01-15T08:00:00Z",
        )
        let secondStart = appState.beginReceiptLoopRun(
            for: secondIdea,
            project: project,
            runID: "receipt-run-second",
            at: "2027-01-15T08:01:00Z",
        )

        XCTAssertTrue(firstStart.didStart)
        XCTAssertFalse(secondStart.didStart)
        XCTAssertEqual(secondStart.state.id, "receipt-run-first")
        XCTAssertEqual(appState.receiptLoopRun(for: project)?.id, "receipt-run-first")
        XCTAssertEqual(appState.receiptLoopRun(for: project)?.ideaId, "idea-1")
    }

    func testBeginReceiptLoopRunRejectsSecondRunningLoopAcrossProjects() {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        let firstProject = makeProject(path: "/tmp/receipt-a")
        let secondProject = makeProject(path: "/tmp/receipt-b")

        let firstStart = appState.beginReceiptLoopRun(
            for: makeIdea(id: "idea-1"),
            project: firstProject,
            runID: "receipt-run-first",
            at: "2027-01-15T08:00:00Z",
        )
        let secondStart = appState.beginReceiptLoopRun(
            for: makeIdea(id: "idea-2"),
            project: secondProject,
            runID: "receipt-run-second",
            at: "2027-01-15T08:01:00Z",
        )

        XCTAssertTrue(firstStart.didStart)
        XCTAssertFalse(secondStart.didStart)
        XCTAssertEqual(secondStart.state.id, "receipt-run-first")
        XCTAssertNil(appState.receiptLoopRun(for: secondProject))
    }

    func testRejectedReceiptGoalPacketRunPostsFailureNotification() async {
        let appState = AppState()
        appState.cancelRuntimeAutomationForTesting()
        appState.featureState.configure(with: AppConfig(
            channel: .dev,
            profile: .frontier,
            featureFlags: .defaults(for: .frontier),
        ))
        let firstProject = makeProject(path: "/tmp/receipt-a")
        let secondProject = makeProject(path: "/tmp/receipt-b")

        appState.recordReceiptLoopStarted(
            for: makeIdea(id: "idea-1"),
            project: firstProject,
            runID: "receipt-run-first",
            at: "2027-01-15T08:00:00Z",
        )

        let rejected = expectation(description: "receipt loop rejection posts failure notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .circuitFirstSliceDidFail,
            object: nil,
            queue: nil,
        ) { _ in
            rejected.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        appState.runMethodOnIdea(
            makeIdea(id: "idea-2"),
            method: CircuitReceiptGoalPacketMethod.template,
            for: secondProject,
        )

        await fulfillment(of: [rejected], timeout: 1.0)
        XCTAssertNil(appState.receiptLoopRun(for: secondProject))
    }

    private func makeProject(path: String) -> Project {
        Project(
            name: "Receipt",
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

    private func makeIdea(id: String = "idea-1") -> Idea {
        Idea(
            id: id,
            title: "Improve checkpoint evidence packets",
            description: "Success means: I can approve without reading the diff first.",
            added: "2027-01-15T07:58:00Z",
            effort: "small",
            status: "open",
            triage: "pending",
            related: nil,
        )
    }
}
