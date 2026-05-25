@testable import Capacitor
import XCTest

final class ProjectCardContextLineResolverTests: XCTestCase {
    // MARK: - Priority 1: Run Context Text

    func testActiveRunStatusMessageWins() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .working(statusMessage: "Generating plan"),
            activeRunState: nil,
            delegationState: makeDelegation(status: "active"),
            projectStatus: makeStatus(workingOn: "Refactoring auth module"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Generating plan")
    }

    func testCompletedRunShowsFinalReviewCopy() {
        let run = makeRun(methodName: "Shape & Execute", status: "completed")
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .completed(statusMessage: nil),
            activeRunState: run,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "Some task"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Ready for final review: Shape & Execute")
    }

    func testFailedRunFallsBackToDefaultMessage() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .failed(statusMessage: nil),
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "Some task"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Run failed")
    }

    // MARK: - Priority 2: Delegation Context Text

    func testDelegationWithWorkingOnShowsWorkingOn() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: makeDelegation(status: "active"),
            projectStatus: makeStatus(workingOn: "Implementing auth flow"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Implementing auth flow")
    }

    func testDelegationWithReviewNeededShowsMilestoneMessage() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: makeDelegation(
                status: "review_needed",
                submittedMilestoneId: "M1",
            ),
            projectStatus: nil,
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Milestone M1 awaiting review")
    }

    func testDelegationWithoutWorkingOnShowsFallbackStatus() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: makeDelegation(status: "active"),
            projectStatus: nil,
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Delegation in progress")
    }

    // MARK: - Priority 3: Session Description (the new seam)

    func testStandaloneSessionShowsWorkingOn() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "Refactoring the auth module"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Refactoring the auth module")
    }

    func testWorkBatchSummaryWinsOverLegacySessionSummary() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "Fixed footer responsive breakpoint bug"),
            workBatchSummary: "Claude Code is starting on add a green border around the mobile prototype.",
            sessionSummary: "Fixed footer responsive breakpoint bug",
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Claude Code is starting on add a green border around the mobile prototype.")
    }

    func testStandaloneSessionTrimsWhitespace() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "  Cleaning up tests  \n"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Cleaning up tests")
    }

    func testStandaloneSessionWithEmptyWorkingOnReturnsNil() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "   "),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertNil(result)
    }

    func testStandaloneSessionWithNilWorkingOnReturnsNil() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: nil),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertNil(result)
    }

    func testStandaloneSessionWithNilProjectStatusReturnsNil() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: nil,
            projectStatus: nil,
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertNil(result)
    }

    // MARK: - Precedence / Guard Rails

    func testRunContextBlocksSessionDescription() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .working(statusMessage: "Building step 2/4"),
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "Refactoring auth"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Building step 2/4", "Run context must win over session description")
    }

    func testDelegationBlocksSessionDescription() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: makeDelegation(status: "resume_pending"),
            projectStatus: makeStatus(workingOn: "Refactoring auth"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        // Delegation has workingOn available, so it should show that (via delegation path)
        XCTAssertEqual(result, "Refactoring auth")
    }

    func testDelegationWithoutWorkingOnBlocksSessionDescriptionFallback() {
        // Even with no workingOn, delegation's own status messages should show
        // and session description should NOT activate (delegation is present)
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .none,
            activeRunState: nil,
            delegationState: makeDelegation(status: "resume_pending"),
            projectStatus: nil,
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Delegation is resuming")
    }

    func testNonNoneRunVisualStateBlocksLowerPrioritySources() {
        // A completed/failed run should still block delegation and session description
        // even though its sessionState is nil — the visual state is not .none
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .completed(statusMessage: "3/3 Review"),
            activeRunState: nil,
            delegationState: makeDelegation(status: "active"),
            projectStatus: makeStatus(workingOn: "Should not appear"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "3/3 Review")
    }

    // MARK: - Fallthrough: Run with no text yields to session summary

    func testWorkingRunWithNilStatusFallsToSessionSummary() {
        var inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .working(statusMessage: nil),
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "Refactoring auth"),
        )
        inputs.sessionSummary = "Updating unit tests for auth module"

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Updating unit tests for auth module",
                       "Session summary should show when run has no displayable text")
    }

    func testWaitingRunWithNilStatusFallsToSessionSummary() {
        var inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .waiting(statusMessage: nil),
            activeRunState: nil,
            delegationState: nil,
            projectStatus: nil,
        )
        inputs.sessionSummary = "Waiting for review feedback"

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Waiting for review feedback",
                       "Session summary should show when waiting run has no displayable text")
    }

    func testWorkingRunWithNilStatusAndNilSummaryFallsToWorkingOn() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .working(statusMessage: nil),
            activeRunState: nil,
            delegationState: nil,
            projectStatus: makeStatus(workingOn: "Refactoring auth module"),
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Refactoring auth module",
                       "workingOn from hud-status.json should serve as final fallback")
    }

    func testWorkingRunWithNilStatusAndNilSummaryAndNilWorkingOnReturnsNil() {
        let inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .working(statusMessage: nil),
            activeRunState: nil,
            delegationState: nil,
            projectStatus: nil,
        )

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertNil(result, "Nil when all sources are exhausted")
    }

    func testWorkingRunWithNilStatusFallsToDelegationBeforeSummary() {
        var inputs = ProjectCardContextLineResolver.Inputs(
            runVisualState: .working(statusMessage: nil),
            activeRunState: nil,
            delegationState: makeDelegation(status: "active"),
            projectStatus: makeStatus(workingOn: "Implementing auth flow"),
        )
        inputs.sessionSummary = "Should not appear"

        let result = ProjectCardContextLineResolver.resolve(inputs)

        XCTAssertEqual(result, "Implementing auth flow",
                       "Delegation text should win over session summary even during active run fallthrough")
    }

    // MARK: - Dock isolation proof

    func testDockPathDoesNotUseContextLineResolver() {
        // Dock cards use DockProjectCardPresentation.resolve(), which only reads
        // trackedRunVisualState.statusMessage — it never calls this resolver.
        // This test documents the boundary: even with a session summary available,
        // the dock presentation returns nil contextLine when the run has no text.
        let dockPresentation = DockProjectCardPresentation.resolve(
            sessionState: nil,
            trackedRunVisualState: .working(statusMessage: nil),
        )
        XCTAssertNil(dockPresentation.contextLine,
                     "Dock path must not show session summaries — it uses its own resolver")
    }

    // MARK: - Helpers

    private func makeDelegation(
        status: String,
        submittedMilestoneId: String? = nil,
        currentReview: RuntimeDelegationReview? = nil,
    ) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: "/tmp/test-project",
            workerId: "worker-1",
            ideaId: nil,
            worktreeName: "wt-1",
            worktreePath: "/tmp/test-project/.worktrees/wt-1",
            sessionId: "session-1",
            status: status,
            startedAt: "2026-03-29T10:00:00Z",
            updatedAt: "2026-03-29T10:05:00Z",
            submittedMilestoneId: submittedMilestoneId,
            currentReview: currentReview,
        )
    }

    private func makeRun(
        methodName: String = "Execute",
        status: String = "active",
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: "/tmp/test-project",
            methodId: "execution_only",
            methodName: methodName,
            status: status,
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: "2026-03-29T10:00:00Z",
            updatedAt: "2026-03-29T10:05:00Z",
            activeCheckpoint: nil,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    private func makeStatus(workingOn: String?) -> ProjectStatus {
        ProjectStatus(
            workingOn: workingOn,
            nextStep: nil,
            status: nil,
            blocker: nil,
            updatedAt: nil,
        )
    }
}
