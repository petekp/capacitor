import Foundation

enum WorkBatchDeliveryAction: String, Equatable {
    case queueOnly = "queue_only"
    case startNewSession = "start_new_session"
    case resumeExistingSession = "resume_existing_session"
    case wakeExistingSession = "wake_existing_session"
    case waitForCheckpoint = "wait_for_checkpoint"
    case waitForDuplicateCockpit = "wait_for_duplicate_cockpit"
    case waitForDeliveryFailure = "wait_for_delivery_failure"
    case safeWakeDeferred = "safe_wake_deferred"
}

struct WorkBatchDeliveryPolicyInput: Equatable {
    let batchID: String
    let tasks: [WorkBatchTaskRecord]
    let checkpoints: [WorkBatchCheckpointRecord]
    let binding: WorkBatchCockpitBinding?
    let reconciliationIssues: [WorkBatchBindingReconciliationIssue]
    let mirrorWriteSucceeded: Bool
    let exactLiveSessionExists: Bool
    let deliveryRecord: WorkBatchDeliveryRecord?
}

enum WorkBatchDeliveryPolicy {
    static func decide(_ input: WorkBatchDeliveryPolicyInput) -> WorkBatchDeliveryAction {
        guard input.mirrorWriteSucceeded else {
            return .waitForDeliveryFailure
        }

        if input.checkpoints.contains(where: { $0.status == .pending }) {
            return .waitForCheckpoint
        }

        if input.reconciliationIssues.contains(where: {
            $0.batchID == input.batchID && $0.kind == .duplicateCockpit
        }) {
            return .waitForDuplicateCockpit
        }

        guard let binding = input.binding else {
            return .startNewSession
        }

        let hasOpenTasks = input.tasks.contains { $0.status != .done }
        guard hasOpenTasks else {
            return .queueOnly
        }

        switch binding.status {
        case .stale, .waiting, .done:
            if input.exactLiveSessionExists {
                return alreadyAttemptedCurrentGeneration(input.deliveryRecord)
                    ? .queueOnly
                    : .wakeExistingSession
            }
            if alreadyAttemptedCurrentGeneration(input.deliveryRecord) {
                return .safeWakeDeferred
            }
            return .resumeExistingSession
        case .launching:
            return .queueOnly
        case .running:
            guard input.exactLiveSessionExists else {
                return .safeWakeDeferred
            }
            return alreadyAttemptedCurrentGeneration(input.deliveryRecord)
                ? .queueOnly
                : .wakeExistingSession
        }
    }

    private static func alreadyAttemptedCurrentGeneration(_ record: WorkBatchDeliveryRecord?) -> Bool {
        guard let record,
              let lastContextWrittenAt = record.lastContextWrittenAt,
              let lastDeliveryAttemptAt = record.lastDeliveryAttemptAt
        else {
            return false
        }
        let attemptedKinds = [
            WorkBatchDeliveryAction.resumeExistingSession.rawValue,
            WorkBatchDeliveryAction.wakeExistingSession.rawValue,
        ]
        return attemptedKinds.contains(record.lastDeliveryAttemptKind ?? "") &&
            lastDeliveryAttemptAt >= lastContextWrittenAt
    }
}
