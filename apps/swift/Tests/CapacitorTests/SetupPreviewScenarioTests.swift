@testable import Capacitor
import XCTest

final class SetupPreviewScenarioTests: XCTestCase {
    func testEveryPreviewScenarioUsesCanonicalStepOrder() {
        for scenario in SetupPreviewScenario.allCases {
            XCTAssertEqual(
                scenario.steps.map(\.id),
                [.claude, .hooks, .shell],
                "Scenario \(scenario.rawValue) should preserve canonical setup step order",
            )
        }
    }

    func testHooksPolicyBlockedScenarioUsesPolicyBlockedStatus() {
        let hooksStep = SetupPreviewScenario.hooksPolicyBlocked.steps[1]
        XCTAssertEqual(
            hooksStep.status,
            HookPresentationPolicy.setupStepStatus(for: .policyBlocked(reason: "preview")),
        )
    }
}
