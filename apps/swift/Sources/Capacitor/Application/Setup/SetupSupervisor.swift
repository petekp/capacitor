import Foundation

@MainActor
final class SetupSupervisor {
    private let setupGateway: any SetupGateway

    private(set) var readiness: ShellSetupReadiness?
    private(set) var hookDiagnostic: HookDiagnosticReport?
    private(set) var hookTestResult: HookTestResult?
    private(set) var lastError: Error?

    init(setupGateway: any SetupGateway) {
        self.setupGateway = setupGateway
    }

    func refresh() async {
        do {
            readiness = try await setupGateway.checkReadiness()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    func refreshHookDiagnostic() async -> Result<HookDiagnosticReport, Error> {
        do {
            let hookDiagnostic = try await setupGateway.fetchHookDiagnostic()
            self.hookDiagnostic = hookDiagnostic
            lastError = nil
            return .success(hookDiagnostic)
        } catch {
            lastError = error
            return .failure(error)
        }
    }

    func runHookTest() -> HookTestResult? {
        do {
            let hookTestResult = try setupGateway.runHookTest()
            self.hookTestResult = hookTestResult
            lastError = nil
            return hookTestResult
        } catch {
            lastError = error
            return nil
        }
    }

    func installHooks() -> String? {
        let errorMessage = setupGateway.installHooks()
        if errorMessage == nil {
            lastError = nil
        }
        return errorMessage
    }
}
