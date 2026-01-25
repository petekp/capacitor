@testable import Capacitor
import XCTest

final class ProjectIngestionWorkerTests: XCTestCase {
    func testSuggestParentDecisionFlagsFailureWithSuggestedName() {
        let result = ValidationResultFfi(
            resultType: "suggest_parent",
            path: "/tmp/project/subdir",
            suggestedPath: "/tmp/project",
            reason: nil,
            hasClaudeMd: false,
            hasOtherMarkers: true,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/project/subdir", result: result)

        switch decision {
        case let .failed(name):
            XCTAssertEqual(name, "subdir (use project)")
        default:
            XCTFail("Expected failed decision for suggest_parent")
        }
    }

    func testNotAProjectDecisionFlagsFailureWithReason() {
        let result = ValidationResultFfi(
            resultType: "not_a_project",
            path: "/tmp/empty",
            suggestedPath: nil,
            reason: "No markers",
            hasClaudeMd: false,
            hasOtherMarkers: false,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/empty", result: result)

        switch decision {
        case let .failed(name):
            XCTAssertEqual(name, "empty (not a project)")
        default:
            XCTFail("Expected failed decision for not_a_project")
        }
    }

    func testAlreadyTrackedDecisionReturnsTrackedPath() {
        let result = ValidationResultFfi(
            resultType: "already_tracked",
            path: "/tmp/project",
            suggestedPath: nil,
            reason: nil,
            hasClaudeMd: true,
            hasOtherMarkers: true,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/project", result: result)

        switch decision {
        case let .alreadyTracked(path):
            XCTAssertEqual(path, "/tmp/project")
        default:
            XCTFail("Expected alreadyTracked decision")
        }
    }

    func testValidDecisionAddsPath() {
        let result = ValidationResultFfi(
            resultType: "valid",
            path: "/tmp/project",
            suggestedPath: nil,
            reason: nil,
            hasClaudeMd: true,
            hasOtherMarkers: true,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/project", result: result)

        switch decision {
        case let .add(path):
            XCTAssertEqual(path, "/tmp/project")
        default:
            XCTFail("Expected add decision for valid project")
        }
    }
}
