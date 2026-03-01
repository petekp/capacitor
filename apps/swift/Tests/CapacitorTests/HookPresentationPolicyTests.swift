@testable import Capacitor
import XCTest

final class HookPresentationPolicyTests: XCTestCase {
    func testSetupStepStatusScenariosMatchCanonicalContract() {
        struct Scenario {
            let label: String
            let status: HookStatus
            let expected: SetupStepStatus
        }

        let scenarios: [Scenario] = [
            Scenario(
                label: "installed",
                status: .installed(version: "1.2.3"),
                expected: .completed(detail: "Connected"),
            ),
            Scenario(
                label: "not-installed",
                status: .notInstalled,
                expected: .actionNeeded(message: "Tap Install to connect"),
            ),
            Scenario(
                label: "policy-blocked",
                status: .policyBlocked(reason: "disableAllHooks is enabled"),
                expected: .error(message: "Your Claude settings prevent hook installation"),
            ),
            Scenario(
                label: "binary-broken",
                status: .binaryBroken(reason: "codesign error"),
                expected: .error(message: "Session tracking needs repair"),
            ),
            Scenario(
                label: "symlink-broken",
                status: .symlinkBroken(target: "/missing", reason: "target missing"),
                expected: .error(message: "Session tracking needs repair"),
            ),
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                HookPresentationPolicy.setupStepStatus(for: scenario.status),
                scenario.expected,
                "[\(scenario.label)] setup status mismatch",
            )
        }
    }

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
