@testable import Capacitor
import XCTest

final class AccessibilityIdentifiersTests: XCTestCase {
    func testIdeaDetailAccessibilityIdentifiersRemainStable() {
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailIdentifier, "ax.idea-detail")
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailDismissIdentifier, "ax.idea-detail.dismiss")
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailDelegateIdentifier, "ax.idea-detail.delegate")
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailRemoveIdentifier, "ax.idea-detail.remove")
    }
}
