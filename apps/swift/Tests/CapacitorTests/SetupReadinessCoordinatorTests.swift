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
                label: "hooks-partially-configured",
                input: (
                    dependencies: [presentClaudeDependency],
                    hooks: .partiallyConfigured(
                        missingEvents: ["TaskCompleted", "SessionEnd"],
                        reason: "Missing or invalid managed hook configuration for 2 event(s)",
                    ),
                ),
                expected: .attemptHookRepair(event: .hooksNeedAutoRepair(status: .partiallyConfigured(
                    missingEvents: ["TaskCompleted", "SessionEnd"],
                    reason: "Missing or invalid managed hook configuration for 2 event(s)",
                ))),
            ),
            LabeledExpectationScenario(
                label: "hooks-settings-unreadable",
                input: (
                    dependencies: [presentClaudeDependency],
                    hooks: .settingsUnreadable(reason: "Failed to parse settings.json"),
                ),
                expected: .attemptHookRepair(event: .hooksNeedAutoRepair(status: .settingsUnreadable(
                    reason: "Failed to parse settings.json",
                ))),
            ),
            LabeledExpectationScenario(
                label: "hooks-binary-broken",
                input: (
                    dependencies: [presentClaudeDependency],
                    hooks: .binaryBroken(reason: "codesign error"),
                ),
                expected: .attemptHookRepair(event: .hooksNeedAutoRepair(status: .binaryBroken(reason: "codesign error"))),
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
