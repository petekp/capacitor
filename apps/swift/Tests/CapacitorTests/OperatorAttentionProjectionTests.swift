@testable import Capacitor
import XCTest

final class OperatorAttentionProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPausedActiveCheckpointAppearsInNeedsYou() {
        let project = makeProject(name: "Proof", path: "/tmp/proof")
        let checkpoint = makeCheckpoint(
            id: "checkpoint-1",
            title: "Evidence packet ready",
            createdAt: "2026-05-24T15:00:00Z",
        )
        let run = makeRun(
            id: "run-1",
            projectPath: project.path,
            status: "paused",
            updatedAt: "2026-05-24T15:01:00Z",
            activeCheckpoint: checkpoint,
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: runsByID([run]),
            now: now,
        )

        XCTAssertEqual(summary.needsYou.map(\.title), ["Evidence packet ready"])
        XCTAssertEqual(summary.needsYou.first?.kind, .checkpoint)
        XCTAssertEqual(summary.needsYou.first?.recommendedAction, "Review brief")
        XCTAssertEqual(
            summary.needsYou.first?.target,
            .checkpoint(
                runID: "run-1",
                checkpointID: "checkpoint-1",
                projectPath: project.path,
            ),
        )
        XCTAssertEqual(summary.runningNormally, [])
    }

    func testNeedsYouOrdersOldestCheckpointFirst() {
        let olderProject = makeProject(name: "Older", path: "/tmp/older")
        let newerProject = makeProject(name: "Newer", path: "/tmp/newer")
        let olderRun = makeRun(
            id: "run-older",
            projectPath: olderProject.path,
            status: "paused",
            updatedAt: "2026-05-24T15:05:00Z",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-older",
                title: "Older checkpoint",
                createdAt: "2026-05-24T15:00:00Z",
            ),
        )
        let newerRun = makeRun(
            id: "run-newer",
            projectPath: newerProject.path,
            status: "paused",
            updatedAt: "2026-05-24T15:05:00Z",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-newer",
                title: "Newer checkpoint",
                createdAt: "2026-05-24T15:04:00Z",
            ),
        )

        let summary = OperatorAttentionProjection.build(
            projects: [newerProject, olderProject],
            runsByID: runsByID([newerRun, olderRun]),
            now: now,
        )

        XCTAssertEqual(summary.needsYou.map(\.title), ["Older checkpoint", "Newer checkpoint"])
    }

    func testWorkBatchCheckpointAppearsInNeedsYou() {
        let project = makeProject(name: "Parable", path: "/tmp/parable")
        let checkpointDate = Date(timeIntervalSince1970: 1_800_000_010)
        let batch = makeWorkBatch(
            id: "batch-typeface",
            name: "Typeface unification",
            status: .idle,
            taskStatus: .needsYou,
            checkpoint: WorkBatchCheckpointRecord(
                id: "checkpoint-typeface",
                batchID: "batch-typeface",
                taskID: "task-typeface",
                question: "Which source typeface should I use?",
                reason: "Multiple source stories use different typefaces.",
                recommendedAction: "Choose the source story.",
                status: .pending,
                requestedAt: checkpointDate,
                respondedAt: nil,
                response: nil,
                updatedAt: checkpointDate,
            ),
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            workBatchesByProjectPath: [project.path: [batch]],
            now: now,
        )

        XCTAssertEqual(summary.needsYou.map(\.title), ["Typeface unification"])
        XCTAssertEqual(summary.needsYou.first?.kind, .workBatchCheckpoint)
        XCTAssertEqual(
            summary.needsYou.first?.reason,
            "Checkpoint ready: Which source typeface should I use?",
        )
        XCTAssertEqual(summary.needsYou.first?.recommendedAction, "Choose the source story.")
        XCTAssertEqual(summary.needsYou.first?.target, .project(path: project.path))
        XCTAssertEqual(summary.dormant, [])
    }

    func testHealthyActiveRunAppearsInRunningNormally() {
        let project = makeProject(name: "Active", path: "/tmp/active")
        let run = makeRun(
            id: "run-active",
            projectPath: project.path,
            status: "active",
            statusMessage: "Implementing attention projection",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: runsByID([run]),
            now: now,
        )

        XCTAssertEqual(summary.runningNormally.map(\.title), ["Active"])
        XCTAssertEqual(summary.runningNormally.first?.kind, .runningRun)
        XCTAssertEqual(summary.runningNormally.first?.reason, "Implementing attention projection")
        XCTAssertEqual(summary.needsYou, [])
    }

    func testRunningWorkBatchAppearsInRunningNormally() {
        let project = makeProject(name: "Parable", path: "/tmp/parable")
        let batch = makeWorkBatch(
            id: "batch-type-scale",
            name: "Type scale",
            status: .working,
            currentActivitySummary: "Working on make all type a bit larger.",
            taskStatus: .working,
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            workBatchesByProjectPath: [project.path: [batch]],
            now: now,
        )

        XCTAssertEqual(summary.runningNormally.map(\.title), ["Parable"])
        XCTAssertEqual(summary.runningNormally.first?.kind, .runningWorkBatch)
        XCTAssertEqual(summary.runningNormally.first?.reason, "Working on make all type a bit larger.")
        XCTAssertEqual(summary.dormant, [])
    }

    func testWaitingWorkBatchAppearsAsExceptionInsteadOfRunningNormally() {
        let project = makeProject(name: "Parable", path: "/tmp/parable")
        let batch = makeWorkBatch(
            id: "batch-type-scale",
            name: "Type scale",
            status: .waiting,
            currentActivitySummary: "Claude Code session needs reconnect.",
            taskStatus: .queued,
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            workBatchesByProjectPath: [project.path: [batch]],
            now: now,
        )

        XCTAssertEqual(summary.exceptions.map(\.title), ["Type scale"])
        XCTAssertEqual(summary.exceptions.first?.kind, .waitingWorkBatch)
        XCTAssertEqual(summary.exceptions.first?.reason, "Claude Code session needs reconnect.")
        XCTAssertEqual(summary.exceptions.first?.recommendedAction, "Reconnect session")
        XCTAssertEqual(summary.exceptions.first?.target, .project(path: project.path))
        XCTAssertEqual(summary.runningNormally, [])
        XCTAssertEqual(summary.dormant, [])
    }

    func testWaitingWorkBatchDuplicateSummaryRecommendsResolvingDuplicateSessions() {
        let project = makeProject(name: "Parable", path: "/tmp/parable")
        let batch = makeWorkBatch(
            id: "batch-type-scale",
            name: "Type scale",
            status: .waiting,
            currentActivitySummary: "Multiple Claude Code sessions match this Work Batch.",
            taskStatus: .queued,
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            workBatchesByProjectPath: [project.path: [batch]],
            now: now,
        )

        XCTAssertEqual(summary.exceptions.first?.kind, .waitingWorkBatch)
        XCTAssertEqual(summary.exceptions.first?.recommendedAction, "Resolve duplicate sessions")
    }

    func testRunningReceiptLoopAppearsInRunningNormallyWithHandoffCopy() {
        let project = makeProject(name: "Receipt", path: "/tmp/receipt")
        let receiptRun = ReceiptLoopRunState(
            id: "receipt-run-1",
            projectPath: project.path,
            ideaId: "idea-1",
            ideaTitle: "Improve checkpoint evidence packets",
            status: .running,
            createdAt: "2027-01-15T07:59:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            receiptRunsByProjectPath: [project.path: receiptRun],
            now: now,
        )

        XCTAssertEqual(summary.runningNormally.map(\.title), ["Receipt"])
        XCTAssertEqual(summary.runningNormally.first?.kind, .runningReceipt)
        XCTAssertEqual(
            summary.runningNormally.first?.reason,
            "Working on: Improve checkpoint evidence packets. Expected next signal: receipt. Healthy silence window: ~20m",
        )
        XCTAssertEqual(summary.needsYou, [])
    }

    func testDelegationReviewAppearsInNeedsYou() {
        let project = makeProject(name: "Review", path: "/tmp/review")
        let delegation = makeDelegation(
            projectPath: project.path,
            status: "review_needed",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            delegationStatesByProjectPath: [project.path: delegation],
            now: now,
        )

        XCTAssertEqual(summary.needsYou.map(\.title), ["Review"])
        XCTAssertEqual(summary.needsYou.first?.kind, .delegationReview)
        XCTAssertEqual(summary.needsYou.first?.reason, "Worker needs a decision before continuing")
        XCTAssertEqual(summary.needsYou.first?.recommendedAction, "Review brief")
        XCTAssertEqual(summary.dormant, [])
    }

    func testCompletedReceiptLoopAppearsRecentlyChanged() {
        let project = makeProject(name: "Receipt Done", path: "/tmp/receipt-done")
        let receiptRun = ReceiptLoopRunState(
            id: "receipt-run-done",
            projectPath: project.path,
            ideaId: "idea-1",
            ideaTitle: "Tighten receipt loop",
            status: .completed,
            createdAt: "2027-01-15T07:50:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            receiptRunsByProjectPath: [project.path: receiptRun],
            now: now,
        )

        XCTAssertEqual(summary.recentlyChanged.map(\.title), ["Receipt Done"])
        XCTAssertEqual(summary.recentlyChanged.first?.kind, .completedReceipt)
        XCTAssertEqual(summary.recentlyChanged.first?.reason, "Receipt captured for Tighten receipt loop")
        XCTAssertEqual(summary.recentlyChanged.first?.recommendedAction, "Show receipt")
        XCTAssertEqual(
            summary.recentlyChanged.first?.target,
            .receiptProof(runID: "receipt-run-done", projectPath: project.path),
        )
    }

    func testOnlyLatestCompletedReceiptLoopTargetsReceiptProofSurface() {
        let olderProject = makeProject(name: "Older Receipt", path: "/tmp/receipt-older")
        let newerProject = makeProject(name: "Newer Receipt", path: "/tmp/receipt-newer")
        let olderReceiptRun = ReceiptLoopRunState(
            id: "receipt-run-older",
            projectPath: olderProject.path,
            ideaId: "idea-older",
            ideaTitle: "Older receipt loop",
            status: .completed,
            createdAt: "2027-01-15T07:45:00Z",
            updatedAt: "2027-01-15T07:55:00Z",
        )
        let newerReceiptRun = ReceiptLoopRunState(
            id: "receipt-run-newer",
            projectPath: newerProject.path,
            ideaId: "idea-newer",
            ideaTitle: "Newer receipt loop",
            status: .completed,
            createdAt: "2027-01-15T07:50:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [olderProject, newerProject],
            receiptRunsByProjectPath: [
                olderProject.path: olderReceiptRun,
                newerProject.path: newerReceiptRun,
            ],
            now: now,
        )

        let targetsByProject = Dictionary(uniqueKeysWithValues: summary.recentlyChanged.map { ($0.projectPath, $0.target) })
        XCTAssertEqual(
            targetsByProject[olderProject.path],
            .run(id: "receipt-run-older", projectPath: olderProject.path),
        )
        XCTAssertEqual(
            targetsByProject[newerProject.path],
            .receiptProof(runID: "receipt-run-newer", projectPath: newerProject.path),
        )
    }

    func testOldCompletedReceiptLoopFallsBackToDormant() {
        let project = makeProject(name: "Old Receipt", path: "/tmp/old-receipt")
        let receiptRun = ReceiptLoopRunState(
            id: "receipt-run-old",
            projectPath: project.path,
            ideaId: "idea-1",
            ideaTitle: "Tighten receipt loop",
            status: .completed,
            createdAt: "2026-05-24T07:50:00Z",
            updatedAt: "2026-05-24T08:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            receiptRunsByProjectPath: [project.path: receiptRun],
            now: now,
        )

        XCTAssertEqual(summary.dormant.map(\.title), ["Old Receipt"])
        XCTAssertEqual(summary.recentlyChanged, [])
    }

    func testFailedReceiptLoopAppearsAsException() {
        let project = makeProject(name: "Receipt Failed", path: "/tmp/receipt-failed")
        let receiptRun = ReceiptLoopRunState(
            id: "receipt-run-failed",
            projectPath: project.path,
            ideaId: "idea-1",
            ideaTitle: "Tighten receipt loop",
            status: .failed,
            failureReason: "Claude receipt loop failed",
            createdAt: "2027-01-15T07:50:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            receiptRunsByProjectPath: [project.path: receiptRun],
            now: now,
        )

        XCTAssertEqual(summary.exceptions.map(\.title), ["Receipt Failed"])
        XCTAssertEqual(summary.exceptions.first?.kind, .failedReceipt)
        XCTAssertEqual(summary.exceptions.first?.reason, "Claude receipt loop failed")
        XCTAssertEqual(summary.exceptions.first?.recommendedAction, "Inspect terminal")
        XCTAssertEqual(
            summary.exceptions.first?.target,
            .run(id: "receipt-run-failed", projectPath: project.path),
        )
    }

    func testRecentCompletionAppearsRecentlyChanged() {
        let project = makeProject(name: "Complete", path: "/tmp/complete")
        let run = makeRun(
            id: "run-complete",
            projectPath: project.path,
            methodName: "Build",
            status: "completed",
            statusMessage: nil,
            updatedAt: "2027-01-15T07:45:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: runsByID([run]),
            now: now,
        )

        XCTAssertEqual(summary.recentlyChanged.map(\.title), ["Complete"])
        XCTAssertEqual(summary.recentlyChanged.first?.kind, .completedRun)
        XCTAssertEqual(summary.recentlyChanged.first?.reason, "Ready for final review: Build")
        XCTAssertEqual(summary.recentlyChanged.first?.recommendedAction, "Review / archive / follow up")
    }

    func testStaleWorkingSessionAppearsAsException() {
        let project = makeProject(name: "Stale", path: "/tmp/stale")
        let session = makeSession(
            state: .working,
            updatedAt: "2027-01-15T07:50:00Z",
            sessionId: "session-stale",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            sessionStatesByProjectPath: [project.path: session],
            now: now,
        )

        XCTAssertEqual(summary.exceptions.map(\.title), ["Stale"])
        XCTAssertEqual(summary.exceptions.first?.kind, .staleSession)
        XCTAssertEqual(summary.exceptions.first?.recommendedAction, "Inspect terminal")
    }

    func testDormantProjectAppearsWhenNoSignalsExist() {
        let project = makeProject(name: "Dormant", path: "/tmp/dormant")

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            now: now,
        )

        XCTAssertEqual(summary.dormant.map(\.title), ["Dormant"])
        XCTAssertEqual(summary.dormant.first?.kind, .dormantProject)
    }

    func testOldTerminalRunFallsBackToDormant() {
        let project = makeProject(name: "Old Done", path: "/tmp/old-done")
        let run = makeRun(
            id: "run-old",
            projectPath: project.path,
            status: "completed",
            updatedAt: "2026-05-24T15:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: runsByID([run]),
            now: now,
        )

        XCTAssertEqual(summary.dormant.map(\.title), ["Old Done"])
        XCTAssertEqual(summary.recentlyChanged, [])
    }

    func testRecentFailedRunAppearsAsException() {
        let project = makeProject(name: "Failed", path: "/tmp/failed")
        let run = makeRun(
            id: "run-failed",
            projectPath: project.path,
            status: "failed",
            statusMessage: "Tests failed",
            updatedAt: "2027-01-15T07:55:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: runsByID([run]),
            now: now,
        )

        XCTAssertEqual(summary.exceptions.map(\.title), ["Failed"])
        XCTAssertEqual(summary.exceptions.first?.kind, .failedRun)
        XCTAssertEqual(summary.exceptions.first?.reason, "Tests failed")
    }

    func testDeduplicatesProjectAcrossHigherPriorityCategories() {
        let project = makeProject(name: "One Card", path: "/tmp/one-card")
        let checkpointRun = makeRun(
            id: "run-checkpoint",
            projectPath: project.path,
            status: "paused",
            updatedAt: "2026-05-24T15:01:00Z",
            activeCheckpoint: makeCheckpoint(
                id: "checkpoint-1",
                title: "Decision ready",
                createdAt: "2026-05-24T15:00:00Z",
            ),
        )
        let activeRun = makeRun(
            id: "run-active",
            projectPath: project.path,
            status: "active",
            updatedAt: "2027-01-15T08:00:00Z",
        )

        let summary = OperatorAttentionProjection.build(
            projects: [project],
            runsByID: runsByID([checkpointRun, activeRun]),
            now: now,
        )

        XCTAssertEqual(summary.needsYou.count, 1)
        XCTAssertEqual(summary.runningNormally, [])
        XCTAssertEqual(summary.recentlyChanged, [])
        XCTAssertEqual(summary.dormant, [])
        XCTAssertEqual(summary.exceptions, [])
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
        methodName: String = "Method",
        status: String,
        statusMessage: String? = "Run in progress",
        updatedAt: String,
        activeCheckpoint: RuntimeCheckpointState? = nil,
    ) -> RuntimeRunState {
        RuntimeRunState(
            id: id,
            projectPath: projectPath,
            methodId: "method",
            methodName: methodName,
            status: try! RunStatus.decode(wire: status),
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: statusMessage,
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

    private func makeSession(
        state: SessionState,
        updatedAt: String,
        sessionId: String,
    ) -> ProjectSessionState {
        ProjectSessionState(
            state: state,
            stateChangedAt: updatedAt,
            updatedAt: updatedAt,
            sessionId: sessionId,
            workingOn: nil,
            context: nil,
            thinking: nil,
            hasSession: true,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
        )
    }

    private func makeWorkBatch(
        id: String,
        name: String,
        status: WorkBatchStatus,
        currentActivitySummary: String = "Checkpoint ready",
        taskStatus: WorkBatchTaskStatus,
        checkpoint: WorkBatchCheckpointRecord? = nil,
    ) -> WorkBatchProjection {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let task = WorkBatchTaskRecord(
            id: "task-\(id)",
            sourceIdeaID: "idea-\(id)",
            title: name,
            body: "",
            status: taskStatus,
            batchID: id,
            createdAt: updatedAt,
            updatedAt: updatedAt,
        )

        return WorkBatchProjection(
            id: id,
            name: name,
            status: status,
            queuedTaskCount: taskStatus == .queued ? 1 : 0,
            currentActivitySummary: currentActivitySummary,
            tasks: [task],
            checkpoints: checkpoint.map { [$0] } ?? [],
            binding: nil,
        )
    }

    private func makeDelegation(
        projectPath: String,
        status: String,
    ) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: projectPath,
            workerId: "worker-1",
            ideaId: "idea-1",
            worktreeName: "delegation-worker-1",
            worktreePath: "\(projectPath)/.capacitor/worktrees/delegation-worker-1",
            sessionId: "session-1",
            status: try! DelegationStatus.decode(wire: status),
            startedAt: "2027-01-15T07:45:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
            currentReview: RuntimeDelegationReview(
                milestoneId: "milestone-1",
                briefPath: "\(projectPath)/brief.md",
                manifestPath: "\(projectPath)/manifest.json",
                requestedAt: "2027-01-15T08:00:00Z",
            ),
        )
    }

    private func runsByID(_ runs: [RuntimeRunState]) -> [RuntimeRunKey: RuntimeRunState] {
        Dictionary(uniqueKeysWithValues: runs.map { (RuntimeRunKey(run: $0), $0) })
    }
}
