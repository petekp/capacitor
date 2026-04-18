@testable import Capacitor
import XCTest

final class RunCheckpointTimelineProjectionTests: XCTestCase {
    func testEmptyRunHasNoTimelineProjection() {
        XCTAssertNil(RunCheckpointTimelineProjection(run: makeRun()))
    }

    func testProjectsPastCheckpointsAndActiveCheckpointChronologically() throws {
        let firstCheckpoint = makeCheckpoint(
            id: "checkpoint-1",
            phaseID: "implementation",
            title: "First implementation pass",
            createdAt: "2026-03-26T10:00:00Z",
            decidedAt: "2026-03-26T10:05:00Z",
            decisionAction: "request_changes",
            decisionNote: "Tighten the tests.",
        )
        let secondCheckpoint = makeCheckpoint(
            id: "checkpoint-2",
            phaseID: "implementation",
            title: "Second implementation pass",
            createdAt: "2026-03-26T10:10:00Z",
            decidedAt: "2026-03-26T10:14:00Z",
            decisionAction: "approve",
            decisionNote: nil,
        )
        let activeCheckpoint = makeCheckpoint(
            id: "checkpoint-3",
            phaseID: "implementation",
            title: "Final verification",
            status: "active",
            createdAt: "2026-03-26T10:20:00Z",
        )
        let run = makeRun(
            activeCheckpoint: activeCheckpoint,
            pastCheckpoints: [secondCheckpoint, firstCheckpoint],
            phases: [
                RuntimePhaseInstance(
                    id: "implementation",
                    name: "Implementation",
                    status: "active",
                    startedAt: nil,
                    completedAt: nil,
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.runID, "run-1")
        XCTAssertEqual(projection.methodName, "Shape & Execute")
        XCTAssertEqual(projection.entries.map(\.checkpointID), [
            "checkpoint-1",
            "checkpoint-2",
            "checkpoint-3",
        ])
        XCTAssertEqual(projection.entries.map(\.id), [
            "checkpoint-1#0",
            "checkpoint-2#1",
            "checkpoint-3#2",
        ])
        XCTAssertEqual(projection.entries.map(\.phaseName), [
            "Implementation",
            "Implementation",
            "Implementation",
        ])
        XCTAssertEqual(projection.entries.map(\.phaseRoundNumber), [1, 2, 3])
        XCTAssertEqual(projection.entries[0].decisionState, .changesRequested)
        XCTAssertEqual(projection.entries[0].decisionNote, "Tighten the tests.")
        XCTAssertEqual(projection.entries[0].eventTimestamp, "2026-03-26T10:05:00Z")
        XCTAssertEqual(projection.entries[1].decisionState, .approved)
        XCTAssertEqual(projection.entries[2].decisionState, .awaitingReview)
        XCTAssertEqual(projection.entries[2].eventTimestamp, "2026-03-26T10:20:00Z")
    }

    func testRoundNumbersAreTrackedPerPhase() throws {
        let run = makeRun(
            activeCheckpoint: makeCheckpoint(
                id: "review-2",
                phaseID: "review",
                title: "Review recheck",
                status: "active",
                createdAt: "2026-03-26T10:30:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "implementation-1",
                    phaseID: "implementation",
                    title: "Implementation pass",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:03:00Z",
                    decisionAction: "approve",
                ),
                makeCheckpoint(
                    id: "review-1",
                    phaseID: "review",
                    title: "Review pass",
                    createdAt: "2026-03-26T10:10:00Z",
                    decidedAt: "2026-03-26T10:15:00Z",
                    decisionAction: "request_changes",
                ),
                makeCheckpoint(
                    id: "implementation-2",
                    phaseID: "implementation",
                    title: "Implementation follow-up",
                    createdAt: "2026-03-26T10:20:00Z",
                    decidedAt: "2026-03-26T10:24:00Z",
                    decisionAction: "approve",
                ),
            ],
            phases: [
                RuntimePhaseInstance(
                    id: "implementation",
                    name: "Implementation",
                    status: "completed",
                    startedAt: nil,
                    completedAt: nil,
                ),
                RuntimePhaseInstance(
                    id: "review",
                    name: "Review",
                    status: "active",
                    startedAt: nil,
                    completedAt: nil,
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries.map(\.checkpointID), [
            "implementation-1",
            "review-1",
            "implementation-2",
            "review-2",
        ])
        XCTAssertEqual(projection.entries.map(\.phaseRoundNumber), [1, 1, 2, 2])
    }

    func testDecisionStateFallbacksUseRuntimeFacts() throws {
        let decidedWithoutDecision = makeCheckpoint(
            id: "checkpoint-decided",
            phaseID: "phase-1",
            title: "Archived without decision payload",
            status: "decided",
            createdAt: "2026-03-26T10:00:00Z",
            decidedAt: "2026-03-26T10:01:00Z",
        )
        let unknownAction = makeCheckpoint(
            id: "checkpoint-unknown",
            phaseID: "phase-1",
            title: "Archived with future action",
            createdAt: "2026-03-26T10:02:00Z",
            decidedAt: "2026-03-26T10:03:00Z",
            decisionAction: "escalate",
        )
        let run = makeRun(pastCheckpoints: [unknownAction, decidedWithoutDecision])

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries.map(\.decisionState), [
            .decided,
            .unknown("escalate"),
        ])
        XCTAssertEqual(projection.entries.map(\.phaseName), ["phase-1", "phase-1"])
    }

    func testRepeatedGateCheckpointIDsStillProduceDistinctEntryIdentities() throws {
        let run = makeRun(
            activeCheckpoint: makeCheckpoint(
                id: "gate-review",
                phaseID: "implementation",
                title: "Retry awaiting review",
                status: "active",
                createdAt: "2026-03-26T10:20:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "gate-review",
                    phaseID: "implementation",
                    title: "First review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                ),
                makeCheckpoint(
                    id: "gate-review",
                    phaseID: "implementation",
                    title: "Second review",
                    createdAt: "2026-03-26T10:10:00Z",
                    decidedAt: "2026-03-26T10:15:00Z",
                    decisionAction: "request_changes",
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries.map(\.checkpointID), [
            "gate-review",
            "gate-review",
            "gate-review",
        ])
        XCTAssertEqual(projection.entries.map(\.id), [
            "gate-review#0",
            "gate-review#1",
            "gate-review#2",
        ])
        XCTAssertEqual(projection.entries.map(\.phaseRoundNumber), [1, 2, 3])
    }

    private func makeRun(
        activeCheckpoint: RuntimeCheckpointState? = nil,
        pastCheckpoints: [RuntimeCheckpointState] = [],
        phases: [RuntimePhaseInstance] = [],
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: "/tmp/core-project",
            methodId: "shape_and_execute",
            methodName: "Shape & Execute",
            status: activeCheckpoint == nil ? "completed" : "paused",
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: nil,
            phases: phases,
            currentPhaseIndex: 0,
            createdAt: "2026-03-26T09:55:00Z",
            updatedAt: "2026-03-26T10:30:00Z",
            activeCheckpoint: activeCheckpoint,
            pastCheckpoints: pastCheckpoints,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    private func makeCheckpoint(
        id: String,
        phaseID: String,
        title: String,
        status: String = "decided",
        kind: RuntimeCheckpointKind = .implementationMilestone,
        summary: String? = "Review the current milestone.",
        createdAt: String,
        decidedAt: String? = nil,
        decisionAction: String? = nil,
        decisionNote: String? = nil,
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            phaseId: phaseID,
            kind: kind,
            status: status,
            title: title,
            summary: summary,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            decision: decisionAction.map {
                RuntimeCheckpointDecision(action: $0, note: decisionNote)
            },
            createdAt: createdAt,
            decidedAt: decidedAt,
        )
    }
}
