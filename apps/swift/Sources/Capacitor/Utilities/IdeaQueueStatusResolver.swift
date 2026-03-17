import SwiftUI

enum IdeaQueueActivity: Equatable {
    case generatingTitle
    case delegationWorking
    case reviewReady
    case inProgress

    var label: String {
        switch self {
        case .generatingTitle:
            "Generating title"
        case .delegationWorking:
            "Delegated and working"
        case .reviewReady:
            "Ready for review"
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
        case .inProgress:
            "In progress"
        }
    }

    var tint: Color {
        switch self {
        case .generatingTitle, .delegationWorking:
            .statusWorking
        case .reviewReady:
            .orange.opacity(0.95)
        case .inProgress:
            .hudAccent
        }
    }

    var showsProgress: Bool {
        switch self {
        case .generatingTitle, .delegationWorking:
            true
        case .reviewReady, .inProgress:
            false
        }
    }

    var symbolName: String {
        switch self {
        case .reviewReady:
            "checkmark.circle.fill"
        case .inProgress:
            "circle.fill"
        case .generatingTitle, .delegationWorking:
            "circle.fill"
        }
    }

    var usesPlaceholderTitle: Bool {
        switch self {
        case .generatingTitle:
            true
        case .delegationWorking, .reviewReady, .inProgress:
            false
        }
    }
}

enum IdeaQueueStatusResolver {
    static func resolve(
        idea: Idea,
        isGeneratingTitle: Bool,
        delegationState: RuntimeDelegationState?,
    ) -> IdeaQueueActivity? {
        if let delegationState, delegationState.ideaId == idea.id {
            if delegationState.status == "review_needed", delegationState.currentReview != nil {
                return .reviewReady
            }

            if delegationState.status == "working" {
                return .delegationWorking
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
