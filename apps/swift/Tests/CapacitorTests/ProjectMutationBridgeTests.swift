@testable import Capacitor
import XCTest

final class ProjectMutationBridgeTests: XCTestCase {
    func testValidationResultMapsIntoShellDto() {
        let ffiResult = ValidationResultFfi(
            resultType: "suggest_parent",
            path: "/tmp/project/subdir",
            suggestedPath: "/tmp/project",
            reason: "Use project root",
            hasClaudeMd: false,
            hasOtherMarkers: true,
        )

        let shellResult = ProjectMutationBridge.validationResult(from: ffiResult)

        XCTAssertEqual(shellResult.kind, .suggestParent)
        XCTAssertEqual(shellResult.path, "/tmp/project/subdir")
        XCTAssertEqual(shellResult.suggestedPath, "/tmp/project")
        XCTAssertEqual(shellResult.reason, "Use project root")
        XCTAssertFalse(shellResult.hasClaudeMd)
        XCTAssertTrue(shellResult.hasOtherMarkers)
    }

    func testUnknownValidationResultFallsBackToUnknownKind() {
        let ffiResult = ValidationResultFfi(
            resultType: "mystery",
            path: "/tmp/project",
            suggestedPath: nil,
            reason: nil,
            hasClaudeMd: false,
            hasOtherMarkers: false,
        )

        let shellResult = ProjectMutationBridge.validationResult(from: ffiResult)

        XCTAssertEqual(shellResult.kind, .unknown)
    }
}
