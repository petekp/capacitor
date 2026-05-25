@testable import Capacitor
import XCTest

final class ReturnBriefContentTests: XCTestCase {
    func testSummarizesAttentionCountsInStoryboardOrder() {
        let content = ReturnBriefContent.make(from: OperatorAttentionSummary(
            needsYou: [
                item(kind: .checkpoint, title: "Packet ready"),
                item(kind: .checkpoint, title: "Direction ready"),
            ],
            runningNormally: [
                item(kind: .runningRun, title: "Active A"),
                item(kind: .runningSession, title: "Active B"),
                item(kind: .runningRun, title: "Active C"),
            ],
            recentlyChanged: [
                item(kind: .completedRun, title: "Completed"),
            ],
            dormant: [
                item(kind: .dormantProject, title: "Hidden"),
            ],
            exceptions: [
                item(kind: .staleSession, title: "Stale"),
            ],
        ))

        XCTAssertEqual(content.title, "While you were away")
        XCTAssertEqual(content.lines.map(\.text), [
            "2 decisions need you",
            "1 worker completed",
            "3 sessions are healthy",
            "1 session looks stale",
            "Nothing else needs attention",
        ])
    }

    func testShowsNoAttentionStateWhenOnlyHealthyWorkExists() {
        let content = ReturnBriefContent.make(from: OperatorAttentionSummary(
            runningNormally: [
                item(kind: .runningRun, title: "Active A"),
                item(kind: .runningSession, title: "Active B"),
            ],
        ))

        XCTAssertEqual(content.lines.map(\.text), [
            "2 sessions are healthy",
            "Nothing needs attention",
        ])
    }

    func testIgnoresDormantProjectsAsAttention() {
        let content = ReturnBriefContent.make(from: OperatorAttentionSummary(
            dormant: [
                item(kind: .dormantProject, title: "Hidden"),
                item(kind: .dormantProject, title: "Quiet"),
            ],
        ))

        XCTAssertEqual(content.lines.map(\.text), [
            "Nothing needs attention",
        ])
    }

    func testCarriesLastOpenedAtFromOperatorViewState() {
        let lastOpenedAt = Date(timeIntervalSince1970: 1_800_000_360)
        let content = ReturnBriefContent.make(
            from: OperatorAttentionSummary(),
            viewState: OperatorViewStateStore.Snapshot(lastAppOpenedAt: lastOpenedAt),
        )

        XCTAssertEqual(content.lastAppOpenedAt, lastOpenedAt)
    }

    func testSummarizesWhatChangedSinceLastLooked() {
        let lastOpenedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let content = ReturnBriefContent.make(
            from: OperatorAttentionSummary(
                needsYou: [
                    item(kind: .checkpoint, title: "New Decision", changedAt: 1_800_000_060),
                    item(kind: .checkpoint, title: "Old Decision", changedAt: 1_799_999_940),
                ],
                runningNormally: [
                    item(kind: .runningRun, title: "Healthy", changedAt: 1_800_000_120),
                ],
                recentlyChanged: [
                    item(kind: .completedRun, title: "Done", changedAt: 1_800_000_180),
                ],
                exceptions: [
                    item(kind: .staleSession, title: "Stale", changedAt: 1_800_000_240),
                ],
            ),
            viewState: OperatorViewStateStore.Snapshot(lastAppOpenedAt: lastOpenedAt),
        )

        XCTAssertEqual(content.lines.map(\.text), [
            "Since you last looked: 1 new decision, 1 new completion, 1 new exception, 1 healthy update",
            "2 decisions need you",
            "1 worker completed",
            "1 session is healthy",
            "1 session looks stale",
            "Nothing else needs attention",
        ])
    }

    func testShowsNoChangeSinceLastLookedWhenSignalsAreOlderThanPreviousOpen() {
        let lastOpenedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let content = ReturnBriefContent.make(
            from: OperatorAttentionSummary(
                needsYou: [
                    item(kind: .checkpoint, title: "Old Decision", changedAt: 1_799_999_940),
                ],
            ),
            viewState: OperatorViewStateStore.Snapshot(lastAppOpenedAt: lastOpenedAt),
        )

        XCTAssertEqual(content.lines.map(\.text), [
            "Nothing changed since you last looked",
            "1 decision needs you",
            "Nothing else needs attention",
        ])
    }

    func testProjectionOutputFeedsSinceLastLookedLine() {
        let project = makeProject(name: "Proof", path: "/tmp/proof")
        let run = makeRun(
            id: "run-1",
            projectPath: project.path,
            status: "paused",
            updatedAt: "2026-05-24T15:01:00Z",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-1",
                title: "Evidence packet ready",
                createdAt: "2026-05-24T15:00:00Z",
            ),
        )
        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: [RuntimeRunKey(run: run): run],
            now: Date(timeIntervalSince1970: 1_800_000_000),
        )

        let content = ReturnBriefContent.make(
            from: summary,
            viewState: OperatorViewStateStore.Snapshot(
                lastAppOpenedAt: parseISO8601Date("2026-05-24T14:59:00Z"),
            ),
        )

        XCTAssertEqual(content.lines.map(\.text), [
            "Since you last looked: 1 new decision",
            "1 decision needs you",
            "Nothing else needs attention",
        ])
    }

    func testUsesPlainInspectionCopyForNonStaleExceptions() {
        let content = ReturnBriefContent.make(from: OperatorAttentionSummary(
            exceptions: [
                item(kind: .failedRun, title: "Failed"),
            ],
        ))

        XCTAssertEqual(content.lines.map(\.text), [
            "1 item needs inspection",
            "Nothing else needs attention",
        ])
    }

    func testProjectionOutputFeedsDecisionBriefLine() {
        let project = makeProject(name: "Proof", path: "/tmp/proof")
        let run = makeRun(
            id: "run-1",
            projectPath: project.path,
            status: "paused",
            updatedAt: "2026-05-24T15:01:00Z",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-1",
                title: "Evidence packet ready",
                createdAt: "2026-05-24T15:00:00Z",
            ),
        )
        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: [RuntimeRunKey(run: run): run],
            now: Date(timeIntervalSince1970: 1_800_000_000),
        )

        let content = ReturnBriefContent.make(from: summary)

        XCTAssertEqual(content.lines.map(\.text), [
            "1 decision needs you",
            "Nothing else needs attention",
        ])
    }

    private func item(
        kind: OperatorAttentionItem.Kind,
        title: String,
        changedAt: TimeInterval? = nil,
    ) -> OperatorAttentionItem {
        OperatorAttentionItem(
            id: "\(kind)-\(title)",
            kind: kind,
            projectPath: "/tmp/\(title)",
            title: title,
            reason: title,
            ageLabel: nil,
            recommendedAction: nil,
            lastChangedAt: changedAt.map(Date.init(timeIntervalSince1970:)),
            target: .project(path: "/tmp/\(title)"),
        )
    }

    private func makeProject(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            displayPath: path,
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
        id: String,
        projectPath: String,
        status: String,
        updatedAt: String,
        activeCheckpoint: RuntimeCheckpointState?,
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: id,
            projectPath: projectPath,
            methodId: "method",
            methodName: "Method",
            status: status,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: "Run in progress",
            createdAt: "2026-05-24T14:00:00Z",
            updatedAt: updatedAt,
            activeCheckpoint: activeCheckpoint,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    private func makeCheckpoint(
        id: String,
        title: String,
        createdAt: String,
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            phaseId: "phase",
            kind: .implementationMilestone,
            status: "pending",
            title: title,
            summary: "Needs direction",
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            createdAt: createdAt,
            decidedAt: nil,
        )
    }
}
