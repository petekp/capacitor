@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchProjectPrimaryActionResolverTests: XCTestCase {
    func testFallsBackToLegacyTerminalWhenProjectHasNoBatches() {
        XCTAssertEqual(
            WorkBatchProjectPrimaryActionResolver.resolve([]),
            .legacyTerminal,
        )
    }

    func testOpensCheckpointBatchFirst() {
        let batches = [
            projection(id: "batch-idle", status: .idle, binding: binding(batchID: "batch-idle")),
            projection(
                id: "batch-checkpoint",
                status: .waiting,
                checkpoints: [checkpoint(id: "checkpoint-1")],
                binding: binding(batchID: "batch-checkpoint"),
            ),
        ]

        XCTAssertEqual(
            WorkBatchProjectPrimaryActionResolver.resolve(batches),
            .openWorkBatch(batchID: "batch-checkpoint"),
        )
    }

    func testOpensSingleActiveBoundBatch() {
        let batches = [
            projection(id: "batch-active", status: .working, binding: binding(batchID: "batch-active")),
            projection(id: "batch-idle", status: .idle, binding: binding(batchID: "batch-idle")),
        ]

        XCTAssertEqual(
            WorkBatchProjectPrimaryActionResolver.resolve(batches),
            .openWorkBatch(batchID: "batch-active"),
        )
    }

    func testShowsProjectDetailWhenMultipleActiveBatchesCouldBeCorrect() {
        let batches = [
            projection(id: "batch-a", status: .working, binding: binding(batchID: "batch-a")),
            projection(id: "batch-b", status: .waiting, binding: binding(batchID: "batch-b")),
        ]

        XCTAssertEqual(
            WorkBatchProjectPrimaryActionResolver.resolve(batches),
            .showProjectDetail,
        )
    }

    func testOpensSingleIdleBoundBatchForFollowUpContinuity() {
        let batches = [
            projection(id: "batch-complete", status: .idle, binding: binding(batchID: "batch-complete")),
        ]

        XCTAssertEqual(
            WorkBatchProjectPrimaryActionResolver.resolve(batches),
            .openWorkBatch(batchID: "batch-complete"),
        )
    }

    func testShowsProjectDetailForUnboundActiveBatchInsteadOfLegacyTmux() {
        let batches = [
            projection(id: "batch-launching", status: .working, binding: nil),
        ]

        XCTAssertEqual(
            WorkBatchProjectPrimaryActionResolver.resolve(batches),
            .showProjectDetail,
        )
    }

    private func projection(
        id: String,
        status: WorkBatchStatus,
        checkpoints: [WorkBatchCheckpointRecord] = [],
        binding: WorkBatchCockpitBinding?,
    ) -> WorkBatchProjection {
        WorkBatchProjection(
            id: id,
            name: id,
            status: status,
            queuedTaskCount: status == .working ? 1 : 0,
            currentActivitySummary: "Summary",
            tasks: [],
            checkpoints: checkpoints,
            binding: binding,
        )
    }

    private func binding(batchID: String) -> WorkBatchCockpitBinding {
        WorkBatchCockpitBinding(
            id: batchID,
            batchID: batchID,
            batchName: batchID,
            projectPath: "/tmp/project",
            worktreeName: batchID,
            worktreePath: "/tmp/project/.capacitor/worktrees/\(batchID)",
            host: .claudeCode,
            claudeSessionID: "session-\(batchID)",
            status: .running,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_775_000_000),
        )
    }

    private func checkpoint(id: String) -> WorkBatchCheckpointRecord {
        WorkBatchCheckpointRecord(
            id: id,
            batchID: "batch-checkpoint",
            taskID: "task-1",
            question: "Choose direction?",
            reason: "The worker needs direction before continuing.",
            recommendedAction: nil,
            status: .pending,
            requestedAt: Date(timeIntervalSince1970: 1_775_000_000),
            respondedAt: nil,
            response: nil,
            updatedAt: Date(timeIntervalSince1970: 1_775_000_000),
        )
    }
}
