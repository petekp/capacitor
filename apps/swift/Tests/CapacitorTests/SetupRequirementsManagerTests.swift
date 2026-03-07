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

    func testRunChecksReadsCanonicalStatusThroughSetupGateway() async {
        let manager = SetupRequirementsManager(
            setupGateway: StubSetupGateway(
                setupStatus: SetupTestFixtures.setupStatus(
                    dependencies: [SetupTestFixtures.claudeDependency(found: true)],
                    hooks: .installed(version: "1.0.0"),
                ),
            ),
            shellStateStore: nil,
        )

        await manager.runChecks()

        XCTAssertEqual(
            manager.steps.first(where: { $0.id == .claude })?.status,
            .completed(detail: "Installed"),
        )
        XCTAssertEqual(
            manager.steps.first(where: { $0.id == .hooks })?.status,
            .completed(detail: "Connected"),
        )
    }

    func testExecuteHooksStepInstallsThroughSetupGateway() async {
        let manager = SetupRequirementsManager(
            setupGateway: StubSetupGateway(
                setupStatus: SetupTestFixtures.setupStatus(
                    dependencies: [SetupTestFixtures.claudeDependency(found: true)],
                    hooks: .notInstalled,
                ),
                hookStatus: .installed(version: "1.0.0"),
                hookInstallError: nil,
            ),
            shellStateStore: nil,
        )

        await manager.executeStep(.hooks)

        XCTAssertEqual(
            manager.steps.first(where: { $0.id == .hooks })?.status,
            .completed(detail: "Connected"),
        )
    }
}

private struct StubSetupGateway: SetupGateway {
    let setupStatus: SetupStatus
    let hookStatus: HookStatus
    let hookInstallError: String?

    init(
        setupStatus: SetupStatus,
        hookStatus: HookStatus = .notInstalled,
        hookInstallError: String? = nil,
    ) {
        self.setupStatus = setupStatus
        self.hookStatus = hookStatus
        self.hookInstallError = hookInstallError
    }

    func checkReadiness() async throws -> ShellSetupReadiness {
        ShellSetupReadiness(
            stage: setupStatus.allReady ? .ready : .needsAttention,
            blockingReason: setupStatus.blockingReason,
            missingDependencies: setupStatus.dependencies.filter { $0.required && !$0.found }.map(\.name),
            hookState: "stub",
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
        .ready
    }

    func attemptHookAutoRepair() -> String? {
        hookInstallError
    }

    func fetchSetupStatus() throws -> SetupStatus {
        setupStatus
    }

    func checkDependency(name: String) throws -> DependencyStatus {
        setupStatus.dependencies.first(where: { $0.name == name }) ?? DependencyStatus(
            name: name,
            required: true,
            found: false,
            path: nil,
            installHint: nil,
        )
    }

    func fetchHookStatus() throws -> HookStatus {
        hookStatus
    }

    func installHooks() -> String? {
        hookInstallError
    }
}
