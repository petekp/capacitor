@testable import Capacitor
import XCTest

final class OperatorAttentionPrimaryActionResolverTests: XCTestCase {
    func testCheckpointRecommendationOpensCheckpointReviewTarget() {
        let item = attentionItem(
            kind: .checkpoint,
            target: .checkpoint(
                runID: "run-1",
                checkpointID: "checkpoint-1",
                projectPath: "/tmp/project",
            ),
        )

        let action = OperatorAttentionPrimaryActionResolver.resolve(
            attentionItem: item,
            delegationState: nil,
            isDelegationEnabled: true,
        )

        XCTAssertEqual(
            action,
            .openRunCheckpointReview(
                projectPath: "/tmp/project",
                runID: "run-1",
                checkpointID: "checkpoint-1",
            ),
        )
    }

    func testDelegationReviewRecommendationOpensDelegationReviewWhenEnabled() {
        let action = OperatorAttentionPrimaryActionResolver.resolve(
            attentionItem: attentionItem(kind: .delegationReview),
            delegationState: delegation(status: "review_needed"),
            isDelegationEnabled: true,
        )

        XCTAssertEqual(action, .openDelegationReview)
    }

    func testDelegationReviewRecommendationFallsBackWhenDelegationDisabled() {
        let action = OperatorAttentionPrimaryActionResolver.resolve(
            attentionItem: attentionItem(kind: .delegationReview),
            delegationState: delegation(status: "review_needed"),
            isDelegationEnabled: false,
        )

        XCTAssertEqual(action, .defaultProjectAction)
    }

    func testCompletedReceiptRecommendationOpensReceiptProof() {
        let action = OperatorAttentionPrimaryActionResolver.resolve(
            attentionItem: attentionItem(
                kind: .completedReceipt,
                target: .receiptProof(runID: "receipt-run-1", projectPath: "/tmp/project"),
            ),
            delegationState: nil,
            isDelegationEnabled: true,
        )

        XCTAssertEqual(action, .openReceiptProof)
    }

    func testFailedReceiptRecommendationOpensReceiptProof() {
        let action = OperatorAttentionPrimaryActionResolver.resolve(
            attentionItem: attentionItem(
                kind: .failedReceipt,
                target: .receiptProof(runID: "receipt-run-1", projectPath: "/tmp/project"),
            ),
            delegationState: nil,
            isDelegationEnabled: true,
        )

        XCTAssertEqual(action, .openReceiptProof)
    }

    func testReceiptRecommendationKeepsDefaultActionWhenProofIsNotRenderable() {
        let action = OperatorAttentionPrimaryActionResolver.resolve(
            attentionItem: attentionItem(
                kind: .completedReceipt,
                target: .run(id: "receipt-run-1", projectPath: "/tmp/project"),
            ),
            delegationState: nil,
            isDelegationEnabled: true,
        )

        XCTAssertEqual(action, .defaultProjectAction)
    }

    func testRunningAndDormantItemsKeepDefaultProjectAction() {
        XCTAssertEqual(
            OperatorAttentionPrimaryActionResolver.resolve(
                attentionItem: attentionItem(kind: .runningRun),
                delegationState: nil,
                isDelegationEnabled: true,
            ),
            .defaultProjectAction,
        )
        XCTAssertEqual(
            OperatorAttentionPrimaryActionResolver.resolve(
                attentionItem: attentionItem(kind: .runningWorkBatch),
                delegationState: nil,
                isDelegationEnabled: true,
            ),
            .defaultProjectAction,
        )
        XCTAssertEqual(
            OperatorAttentionPrimaryActionResolver.resolve(
                attentionItem: attentionItem(kind: .workBatchCheckpoint),
                delegationState: nil,
                isDelegationEnabled: true,
            ),
            .defaultProjectAction,
        )
        XCTAssertEqual(
            OperatorAttentionPrimaryActionResolver.resolve(
                attentionItem: attentionItem(kind: .waitingWorkBatch),
                delegationState: nil,
                isDelegationEnabled: true,
            ),
            .defaultProjectAction,
        )
        XCTAssertEqual(
            OperatorAttentionPrimaryActionResolver.resolve(
                attentionItem: attentionItem(kind: .dormantProject),
                delegationState: nil,
                isDelegationEnabled: true,
            ),
            .defaultProjectAction,
        )
    }

    private func attentionItem(
        kind: OperatorAttentionItem.Kind,
        target: OperatorAttentionTarget = .project(path: "/tmp/project"),
    ) -> OperatorAttentionItem {
        OperatorAttentionItem(
            id: "\(kind)",
            kind: kind,
            projectPath: "/tmp/project",
            title: "Project",
            reason: "Reason",
            ageLabel: nil,
            recommendedAction: nil,
            target: target,
        )
    }

    private func delegation(status: String) -> RuntimeDelegationState {
        RuntimeDelegationState(
            projectPath: "/tmp/project",
            workerId: "worker-1",
            ideaId: "idea-1",
            worktreeName: "delegation-worker-1",
            worktreePath: "/tmp/project/.capacitor/worktrees/delegation-worker-1",
            sessionId: "session-1",
            status: try! DelegationStatus.decode(wire: status),
            startedAt: "2027-01-15T07:45:00Z",
            updatedAt: "2027-01-15T08:00:00Z",
            currentReview: RuntimeDelegationReview(
                milestoneId: "milestone-1",
                briefPath: "/tmp/project/brief.md",
                manifestPath: "/tmp/project/manifest.json",
                requestedAt: "2027-01-15T08:00:00Z",
            ),
        )
    }
}
