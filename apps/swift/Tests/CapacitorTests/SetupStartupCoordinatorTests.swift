@testable import Capacitor
import XCTest

final class SetupStartupCoordinatorTests: XCTestCase {
    func testResolveLaunchShowsWelcomeForBlockingDecision() {
        let coordinator = SetupStartupCoordinator(
            setupGateway: StubStartupSetupGateway(startupDecision: .showWelcome(event: .claudeMissing)),
        )

        let outcome = coordinator.resolveLaunch()

        XCTAssertEqual(outcome?.shouldShowWelcome, true)
        XCTAssertEqual(outcome?.startupEvents, [.claudeMissing])
    }

    func testResolveLaunchAttemptsAutoRepairAndStaysReadyOnSuccess() {
        let coordinator = SetupStartupCoordinator(
            setupGateway: StubStartupSetupGateway(
                startupDecision: .attemptHookRepair(event: .hooksNeedAutoRepair(status: .notInstalled)),
                autoRepairErrorMessage: nil,
            ),
        )

        let outcome = coordinator.resolveLaunch()

        XCTAssertEqual(outcome?.shouldShowWelcome, false)
        XCTAssertEqual(
            outcome?.startupEvents,
            [
                .hooksNeedAutoRepair(status: .notInstalled),
                .hooksAutoRepairSucceeded,
            ],
        )
    }

    func testResolveLaunchShowsWelcomeWhenAutoRepairFails() {
        let coordinator = SetupStartupCoordinator(
            setupGateway: StubStartupSetupGateway(
                startupDecision: .attemptHookRepair(event: .hooksNeedAutoRepair(status: .notInstalled)),
                autoRepairErrorMessage: "install failed",
            ),
        )

        let outcome = coordinator.resolveLaunch()

        XCTAssertEqual(outcome?.shouldShowWelcome, true)
        XCTAssertEqual(
            outcome?.startupEvents,
            [
                .hooksNeedAutoRepair(status: .notInstalled),
                .hooksAutoRepairFailed(error: "install failed"),
            ],
        )
    }
}

private struct StubStartupSetupGateway: SetupGateway {
    let startupDecision: StartupSetupDecision?
    let autoRepairErrorMessage: String?

    init(
        startupDecision: StartupSetupDecision? = nil,
        autoRepairErrorMessage: String? = nil,
    ) {
        self.startupDecision = startupDecision
        self.autoRepairErrorMessage = autoRepairErrorMessage
    }

    func checkReadiness() async throws -> ShellSetupReadiness {
        ShellSetupReadiness(
            stage: .unknown,
            blockingReason: nil,
            missingDependencies: [],
            hookState: "unknown",
        )
    }

    func fetchHookDiagnostic() async throws -> HookDiagnosticReport {
        SetupTestFixtures.hookDiagnosticReport(primaryIssue: nil, isHealthy: true)
    }

    func runHookTest() throws -> HookTestResult {
        HookTestResult(
            success: true,
            heartbeatOk: true,
            heartbeatAgeSecs: 1,
            stateFileOk: true,
            message: "ok",
        )
    }

    func fetchStartupDecision() throws -> StartupSetupDecision {
        try XCTUnwrap(startupDecision)
    }

    func attemptHookAutoRepair() -> String? {
        autoRepairErrorMessage
    }

    func fetchSetupStatus() throws -> SetupStatus {
        SetupTestFixtures.setupStatus(
            dependencies: [SetupTestFixtures.claudeDependency(found: true)],
            hooks: .installed(version: "1.0.0"),
        )
    }

    func checkDependency(name: String) throws -> DependencyStatus {
        DependencyStatus(name: name, required: true, found: true, path: "/opt/homebrew/bin/\(name)", installHint: nil)
    }

    func fetchHookStatus() throws -> HookStatus {
        .installed(version: "1.0.0")
    }

    func installHooks() -> String? {
        autoRepairErrorMessage
    }
}
