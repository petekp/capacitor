@testable import Capacitor
import XCTest

final class RunCheckpointRevisionContinuityProjectionTests: XCTestCase {
    func testBuildsContinuityFromLatestRequestChangesDecisionInSamePhase() throws {
        let prior = makeCheckpoint(
            id: "checkpoint-1",
            historyOrdinal: 1,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "Make the packet less code-centric.",
            decidedAt: "2026-05-24T15:10:00Z",
        )
        let active = makeCheckpoint(
            id: "checkpoint-2",
            historyOrdinal: 2,
            phaseID: "implementation",
            title: "Revision checkpoint",
            summary: "Reworked the brief around intent, outcome, risk, and ask.",
        )
        let run = makeRun(activeCheckpoint: active, pastCheckpoints: [prior])

        let continuity = try XCTUnwrap(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))

        XCTAssertEqual(continuity.priorCheckpointID, "checkpoint-1")
        XCTAssertEqual(continuity.priorDecisionAt, "2026-05-24T15:10:00Z")
        XCTAssertEqual(continuity.youAsked, "Make the packet less code-centric.")
        XCTAssertEqual(continuity.agentResponse, "Reworked the brief around intent, outcome, risk, and ask.")
        XCTAssertEqual(continuity.evidence, ["Updated checkpoint review projection."])
        XCTAssertEqual(continuity.remainingRisks, ["Needs UI validation."])
    }

    func testBuildsContinuityFromLegacyRejectedDecisionInSamePhase() throws {
        let prior = makeCheckpoint(
            id: "checkpoint-1",
            historyOrdinal: 1,
            phaseID: "implementation",
            decisionAction: "rejected",
            decisionNote: "Show how the revision responds to my note.",
            decidedAt: "2026-05-24T15:10:00Z",
        )
        let active = makeCheckpoint(
            id: "checkpoint-2",
            historyOrdinal: 2,
            phaseID: "implementation",
            summary: "Connected the revision to the prior decision.",
        )
        let run = makeRun(activeCheckpoint: active, pastCheckpoints: [prior])

        let continuity = try XCTUnwrap(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))

        XCTAssertEqual(continuity.priorCheckpointID, "checkpoint-1")
        XCTAssertEqual(continuity.youAsked, "Show how the revision responds to my note.")
        XCTAssertEqual(continuity.agentResponse, "Connected the revision to the prior decision.")
    }

    func testDoesNotShowContinuityWhenLatestSamePhaseDecisionWasApprove() {
        let earlierRequest = makeCheckpoint(
            id: "checkpoint-1",
            historyOrdinal: 1,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "Tighten evidence.",
        )
        let laterApproval = makeCheckpoint(
            id: "checkpoint-2",
            historyOrdinal: 2,
            phaseID: "implementation",
            decisionAction: "approve",
            decisionNote: nil,
        )
        let active = makeCheckpoint(
            id: "checkpoint-3",
            historyOrdinal: 3,
            phaseID: "implementation",
        )
        let run = makeRun(activeCheckpoint: active, pastCheckpoints: [earlierRequest, laterApproval])

        XCTAssertNil(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))
    }

    func testDoesNotShowContinuityForDifferentPhaseRequest() {
        let prior = makeCheckpoint(
            id: "checkpoint-1",
            historyOrdinal: 1,
            phaseID: "design",
            decisionAction: "request_changes",
            decisionNote: "Revise the design.",
        )
        let active = makeCheckpoint(
            id: "checkpoint-2",
            historyOrdinal: 2,
            phaseID: "implementation",
        )
        let run = makeRun(activeCheckpoint: active, pastCheckpoints: [prior])

        XCTAssertNil(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))
    }

    func testDoesNotShowContinuityForBlankRequestNote() {
        let prior = makeCheckpoint(
            id: "checkpoint-1",
            historyOrdinal: 1,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "   ",
        )
        let active = makeCheckpoint(
            id: "checkpoint-2",
            historyOrdinal: 2,
            phaseID: "implementation",
        )
        let run = makeRun(activeCheckpoint: active, pastCheckpoints: [prior])

        XCTAssertNil(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))
    }

    func testHistoryOrdinalChoosesLatestPriorDecisionBeforeActiveCheckpoint() throws {
        let newerTimestampButEarlierOrdinal = makeCheckpoint(
            id: "checkpoint-1",
            historyOrdinal: 1,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "First ask.",
            decidedAt: "2026-05-24T15:30:00Z",
        )
        let laterOrdinal = makeCheckpoint(
            id: "checkpoint-2",
            historyOrdinal: 2,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "Second ask.",
            decidedAt: "2026-05-24T15:20:00Z",
        )
        let active = makeCheckpoint(
            id: "checkpoint-3",
            historyOrdinal: 3,
            phaseID: "implementation",
        )
        let run = makeRun(
            activeCheckpoint: active,
            pastCheckpoints: [newerTimestampButEarlierOrdinal, laterOrdinal],
        )

        let continuity = try XCTUnwrap(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))

        XCTAssertEqual(continuity.priorCheckpointID, "checkpoint-2")
        XCTAssertEqual(continuity.youAsked, "Second ask.")
    }

    func testSkipsPastCheckpointWithOrdinalNotBeforeActiveCheckpoint() {
        let futureCheckpoint = makeCheckpoint(
            id: "checkpoint-4",
            historyOrdinal: 4,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "Impossible future ask.",
        )
        let active = makeCheckpoint(
            id: "checkpoint-3",
            historyOrdinal: 3,
            phaseID: "implementation",
        )
        let run = makeRun(activeCheckpoint: active, pastCheckpoints: [futureCheckpoint])

        XCTAssertNil(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))
    }

    func testMixedMissingOrdinalsFallBackToDecisionTime() throws {
        let ordinalCheckpointWithOlderDecision = makeCheckpoint(
            id: "checkpoint-1",
            historyOrdinal: 1,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "Older ask.",
            decidedAt: "2026-05-24T15:10:00Z",
        )
        let missingOrdinalWithNewerDecision = makeCheckpoint(
            id: "checkpoint-2",
            historyOrdinal: nil,
            phaseID: "implementation",
            decisionAction: "request_changes",
            decisionNote: "Newer ask.",
            decidedAt: "2026-05-24T15:20:00Z",
        )
        let active = makeCheckpoint(
            id: "checkpoint-3",
            historyOrdinal: nil,
            phaseID: "implementation",
        )
        let run = makeRun(
            activeCheckpoint: active,
            pastCheckpoints: [missingOrdinalWithNewerDecision, ordinalCheckpointWithOlderDecision],
        )

        let continuity = try XCTUnwrap(RunCheckpointRevisionContinuityProjection.make(
            run: run,
            checkpoint: active,
            operatorBrief: operatorBrief,
        ))

        XCTAssertEqual(continuity.priorCheckpointID, "checkpoint-2")
        XCTAssertEqual(continuity.youAsked, "Newer ask.")
    }

    private var operatorBrief: RunCheckpointOperatorBrief {
        RunCheckpointOperatorBrief(
            goal: "Improve checkpoint evidence packets",
            claim: "Introduced revision continuity.",
            changed: ["Checkpoint review now carries prior operator ask."],
            evidence: ["Updated checkpoint review projection."],
            risks: ["Needs UI validation."],
            ask: "Approve direction or request changes before the run continues.",
        )
    }

    private func makeRun(
        activeCheckpoint: RuntimeCheckpointState,
        pastCheckpoints: [RuntimeCheckpointState],
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: "/tmp/project",
            methodId: "method",
            methodName: "Method",
            status: "paused",
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: "2026-05-24T15:00:00Z",
            updatedAt: "2026-05-24T15:05:00Z",
            activeCheckpoint: activeCheckpoint,
            pastCheckpoints: pastCheckpoints,
            ideaId: "idea-1",
            ideaTitle: "Improve checkpoint evidence packets",
            ideaDescription: nil,
        )
    }

    private func makeCheckpoint(
        id: String,
        historyOrdinal: UInt64?,
        phaseID: String,
        title: String = "Checkpoint ready",
        summary: String? = "Worker returned a follow-up checkpoint.",
        decisionAction: String? = nil,
        decisionNote: String? = nil,
        decidedAt: String? = nil,
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            historyOrdinal: historyOrdinal,
            phaseId: phaseID,
            kind: .implementationMilestone,
            status: decidedAt == nil ? "active" : "decided",
            title: title,
            summary: summary,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            decision: decisionAction.map { RuntimeCheckpointDecision(action: $0, note: decisionNote) },
            createdAt: "2026-05-24T15:01:00Z",
            decidedAt: decidedAt,
        )
    }
}
