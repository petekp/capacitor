@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchBindingReconcilerTests: XCTestCase {
    func testExactLiveBatchSessionMarksBindingRunning() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        let result = WorkBatchBindingReconciler.reconcile(
            state: state(status: .waiting, summary: "Claude Code session needs reconnect."),
            bindings: [binding(status: .stale)],
            sessions: [
                runtimeSession(
                    sessionId: "session-batch",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                    isAlive: true,
                ),
            ],
            now: now,
        )

        XCTAssertEqual(result.bindings[0].status, .running)
        XCTAssertEqual(result.state.batches[0].status, .working)
        XCTAssertEqual(result.state.batches[0].currentActivitySummary, "Claude Code is working in Mobile prototype.")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMissingLiveSessionMarksBindingStaleAfterLaunchGrace() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        var inputState = state(status: .working, summary: "Claude Code is starting on Add green border.")
        inputState.tasks[0].status = .working
        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [binding(status: .launching, updatedAt: now.addingTimeInterval(-120))],
            sessions: [],
            now: now,
        )

        XCTAssertEqual(result.bindings[0].status, .stale)
        XCTAssertEqual(result.state.batches[0].status, .waiting)
        XCTAssertEqual(result.state.batches[0].currentActivitySummary, "Claude Code session needs reconnect.")
        XCTAssertEqual(result.state.tasks[0].status, .queued)
        XCTAssertEqual(result.issues.map(\.kind), [.missingCockpit])
    }

    func testRecentLaunchingBindingKeepsGraceWindow() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        let result = WorkBatchBindingReconciler.reconcile(
            state: state(status: .working, summary: "Claude Code is starting on Add green border."),
            bindings: [binding(status: .launching, updatedAt: now.addingTimeInterval(-20))],
            sessions: [],
            now: now,
        )

        XCTAssertEqual(result.bindings[0].status, .launching)
        XCTAssertEqual(result.state.batches[0].status, .working)
        XCTAssertEqual(result.state.batches[0].currentActivitySummary, "Claude Code is starting on Add green border.")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testManualRootSessionIsNotAdoptedAsBatchCockpit() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        let result = WorkBatchBindingReconciler.reconcile(
            state: state(status: .working, summary: "Claude Code is starting on Add green border."),
            bindings: [binding(status: .launching, updatedAt: now.addingTimeInterval(-120))],
            sessions: [
                runtimeSession(
                    sessionId: "manual-root",
                    cwd: "/tmp/project",
                    projectPath: "/tmp/project",
                    isAlive: true,
                ),
            ],
            now: now,
        )

        XCTAssertEqual(result.bindings[0].status, .stale)
        XCTAssertEqual(result.issues.map(\.kind), [.missingCockpit])
    }

    func testDifferentSessionInSameBatchWorktreeFlagsDuplicateInsteadOfAdopting() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        var inputState = state(status: .working, summary: "Adding green border.")
        inputState.tasks[0].status = .working
        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [binding(status: .running)],
            sessions: [
                runtimeSession(
                    sessionId: "session-batch",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                    isAlive: true,
                ),
                runtimeSession(
                    sessionId: "manual-duplicate",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile/src",
                    isAlive: true,
                ),
            ],
            now: now,
        )

        XCTAssertEqual(result.bindings[0].status, .waiting)
        XCTAssertEqual(result.state.batches[0].status, .waiting)
        XCTAssertEqual(result.state.batches[0].currentActivitySummary, "Multiple Claude Code sessions match this Work Batch.")
        XCTAssertEqual(result.state.tasks[0].status, .queued)
        XCTAssertEqual(result.issues.map(\.kind), [.duplicateCockpit])
    }

    func testHealthyRunningBindingDoesNotChurnTimestamps() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        let inputState = state(status: .working, summary: "Adding green border.")
        let inputBinding = binding(status: .running)

        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [inputBinding],
            sessions: [
                runtimeSession(
                    sessionId: "session-batch",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                    isAlive: true,
                ),
            ],
            now: now,
        )

        XCTAssertEqual(result.state, inputState)
        XCTAssertEqual(result.bindings, [inputBinding])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testDoneBindingStaysDoneWhenTerminalIsStillAliveAndAllTasksAreDone() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        var inputState = state(status: .idle, summary: "Done: Added green border.")
        inputState.tasks[0].status = .done
        let inputBinding = binding(status: .done)

        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [inputBinding],
            sessions: [
                runtimeSession(
                    sessionId: "session-batch",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                    isAlive: true,
                ),
            ],
            now: now,
        )

        XCTAssertEqual(result.state, inputState)
        XCTAssertEqual(result.bindings, [inputBinding])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testPendingCheckpointKeepsLiveBindingWaiting() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        var inputState = state(status: .waiting, summary: "Checkpoint ready: Which green token should I use?")
        inputState.tasks[0].status = .needsYou
        inputState.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-green-token",
                batchID: "batch-mobile",
                taskID: "task-green",
                question: "Which green token should I use?",
                reason: "The Task did not say whether this is debug-only.",
                recommendedAction: nil,
                status: .pending,
                requestedAt: now,
                respondedAt: nil,
                response: nil,
                updatedAt: now,
            ),
        ]
        let inputBinding = binding(status: .waiting, updatedAt: now)

        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [inputBinding],
            sessions: [
                runtimeSession(
                    sessionId: "session-batch",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                    isAlive: true,
                ),
            ],
            now: now.addingTimeInterval(60),
        )

        XCTAssertEqual(result.bindings[0].status, .waiting)
        XCTAssertEqual(result.state.batches[0].status, .waiting)
        XCTAssertEqual(result.state.batches[0].currentActivitySummary, "Checkpoint ready: Which green token should I use?")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testPendingCheckpointKeepsMissingBindingSummaryFocusedOnUserInput() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        var inputState = state(status: .waiting, summary: "Checkpoint ready: Which green token should I use?")
        inputState.tasks[0].status = .needsYou
        inputState.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-green-token",
                batchID: "batch-mobile",
                taskID: "task-green",
                question: "Which green token should I use?",
                reason: "The Task did not say whether this is debug-only.",
                recommendedAction: nil,
                status: .pending,
                requestedAt: now,
                respondedAt: nil,
                response: nil,
                updatedAt: now,
            ),
        ]

        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [binding(status: .running, updatedAt: now)],
            sessions: [],
            now: now.addingTimeInterval(60),
        )

        XCTAssertEqual(result.bindings[0].status, .stale)
        XCTAssertEqual(result.state.batches[0].status, .waiting)
        XCTAssertEqual(result.state.batches[0].currentActivitySummary, "Checkpoint ready: Which green token should I use?")
        XCTAssertEqual(result.state.tasks[0].status, .needsYou)
        XCTAssertEqual(result.issues.map(\.kind), [.missingCockpit])
    }

    func testPendingCheckpointReclaimsReconnectSummary() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        var inputState = state(status: .waiting, summary: "Claude Code session needs reconnect.")
        inputState.tasks[0].status = .needsYou
        inputState.checkpoints = [
            WorkBatchCheckpointRecord(
                id: "checkpoint-green-token",
                batchID: "batch-mobile",
                taskID: "task-green",
                question: "Which green token should I use?",
                reason: "The Task did not say whether this is debug-only.",
                recommendedAction: nil,
                status: .pending,
                requestedAt: now,
                respondedAt: nil,
                response: nil,
                updatedAt: now,
            ),
        ]

        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [binding(status: .stale, updatedAt: now)],
            sessions: [],
            now: now.addingTimeInterval(60),
        )

        XCTAssertEqual(result.bindings[0].status, .stale)
        XCTAssertEqual(result.state.batches[0].status, .waiting)
        XCTAssertEqual(result.state.batches[0].currentActivitySummary, "Checkpoint needs your input.")
        XCTAssertEqual(result.state.tasks[0].status, .needsYou)
        XCTAssertEqual(result.issues.map(\.kind), [.missingCockpit])
    }

    func testPersistentStaleBindingDoesNotChurnTimestamps() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        let inputState = state(status: .waiting, summary: "Claude Code session needs reconnect.")
        let inputBinding = binding(status: .stale)

        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [inputBinding],
            sessions: [],
            now: now,
        )

        XCTAssertEqual(result.state, inputState)
        XCTAssertEqual(result.bindings, [inputBinding])
        XCTAssertEqual(result.issues.map(\.kind), [.missingCockpit])
    }

    func testPersistentDuplicateBindingDoesNotChurnTimestamps() {
        let now = Date(timeIntervalSince1970: 1_775_000_200)
        let inputState = state(status: .waiting, summary: "Multiple Claude Code sessions match this Work Batch.")
        let inputBinding = binding(status: .waiting)

        let result = WorkBatchBindingReconciler.reconcile(
            state: inputState,
            bindings: [inputBinding],
            sessions: [
                runtimeSession(
                    sessionId: "session-batch",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile",
                    isAlive: true,
                ),
                runtimeSession(
                    sessionId: "manual-duplicate",
                    cwd: "/tmp/project/.capacitor/worktrees/batch-mobile/src",
                    isAlive: true,
                ),
            ],
            now: now,
        )

        XCTAssertEqual(result.state, inputState)
        XCTAssertEqual(result.bindings, [inputBinding])
        XCTAssertEqual(result.issues.map(\.kind), [.duplicateCockpit])
    }

    private func state(
        status: WorkBatchStatus,
        summary: String,
    ) -> WorkBatchStateSnapshot {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        return WorkBatchStateSnapshot(
            version: 1,
            batches: [
                WorkBatchRecord(
                    id: "batch-mobile",
                    name: "Mobile prototype",
                    projectPath: "/tmp/project",
                    status: status,
                    currentActivitySummary: summary,
                    taskIDs: ["task-green"],
                    cockpitBindingID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: now,
                    updatedAt: now,
                ),
            ],
            classifications: [],
        )
    }

    private func binding(
        status: WorkBatchCockpitBindingStatus,
        updatedAt: Date = Date(timeIntervalSince1970: 1_775_000_000),
    ) -> WorkBatchCockpitBinding {
        WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "session-batch",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: updatedAt,
        )
    }

    private func runtimeSession(
        sessionId: String,
        cwd: String,
        projectPath: String? = nil,
        isAlive: Bool?,
    ) -> RuntimeSession {
        RuntimeSession(
            sessionId: sessionId,
            pid: 1234,
            state: "working",
            cwd: cwd,
            projectId: nil,
            workspaceId: nil,
            projectPath: projectPath ?? cwd,
            updatedAt: "2026-05-25T00:00:00Z",
            stateChangedAt: "2026-05-25T00:00:00Z",
            lastEvent: nil,
            lastActivityAt: nil,
            toolsInFlight: nil,
            stateSource: nil,
            lastAuthoritativeEventAt: nil,
            gcReason: nil,
            isAlive: isAlive,
        )
    }
}
