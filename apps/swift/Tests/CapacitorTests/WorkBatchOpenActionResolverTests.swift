@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchOpenActionResolverTests: XCTestCase {
    func testOpenActionAnswersNewestPendingCheckpointBeforeOpeningCockpit() throws {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let projection = try XCTUnwrap(WorkBatchProjectionBuilder.build(
            state: WorkBatchStateSnapshot(
                version: 1,
                batches: [
                    batch(status: .waiting, updatedAt: now),
                ],
                tasks: [
                    task(status: .needsYou, updatedAt: now),
                ],
                classifications: [],
                checkpoints: [
                    checkpoint(
                        id: "checkpoint-old",
                        status: .pending,
                        updatedAt: now,
                    ),
                    checkpoint(
                        id: "checkpoint-answered",
                        status: .answered,
                        updatedAt: now.addingTimeInterval(30),
                    ),
                    checkpoint(
                        id: "checkpoint-new",
                        status: .pending,
                        updatedAt: now.addingTimeInterval(60),
                    ),
                ],
            ),
            bindings: [binding()],
        ).first)

        XCTAssertEqual(projection.pendingCheckpoints.map(\.id), ["checkpoint-new", "checkpoint-old"])
        XCTAssertEqual(
            WorkBatchOpenActionResolver.resolve(projection),
            .answerCheckpoint(checkpoint(
                id: "checkpoint-new",
                status: .pending,
                updatedAt: now.addingTimeInterval(60),
            )),
        )
    }

    func testOpenActionUsesCockpitWhenNoCheckpointIsPending() {
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let projection = WorkBatchProjection(
            id: "batch-mobile",
            name: "Mobile prototype",
            status: .working,
            queuedTaskCount: 1,
            currentActivitySummary: "Claude Code is working.",
            tasks: [task(status: .queued, updatedAt: now)],
            checkpoints: [
                checkpoint(
                    id: "checkpoint-answered",
                    status: .answered,
                    updatedAt: now,
                ),
            ],
            binding: binding(),
        )

        XCTAssertEqual(WorkBatchOpenActionResolver.resolve(projection), .openCockpit)
    }

    private func batch(
        status: WorkBatchStatus,
        updatedAt: Date,
    ) -> WorkBatchRecord {
        WorkBatchRecord(
            id: "batch-mobile",
            name: "Mobile prototype",
            projectPath: "/tmp/project",
            status: status,
            currentActivitySummary: "Checkpoint ready.",
            taskIDs: ["task-green"],
            cockpitBindingID: "batch-mobile",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: updatedAt,
        )
    }

    private func task(
        status: WorkBatchTaskStatus,
        updatedAt: Date,
    ) -> WorkBatchTaskRecord {
        WorkBatchTaskRecord(
            id: "task-green",
            sourceIdeaID: "task-green",
            title: "Add green border",
            body: "",
            status: status,
            batchID: "batch-mobile",
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: updatedAt,
        )
    }

    private func checkpoint(
        id: String,
        status: WorkBatchCheckpointStatus,
        updatedAt: Date,
    ) -> WorkBatchCheckpointRecord {
        WorkBatchCheckpointRecord(
            id: id,
            batchID: "batch-mobile",
            taskID: "task-green",
            question: "Which green token should I use?",
            reason: "The Task did not say whether this is debug-only.",
            recommendedAction: nil,
            status: status,
            requestedAt: updatedAt,
            respondedAt: status == .answered ? updatedAt : nil,
            response: status == .answered ? "Use production green." : nil,
            updatedAt: updatedAt,
        )
    }

    private func binding() -> WorkBatchCockpitBinding {
        WorkBatchCockpitBinding(
            id: "batch-mobile",
            batchID: "batch-mobile",
            batchName: "Mobile prototype",
            projectPath: "/tmp/project",
            worktreeName: "batch-mobile",
            worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
            host: .claudeCode,
            claudeSessionID: "session-batch",
            status: .waiting,
            createdAt: Date(timeIntervalSince1970: 1_775_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_775_000_000),
        )
    }
}
