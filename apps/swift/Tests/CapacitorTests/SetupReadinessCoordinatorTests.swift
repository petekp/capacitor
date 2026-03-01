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

        let presentClaudeDependency = DependencyStatus(
            name: "claude",
            required: true,
            found: true,
            path: "/opt/homebrew/bin/claude",
            installHint: nil,
        )

        let scenarios: [Scenario] = [
            Scenario(
                label: "claude-missing",
                dependencies: [DependencyStatus(name: "claude", required: true, found: false, path: nil, installHint: nil)],
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
            let setupStatus = makeSetupStatus(
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

    private func makeSetupStatus(dependencies: [DependencyStatus], hooks: HookStatus) -> SetupStatus {
        SetupStatus(dependencies: dependencies, hooks: hooks, storageReady: true, allReady: true, blockingReason: nil)
    }
}
