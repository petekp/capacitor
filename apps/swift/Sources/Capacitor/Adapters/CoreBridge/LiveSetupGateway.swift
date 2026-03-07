import Foundation

struct LiveSetupGateway: SetupGateway {
    private let runtimeProvider: () throws -> CoreRuntime

    init(runtimeProvider: @escaping () throws -> CoreRuntime = { try CoreRuntime() }) {
        self.runtimeProvider = runtimeProvider
    }

    func checkReadiness() async throws -> ShellSetupReadiness {
        let status = try runtimeProvider().checkSetupStatus()

        return ShellSetupReadiness(
            stage: status.allReady ? .ready : .needsAttention,
            blockingReason: status.blockingReason,
            missingDependencies: status.dependencies
                .filter { $0.required && !$0.found }
                .map(\.name),
            hookState: Self.describe(status.hooks),
        )
    }

    func fetchHookDiagnostic() async throws -> HookDiagnosticReport {
        try runtimeProvider().getHookDiagnostic()
    }

    func fetchSetupStatus() throws -> SetupStatus {
        try runtimeProvider().checkSetupStatus()
    }

    func checkDependency(name: String) throws -> DependencyStatus {
        try runtimeProvider().checkDependency(name: name)
    }

    func fetchHookStatus() throws -> HookStatus {
        try runtimeProvider().getHookStatus()
    }

    func runHookTest() throws -> HookTestResult {
        try runtimeProvider().runHookTest()
    }

    func fetchStartupDecision() throws -> StartupSetupDecision {
        try SetupReadinessCoordinator.startupDecision(from: runtimeProvider().checkSetupStatus())
    }

    func attemptHookAutoRepair() -> String? {
        guard let runtime = try? runtimeProvider() else {
            return "Runtime initialization failed. Restart Capacitor and try again."
        }
        return HookInstaller.ensureHooksInstalled(using: runtime)
    }

    func installHooks() -> String? {
        attemptHookAutoRepair()
    }

    private static func describe(_ hookStatus: HookStatus) -> String {
        switch hookStatus {
        case .notInstalled:
            "not_installed"
        case let .installed(version):
            "installed:\(version)"
        case let .policyBlocked(reason):
            "policy_blocked:\(reason)"
        case let .binaryBroken(reason):
            "binary_broken:\(reason)"
        case let .symlinkBroken(target, reason):
            "symlink_broken:\(target):\(reason)"
        }
    }
}
