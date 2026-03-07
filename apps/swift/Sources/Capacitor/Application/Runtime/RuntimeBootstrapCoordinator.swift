import Foundation

@MainActor
final class RuntimeBootstrapCoordinator {
    private let runtimeFactory: () throws -> CoreRuntime
    private let writeEngine: (CoreRuntime) -> Void
    private let ensureRuntimeReady: () -> Void
    private let configureProjectDetails: (CoreRuntime) -> Void
    private let reloadDashboard: () -> Void
    private let refreshSetupDiagnostics: () -> Void
    private let startHookServer: () -> Void
    private let startRefreshLoop: () -> Void
    private let startShellTracking: () -> Void
    private let writeError: (String) -> Void
    private let writeIsLoading: (Bool) -> Void

    init(
        runtimeFactory: @escaping () throws -> CoreRuntime,
        writeEngine: @escaping (CoreRuntime) -> Void,
        ensureRuntimeReady: @escaping () -> Void,
        configureProjectDetails: @escaping (CoreRuntime) -> Void,
        reloadDashboard: @escaping () -> Void,
        refreshSetupDiagnostics: @escaping () -> Void,
        startHookServer: @escaping () -> Void,
        startRefreshLoop: @escaping () -> Void,
        startShellTracking: @escaping () -> Void,
        writeError: @escaping (String) -> Void,
        writeIsLoading: @escaping (Bool) -> Void,
    ) {
        self.runtimeFactory = runtimeFactory
        self.writeEngine = writeEngine
        self.ensureRuntimeReady = ensureRuntimeReady
        self.configureProjectDetails = configureProjectDetails
        self.reloadDashboard = reloadDashboard
        self.refreshSetupDiagnostics = refreshSetupDiagnostics
        self.startHookServer = startHookServer
        self.startRefreshLoop = startRefreshLoop
        self.startShellTracking = startShellTracking
        self.writeError = writeError
        self.writeIsLoading = writeIsLoading
    }

    static func live(
        writeEngine: @escaping (CoreRuntime) -> Void,
        ensureRuntimeReady: @escaping () -> Void,
        configureProjectDetails: @escaping (CoreRuntime) -> Void,
        reloadDashboard: @escaping () -> Void,
        refreshSetupDiagnostics: @escaping () -> Void,
        startHookServer: @escaping () -> Void,
        startRefreshLoop: @escaping () -> Void,
        startShellTracking: @escaping () -> Void,
        writeError: @escaping (String) -> Void,
        writeIsLoading: @escaping (Bool) -> Void,
    ) -> RuntimeBootstrapCoordinator {
        RuntimeBootstrapCoordinator(
            runtimeFactory: { try CoreRuntime() },
            writeEngine: writeEngine,
            ensureRuntimeReady: ensureRuntimeReady,
            configureProjectDetails: configureProjectDetails,
            reloadDashboard: reloadDashboard,
            refreshSetupDiagnostics: refreshSetupDiagnostics,
            startHookServer: startHookServer,
            startRefreshLoop: startRefreshLoop,
            startShellTracking: startShellTracking,
            writeError: writeError,
            writeIsLoading: writeIsLoading,
        )
    }

    func bootstrap() async {
        do {
            guard !_Concurrency.Task.isCancelled else { return }
            let runtime = try runtimeFactory()
            guard !_Concurrency.Task.isCancelled else { return }

            writeEngine(runtime)
            ensureRuntimeReady()
            guard !_Concurrency.Task.isCancelled else { return }

            configureProjectDetails(runtime)
            reloadDashboard()
            guard !_Concurrency.Task.isCancelled else { return }

            refreshSetupDiagnostics()
            startHookServer()
            startRefreshLoop()
            startShellTracking()
        } catch {
            writeError(error.localizedDescription)
            writeIsLoading(false)
        }
    }
}
