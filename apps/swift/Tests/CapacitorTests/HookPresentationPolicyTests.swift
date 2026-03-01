@testable import Capacitor
import XCTest

final class HookPresentationPolicyTests: XCTestCase {
    func testSetupCardHeaderScenariosMatchCanonicalContract() {
        struct Scenario {
            let label: String
            let issue: HookIssue?
            let isFirstRun: Bool
            let expected: String
        }

        let scenarios: [Scenario] = [
            Scenario(
                label: "first-run-override",
                issue: .configMissing,
                isFirstRun: true,
                expected: "Let's get you set up",
            ),
            Scenario(
                label: "binary-missing",
                issue: .binaryMissing,
                isFirstRun: false,
                expected: "Hook binary missing",
            ),
            Scenario(
                label: "unknown-issue",
                issue: nil,
                isFirstRun: false,
                expected: "Session tracking unavailable",
            ),
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                HookPresentationPolicy.setupCardHeader(for: scenario.issue, isFirstRun: scenario.isFirstRun),
                scenario.expected,
                "[\(scenario.label)] setup card header mismatch",
            )
        }
    }
}
