@testable import Capacitor
import XCTest

final class AccessibilityIdentifiersTests: XCTestCase {
    func testIdeaDetailAccessibilityIdentifiersRemainStable() {
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailIdentifier, "ax.idea-detail")
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailDismissIdentifier, "ax.idea-detail.dismiss")
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailDelegateIdentifier, "ax.idea-detail.delegate")
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailReviewIdentifier, "ax.idea-detail.review")
        XCTAssertEqual(AccessibilityIdentifiers.ideaDetailRemoveIdentifier, "ax.idea-detail.remove")
    }

    func testRunCheckpointAccessibilityIdentifiersRemainStable() {
        XCTAssertEqual(AccessibilityIdentifiers.runCheckpointReviewIdentifier, "ax.run-checkpoint-review")
        XCTAssertEqual(AccessibilityIdentifiers.runCheckpointApproveIdentifier, "ax.run-checkpoint-review.approve")
        XCTAssertEqual(
            AccessibilityIdentifiers.runCheckpointRequestChangesIdentifier,
            "ax.run-checkpoint-review.request-changes",
        )
        XCTAssertEqual(AccessibilityIdentifiers.runCheckpointNotesIdentifier, "ax.run-checkpoint-review.notes")
        XCTAssertEqual(AccessibilityIdentifiers.runCheckpointTimelineIdentifier, "ax.run-checkpoint-timeline")
    }

    func testProjectDetailViewIdentifierIsDistinctFromDockNavigationIdentifier() {
        let project = Project(
            name: "Capacitor",
            path: "/Users/petepetrash/Code/capacitor",
            displayPath: "/Users/petepetrash/Code/capacitor",
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )

        XCTAssertEqual(
            AccessibilityIdentifiers.projectDetailsIdentifier(for: project),
            "ax.project-details.capacitor",
        )
        XCTAssertEqual(
            AccessibilityIdentifiers.projectDetailViewIdentifier(for: project),
            "ax.project-detail-view.capacitor",
        )
        XCTAssertNotEqual(
            AccessibilityIdentifiers.projectDetailsIdentifier(for: project),
            AccessibilityIdentifiers.projectDetailViewIdentifier(for: project),
        )
    }
}
