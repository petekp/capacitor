import Foundation

enum OperatorAttentionPrimaryAction: Equatable {
    case defaultProjectAction
    case openDelegationReview
    case openRunCheckpointReview(projectPath: String, runID: String, checkpointID: String)
    case openReceiptProof
}

enum OperatorAttentionPrimaryActionResolver {
    static func resolve(
        attentionItem: OperatorAttentionItem?,
        delegationState: RuntimeDelegationState?,
        isDelegationEnabled: Bool,
    ) -> OperatorAttentionPrimaryAction {
        guard let attentionItem else {
            return .defaultProjectAction
        }

        switch attentionItem.kind {
        case .checkpoint:
            if case let .checkpoint(runID, checkpointID, projectPath) = attentionItem.target {
                return .openRunCheckpointReview(
                    projectPath: projectPath,
                    runID: runID,
                    checkpointID: checkpointID,
                )
            }
            return .defaultProjectAction

        case .delegationReview:
            let projectAction = ProjectPrimaryActionResolver.resolve(
                delegationState: delegationState,
                isDelegationEnabled: isDelegationEnabled,
            )
            return projectAction == .openDelegationReview ? .openDelegationReview : .defaultProjectAction

        case .completedReceipt, .failedReceipt:
            if case .receiptProof = attentionItem.target {
                return .openReceiptProof
            }
            return .defaultProjectAction

        case .completedRun,
             .failedRun,
             .runningRun,
             .runningReceipt,
             .runningSession,
             .staleRun,
             .staleSession,
             .dormantProject:
            return .defaultProjectAction
        }
    }
}
