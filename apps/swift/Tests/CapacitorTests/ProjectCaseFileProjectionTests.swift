@testable import Capacitor
import XCTest

final class ProjectCaseFileProjectionTests: XCTestCase {
    func testPausedCheckpointBuildsCaseFileWithSinceLastLookedCount() throws {
        let run = makeRun(
            status: "paused",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-2",
                title: "Implementation checkpoint",
                summary: "Agent needs direction before continuing.",
                createdAt: "2026-03-26T10:10:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    title: "Design checkpoint",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))
        let viewState = try OperatorViewStateStore.Snapshot(
            lastSeenProjects: [
                PathNormalizer.normalize(project.path): XCTUnwrap(parseISO8601Date("2026-03-26T10:06:00Z")),
            ],
        )

        let projection = ProjectCaseFileProjection.make(
            project: project,
            run: run,
            timeline: timeline,
            viewState: viewState,
        )

        XCTAssertEqual(projection.currentState.kind, .needsDecision)
        XCTAssertEqual(projection.currentState.title, "Needs decision")
        XCTAssertEqual(projection.currentState.detail, "Checkpoint ready: Implementation checkpoint")
        XCTAssertEqual(projection.sinceLastLooked.changedCheckpointCount, 1)
        XCTAssertEqual(projection.sinceLastLooked.summary, "1 checkpoint update since you last looked.")
        XCTAssertEqual(projection.recentDecisions.map(\.label), ["Approved"])
        XCTAssertEqual(projection.openRisks, [
            "Decision needed before work can continue: Implementation checkpoint",
        ])
    }

    func testRevisionCheckpointSurfacesPriorRequestAsOpenRisk() throws {
        let run = makeRun(
            status: "paused",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-2",
                historyOrdinal: 2,
                title: "Revision checkpoint",
                summary: "Reworked the brief around operator intent.",
                createdAt: "2026-03-26T10:20:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    historyOrdinal: 1,
                    title: "Evidence packet review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:10:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Make the packet less code-centric.",
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        let projection = ProjectCaseFileProjection.make(
            project: project,
            run: run,
            timeline: timeline,
            viewState: .empty,
        )

        XCTAssertEqual(projection.recentDecisions.first?.label, "Changes requested")
        XCTAssertEqual(projection.recentDecisions.first?.note, "Make the packet less code-centric.")
        XCTAssertEqual(projection.openRisks, [
            "Decision needed before work can continue: Revision checkpoint",
            "Verify revision against round 1: Make the packet less code-centric.",
        ])
    }

    func testApprovalClearsOutstandingRequestRisk() throws {
        let run = makeRun(
            status: "completed",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    historyOrdinal: 1,
                    title: "First review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Tighten evidence.",
                ),
                makeCheckpoint(
                    id: "checkpoint-2",
                    historyOrdinal: 2,
                    title: "Revision approved",
                    createdAt: "2026-03-26T10:10:00Z",
                    decidedAt: "2026-03-26T10:15:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        let projection = ProjectCaseFileProjection.make(
            project: project,
            run: run,
            timeline: timeline,
            viewState: .empty,
        )

        XCTAssertEqual(projection.currentState.kind, .completed)
        XCTAssertEqual(projection.recentDecisions.map(\.title), [
            "Revision approved",
            "First review",
        ])
        XCTAssertEqual(projection.openRisks, ["No open risks surfaced from runtime facts."])
    }

    func testUsesLatestSeenAcrossProjectRunAndCheckpoints() throws {
        let run = makeRun(
            status: "paused",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-2",
                title: "Review now",
                createdAt: "2026-03-26T10:10:00Z",
            ),
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    title: "Earlier review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))
        let viewState = try OperatorViewStateStore.Snapshot(
            lastSeenCheckpoints: [
                "checkpoint-2": XCTUnwrap(parseISO8601Date("2026-03-26T10:12:00Z")),
            ],
            lastSeenProjects: [
                PathNormalizer.normalize(project.path): XCTUnwrap(parseISO8601Date("2026-03-26T09:00:00Z")),
            ],
            lastSeenRuns: [
                run.id: XCTUnwrap(parseISO8601Date("2026-03-26T10:06:00Z")),
            ],
        )

        let projection = ProjectCaseFileProjection.make(
            project: project,
            run: run,
            timeline: timeline,
            viewState: viewState,
        )

        XCTAssertEqual(projection.sinceLastLooked.changedCheckpointCount, 0)
        XCTAssertEqual(projection.sinceLastLooked.summary, "Nothing new since you last looked.")
    }

    func testAccessibilityLabelSummarizesCaseFile() throws {
        let run = makeRun(
            status: "failed",
            statusMessage: "Worker stopped after checkpoint capture failed.",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    title: "Capture review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Need a screenshot.",
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))
        let projection = ProjectCaseFileProjection.make(
            project: project,
            run: run,
            timeline: timeline,
            viewState: .empty,
        )

        XCTAssertEqual(
            ProjectCaseFileAccessibility.sectionLabel(for: projection),
            "Case file, Capacitor, Failed, Worker stopped after checkpoint capture failed., First recorded look at this run., 1 recent decision, open risks: Worker stopped after checkpoint capture failed.; Revision requested: Need a screenshot.",
        )
    }

    private var project: Project {
        Project(
            name: "Capacitor",
            path: "/tmp/capacitor",
            displayPath: "/tmp/capacitor",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func makeRun(
        status: String,
        statusMessage: String? = nil,
        activeCheckpoint: RuntimeCheckpointState? = nil,
        pastCheckpoints: [RuntimeCheckpointState] = [],
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: project.path,
            methodId: "shape_and_execute",
            methodName: "Shape & Execute",
            status: status,
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: statusMessage,
            phases: [
                RuntimePhaseInstance(
                    id: "implementation",
                    name: "Implementation",
                    status: status == "completed" ? "completed" : "active",
                    startedAt: nil,
                    completedAt: nil,
                ),
            ],
            currentPhaseIndex: 0,
            createdAt: "2026-03-26T09:55:00Z",
            updatedAt: "2026-03-26T10:30:00Z",
            activeCheckpoint: activeCheckpoint,
            pastCheckpoints: pastCheckpoints,
            ideaId: "idea-1",
            ideaTitle: "Improve checkpoint evidence packets",
            ideaDescription: nil,
        )
    }

    private func makeCheckpoint(
        id: String,
        historyOrdinal: UInt64? = nil,
        title: String,
        summary: String? = "Review the current milestone.",
        createdAt: String,
        decidedAt: String? = nil,
        decisionAction: String? = nil,
        decisionNote: String? = nil,
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            historyOrdinal: historyOrdinal,
            phaseId: "implementation",
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
            createdAt: createdAt,
            decidedAt: decidedAt,
        )
    }
}
