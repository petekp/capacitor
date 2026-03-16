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
        guard isDelegationEnabled,
              delegationState?.status == "review_needed",
              delegationState?.currentReview != nil
        else {
            return .openTerminal
        }

        return .openDelegationReview
    }
}
