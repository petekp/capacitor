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
            .showWelcome(logMessage: "[Startup] Claude CLI not found, showing WelcomeView"),
        )
    }

    func testStartupDecisionShowsWelcomeWhenHooksPolicyBlocked() {
        let setupStatus = makeSetupStatus(
            dependencies: [DependencyStatus(name: "claude", required: true, found: true, path: "/opt/homebrew/bin/claude", installHint: nil)],
            hooks: .policyBlocked(reason: "disableAllHooks is enabled."),
        )

        XCTAssertEqual(
            SetupReadinessCoordinator.startupDecision(from: setupStatus),
            .showWelcome(logMessage: "[Startup] Hooks blocked by policy (disableAllHooks is enabled.), showing WelcomeView"),
        )
    }

    func testStartupDecisionAttemptsRepairWhenHooksNeedRepair() {
        let setupStatus = makeSetupStatus(
            dependencies: [DependencyStatus(name: "claude", required: true, found: true, path: "/opt/homebrew/bin/claude", installHint: nil)],
            hooks: .notInstalled,
        )

        XCTAssertEqual(
            SetupReadinessCoordinator.startupDecision(from: setupStatus),
            .attemptHookRepair(logMessage: "[Startup] Hook status notInstalled requires auto-repair"),
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
