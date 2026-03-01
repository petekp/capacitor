@testable import Capacitor
import XCTest

final class SetupReadinessCoordinatorTests: XCTestCase {
    func testStartupDecisionScenariosMatchCanonicalContract() {
        struct Scenario {
            let label: String
            let dependencies: [DependencyStatus]
            let hooks: HookStatus
            let expected: StartupSetupDecision
        }

        let presentClaudeDependency = SetupTestFixtures.claudeDependency(found: true)

        let scenarios: [Scenario] = [
            Scenario(
                label: "claude-missing",
                dependencies: [SetupTestFixtures.claudeDependency(found: false)],
                hooks: .installed(version: "1.0.0"),
                expected: .showWelcome(event: .claudeMissing),
            ),
            Scenario(
                label: "hooks-policy-blocked",
                dependencies: [presentClaudeDependency],
                hooks: .policyBlocked(reason: "disableAllHooks is enabled."),
                expected: .showWelcome(event: .hooksBlockedByPolicy(reason: "disableAllHooks is enabled.")),
            ),
            Scenario(
                label: "hooks-needs-repair",
                dependencies: [presentClaudeDependency],
                hooks: .notInstalled,
                expected: .attemptHookRepair(event: .hooksNeedAutoRepair(status: .notInstalled)),
            ),
            Scenario(
                label: "ready",
                dependencies: [presentClaudeDependency],
                hooks: .installed(version: "1.0.0"),
                expected: .ready,
            ),
        ]

        for scenario in scenarios {
            let setupStatus = SetupTestFixtures.setupStatus(
                dependencies: scenario.dependencies,
                hooks: scenario.hooks,
            )

            XCTAssertEqual(
                SetupReadinessCoordinator.startupDecision(from: setupStatus),
                scenario.expected,
                "[\(scenario.label)] startup decision mismatch",
            )
        }
    }
}
