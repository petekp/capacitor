@testable import Capacitor
import XCTest

final class RunCheckpointTimelineSectionTests: XCTestCase {
    func testCountAccessibilityLabelUsesSingularAndPluralCheckpointCopy() {
        XCTAssertEqual(
            RunCheckpointTimelineAccessibility.sectionCountLabel(entryCount: 1),
            "1 checkpoint",
        )
        XCTAssertEqual(
            RunCheckpointTimelineAccessibility.sectionCountLabel(entryCount: 2),
            "2 checkpoints",
        )
    }

    func testRowAccessibilityLabelIncludesDecisionPhaseRoundKindTimestampAndNote() {
        let entry = RunCheckpointTimelineProjection.Entry(
            id: "gate-review#history-3",
            checkpointID: "gate-review",
            source: .archived,
            phaseID: "phase-001",
            phaseName: "Execute",
            phaseRoundNumber: 2,
            kindLabel: "Implementation",
            title: "Review checkpoint",
            summary: "Summary is visible but not repeated in the combined label.",
            decisionState: .changesRequested,
            decisionNote: "Needs another pass",
            createdAt: "2026-03-26T10:00:00Z",
            decidedAt: "not-a-date",
            timestampRole: .decided,
        )

        XCTAssertEqual(
            RunCheckpointTimelineAccessibility.rowLabel(for: entry),
            "Review checkpoint, Changes requested, Execute, round 2, Implementation, Decided not-a-date, note: Needs another pass",
        )
    }
}
