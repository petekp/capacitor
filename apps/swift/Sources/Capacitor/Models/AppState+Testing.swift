import Foundation

extension AppState {
    #if DEBUG
        func applyRuntimeSnapshotForTesting(
            _ snapshot: RuntimeSnapshot,
            refreshGeneration: UInt64,
            correlationId: String,
            projects: [Project],
        ) async {
            let context = RuntimeSnapshotApplicator.RequestContext(
                generation: refreshGeneration,
                correlationId: correlationId,
                projects: projects,
            )
            await applyRuntimeSnapshot(
                snapshot,
                context: context,
            )
        }

        func setRuntimeSnapshotGenerationForTesting(_ generation: UInt64) {
            runtimeSnapshotApplicator.setRequestGenerationForTesting(generation)
        }

        func handleRuntimeSnapshotFailureForTesting(
            refreshGeneration: UInt64,
            correlationId: String,
            errorDescription: String,
        ) {
            let context = RuntimeSnapshotApplicator.RequestContext(
                generation: refreshGeneration,
                correlationId: correlationId,
                projects: projectState.projects,
            )
            let outcome = runtimeSnapshotApplicator.recordFailure(
                context: context,
                errorDescription: errorDescription,
            )
            executeRuntimeSnapshotEffects(outcome.effects)
        }

        func cancelRuntimeAutomationForTesting() {
            runtimeBootstrapTask?.cancel()
            runtimeBootstrapTask = nil
            longPollTask?.cancel()
            longPollTask = nil
            runtimeSnapshotTask?.cancel()
            runtimeSnapshotTask = nil
            refreshTimer?.invalidate()
            refreshTimer = nil
        }

        func applyDiscoveredSessionToCreationForTesting(_ creationID: String, sessionId: String) -> Bool {
            projectCreationCoordinator.applyDiscoveredSessionToCreationForTesting(creationID, sessionId: sessionId)
        }

        func setCreationMonitorTasksForTesting(
            creationId: String,
            sessionTask: _Concurrency.Task<Void, Never>?,
            completionTask: _Concurrency.Task<Void, Never>?,
        ) {
            projectCreationCoordinator.setCreationMonitorTasksForTesting(
                creationId: creationId,
                sessionTask: sessionTask,
                completionTask: completionTask,
            )
        }

        func hasCreationMonitorTasksForTesting(creationId: String) -> Bool {
            projectCreationCoordinator.hasCreationMonitorTasksForTesting(creationId: creationId)
        }
    #endif

    func recordRuntimeBootstrapStepForTesting(_ step: String) {
        #if DEBUG
            runtimeBootstrapTraceForTesting.append(step)
        #endif
    }
}
