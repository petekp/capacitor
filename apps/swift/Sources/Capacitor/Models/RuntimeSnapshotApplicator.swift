import Foundation

@MainActor
final class RuntimeSnapshotApplicator {
    typealias LiveClaudeProcessEvidenceProvider = ([Project]) -> [String: LiveClaudeProjectProcessEvidence]

    struct RequestContext: Equatable {
        let generation: UInt64?
        let correlationId: String
        let projects: [Project]
    }

    struct Outcome: Equatable {
        let decision: Decision
        let effects: [Effect]
    }

    enum Decision: Equatable {
        case applied
        case ignoredStaleGeneration
        case ignoredStaleVersion
        case duplicateVersionNoop
        case failureHeld
        case failureCleared
    }

    enum Effect: Equatable {
        case updatePostSessionRefreshContext
        case reconcileDelegations([RuntimeDelegationState])
        case reconcileRunCaptures([RuntimeRunState])
    }

    private enum Constants {
        static let failureClearThreshold = 2
    }

    private let sessionStateManager: SessionStateManager
    private let shellStateStore: ShellStateStore
    private let routingStateStore: RoutingStateStore
    private let runState: RunStateStore
    private let uiState: UIState
    private let isDelegationLoopEnabled: () -> Bool
    private let liveClaudeProcessEvidenceProvider: LiveClaudeProcessEvidenceProvider

    private var requestGeneration: UInt64 = 0
    private var correlationCounter: UInt64 = 0
    private var lastAppliedSnapshotVersion: UInt64 = 0
    private var lastPolledSnapshotVersion: UInt64 = 0
    private var lastAppliedProjectStates: [RuntimeProjectState] = []
    private var lastAppliedSessions: [RuntimeSession] = []
    private var consecutiveRuntimeSnapshotFailures = 0

    init(
        sessionStateManager: SessionStateManager,
        shellStateStore: ShellStateStore,
        routingStateStore: RoutingStateStore,
        runState: RunStateStore,
        uiState: UIState,
        isDelegationLoopEnabled: @escaping () -> Bool,
        liveClaudeProcessEvidenceProvider: LiveClaudeProcessEvidenceProvider? = nil,
    ) {
        self.sessionStateManager = sessionStateManager
        self.shellStateStore = shellStateStore
        self.routingStateStore = routingStateStore
        self.runState = runState
        self.uiState = uiState
        self.isDelegationLoopEnabled = isDelegationLoopEnabled
        let processScanner = WorkBatchClaudeProcessScanner()
        self.liveClaudeProcessEvidenceProvider = liveClaudeProcessEvidenceProvider ?? { projects in
            processScanner.processEvidenceByProjectPath(for: projects)
        }
    }

    func beginFetch(projects: [Project]) -> RequestContext {
        requestGeneration &+= 1
        return RequestContext(
            generation: requestGeneration,
            correlationId: nextCorrelationId(),
            projects: projects,
        )
    }

    func makeLongPollContext(projects: [Project]) -> RequestContext {
        RequestContext(
            generation: nil,
            correlationId: nextCorrelationId(),
            projects: projects,
        )
    }

    func nextLongPollSinceVersion() -> UInt64 {
        max(lastPolledSnapshotVersion, lastAppliedSnapshotVersion)
    }

    func recordLongPollUnchanged(snapshotVersion: UInt64) {
        lastPolledSnapshotVersion = max(lastPolledSnapshotVersion, snapshotVersion)
    }

    func apply(_ snapshot: RuntimeSnapshot, context: RequestContext) -> Outcome {
        if let generation = context.generation, generation != requestGeneration {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_drop_stale cid=\(context.correlationId) generation=\(generation) current=\(requestGeneration)",
            )
            return Outcome(decision: .ignoredStaleGeneration, effects: [])
        }

        lastPolledSnapshotVersion = max(lastPolledSnapshotVersion, snapshot.snapshotVersion)

        if snapshot.snapshotVersion > 0 {
            if snapshot.snapshotVersion < lastAppliedSnapshotVersion {
                DebugLog.write(
                    "AppState.refreshSessionStates source=runtime_snapshot_drop_stale_version cid=\(context.correlationId) version=\(snapshot.snapshotVersion) current=\(lastAppliedSnapshotVersion)",
                )
                return Outcome(decision: .ignoredStaleVersion, effects: [])
            }

            if snapshot.snapshotVersion == lastAppliedSnapshotVersion {
                DebugLog.write(
                    "AppState.refreshSessionStates source=runtime_snapshot_volatile_refresh cid=\(context.correlationId) version=\(snapshot.snapshotVersion)",
                )
                // New Work Batch/Claude-process projection: the runtime snapshot version
                // protects durable service state, but live Claude process evidence is volatile.
                // Re-apply the last durable project/session state with fresh process evidence
                // so active cockpits can become Ready and then clear without a service version bump.
                sessionStateManager.applyRuntimeProjectStates(
                    lastAppliedProjectStates,
                    sessions: lastAppliedSessions,
                    liveClaudeProcessesByProjectPath: liveClaudeProcessEvidenceProvider(context.projects),
                    for: context.projects,
                    correlationId: context.correlationId,
                )
                consecutiveRuntimeSnapshotFailures = 0
                return Outcome(decision: .duplicateVersionNoop, effects: [.updatePostSessionRefreshContext])
            }
        }

        sessionStateManager.applyRuntimeProjectStates(
            snapshot.projectStates,
            sessions: snapshot.sessions,
            liveClaudeProcessesByProjectPath: liveClaudeProcessEvidenceProvider(context.projects),
            for: context.projects,
            correlationId: context.correlationId,
        )
        shellStateStore.applyRuntimeShellState(
            snapshot.shellState,
            correlationId: context.correlationId,
        )
        routingStateStore.applyRuntimeRoutingViews(
            snapshot.routingViews,
            correlationId: context.correlationId,
        )

        let delegationLoopEnabled = isDelegationLoopEnabled()
        runState.applyDelegationStates(
            snapshot.delegations,
            enabled: delegationLoopEnabled,
        )
        let previousRunsByID = runState.replaceRunStates(with: snapshot.runs)
        uiState.runCheckpointWindowTarget = runState.reconcileRunCheckpointWindowTarget(
            currentTarget: uiState.runCheckpointWindowTarget,
            previousRunsByID: previousRunsByID,
        )
        consecutiveRuntimeSnapshotFailures = 0

        let gcSessions = snapshot.sessions.filter { $0.gcReason != nil }
        if !gcSessions.isEmpty {
            DebugLog.write(
                "AppState.gc_reason sessions=\(gcSessions.map { "\($0.sessionId):\($0.gcReason ?? "")" }.joined(separator: ","))",
            )
        }

        DebugLog.write(
            "AppState.refreshSessionStates source=runtime_snapshot_apply cid=\(context.correlationId) projects=\(snapshot.projectStates.count) sessions=\(snapshot.sessions.count) shells=\(snapshot.shellState.shells.count) routing=\(snapshot.routingViews.count) runs=\(snapshot.runs.count)",
        )
        lastAppliedProjectStates = snapshot.projectStates
        lastAppliedSessions = snapshot.sessions
        lastAppliedSnapshotVersion = max(lastAppliedSnapshotVersion, snapshot.snapshotVersion)
        lastPolledSnapshotVersion = max(lastPolledSnapshotVersion, snapshot.snapshotVersion)

        var effects: [Effect] = []
        if delegationLoopEnabled {
            effects.append(.reconcileDelegations(snapshot.delegations))
        }
        effects.append(.reconcileRunCaptures(snapshot.runs))
        effects.append(.updatePostSessionRefreshContext)
        return Outcome(decision: .applied, effects: effects)
    }

    func recordFailure(context: RequestContext, errorDescription: String) -> Outcome {
        if let generation = context.generation, generation != requestGeneration {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_error_drop_stale cid=\(context.correlationId) generation=\(generation) current=\(requestGeneration)",
            )
            return Outcome(decision: .ignoredStaleGeneration, effects: [])
        }

        consecutiveRuntimeSnapshotFailures += 1
        DebugLog.write(
            "AppState.refreshSessionStates source=runtime_snapshot_error cid=\(context.correlationId) failures=\(consecutiveRuntimeSnapshotFailures) error=\(errorDescription)",
        )

        if consecutiveRuntimeSnapshotFailures >= Constants.failureClearThreshold {
            DebugLog.write(
                "AppState.refreshSessionStates source=runtime_snapshot_error_clear cid=\(context.correlationId) failures=\(consecutiveRuntimeSnapshotFailures)",
            )
            sessionStateManager.clearRuntimeProjectStates()
            shellStateStore.clearRuntimeShellState(correlationId: context.correlationId)
            routingStateStore.clearRuntimeRoutingViews(correlationId: context.correlationId)
            runState.clearDelegationStates()
            uiState.runCheckpointWindowTarget = nil
            return Outcome(decision: .failureCleared, effects: [.updatePostSessionRefreshContext])
        }

        return Outcome(decision: .failureHeld, effects: [.updatePostSessionRefreshContext])
    }

    private func nextCorrelationId() -> String {
        correlationCounter &+= 1
        return "app-snap-\(correlationCounter)"
    }

    #if DEBUG
        func setRequestGenerationForTesting(_ generation: UInt64) {
            requestGeneration = generation
        }
    #endif
}
