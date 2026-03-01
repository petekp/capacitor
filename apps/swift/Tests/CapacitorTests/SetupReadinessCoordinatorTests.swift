@testable import Capacitor
import XCTest

final class SetupReadinessCoordinatorTests: XCTestCase {
    func testStartupDecisionScenariosMatchCanonicalContract() {
        let presentClaudeDependency = SetupTestFixtures.claudeDependency(found: true)

        let scenarios: [LabeledExpectationScenario<(dependencies: [DependencyStatus], hooks: HookStatus), StartupSetupDecision>] = [
            LabeledExpectationScenario(
                label: "claude-missing",
                input: (
                    dependencies: [SetupTestFixtures.claudeDependency(found: false)],
                    hooks: .installed(version: "1.0.0"),
                ),
                expected: .showWelcome(event: .claudeMissing),
            ),
            LabeledExpectationScenario(
                label: "hooks-policy-blocked",
                input: (
                    dependencies: [presentClaudeDependency],
                    hooks: .policyBlocked(reason: "disableAllHooks is enabled."),
                ),
                expected: .showWelcome(event: .hooksBlockedByPolicy(reason: "disableAllHooks is enabled.")),
            ),
            LabeledExpectationScenario(
                label: "hooks-needs-repair",
                input: (
                    dependencies: [presentClaudeDependency],
                    hooks: .notInstalled,
                ),
                expected: .attemptHookRepair(event: .hooksNeedAutoRepair(status: .notInstalled)),
            ),
            LabeledExpectationScenario(
                label: "ready",
                input: (
                    dependencies: [presentClaudeDependency],
                    hooks: .installed(version: "1.0.0"),
                ),
                expected: .ready,
            ),
        ]

        assertLabeledScenarios(scenarios, mismatch: "startup decision mismatch") { input in
            SetupReadinessCoordinator.startupDecision(
                from: SetupTestFixtures.setupStatus(
                    dependencies: input.dependencies,
                    hooks: input.hooks,
                ),
            )
        }
    }
}
