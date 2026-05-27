@testable import Capacitor
import XCTest

final class StatusChipsRowTests: XCTestCase {
    func testRunPresentationWinsOverDelegationReviewWhenRunIsActive() {
        let presentation = StatusChipsRow.presentation(
            sessionState: makeSessionState(.ready),
            delegationState: makeDelegation(status: "review_needed", currentReview: makeReview()),
            activeRunState: makeRun(status: "active", checkpointID: nil),
        )

        XCTAssertEqual(presentation, .session(.working))
    }

    func testPausedRunWithCheckpointSurfacesCheckpointPresentation() {
        let presentation = StatusChipsRow.presentation(
            sessionState: makeSessionState(.working),
            delegationState: nil,
            activeRunState: makeRun(status: "paused", checkpointID: "checkpoint-1"),
        )

        XCTAssertEqual(presentation, .session(.waiting))
    }

    func testCreatedRunFallsBackToDelegationReviewUntilStartLands() {
        let presentation = StatusChipsRow.presentation(
            sessionState: makeSessionState(.ready),
            delegationState: makeDelegation(status: "review_needed", currentReview: makeReview()),
            activeRunState: makeRun(status: "created", checkpointID: nil),
        )

        XCTAssertEqual(presentation, .delegationReview)
    }

    func testDelegationReviewFallsBackWhenNoRunExists() {
        let presentation = StatusChipsRow.presentation(
            sessionState: makeSessionState(.ready),
            delegationState: makeDelegation(status: "review_needed", currentReview: makeReview()),
            activeRunState: nil,
        )

        XCTAssertEqual(presentation, .delegationReview)
    }

    func testSessionStateUsedWhenNoRunOrDelegationSignalExists() {
        let presentation = StatusChipsRow.presentation(
            sessionState: makeSessionState(.waiting),
            delegationState: nil,
            activeRunState: nil,
        )

        XCTAssertEqual(presentation, .session(.waiting))
    }

    func testWorkBatchStateWinsOverIdleLegacySession() {
        let presentation = StatusChipsRow.presentation(
            sessionState: makeSessionState(.idle),
            delegationState: nil,
            activeRunState: nil,
            workBatchState: .waiting,
        )

        XCTAssertEqual(presentation, .session(.waiting))
    }

    func testActiveRunWinsOverWorkBatchState() {
        let presentation = StatusChipsRow.presentation(
            sessionState: makeSessionState(.idle),
            delegationState: nil,
            activeRunState: makeRun(status: "active", checkpointID: nil),
            workBatchState: .waiting,
        )

        XCTAssertEqual(presentation, .session(.working))
    }

    private func makeSessionState(_ state: SessionState) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: nil,
            updatedAt: nil,
            sessionId: nil,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: state != .idle,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
        )
    }

    private func makeDelegation(
        status: String,
        currentReview: RuntimeDelegationReview?,
    ) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: "/tmp/core-project",
            workerId: "worker-1",
            ideaId: "idea-1",
            worktreeName: "delegation-worker-1",
            worktreePath: "/tmp/core-project/.capacitor/worktrees/delegation-worker-1",
            sessionId: "worker-session-1",
            status: status,
            startedAt: "2026-03-25T10:00:00Z",
            updatedAt: "2026-03-25T10:05:00Z",
            currentReview: currentReview,
        )
    }

    private func makeReview() -> RuntimeDelegationReview {
        RuntimeDelegationReview(
            milestoneId: "01",
            briefPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/brief.md",
            manifestPath: "/tmp/core-project/.capacitor/delegations/worker-1/milestones/01/manifest.json",
            requestedAt: "2026-03-25T10:05:00Z",
        )
    }

    private func makeRun(status: String, checkpointID: String?) -> RuntimeRunState {
        let timestamp = currentISO8601Timestamp()
        let checkpoint: RuntimeCheckpointState? = if let checkpointID {
            RuntimeCheckpointState(
                id: checkpointID,
                phaseId: "phase-\(checkpointID)",
                kind: .implementationMilestone,
                status: "active",
                title: "Checkpoint \(checkpointID)",
                summary: "Review the current milestone.",
                briefPath: nil,
                manifestPath: nil,
                mediaArtifacts: [],
                mermaidSources: [],
                captureStatus: .notRequested,
                captureUrl: nil,
                captureClaim: nil,
                createdAt: timestamp,
                decidedAt: nil,
            )
        } else {
            nil
        }

        return RuntimeRunState(
            id: "run-1",
            projectPath: "/tmp/core-project",
            methodId: "execution_only",
            methodName: "Execute",
            status: status,
            sessionId: "run-session-1",
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: timestamp,
            updatedAt: timestamp,
            activeCheckpoint: checkpoint,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }
}
