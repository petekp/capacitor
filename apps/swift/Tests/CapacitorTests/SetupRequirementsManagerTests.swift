@testable import Capacitor
import XCTest

@MainActor
final class SetupRequirementsManagerTests: XCTestCase {
    func testLifecycleInitializeFailureMarksHooksAsBlockingError() {
        var lifecycle = SetupLifecycleState.initial()

        lifecycle.apply(.initialize(initializationErrorMessage: "Runtime initialization failed"))

        XCTAssertEqual(lifecycle.initializationErrorMessage, "Runtime initialization failed")
        XCTAssertEqual(
            lifecycle.steps.first(where: { $0.id == .hooks })?.status,
            .error(message: "Runtime initialization failed"),
        )
        XCTAssertTrue(lifecycle.hasBlockingError)
    }

    func testLifecycleCheckAndHookInstallTransitionsAreExplicit() {
        var lifecycle = SetupLifecycleState.initial()

        lifecycle.apply(.checksStarted)
        XCTAssertTrue(lifecycle.isRunningChecks)

        lifecycle.apply(.dependencyResolved(DependencyStatus(
            name: "claude",
            required: true,
            found: true,
            path: "/opt/homebrew/bin/claude",
            installHint: nil,
        )))
        lifecycle.apply(.hookStatusResolved(.notInstalled))
        lifecycle.apply(.shellStatusResolved(.actionNeeded(message: "Add hook to ~/.zshrc")))
        lifecycle.apply(.checksFinished)

        XCTAssertFalse(lifecycle.isRunningChecks)
        XCTAssertEqual(lifecycle.claudePath, "/opt/homebrew/bin/claude")
        XCTAssertEqual(
            lifecycle.steps.first(where: { $0.id == .claude })?.status,
            .completed(detail: "Installed"),
        )
        XCTAssertEqual(
            lifecycle.steps.first(where: { $0.id == .hooks })?.status,
            .actionNeeded(message: "Tap Install to connect"),
        )

        lifecycle.apply(.hookInstallStarted)
        XCTAssertEqual(
            lifecycle.steps.first(where: { $0.id == .hooks })?.status,
            .checking,
        )

        lifecycle.apply(.hookInstallFinished(result: .failure("install failed")))
        XCTAssertEqual(
            lifecycle.steps.first(where: { $0.id == .hooks })?.status,
            .error(message: "install failed"),
        )
    }

    func testLifecycleShellInstructionsPresentationAndDismissalAreExplicit() {
        var lifecycle = SetupLifecycleState.initial()

        lifecycle.apply(.shellInstructionsPresented)
        XCTAssertTrue(lifecycle.showShellInstructions)

        lifecycle.apply(.shellInstructionsDismissed(status: .completed(detail: "Installed")))
        XCTAssertFalse(lifecycle.showShellInstructions)
        XCTAssertEqual(
            lifecycle.steps.first(where: { $0.id == .shell })?.status,
            .completed(detail: "Installed"),
        )
    }

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

    func testInitializationFailureIsRecoverableAndSurfacedAsBlockingError() async {
        struct RuntimeInitFailure: Error {}

        let manager = SetupRequirementsManager(
            engine: nil,
            shellStateStore: nil,
            runtimeFactory: { throw RuntimeInitFailure() },
        )

        XCTAssertNotNil(manager.initializationErrorMessage)
        XCTAssertTrue(manager.hasBlockingError)
        XCTAssertFalse(manager.allComplete)

        guard let hooksStep = manager.steps.first(where: { $0.id == .hooks }) else {
            XCTFail("Expected hooks step to exist")
            return
        }

        if case .error = hooksStep.status {
            // expected
        } else {
            XCTFail("Expected hooks step to be in .error state, got \(hooksStep.status)")
        }

        await manager.runChecks()

        guard let hooksAfterRun = manager.steps.first(where: { $0.id == .hooks }) else {
            XCTFail("Expected hooks step to exist after runChecks")
            return
        }
        if case .error = hooksAfterRun.status {
            // expected
        } else {
            XCTFail("Expected hooks step to stay in .error state after runChecks, got \(hooksAfterRun.status)")
        }
    }
}
