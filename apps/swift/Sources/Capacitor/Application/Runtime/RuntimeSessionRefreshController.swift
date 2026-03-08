import Foundation

@MainActor
final class RuntimeSessionRefreshController {
    private let runtimeSupervisor: RuntimeSupervisor
    private let sessionStateManager: SessionStateManager
    private let shellStateStore: ShellStateStore
    private let didUpdateContext: @MainActor () -> Void

    private var refreshTask: _Concurrency.Task<Void, Never>?
    private var generation: UInt64 = 0
    private var correlationCounter: UInt64 = 0
    private var consecutiveFailures = 0

    init(
        runtimeSupervisor: RuntimeSupervisor,
        sessionStateManager: SessionStateManager,
        shellStateStore: ShellStateStore,
        didUpdateContext: @escaping @MainActor () -> Void,
    ) {
        self.runtimeSupervisor = runtimeSupervisor
        self.sessionStateManager = sessionStateManager
        self.shellStateStore = shellStateStore
        self.didUpdateContext = didUpdateContext
    }

    func refresh(projects: [some ProjectPathProviding]) {
        generation &+= 1
        let refreshGeneration = generation
        let correlationId = nextCorrelationId()
        refreshTask?.cancel()
        refreshTask = _Concurrency.Task { [weak self] in
            guard let self else { return }

            let observationResult = await runtimeSupervisor.refreshObservation(correlationId: correlationId)
            guard !_Concurrency.Task.isCancelled else { return }

            switch observationResult {
            case let .success(observation):
                await applyObservationIfFresh(
                    observation,
                    refreshGeneration: refreshGeneration,
                    correlationId: correlationId,
                    projects: projects,
                )
            case let .failure(error):
                await MainActor.run {
                    self.handleFailureIfFresh(
                        refreshGeneration: refreshGeneration,
                        correlationId: correlationId,
                        errorDescription: String(describing: error),
                    )
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @MainActor
    private func applySessionStateIfFresh(
        _ observation: ShellRuntimeObservation,
        refreshGeneration: UInt64,
        correlationId: String,
        projects: [some ProjectPathProviding],
    ) -> Bool {
        guard refreshGeneration == generation else {
            DebugLog.write(
                "RuntimeSessionRefreshController.apply source=runtime_snapshot_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(generation)",
            )
            return false
        }

        sessionStateManager.applyRuntimeProjectStates(
            observation.projectStates,
            for: projects,
            correlationId: correlationId,
        )
        consecutiveFailures = 0

        DebugLog.write(
            "RuntimeSessionRefreshController.apply source=runtime_snapshot_apply cid=\(correlationId) projects=\(observation.projectStates.count) sessions=\(observation.sessions.count) shells=\(observation.shellState.shells.count)",
        )
        didUpdateContext()
        return true
    }

    private func applyObservationIfFresh(
        _ observation: ShellRuntimeObservation,
        refreshGeneration: UInt64,
        correlationId: String,
        projects: [some ProjectPathProviding],
    ) async {
        let shouldApply = await MainActor.run {
            applySessionStateIfFresh(
                observation,
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                projects: projects,
            )
        }

        guard shouldApply else { return }

        await shellStateStore.applyRuntimeShellState(
            observation.shellState,
            correlationId: correlationId,
        )
    }

    @MainActor
    private func handleFailureIfFresh(
        refreshGeneration: UInt64,
        correlationId: String,
        errorDescription: String,
    ) {
        guard refreshGeneration == generation else {
            DebugLog.write(
                "RuntimeSessionRefreshController.failure source=runtime_snapshot_error_drop_stale cid=\(correlationId) generation=\(refreshGeneration) current=\(generation)",
            )
            return
        }

        consecutiveFailures += 1
        DebugLog.write(
            "RuntimeSessionRefreshController.failure source=runtime_snapshot_error cid=\(correlationId) failures=\(consecutiveFailures) error=\(errorDescription)",
        )

        if consecutiveFailures >= 2 {
            DebugLog.write(
                "RuntimeSessionRefreshController.failure source=runtime_snapshot_error_clear cid=\(correlationId) failures=\(consecutiveFailures)",
            )
            sessionStateManager.clearRuntimeProjectStates()
            shellStateStore.clearRuntimeShellState(correlationId: correlationId)
        }

        didUpdateContext()
    }

    private func nextCorrelationId() -> String {
        correlationCounter &+= 1
        return "app-snap-\(correlationCounter)"
    }

    #if DEBUG
        func applyObservationForTesting(
            _ observation: ShellRuntimeObservation,
            refreshGeneration: UInt64,
            correlationId: String,
            projects: [some ProjectPathProviding],
        ) async {
            await applyObservationIfFresh(
                observation,
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                projects: projects,
            )
        }

        func setGenerationForTesting(_ generation: UInt64) {
            self.generation = generation
        }

        func handleFailureForTesting(
            refreshGeneration: UInt64,
            correlationId: String,
            errorDescription: String,
        ) {
            handleFailureIfFresh(
                refreshGeneration: refreshGeneration,
                correlationId: correlationId,
                errorDescription: errorDescription,
            )
        }
    #endif
}
