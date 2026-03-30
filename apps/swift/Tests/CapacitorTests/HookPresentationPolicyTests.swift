@testable import Capacitor
import XCTest

final class HookPresentationPolicyTests: XCTestCase {
    func testSetupStepStatusHandlesNewHookStatusVariants() {
        XCTAssertEqual(
            HookPresentationPolicy.setupStepStatus(for: .partiallyConfigured(
                missingEvents: ["TaskCompleted"],
                reason: "Missing or invalid managed hook configuration for 1 event(s)",
            )),
            .error(message: "Session tracking needs repair"),
        )
        XCTAssertEqual(
            HookPresentationPolicy.setupStepStatus(for: .settingsUnreadable(reason: "Failed to parse settings.json")),
            .error(message: "Claude settings file is unreadable"),
        )
    }

    func testSetupCardHeaderScenariosMatchCanonicalContract() {
        let scenarios: [LabeledExpectationScenario<(issue: HookIssue?, isFirstRun: Bool), String>] = [
            LabeledExpectationScenario(
                label: "first-run-override",
                input: (issue: .configMissing, isFirstRun: true),
                expected: "Let's get you set up",
            ),
            LabeledExpectationScenario(
                label: "binary-missing",
                input: (issue: .binaryMissing, isFirstRun: false),
                expected: "Hook binary missing",
            ),
            LabeledExpectationScenario(
                label: "unknown-issue",
                input: (issue: nil, isFirstRun: false),
                expected: "Session tracking unavailable",
            ),
        ]

        assertLabeledScenarios(scenarios, mismatch: "setup card header mismatch") { input in
            HookPresentationPolicy.setupCardHeader(for: input.issue, isFirstRun: input.isFirstRun)
        }
    }
}
