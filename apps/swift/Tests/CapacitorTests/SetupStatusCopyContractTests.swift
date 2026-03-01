@testable import Capacitor
import XCTest

final class SetupStatusCopyContractTests: XCTestCase {
    func testHookSetupStatusCopyScenariosMatchCanonicalContract() {
        let scenarios: [LabeledExpectationScenario<HookStatus, SetupStepStatus>] = [
            LabeledExpectationScenario(
                label: "installed",
                input: .installed(version: "1.2.3"),
                expected: .completed(detail: "Connected"),
            ),
            LabeledExpectationScenario(
                label: "not-installed",
                input: .notInstalled,
                expected: .actionNeeded(message: "Tap Install to connect"),
            ),
            LabeledExpectationScenario(
                label: "policy-blocked",
                input: .policyBlocked(reason: "disableAllHooks is enabled"),
                expected: .error(message: "Your Claude settings prevent hook installation"),
            ),
            LabeledExpectationScenario(
                label: "binary-broken",
                input: .binaryBroken(reason: "codesign error"),
                expected: .error(message: "Session tracking needs repair"),
            ),
        ]

        assertLabeledScenarios(scenarios, mismatch: "HookPresentationPolicy mapping mismatch") { hookStatus in
            HookPresentationPolicy.setupStepStatus(for: hookStatus)
        }
    }

    func testHookAndShellStepBuildersAndPreviewScenariosUseCanonicalStatuses() {
        struct PreviewStatusProjection: Equatable {
            let hookStepID: SetupStepID
            let shellStepID: SetupStepID
            let hookStatus: SetupStepStatus
            let shellStatus: SetupStepStatus
            let hookCatalogStatus: SetupStepStatus
            let shellCatalogStatus: SetupStepStatus
        }

        let scenarios: [LabeledExpectationScenario<SetupPreviewScenario, PreviewStatusProjection>] = [
            LabeledExpectationScenario(
                label: "hooks-needed",
                input: .hooksNeeded,
                expected: PreviewStatusProjection(
                    hookStepID: .hooks,
                    shellStepID: .shell,
                    hookStatus: .actionNeeded(message: "Tap Install to connect"),
                    shellStatus: .pending,
                    hookCatalogStatus: .actionNeeded(message: "Tap Install to connect"),
                    shellCatalogStatus: .pending
                ),
            ),
            LabeledExpectationScenario(
                label: "hooks-policy-blocked",
                input: .hooksPolicyBlocked,
                expected: PreviewStatusProjection(
                    hookStepID: .hooks,
                    shellStepID: .shell,
                    hookStatus: .error(message: "Your Claude settings prevent hook installation"),
                    shellStatus: .pending,
                    hookCatalogStatus: .error(message: "Your Claude settings prevent hook installation"),
                    shellCatalogStatus: .pending
                ),
            ),
            LabeledExpectationScenario(
                label: "shell-optional",
                input: .shellOptional,
                expected: PreviewStatusProjection(
                    hookStepID: .hooks,
                    shellStepID: .shell,
                    hookStatus: .completed(detail: "Connected"),
                    shellStatus: .actionNeeded(message: "Add to ~/.zshrc"),
                    hookCatalogStatus: .completed(detail: "Connected"),
                    shellCatalogStatus: .actionNeeded(message: "Add to ~/.zshrc")
                ),
            ),
            LabeledExpectationScenario(
                label: "all-complete",
                input: .allComplete,
                expected: PreviewStatusProjection(
                    hookStepID: .hooks,
                    shellStepID: .shell,
                    hookStatus: .completed(detail: "Connected"),
                    shellStatus: .completed(detail: "Active"),
                    hookCatalogStatus: .completed(detail: "Connected"),
                    shellCatalogStatus: .completed(detail: "Active")
                ),
            ),
        ]

        assertLabeledScenarios(scenarios, mismatch: "preview scenario status projection mismatch") { previewScenario in
            let steps = previewScenario.steps
            let hookStep = steps[1]
            let shellStep = steps[2]

            return PreviewStatusProjection(
                hookStepID: hookStep.id,
                shellStepID: shellStep.id,
                hookStatus: hookStep.status,
                shellStatus: shellStep.status,
                hookCatalogStatus: SetupStepCatalog.hooks(status: hookStep.status).status,
                shellCatalogStatus: SetupStepCatalog.shell(status: shellStep.status).status
            )
        }
    }
}
