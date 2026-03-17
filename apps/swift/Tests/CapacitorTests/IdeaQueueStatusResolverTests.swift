@testable import Capacitor
import XCTest

final class IdeaQueueStatusResolverTests: XCTestCase {
    func testPrefersReviewReadyForMatchingDelegation() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: makeDelegation(status: "review_needed", currentReview: makeReview()),
        )

        XCTAssertEqual(status, .reviewReady)
    }

    func testMapsWorkingDelegationForMatchingIdea() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: makeDelegation(status: "working", currentReview: nil),
        )

        XCTAssertEqual(status, .delegationWorking)
    }

    func testFallsBackToGeneratingTitleWhenNoDelegationMatches() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: true,
            delegationState: makeDelegation(ideaId: "other-idea", status: "working", currentReview: nil),
        )

        XCTAssertEqual(status, .generatingTitle)
    }

    func testPrefersLiveDelegationStateOverGeneratingTitleFallback() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: true,
            delegationState: makeDelegation(status: "working", currentReview: nil),
        )

        XCTAssertEqual(status, .delegationWorking)
    }

    func testMapsInProgressIdeaStatusWhenNoLiveProcessingExists() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(status: "in-progress"),
            isGeneratingTitle: false,
            delegationState: nil,
        )

        XCTAssertEqual(status, .inProgress)
    }

    func testReturnsNilForOpenIdeaWithoutProcessingSignals() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: nil,
        )

        XCTAssertNil(status)
    }

    private func makeIdea(status: String = "open") -> Idea {
        Idea(
            id: "idea-1",
            title: "Queue status work",
            description: "Show live idea processing states",
            added: "2026-03-16T18:37:02Z",
            effort: "small",
            status: status,
            triage: "validated",
            related: nil,
        )
    }

    private func makeDelegation(
        ideaId: String? = "idea-1",
        status: String,
        currentReview: RuntimeDelegationReview?,
    ) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: "/tmp/core-project",
            workerId: "worker-1",
            ideaId: ideaId,
            worktreeName: "delegation-worker-1",
            worktreePath: "/tmp/core-project/.capacitor/worktrees/delegation-worker-1",
            sessionId: "worker-session-1",
            status: status,
            startedAt: "2026-03-16T18:37:02Z",
            updatedAt: "2026-03-16T18:41:41Z",
            currentReview: currentReview,
        )
    }

    private func makeReview() -> RuntimeDelegationReview {
        RuntimeDelegationReview(
            milestoneId: "01",
            briefPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/brief.md",
            manifestPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
            requestedAt: "2026-03-16T18:41:41Z",
        )
    }
}
