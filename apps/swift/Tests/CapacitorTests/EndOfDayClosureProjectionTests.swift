@testable import Capacitor
import XCTest

final class EndOfDayClosureProjectionTests: XCTestCase {
    func testSafeToStopWhenOnlyHealthyOrCompletedLoopsRemain() {
        let content = EndOfDayClosureContent.make(from: OperatorAttentionSummary(
            runningNormally: [
                item(kind: .runningRun, title: "Running"),
                item(kind: .runningSession, title: "Session"),
            ],
            recentlyChanged: [
                item(kind: .completedRun, title: "Done"),
            ],
        ))

        XCTAssertTrue(content.safeToStop)
        XCTAssertEqual(content.openLoopCount, 3)
        XCTAssertEqual(content.lines.map(\.text), [
            "Open loops: 3",
            "Today: no completed runs or decisions recorded",
            "1 completed item ready for review",
            "2 sessions can keep running",
            "Safe to stop: yes",
        ])
    }

    func testNotSafeToStopWhenDecisionsOrExceptionsNeedAttention() {
        let content = EndOfDayClosureContent.make(from: OperatorAttentionSummary(
            needsYou: [
                item(kind: .checkpoint, title: "Checkpoint"),
                item(kind: .delegationReview, title: "Review"),
            ],
            runningNormally: [
                item(kind: .runningRun, title: "Running"),
            ],
            exceptions: [
                item(kind: .staleSession, title: "Stale"),
            ],
        ))

        XCTAssertFalse(content.safeToStop)
        XCTAssertEqual(content.openLoopCount, 4)
        XCTAssertEqual(content.lines.map(\.text), [
            "Open loops: 4",
            "Today: no completed runs or decisions recorded",
            "2 decisions need you",
            "1 item needs inspection",
            "1 session can keep running",
            "Safe to stop: no",
        ])
    }

    func testEmptyAttentionSummaryIsSafeWithZeroOpenLoops() {
        let content = EndOfDayClosureContent.make(from: OperatorAttentionSummary())

        XCTAssertTrue(content.safeToStop)
        XCTAssertEqual(content.openLoopCount, 0)
        XCTAssertEqual(content.lines.map(\.text), [
            "Open loops: 0",
            "Today: no completed runs or decisions recorded",
            "Safe to stop: yes",
        ])
    }

    func testBuildsTodayCountersFromCurrentRuntimeHistory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(parseISO8601Date("2026-05-24T20:00:00Z"))
        let content = EndOfDayClosureContent.make(
            from: OperatorAttentionSummary(),
            runs: [
                makeRun(
                    id: "run-completed-today",
                    status: "completed",
                    updatedAt: "2026-05-24T18:00:00Z",
                    pastCheckpoints: [
                        makeCheckpoint(
                            id: "approved-today",
                            decisionAction: "approve",
                            decidedAt: "2026-05-24T18:30:00Z",
                        ),
                        makeCheckpoint(
                            id: "changes-today",
                            decisionAction: "request_changes",
                            decidedAt: "2026-05-24T19:00:00Z",
                        ),
                    ],
                ),
                makeRun(
                    id: "run-completed-yesterday",
                    status: "completed",
                    updatedAt: "2026-05-23T18:00:00Z",
                    pastCheckpoints: [
                        makeCheckpoint(
                            id: "approved-yesterday",
                            decisionAction: "approve",
                            decidedAt: "2026-05-23T18:30:00Z",
                        ),
                    ],
                ),
            ],
            now: now,
            calendar: calendar,
        )

        XCTAssertEqual(content.today.completedRuns, 1)
        XCTAssertEqual(content.today.approvals, 1)
        XCTAssertEqual(content.today.requestedRevisions, 1)
        XCTAssertEqual(content.lines.map(\.text), [
            "Open loops: 0",
            "Today: 1 run completed, 1 checkpoint approved, 1 revision requested",
            "Safe to stop: yes",
        ])
    }

    private func item(
        kind: OperatorAttentionItem.Kind,
        title: String,
    ) -> OperatorAttentionItem {
        OperatorAttentionItem(
            id: "\(kind)-\(title)",
            kind: kind,
            projectPath: "/tmp/\(title)",
            title: title,
            reason: title,
            ageLabel: nil,
            recommendedAction: nil,
            target: .project(path: "/tmp/\(title)"),
        )
    }

    private func makeRun(
        id: String,
        status: String,
        updatedAt: String,
        pastCheckpoints: [RuntimeCheckpointState] = [],
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: id,
            projectPath: "/tmp/project",
            methodId: "method",
            methodName: "Method",
            status: status,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            createdAt: "2026-05-24T10:00:00Z",
            updatedAt: updatedAt,
            activeCheckpoint: nil,
            pastCheckpoints: pastCheckpoints,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    private func makeCheckpoint(
        id: String,
        decisionAction: String,
        decidedAt: String,
    ) -> RuntimeCheckpointState {
        RuntimeCheckpointState(
            id: id,
            phaseId: "implementation",
            kind: .implementationMilestone,
            status: "decided",
            title: id,
            summary: nil,
            briefPath: nil,
            manifestPath: nil,
            mediaArtifacts: [],
            mermaidSources: [],
            captureStatus: .notRequested,
            captureUrl: nil,
            captureClaim: nil,
            decision: RuntimeCheckpointDecision(action: decisionAction, note: nil),
            createdAt: "2026-05-24T17:00:00Z",
            decidedAt: decidedAt,
        )
    }
}
