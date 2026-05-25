@testable import Capacitor
import XCTest

final class MethodRunContextTests: XCTestCase {
    func testContextJSONObjectCarriesIntentAndSuccessCriteria() {
        let context = MethodRunContext(
            title: "Improve checkpoint evidence packets",
            description: "Keep raw diffs behind disclosure.",
            intent: "Improve checkpoint evidence packets",
            successCriteria: "I can approve or reject without reading the diff first.",
        )

        let object = context.jsonObject

        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["title"] as? String, "Improve checkpoint evidence packets")
        XCTAssertEqual(object["description"] as? String, "Keep raw diffs behind disclosure.")
        XCTAssertEqual(object["intent"] as? String, "Improve checkpoint evidence packets")
        XCTAssertEqual(object["success_criteria"] as? String, "I can approve or reject without reading the diff first.")
    }
}
