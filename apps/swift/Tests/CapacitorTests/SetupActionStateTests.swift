@testable import Capacitor
import XCTest

@MainActor
final class SetupActionStateTests: XCTestCase {
    func testFixHooksWritesSuccessToastAndRefreshesSessionState() async {
        let supervisor = SetupSupervisor(
            setupGateway: StubSetupGateway(
                hookDiagnostic: SetupTestFixtures.hookDiagnosticReport(
                    primaryIssue: nil,
                    isHealthy: true,
                ),
                installHooksError: nil,
            ),
        )
        var toast: ToastMessage?
        var refreshedSessionState = false
        let state = SetupActionState(
            setupSupervisor: supervisor,
            isRuntimeAvailable: { true },
            writeToast: { toast = $0 },
            refreshSessionStates: { refreshedSessionState = true },
        )

        state.fixHooks()
        for _ in 0 ..< 5 {
            await _Concurrency.Task.yield()
        }

        XCTAssertEqual(toast?.message, "Hooks repaired")
        XCTAssertTrue(refreshedSessionState)
        XCTAssertEqual(state.hookDiagnostic?.isHealthy, true)
    }
}

private struct StubSetupGateway: SetupGateway {
    let hookDiagnostic: HookDiagnosticReport
    let installHooksError: String?

    init(
        hookDiagnostic: HookDiagnosticReport = SetupTestFixtures.hookDiagnosticReport(primaryIssue: nil, isHealthy: true),
        installHooksError: String? = nil,
    ) {
        self.hookDiagnostic = hookDiagnostic
        self.installHooksError = installHooksError
    }

    func checkReadiness() async throws -> ShellSetupReadiness {
        ShellSetupReadiness(stage: .ready, blockingReason: nil, missingDependencies: [], hookState: "installed")
    }

    func fetchHookDiagnostic() async throws -> HookDiagnosticReport {
        hookDiagnostic
    }

    func runHookTest() throws -> HookTestResult {
        HookTestResult(success: true, heartbeatOk: true, heartbeatAgeSecs: 1, stateFileOk: true, message: "ok")
    }

    func fetchStartupDecision() throws -> StartupSetupDecision {
        .ready
    }

    func attemptHookAutoRepair() -> String? {
        installHooksError
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
        installHooksError
    }
}
