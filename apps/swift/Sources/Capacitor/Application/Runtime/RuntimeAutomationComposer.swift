import Foundation

@MainActor
enum RuntimeAutomationComposer {
    static func makeController(
        writeEngine: @escaping (CoreRuntime) -> Void,
        ensureRuntimeReady: @escaping () -> Void,
        configureProjectDetails: @escaping (CoreRuntime) -> Void,
        reloadDashboardAfterBootstrap: @escaping () -> Void,
        refreshSetupDiagnosticsAfterBootstrap: @escaping () -> Void,
        startHookServer: @escaping () -> Void,
        startRefreshLoop: @escaping () -> Void,
        startShellTracking: @escaping () -> Void,
        writeError: @escaping (String) -> Void,
        writeIsLoading: @escaping (Bool) -> Void,
        refreshSessionStates: @escaping () -> Void,
        ideaCaptureEnabled: @escaping () -> Bool,
        checkIdeasFileChanges: @escaping () -> Void,
        refreshSetupDiagnostics: @escaping () -> Void,
        checkHookServerHealth: @escaping () -> Void,
        refreshRuntimeHealth: @escaping () -> Void,
        reloadDashboardOnInterval: @escaping () -> Void,
        scheduleRepeatingTimer: @escaping @MainActor (TimeInterval, @escaping () -> Void) -> RuntimeAutomationTimer = { interval, block in
            LiveRuntimeAutomationTimer(interval: interval, block: block)
        },
    ) -> RuntimeAutomationController {
        var hookHealthCheckCounter = 0
        var hookServerHealthCounter = 0
        var statsRefreshCounter = 0
        var runtimeHealthCheckCounter = 0

        let runtimeBootstrapCoordinator = RuntimeBootstrapCoordinator.live(
            writeEngine: writeEngine,
            ensureRuntimeReady: ensureRuntimeReady,
            configureProjectDetails: configureProjectDetails,
            reloadDashboard: reloadDashboardAfterBootstrap,
            refreshSetupDiagnostics: refreshSetupDiagnosticsAfterBootstrap,
            startHookServer: startHookServer,
            startRefreshLoop: startRefreshLoop,
            startShellTracking: startShellTracking,
            writeError: writeError,
            writeIsLoading: writeIsLoading,
        )

        return RuntimeAutomationController(
            bootstrapRuntime: {
                await runtimeBootstrapCoordinator.bootstrap()
            },
            onTimerTick: {
                refreshSessionStates()
                if ideaCaptureEnabled() {
                    checkIdeasFileChanges()
                }

                hookHealthCheckCounter += 1
                if hookHealthCheckCounter >= 5 {
                    hookHealthCheckCounter = 0
                    refreshSetupDiagnostics()
                }

                hookServerHealthCounter += 1
                if hookServerHealthCounter >= 5 {
                    hookServerHealthCounter = 0
                    checkHookServerHealth()
                }

                runtimeHealthCheckCounter += 1
                if runtimeHealthCheckCounter >= 8 {
                    runtimeHealthCheckCounter = 0
                    refreshRuntimeHealth()
                }

                statsRefreshCounter += 1
                if statsRefreshCounter >= 15 {
                    statsRefreshCounter = 0
                    reloadDashboardOnInterval()
                }
            },
            scheduleRepeatingTimer: scheduleRepeatingTimer,
        )
    }
}
