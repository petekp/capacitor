@testable import Capacitor
import XCTest

@MainActor
final class SetupRequirementsManagerTests: XCTestCase {
    func testExecuteStepShellInstructionRoutingScenariosMatchContract() async {
        struct ShellInstructionRoutingState: Equatable {
            let isShownBefore: Bool
            let isShownAfter: Bool
        }

        let scenarios: [LabeledExpectationScenario<SetupStepID, ShellInstructionRoutingState>] = [
            LabeledExpectationScenario(
                label: "shell-step-shows-instructions",
                input: .shell,
                expected: .init(isShownBefore: false, isShownAfter: true),
            ),
            LabeledExpectationScenario(
                label: "claude-step-keeps-instructions-hidden",
                input: .claude,
                expected: .init(isShownBefore: false, isShownAfter: false),
            ),
            LabeledExpectationScenario(
                label: "hooks-step-keeps-instructions-hidden",
                input: .hooks,
                expected: .init(isShownBefore: false, isShownAfter: false),
            ),
        ]

        await assertLabeledScenariosAsync(scenarios, mismatch: "execute step shell-instruction routing mismatch") { stepID in
            let manager = SetupRequirementsManager.preview(.allPending)
            let before = manager.showShellInstructions
            await manager.executeStep(stepID)
            return ShellInstructionRoutingState(isShownBefore: before, isShownAfter: manager.showShellInstructions)
        }
    }
}
