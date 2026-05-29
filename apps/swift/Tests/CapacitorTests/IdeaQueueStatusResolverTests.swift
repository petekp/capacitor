@testable import Capacitor
import XCTest

final class IdeaQueueStatusResolverTests: XCTestCase {
    func testQueuedCountExcludesDoneIdeas() {
        let ideas = [
            makeIdea(status: "open"),
            makeIdea(status: "in-progress"),
            makeIdea(status: "done"),
        ]

        XCTAssertEqual(IdeaQueueMetrics.queuedCount(in: ideas), 2)
    }

    func testPrefersReviewReadyForMatchingDelegation() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: makeDelegation(status: "review_needed", currentReview: makeReview()),
            runState: makeRunState(status: "active", statusMessage: "Drafting packet"),
        )

        XCTAssertEqual(status, .reviewReady)
    }

    func testMapsWorkingDelegationForMatchingIdea() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: makeDelegation(status: "working", currentReview: nil),
            runState: nil,
        )

        XCTAssertEqual(status, .delegationWorking)
    }

    func testMapsResumePendingDelegationForMatchingIdea() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: makeDelegation(status: "resume_pending", currentReview: nil),
            runState: nil,
        )

        XCTAssertEqual(status, .delegationWorking)
    }

    func testMapsActiveRunForMatchingIdea() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: nil,
            runState: makeRunState(status: "active", statusMessage: "Drafting packet"),
        )

        XCTAssertEqual(status, .methodRunning(phaseName: "Drafting packet"))
    }

    func testMapsPausedRunWithCheckpointForMatchingIdea() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: nil,
            runState: makeRunState(
                status: "paused",
                activeCheckpoint: makeCheckpoint(),
            ),
        )

        XCTAssertEqual(status, .methodCheckpointReady)
    }

    func testIgnoresRunForDifferentIdea() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: nil,
            runState: makeRunState(ideaId: "other-idea", status: "active"),
        )

        XCTAssertNil(status)
    }

    func testFallsBackToGeneratingTitleWhenNoDelegationMatches() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: true,
            delegationState: makeDelegation(ideaId: "other-idea", status: "working", currentReview: nil),
            runState: makeRunState(ideaId: "other-idea", status: "active"),
        )

        XCTAssertEqual(status, .generatingTitle)
    }

    func testPrefersLiveDelegationStateOverGeneratingTitleFallback() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: true,
            delegationState: makeDelegation(status: "working", currentReview: nil),
            runState: makeRunState(status: "active", statusMessage: "Drafting packet"),
        )

        XCTAssertEqual(status, .delegationWorking)
    }

    func testMapsInProgressIdeaStatusWhenNoLiveProcessingExists() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(status: "in-progress"),
            isGeneratingTitle: false,
            delegationState: nil,
            runState: nil,
        )

        XCTAssertEqual(status, .inProgress)
    }

    func testReturnsNilForOpenIdeaWithoutProcessingSignals() {
        let status = IdeaQueueStatusResolver.resolve(
            idea: makeIdea(),
            isGeneratingTitle: false,
            delegationState: nil,
            runState: nil,
        )

        XCTAssertNil(status)
    }

    func testCompactRunIdeaDescriptionClampsLongValues() {
        let description = String(repeating: "a", count: 501)

        let compacted = compactRunIdeaDescription(description)

        XCTAssertEqual(compacted?.count, 500)
        XCTAssertEqual(compacted, String(repeating: "a", count: 497) + "...")
    }

    func testCompactRunIdeaDescriptionReturnsNilForMissingOrBlankValues() {
        XCTAssertNil(compactRunIdeaDescription(nil))
        XCTAssertNil(compactRunIdeaDescription(""))
        XCTAssertNil(compactRunIdeaDescription("   \n\t  "))
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
            status: try! DelegationStatus.decode(wire: status),
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

    private func makeRunState(
        ideaId: String? = "idea-1",
        status: String,
        statusMessage: String? = nil,
        activeCheckpoint: RuntimeCheckpointState? = nil,
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: "/tmp/core-project",
            methodId: "method-1",
            methodName: "Packet Builder",
            status: try! RunStatus.decode(wire: status),
            sessionId: "run-session-1",
            delegationWorkerId: nil,
            statusMessage: statusMessage,
            createdAt: "2026-03-16T18:37:02Z",
            updatedAt: "2026-03-16T18:41:41Z",
            activeCheckpoint: activeCheckpoint,
            ideaId: ideaId,
            ideaTitle: "Queue status work",
            ideaDescription: "Show live idea processing states",
        )
    }

    private func makeCheckpoint() -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: "checkpoint-1",
            phaseId: "phase-1",
            kind: .implementationMilestone,
            status: "active",
            title: "Checkpoint 1",
            summary: "Review the current checkpoint.",
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            createdAt: "2026-03-16T18:39:02Z",
            decidedAt: nil,
        )
    }
}
