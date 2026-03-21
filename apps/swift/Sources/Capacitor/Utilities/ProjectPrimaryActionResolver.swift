import Foundation

enum ProjectPrimaryAction: Equatable {
    case openTerminal
    case openDelegationReview
}

enum ProjectPrimaryActionResolver {
    static func resolve(
        delegationState: RuntimeDelegationState?,
        isDelegationEnabled: Bool,
    ) -> ProjectPrimaryAction {
        guard isDelegationEnabled else {
            return .openTerminal
        }

        if let delegationState,
           delegationState.currentReview != nil,
           delegationState.status == "review_needed" || delegationState.status == "resume_failed"
        {
            return .openDelegationReview
        }

        return .openTerminal
    }
}
