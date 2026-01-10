import SwiftUI

extension AnyTransition {
    static func slide(direction: NavigationDirection) -> AnyTransition {
        switch direction {
        case .push:
            return .push(from: .trailing)
        case .pop:
            return .push(from: .leading)
        }
    }
}
