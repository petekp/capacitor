@testable import Capacitor
import XCTest

final class SetupStatusCopyContractTests: XCTestCase {
    func testHookSetupStatusCopyScenariosMatchCanonicalContract() {
        struct Scenario {
            let label: String
            let hookStatus: HookStatus
            let expected: SetupStepStatus
        }

        let scenarios: [Scenario] = [
            Scenario(
                label: "installed",
                hookStatus: .installed(version: "1.2.3"),
                expected: .completed(detail: "Connected"),
            ),
            Scenario(
                label: "not-installed",
                hookStatus: .notInstalled,
                expected: .actionNeeded(message: "Tap Install to connect"),
            ),
            Scenario(
                label: "policy-blocked",
                hookStatus: .policyBlocked(reason: "disableAllHooks is enabled"),
                expected: .error(message: "Your Claude settings prevent hook installation"),
            ),
            Scenario(
                label: "binary-broken",
                hookStatus: .binaryBroken(reason: "codesign error"),
                expected: .error(message: "Session tracking needs repair"),
            ),
            Scenario(
                label: "symlink-broken",
                hookStatus: .symlinkBroken(target: "/missing", reason: "target missing"),
                expected: .error(message: "Session tracking needs repair"),
            ),
        ]

        for scenario in scenarios {
            XCTAssertEqual(
                HookPresentationPolicy.setupStepStatus(for: scenario.hookStatus),
                scenario.expected,
                "[\(scenario.label)] HookPresentationPolicy mapping mismatch",
            )
        }
    }

    func testHookAndShellStepBuildersAndPreviewScenariosUseCanonicalStatuses() {
        struct Scenario {
            let label: String
            let previewScenario: SetupPreviewScenario
            let expectedHookStatus: SetupStepStatus
            let expectedShellStatus: SetupStepStatus
        }

        let scenarios: [Scenario] = [
            Scenario(
                label: "hooks-needed",
                previewScenario: .hooksNeeded,
                expectedHookStatus: .actionNeeded(message: "Tap Install to connect"),
                expectedShellStatus: .pending,
            ),
            Scenario(
                label: "hooks-policy-blocked",
                previewScenario: .hooksPolicyBlocked,
                expectedHookStatus: .error(message: "Your Claude settings prevent hook installation"),
                expectedShellStatus: .pending,
            ),
            Scenario(
                label: "shell-optional",
                previewScenario: .shellOptional,
                expectedHookStatus: .completed(detail: "Connected"),
                expectedShellStatus: .actionNeeded(message: "Add to ~/.zshrc"),
            ),
            Scenario(
                label: "all-complete",
                previewScenario: .allComplete,
                expectedHookStatus: .completed(detail: "Connected"),
                expectedShellStatus: .completed(detail: "Active"),
            ),
        ]

        for scenario in scenarios {
            let steps = scenario.previewScenario.steps
            let hookStep = steps[1]
            let shellStep = steps[2]

            XCTAssertEqual(hookStep.id, .hooks, "[\(scenario.label)] hook step id mismatch")
            XCTAssertEqual(shellStep.id, .shell, "[\(scenario.label)] shell step id mismatch")
            XCTAssertEqual(hookStep.status, scenario.expectedHookStatus, "[\(scenario.label)] hook status mismatch")
            XCTAssertEqual(shellStep.status, scenario.expectedShellStatus, "[\(scenario.label)] shell status mismatch")

            XCTAssertEqual(
                SetupStepCatalog.hooks(status: scenario.expectedHookStatus).status,
                scenario.expectedHookStatus,
                "[\(scenario.label)] hook catalog status passthrough mismatch",
            )
            XCTAssertEqual(
                SetupStepCatalog.shell(status: scenario.expectedShellStatus).status,
                scenario.expectedShellStatus,
                "[\(scenario.label)] shell catalog status passthrough mismatch",
            )
        }
    }
}
