@testable import Capacitor
import XCTest

final class RunCheckpointFollowThroughProjectionTests: XCTestCase {
    private let submittedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testApproveShowsAcceptedWhileSameCheckpointStillVisible() {
        let projection = RunCheckpointFollowThroughProjection.make(
            submission: submission(decision: .approve),
            run: run(
                status: "paused",
                statusMessage: "Waiting for decision",
                activeCheckpoint: checkpoint(id: "checkpoint-1"),
            ),
            now: submittedAt.addingTimeInterval(5),
        )

        XCTAssertEqual(projection.state, .decisionAccepted)
        XCTAssertEqual(projection.title, "Decision accepted")
        XCTAssertEqual(projection.message, "Waiting for the run to resume.")
        XCTAssertEqual(projection.recommendedAction, nil)
    }

    func testApproveShowsRunResumedWhenCheckpointClearsAndRunIsActive() {
        let projection = RunCheckpointFollowThroughProjection.make(
            submission: submission(decision: .approve),
            run: run(
                status: "active",
                statusMessage: "Implementing next phase",
                activeCheckpoint: nil,
            ),
            now: submittedAt.addingTimeInterval(2),
        )

        XCTAssertEqual(projection.state, .runResumed)
        XCTAssertEqual(projection.title, "Decision accepted. Run resumed.")
        XCTAssertEqual(projection.message, "Next expected signal: next checkpoint or completion.")
        XCTAssertEqual(projection.detail, "Implementing next phase")
    }

    func testRequestChangesShowsRevisionExpectedAfterCheckpointClears() {
        let projection = RunCheckpointFollowThroughProjection.make(
            submission: submission(decision: .requestChanges),
            run: run(
                status: "paused",
                statusMessage: nil,
                activeCheckpoint: nil,
            ),
            now: submittedAt.addingTimeInterval(2),
        )

        XCTAssertEqual(projection.state, .revisionExpected)
        XCTAssertEqual(projection.title, "Feedback delivered. Worker is revising.")
        XCTAssertEqual(projection.message, "Next expected signal: revision checkpoint addressing your note.")
    }

    func testSameCheckpointStillVisibleAfterDelayLooksSuspicious() {
        let projection = RunCheckpointFollowThroughProjection.make(
            submission: submission(decision: .approve),
            run: run(
                status: "paused",
                statusMessage: "Waiting for decision",
                activeCheckpoint: checkpoint(id: "checkpoint-1"),
            ),
            now: submittedAt.addingTimeInterval(31),
        )

        XCTAssertEqual(projection.state, .resumeSuspicious)
        XCTAssertEqual(projection.title, "Decision accepted, but the worker did not resume.")
        XCTAssertEqual(projection.recommendedAction, "Inspect terminal")
    }

    func testRunFailureAfterDecisionShowsResumeFailed() {
        let projection = RunCheckpointFollowThroughProjection.make(
            submission: submission(decision: .approve),
            run: run(
                status: "failed",
                statusMessage: "Resume failed",
                activeCheckpoint: nil,
            ),
            now: submittedAt.addingTimeInterval(3),
        )

        XCTAssertEqual(projection.state, .resumeFailed)
        XCTAssertEqual(projection.title, "Decision accepted, but the run failed.")
        XCTAssertEqual(projection.message, "Resume failed")
        XCTAssertEqual(projection.recommendedAction, "Inspect terminal")
    }

    private func submission(decision: RunCheckpointDecision) -> RunCheckpointFollowThroughSubmission {
        RunCheckpointFollowThroughSubmission(
            target: RunCheckpointWindowTarget(
                projectPath: "/tmp/project",
                runID: "run-1",
                checkpointID: "checkpoint-1",
            ),
            decision: decision,
            submittedAt: submittedAt,
        )
    }

    private func run(
        status: String,
        statusMessage: String?,
        activeCheckpoint: RuntimeCheckpointState?,
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: "/tmp/project",
            methodId: "method",
            methodName: "Method",
            status: status,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: statusMessage,
            createdAt: "2026-05-24T15:00:00Z",
            updatedAt: "2026-05-24T15:05:00Z",
            activeCheckpoint: activeCheckpoint,
            ideaId: "idea-1",
            ideaTitle: "Improve checkpoint follow-through",
            ideaDescription: nil,
        )
    }

    private func checkpoint(id: String) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            phaseId: "phase",
            kind: .implementationMilestone,
            status: "pending",
            title: "Checkpoint ready",
            summary: "Needs direction",
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            createdAt: "2026-05-24T15:01:00Z",
            decidedAt: nil,
        )
    }
}
