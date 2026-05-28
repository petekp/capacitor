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
                    status: .active,
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

    func testRevisionRelationshipLinksLaterSamePhaseCheckpointToRequestChangesNote() throws {
        let run = makeRun(
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-2",
                historyOrdinal: 1,
                phaseID: "implementation",
                title: "Revision checkpoint",
                status: "active",
                createdAt: "2026-03-26T10:20:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    historyOrdinal: 0,
                    phaseID: "implementation",
                    title: "First review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Make the packet less code-centric.",
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertNil(projection.entries[0].revisionRelationship)
        XCTAssertEqual(
            projection.entries[1].revisionRelationship,
            RunCheckpointTimelineProjection.Entry.RevisionRelationship(
                priorEntryID: "checkpoint-1#history-0",
                priorCheckpointID: "checkpoint-1",
                priorPhaseRoundNumber: 1,
                priorDecisionNote: "Make the packet less code-centric.",
            ),
        )
    }

    func testApprovalRespondsToRequestThenClearsRelationshipForLaterCheckpoint() throws {
        let run = makeRun(
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-3",
                historyOrdinal: 2,
                phaseID: "implementation",
                title: "Final checkpoint",
                status: "active",
                createdAt: "2026-03-26T10:20:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    historyOrdinal: 0,
                    phaseID: "implementation",
                    title: "First review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Tighten evidence.",
                ),
                makeCheckpoint(
                    id: "checkpoint-2",
                    historyOrdinal: 1,
                    phaseID: "implementation",
                    title: "Revision approved",
                    createdAt: "2026-03-26T10:10:00Z",
                    decidedAt: "2026-03-26T10:15:00Z",
                    decisionAction: "approve",
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries[1].revisionRelationship?.priorCheckpointID, "checkpoint-1")
        XCTAssertNil(projection.entries[2].revisionRelationship)
    }

    func testRevisionRelationshipDoesNotCrossPhaseBoundaries() throws {
        let run = makeRun(
            activeCheckpoint: makeCheckpoint(
                id: "implementation-1",
                historyOrdinal: 1,
                phaseID: "implementation",
                title: "Implementation checkpoint",
                status: "active",
                createdAt: "2026-03-26T10:20:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "design-1",
                    historyOrdinal: 0,
                    phaseID: "design",
                    title: "Design review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Revise the design.",
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertNil(projection.entries[1].revisionRelationship)
    }

    func testBlankRequestNoteDoesNotCreateRevisionRelationship() throws {
        let run = makeRun(
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-2",
                historyOrdinal: 1,
                phaseID: "implementation",
                title: "Revision checkpoint",
                status: "active",
                createdAt: "2026-03-26T10:20:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    historyOrdinal: 0,
                    phaseID: "implementation",
                    title: "First review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "   ",
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertNil(projection.entries[1].revisionRelationship)
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
                    status: .completed,
                    startedAt: nil,
                    completedAt: nil,
                ),
                RuntimePhaseInstance(
                    id: "review",
                    name: "Review",
                    status: .active,
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

    func testChronologyUsesDisplayedEventTimestamp() throws {
        let lateDecision = makeCheckpoint(
            id: "late-decision",
            phaseID: "implementation",
            title: "Created first decided second",
            createdAt: "2026-03-26T10:00:00Z",
            decidedAt: "2026-03-26T10:30:00Z",
            decisionAction: "approve",
        )
        let earlyDecision = makeCheckpoint(
            id: "early-decision",
            phaseID: "implementation",
            title: "Created second decided first",
            createdAt: "2026-03-26T10:10:00Z",
            decidedAt: "2026-03-26T10:20:00Z",
            decisionAction: "approve",
        )
        let run = makeRun(pastCheckpoints: [lateDecision, earlyDecision])

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries.map(\.checkpointID), [
            "early-decision",
            "late-decision",
        ])
        XCTAssertEqual(projection.entries.map(\.eventTimestamp), [
            "2026-03-26T10:20:00Z",
            "2026-03-26T10:30:00Z",
        ])
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

    func testArchivedCheckpointWithoutDecidedAtUsesRecordedTimestampRole() throws {
        let checkpoint = makeCheckpoint(
            id: "checkpoint-recorded",
            phaseID: "phase-1",
            title: "Archived without decided timestamp",
            status: "decided",
            createdAt: "2026-03-26T10:00:00Z",
        )
        let run = makeRun(pastCheckpoints: [checkpoint])

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries.first?.timestampRole, .recorded)
        XCTAssertEqual(projection.entries.first?.eventTimestamp, "2026-03-26T10:00:00Z")
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

    func testRuntimeHistoryOrdinalsDriveOrderAndStableIdentities() throws {
        let run = makeRun(
            activeCheckpoint: makeCheckpoint(
                id: "gate-review",
                historyOrdinal: 2,
                phaseID: "implementation",
                title: "Third runtime gate",
                status: "active",
                createdAt: "not-a-date",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "gate-review",
                    historyOrdinal: 1,
                    phaseID: "implementation",
                    title: "Second runtime gate",
                    createdAt: "not-a-date",
                    decidedAt: "not-a-date",
                    decisionAction: "request_changes",
                ),
                makeCheckpoint(
                    id: "gate-review",
                    historyOrdinal: 0,
                    phaseID: "implementation",
                    title: "First runtime gate",
                    createdAt: "not-a-date",
                    decidedAt: "not-a-date",
                    decisionAction: "request_changes",
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries.map(\.title), [
            "First runtime gate",
            "Second runtime gate",
            "Third runtime gate",
        ])
        XCTAssertEqual(projection.entries.map(\.id), [
            "gate-review#history-0",
            "gate-review#history-1",
            "gate-review#history-2",
        ])
        XCTAssertEqual(projection.entries.map(\.phaseRoundNumber), [1, 2, 3])
    }

    func testDuplicateCheckpointIDsWithEqualTimestampsKeepRuntimeOrder() throws {
        let run = makeRun(
            pastCheckpoints: [
                makeCheckpoint(
                    id: "gate-review",
                    phaseID: "implementation",
                    title: "First recorded review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "First",
                ),
                makeCheckpoint(
                    id: "gate-review",
                    phaseID: "implementation",
                    title: "Second recorded review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Second",
                ),
            ],
        )

        let projection = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertEqual(projection.entries.map(\.title), [
            "First recorded review",
            "Second recorded review",
        ])
        XCTAssertEqual(projection.entries.map(\.id), [
            "gate-review#0",
            "gate-review#1",
        ])
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
            status: activeCheckpoint == nil ? .completed : .paused,
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
        historyOrdinal: UInt64? = nil,
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
            historyOrdinal: historyOrdinal,
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
