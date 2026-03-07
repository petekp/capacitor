import Foundation

@Observable
@MainActor
final class SetupActionState {
    private let setupSupervisor: SetupSupervisor
    private let isRuntimeAvailable: () -> Bool
    private let writeToast: (ToastMessage) -> Void
    private let refreshSessionStates: () -> Void

    private(set) var hookDiagnostic: HookDiagnosticReport?

    init(
        setupSupervisor: SetupSupervisor,
        isRuntimeAvailable: @escaping () -> Bool,
        writeToast: @escaping (ToastMessage) -> Void,
        refreshSessionStates: @escaping () -> Void,
    ) {
        self.setupSupervisor = setupSupervisor
        self.isRuntimeAvailable = isRuntimeAvailable
        self.writeToast = writeToast
        self.refreshSessionStates = refreshSessionStates
    }

    func refreshHookDiagnostic() {
        guard isRuntimeAvailable() else { return }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            let result = await setupSupervisor.refreshHookDiagnostic()
            guard !_Concurrency.Task.isCancelled else { return }

            if case let .success(hookDiagnostic) = result {
                self.hookDiagnostic = hookDiagnostic
            }
        }
    }

    func fixHooks() {
        guard isRuntimeAvailable() else { return }

        if let hookInstallError = setupSupervisor.installHooks() {
            writeToast(ToastMessage(hookInstallError, isError: true))
            return
        }

        _Concurrency.Task { [weak self] in
            guard let self else { return }
            let result = await setupSupervisor.refreshHookDiagnostic()
            guard !_Concurrency.Task.isCancelled else { return }

            if case let .success(hookDiagnostic) = result {
                self.hookDiagnostic = hookDiagnostic
                if hookDiagnostic.isHealthy {
                    writeToast(ToastMessage("Hooks repaired"))
                }
            }
            refreshSessionStates()
        }
    }

    func testHooks() -> HookTestResult {
        guard isRuntimeAvailable() else {
            return HookTestResult(
                success: false,
                heartbeatOk: false,
                heartbeatAgeSecs: nil,
                stateFileOk: false,
                message: "Engine not initialized",
            )
        }

        if let result = setupSupervisor.runHookTest() {
            return result
        }

        return HookTestResult(
            success: false,
            heartbeatOk: false,
            heartbeatAgeSecs: nil,
            stateFileOk: false,
            message: "Hook test unavailable",
        )
    }
}
