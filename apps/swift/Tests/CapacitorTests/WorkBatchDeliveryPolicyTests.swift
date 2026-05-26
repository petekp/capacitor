@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchDeliveryPolicyTests: XCTestCase {
    func testHealthyRunningBindingWakesExactLiveSession() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(bindingStatus: .running, exactLiveSessionExists: true)),
            .wakeExistingSession,
        )
    }

    func testLaunchingBindingQueuesOnly() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(bindingStatus: .launching, exactLiveSessionExists: true)),
            .queueOnly,
        )
    }

    func testStaleBindingResumesExistingSession() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(bindingStatus: .stale, exactLiveSessionExists: false)),
            .resumeExistingSession,
        )
    }

    func testWaitingBindingResumesExistingSessionWhenNoPendingCheckpoint() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(bindingStatus: .waiting, exactLiveSessionExists: false)),
            .resumeExistingSession,
        )
    }

    func testDoneBindingWithOpenTaskResumesExistingSession() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(bindingStatus: .done, exactLiveSessionExists: false)),
            .resumeExistingSession,
        )
    }

    func testRecoverableBindingWithExactLiveSessionWakesInPlace() {
        for status in [WorkBatchCockpitBindingStatus.stale, .waiting, .done] {
            XCTAssertEqual(
                WorkBatchDeliveryPolicy.decide(input(bindingStatus: status, exactLiveSessionExists: true)),
                .wakeExistingSession,
                "Expected \(status) with an exact live Claude process to wake in place.",
            )
        }
    }

    func testCurrentGenerationWakeAttemptSuppressesRepeatedWake() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(
                bindingStatus: .running,
                exactLiveSessionExists: true,
                deliveryRecord: WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: Self.now,
                    lastDeliveryGeneration: "batch-mobile:now",
                    lastDeliveryAttemptAt: Self.now,
                    lastDeliveryAttemptKind: WorkBatchDeliveryAction.wakeExistingSession.rawValue,
                    lastClaimAt: nil,
                ),
            )),
            .queueOnly,
        )
    }

    func testPendingCheckpointWaitsForCheckpoint() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(
                bindingStatus: .running,
                exactLiveSessionExists: true,
                checkpoints: [checkpoint(status: .pending)],
            )),
            .waitForCheckpoint,
        )
    }

    func testDuplicateCockpitWaits() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(
                bindingStatus: .running,
                exactLiveSessionExists: true,
                issues: [
                    WorkBatchBindingReconciliationIssue(
                        kind: .duplicateCockpit,
                        batchID: "batch-mobile",
                        sessionIDs: ["assigned-session", "manual-session"],
                        message: "Duplicate",
                    ),
                ],
            )),
            .waitForDuplicateCockpit,
        )
    }

    func testMirrorFailureWaitsWithoutResume() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(
                bindingStatus: .stale,
                exactLiveSessionExists: false,
                mirrorWriteSucceeded: false,
            )),
            .waitForDeliveryFailure,
        )
    }

    func testNoBindingStartsNewSession() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(bindingStatus: nil, exactLiveSessionExists: false)),
            .startNewSession,
        )
    }

    func testExistingDeliveryAttemptSuppressesRepeatedResume() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(
                bindingStatus: .stale,
                exactLiveSessionExists: false,
                deliveryRecord: WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: Self.now,
                    lastDeliveryGeneration: "batch-mobile:now",
                    lastDeliveryAttemptAt: Self.now,
                    lastDeliveryAttemptKind: WorkBatchDeliveryAction.resumeExistingSession.rawValue,
                    lastClaimAt: nil,
                ),
            )),
            .safeWakeDeferred,
        )
    }

    func testOlderDeliveryAttemptDoesNotSuppressNewGeneration() {
        XCTAssertEqual(
            WorkBatchDeliveryPolicy.decide(input(
                bindingStatus: .stale,
                exactLiveSessionExists: false,
                deliveryRecord: WorkBatchDeliveryRecord(
                    batchID: "batch-mobile",
                    lastContextWrittenAt: Self.now,
                    lastDeliveryGeneration: "batch-mobile:now",
                    lastDeliveryAttemptAt: Self.now.addingTimeInterval(-60),
                    lastDeliveryAttemptKind: WorkBatchDeliveryAction.resumeExistingSession.rawValue,
                    lastClaimAt: nil,
                ),
            )),
            .resumeExistingSession,
        )
    }

    private static let now = Date(timeIntervalSince1970: 1_775_000_000)

    private func input(
        bindingStatus: WorkBatchCockpitBindingStatus?,
        exactLiveSessionExists: Bool,
        mirrorWriteSucceeded: Bool = true,
        checkpoints: [WorkBatchCheckpointRecord] = [],
        issues: [WorkBatchBindingReconciliationIssue] = [],
        deliveryRecord: WorkBatchDeliveryRecord? = nil,
    ) -> WorkBatchDeliveryPolicyInput {
        WorkBatchDeliveryPolicyInput(
            batchID: "batch-mobile",
            tasks: [
                WorkBatchTaskRecord(
                    id: "task-green",
                    sourceIdeaID: "task-green",
                    title: "Add green border",
                    body: "",
                    status: .queued,
                    batchID: "batch-mobile",
                    createdAt: Self.now,
                    updatedAt: Self.now,
                ),
            ],
            checkpoints: checkpoints,
            binding: bindingStatus.map { status in
                WorkBatchCockpitBinding(
                    id: "batch-mobile",
                    batchID: "batch-mobile",
                    batchName: "Mobile prototype",
                    projectPath: "/tmp/project",
                    worktreeName: "batch-mobile",
                    worktreePath: "/tmp/project/.capacitor/worktrees/batch-mobile",
                    host: .claudeCode,
                    claudeSessionID: "assigned-session",
                    status: status,
                    createdAt: Self.now,
                    updatedAt: Self.now,
                )
            },
            reconciliationIssues: issues,
            mirrorWriteSucceeded: mirrorWriteSucceeded,
            exactLiveSessionExists: exactLiveSessionExists,
            deliveryRecord: deliveryRecord,
        )
    }

    private func checkpoint(status: WorkBatchCheckpointStatus) -> WorkBatchCheckpointRecord {
        WorkBatchCheckpointRecord(
            id: "checkpoint-green",
            batchID: "batch-mobile",
            taskID: "task-green",
            question: "Which green?",
            reason: "There are multiple tokens.",
            recommendedAction: nil,
            status: status,
            requestedAt: Self.now,
            respondedAt: nil,
            response: nil,
            updatedAt: Self.now,
        )
    }
}
