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
           delegationState.status == .reviewNeeded || delegationState.status == .resumeFailed
        {
            return .openDelegationReview
        }

        return .openTerminal
    }
}
