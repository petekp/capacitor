import Foundation

protocol SetupGateway {
    func checkReadiness() async throws -> ShellSetupReadiness
    func fetchHookDiagnostic() async throws -> HookDiagnosticReport
    func runHookTest() throws -> HookTestResult
    func fetchStartupDecision() throws -> StartupSetupDecision
    func attemptHookAutoRepair() -> String?
    func fetchSetupStatus() throws -> SetupStatus
    func checkDependency(name: String) throws -> DependencyStatus
    func fetchHookStatus() throws -> HookStatus
    func installHooks() -> String?
}
