import SwiftUI

enum IdeaQueueMetrics {
    static func isQueued(_ idea: Idea) -> Bool {
        idea.status != "done"
    }

    static func queuedCount(in ideas: [Idea]) -> Int {
        ideas.reduce(0) { count, idea in
            count + (isQueued(idea) ? 1 : 0)
        }
    }
}

enum IdeaQueueActivity: Equatable {
    case generatingTitle
    case delegationWorking
    case reviewReady
    case methodRunning(phaseName: String?)
    case methodCheckpointReady
    case inProgress

    var label: String {
        switch self {
        case .generatingTitle:
            "Generating title"
        case .delegationWorking:
            "Delegated and working"
        case .reviewReady:
            "Ready for review"
        case let .methodRunning(phaseName):
            if let phaseName {
                "Running: \(phaseName)"
            } else {
                "Method running"
            }
        case .methodCheckpointReady:
            "Checkpoint ready"
        case .inProgress:
            "In progress"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .generatingTitle:
            "Generating title"
        case .delegationWorking:
            "Delegated and working"
        case .reviewReady:
            "Delegation review ready"
        case .methodRunning:
            "Method run in progress"
        case .methodCheckpointReady:
            "Method checkpoint ready for review"
        case .inProgress:
            "In progress"
        }
    }

    var tint: Color {
        switch self {
        case .generatingTitle, .delegationWorking, .methodRunning:
            .statusWorking
        case .reviewReady, .methodCheckpointReady:
            .orange.opacity(0.95)
        case .inProgress:
            .hudAccent
        }
    }

    var showsProgress: Bool {
        switch self {
        case .generatingTitle, .delegationWorking, .methodRunning:
            true
        case .reviewReady, .methodCheckpointReady, .inProgress:
            false
        }
    }

    var symbolName: String {
        switch self {
        case .reviewReady, .methodCheckpointReady:
            "checkmark.circle.fill"
        case .inProgress:
            "circle.fill"
        case .generatingTitle, .delegationWorking, .methodRunning:
            "circle.fill"
        }
    }

    var usesPlaceholderTitle: Bool {
        switch self {
        case .generatingTitle:
            true
        case .delegationWorking, .reviewReady, .methodRunning, .methodCheckpointReady, .inProgress:
            false
        }
    }
}

enum IdeaQueueStatusResolver {
    static func resolve(
        idea: Idea,
        isGeneratingTitle: Bool,
        delegationState: RuntimeDelegationState?,
        runState: RuntimeRunState?,
    ) -> IdeaQueueActivity? {
        if let delegationState, delegationState.ideaId == idea.id {
            if delegationState.status == "review_needed", delegationState.currentReview != nil {
                return .reviewReady
            }

            if delegationState.status == "resume_failed", delegationState.currentReview != nil {
                return .reviewReady
            }

            if delegationState.status == "working" || delegationState.status == "resume_pending" {
                return .delegationWorking
            }
        }

        if let runState, runState.ideaId == idea.id {
            if runState.status == "paused", runState.activeCheckpoint != nil {
                return .methodCheckpointReady
            }
            if runState.status == "active" || runState.status == "created" {
                let label = runState.statusMessage ?? runState.methodName
                return .methodRunning(phaseName: label)
            }
        }

        if isGeneratingTitle {
            return .generatingTitle
        }

        if idea.status == "in-progress" {
            return .inProgress
        }

        return nil
    }
}
