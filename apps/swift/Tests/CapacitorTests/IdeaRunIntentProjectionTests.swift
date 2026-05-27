@testable import Capacitor
import XCTest

final class IdeaRunIntentProjectionTests: XCTestCase {
    func testProjectsIdeaTitleAndSuccessCriteriaIntoRunIntent() {
        let idea = makeIdea(
            title: "Improve checkpoint evidence packets",
            description: """
            Success means: I can approve or reject without reading the diff first.

            Keep the top layer conceptual.
            """,
        )

        let intent = IdeaRunIntent.project(idea)

        XCTAssertEqual(intent.intent, "Improve checkpoint evidence packets")
        XCTAssertEqual(intent.successCriteria, "I can approve or reject without reading the diff first.")
        XCTAssertEqual(
            intent.sourceText,
            """
            Improve checkpoint evidence packets

            Success means: I can approve or reject without reading the diff first.

            Keep the top layer conceptual.
            """,
        )
    }

    func testKeepsSuccessCriteriaOptionalForPlainCapturedIdeas() {
        let idea = makeIdea(
            title: "Tighten the receipt loop",
            description: "Make the ordinary path less debug-shaped.",
        )

        let intent = IdeaRunIntent.project(idea)

        XCTAssertEqual(intent.intent, "Tighten the receipt loop")
        XCTAssertNil(intent.successCriteria)
        XCTAssertEqual(
            intent.sourceText,
            """
            Tighten the receipt loop

            Make the ordinary path less debug-shaped.
            """,
        )
    }

    private func makeIdea(
        title: String,
        description: String,
    ) -> Idea {
        Idea(
            id: "idea-new-intent",
            title: title,
            description: description,
            added: "2026-05-24T12:00:00Z",
            effort: "small",
            status: "open",
            triage: "pending",
            related: nil,
        )
    }
}
