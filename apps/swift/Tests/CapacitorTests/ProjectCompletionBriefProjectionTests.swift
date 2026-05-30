@testable import Capacitor
import XCTest

final class ProjectCompletionBriefProjectionTests: XCTestCase {
    func testCompletedRunBuildsFinalReviewBriefFromCheckpointHistory() throws {
        let run = makeRun(
            status: "completed",
            statusMessage: "Implementation checkpoint passed.",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    title: "Final review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "approve",
                    briefPath: "/tmp/brief.md",
                    manifestPath: "/tmp/manifest.json",
                    mediaArtifacts: [
                        RuntimeMediaArtifact(
                            artifactType: "screenshot",
                            path: "/tmp/window.png",
                            label: "Window",
                            width: 1200,
                            height: 800,
                            durationSecs: nil,
                        ),
                    ],
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        let projection = try XCTUnwrap(ProjectCompletionBriefProjection.make(
            project: project,
            run: run,
            timeline: timeline,
        ))

        XCTAssertEqual(projection.projectName, "Capacitor")
        XCTAssertEqual(projection.runID, "run-1")
        XCTAssertEqual(projection.headline, "Completed: Improve checkpoint evidence packets")
        XCTAssertEqual(projection.outcome, "Implementation checkpoint passed.")
        XCTAssertEqual(projection.readyFor, "Final review / archive / follow-up")
        XCTAssertEqual(projection.confidence, "medium")
        XCTAssertEqual(projection.evidence, [
            "1 checkpoint entry recorded.",
            "Latest decision: Approved - Final review",
            "3 checkpoint artifacts recorded.",
        ])
        XCTAssertEqual(projection.residualRisks, [
            "No open risks surfaced from runtime facts.",
        ])
        XCTAssertEqual(projection.attentionReason, "Ready for final review: Improve checkpoint evidence packets")
        XCTAssertEqual(projection.recommendedAction, "Review / archive / follow up")
    }

    func testCompletedRunKeepsUnresolvedChangeRequestAsResidualRisk() throws {
        let run = makeRun(
            status: "completed",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    title: "Evidence packet review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "request_changes",
                    decisionNote: "Make the packet less code-centric.",
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        let projection = try XCTUnwrap(ProjectCompletionBriefProjection.make(
            project: project,
            run: run,
            timeline: timeline,
        ))

        XCTAssertEqual(projection.confidence, "low")
        XCTAssertEqual(projection.evidence, [
            "1 checkpoint entry recorded.",
            "Latest decision: Changes requested - Evidence packet review",
        ])
        XCTAssertEqual(projection.residualRisks, [
            "Prior change request may need final confirmation: Make the packet less code-centric.",
            "No explicit approve decision recorded in checkpoint history.",
        ])
    }

    func testCompletedRunWithoutCheckpointHistoryStillBuildsLowConfidenceBrief() throws {
        let run = makeRun(
            status: "completed",
            pastCheckpoints: [],
        )

        let projection = try XCTUnwrap(ProjectCompletionBriefProjection.make(
            project: project,
            run: run,
            timeline: nil,
        ))

        XCTAssertEqual(projection.confidence, "low")
        XCTAssertEqual(projection.evidence, [
            "No checkpoint history recorded.",
        ])
        XCTAssertEqual(projection.residualRisks, [
            "No checkpoint evidence recorded for final review.",
        ])
    }

    func testProjectionIsOnlyForCompletedRuns() throws {
        let run = makeRun(
            status: "paused",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-active",
                title: "Decision ready",
                createdAt: "2026-03-26T10:10:00Z",
            ),
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))

        XCTAssertNil(ProjectCompletionBriefProjection.make(
            project: project,
            run: run,
            timeline: timeline,
        ))
    }

    func testAttentionReasonFallsBackToMethodWhenIdeaTitleIsMissing() {
        let run = makeRun(
            status: "completed",
            ideaTitle: nil,
        )

        XCTAssertEqual(
            ProjectCompletionBriefProjection.attentionReason(for: run),
            "Ready for final review: Shape & Execute",
        )
    }

    func testAccessibilityLabelSummarizesCompletionBrief() throws {
        let run = makeRun(
            status: "completed",
            statusMessage: "Final verification passed.",
            pastCheckpoints: [
                makeCheckpoint(
                    id: "checkpoint-1",
                    title: "Final review",
                    createdAt: "2026-03-26T10:00:00Z",
                    decidedAt: "2026-03-26T10:05:00Z",
                    decisionAction: "approve",
                ),
            ],
        )
        let timeline = try XCTUnwrap(RunCheckpointTimelineProjection(run: run))
        let projection = try XCTUnwrap(ProjectCompletionBriefProjection.make(
            project: project,
            run: run,
            timeline: timeline,
        ))

        XCTAssertEqual(
            ProjectCompletionBriefAccessibility.sectionLabel(for: projection),
            "Completion brief, Capacitor, Completed: Improve checkpoint evidence packets, Final verification passed., ready for: Final review / archive / follow-up, confidence: medium, evidence: 1 checkpoint entry recorded.; Latest decision: Approved - Final review, residual risks: No open risks surfaced from runtime facts.",
        )
    }

    private var project: Project {
        Project(
            name: "Capacitor",
            path: "/tmp/capacitor",
            workspaceId: WorkspaceIdentity.fromPath("/tmp/capacitor"),
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
        ideaTitle: String? = "Improve checkpoint evidence packets",
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: "run-1",
            projectPath: project.path,
            methodId: "shape_and_execute",
            methodName: "Shape & Execute",
            status: try! RunStatus.decode(wire: status),
            sessionId: "session-1",
            delegationWorkerId: nil,
            statusMessage: statusMessage,
            phases: [
                RuntimePhaseInstance(
                    id: "implementation",
                    name: "Implementation",
                    status: status == "completed" ? .completed : .active,
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
            ideaTitle: ideaTitle,
            ideaDescription: nil,
        )
    }

    private func makeCheckpoint(
        id: String,
        title: String,
        createdAt: String,
        decidedAt: String? = nil,
        decisionAction: String? = nil,
        decisionNote: String? = nil,
        briefPath: String? = nil,
        manifestPath: String? = nil,
        mediaArtifacts: [RuntimeMediaArtifact] = [],
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            phaseId: "implementation",
            kind: .implementationMilestone,
            status: decidedAt == nil ? "active" : "decided",
            title: title,
            summary: "Review the current milestone.",
            briefPath: briefPath,
            manifestPath: manifestPath,
            mediaArtifacts: mediaArtifacts,
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
