@testable import Capacitor
import XCTest

@MainActor
final class SetupRequirementsManagerTests: XCTestCase {
    func testExecuteStepShellShowsShellInstructions() async {
        let manager = SetupRequirementsManager.preview(.allPending)

        XCTAssertFalse(manager.showShellInstructions)
        await manager.executeStep(.shell)
        XCTAssertTrue(manager.showShellInstructions)
    }

    func testExecuteStepClaudeDoesNotShowShellInstructions() async {
        let manager = SetupRequirementsManager.preview(.allPending)

        XCTAssertFalse(manager.showShellInstructions)
        await manager.executeStep(.claude)
        XCTAssertFalse(manager.showShellInstructions)
    }
}
