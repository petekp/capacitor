@testable import Capacitor
import XCTest

final class SetupReadinessCoordinatorTests: XCTestCase {
    func testStartupDecisionShowsWelcomeWhenClaudeDependencyMissing() {
        let setupStatus = makeSetupStatus(
            dependencies: [DependencyStatus(name: "claude", required: true, found: false, path: nil, installHint: nil)],
            hooks: .installed(version: "1.0.0"),
        )

        XCTAssertEqual(
            SetupReadinessCoordinator.startupDecision(from: setupStatus),
            .showWelcome(event: .claudeMissing),
        )
    }

    func testStartupDecisionShowsWelcomeWhenHooksPolicyBlocked() {
        let setupStatus = makeSetupStatus(
            dependencies: [DependencyStatus(name: "claude", required: true, found: true, path: "/opt/homebrew/bin/claude", installHint: nil)],
            hooks: .policyBlocked(reason: "disableAllHooks is enabled."),
        )

        XCTAssertEqual(
            SetupReadinessCoordinator.startupDecision(from: setupStatus),
            .showWelcome(event: .hooksBlockedByPolicy(reason: "disableAllHooks is enabled.")),
        )
    }

    func testStartupDecisionAttemptsRepairWhenHooksNeedRepair() {
        let setupStatus = makeSetupStatus(
            dependencies: [DependencyStatus(name: "claude", required: true, found: true, path: "/opt/homebrew/bin/claude", installHint: nil)],
            hooks: .notInstalled,
        )

        XCTAssertEqual(
            SetupReadinessCoordinator.startupDecision(from: setupStatus),
            .attemptHookRepair(event: .hooksNeedAutoRepair(status: .notInstalled)),
        )
    }

    func testStartupDecisionIsReadyWhenClaudePresentAndHooksInstalled() {
        let setupStatus = makeSetupStatus(
            dependencies: [DependencyStatus(name: "claude", required: true, found: true, path: "/opt/homebrew/bin/claude", installHint: nil)],
            hooks: .installed(version: "1.0.0"),
        )

        XCTAssertEqual(SetupReadinessCoordinator.startupDecision(from: setupStatus), .ready)
    }

    private func makeSetupStatus(dependencies: [DependencyStatus], hooks: HookStatus) -> SetupStatus {
        SetupStatus(dependencies: dependencies, hooks: hooks, storageReady: true, allReady: true, blockingReason: nil)
    }
}
