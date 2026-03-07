@testable import Capacitor
import XCTest

@MainActor
final class SetupSupervisorTests: XCTestCase {
    func testRefreshHookDiagnosticStoresDiagnosticAndClearsError() async {
        let gateway = StubSetupGateway(
            hookDiagnostic: SetupTestFixtures.hookDiagnosticReport(
                primaryIssue: .binaryMissing,
                isHealthy: false,
            ),
        )
        let supervisor = SetupSupervisor(setupGateway: gateway)

        let result = await supervisor.refreshHookDiagnostic()

        guard case let .success(diagnostic) = result else {
            return XCTFail("Expected successful hook diagnostic refresh")
        }
        XCTAssertEqual(diagnostic.primaryIssue, .binaryMissing)
        XCTAssertEqual(supervisor.hookDiagnostic?.primaryIssue, .binaryMissing)
        XCTAssertNil(supervisor.lastError)
    }

    func testRunHookTestReturnsGatewayResult() {
        let gateway = StubSetupGateway(
            hookTestResult: HookTestResult(
                success: true,
                heartbeatOk: true,
                heartbeatAgeSecs: 1,
                stateFileOk: true,
                message: "working",
            ),
        )
        let supervisor = SetupSupervisor(setupGateway: gateway)

        let result = supervisor.runHookTest()

        XCTAssertEqual(result?.message, "working")
    }
}

private struct StubSetupGateway: SetupGateway {
    let readiness: ShellSetupReadiness?
    let hookDiagnostic: HookDiagnosticReport?
    let hookTestResult: HookTestResult?
    let error: Error?

    init(
        readiness: ShellSetupReadiness? = nil,
        hookDiagnostic: HookDiagnosticReport? = nil,
        hookTestResult: HookTestResult? = nil,
        error: Error? = nil,
    ) {
        self.readiness = readiness
        self.hookDiagnostic = hookDiagnostic
        self.hookTestResult = hookTestResult
        self.error = error
    }

    func checkReadiness() async throws -> ShellSetupReadiness {
        if let error {
            throw error
        }
        return try XCTUnwrap(readiness)
    }

    func fetchHookDiagnostic() async throws -> HookDiagnosticReport {
        if let error {
            throw error
        }
        return try XCTUnwrap(hookDiagnostic)
    }

    func runHookTest() throws -> HookTestResult {
        if let error {
            throw error
        }
        return try XCTUnwrap(hookTestResult)
    }

    func fetchStartupDecision() throws -> StartupSetupDecision {
        .ready
    }

    func attemptHookAutoRepair() -> String? {
        nil
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
        nil
    }
}
