import Foundation

@MainActor
struct RuntimeSnapshotEffectHandlers {
    let updatePostSessionRefreshContext: @MainActor () -> Void
    let reconcileDelegations: @MainActor ([RuntimeDelegationState]) -> Void
    let reconcileRunCaptures: @MainActor ([RuntimeRunState]) -> Void

    static func live(
        delegationLoopManager: DelegationLoopManager?,
        runCaptureCoordinator: RunCaptureCoordinator,
        updatePostSessionRefreshContext: @escaping @MainActor () -> Void,
    ) -> RuntimeSnapshotEffectHandlers {
        RuntimeSnapshotEffectHandlers(
            updatePostSessionRefreshContext: updatePostSessionRefreshContext,
            reconcileDelegations: { delegations in
                _Concurrency.Task { [delegationLoopManager] in
                    await delegationLoopManager?.reconcile(delegations: delegations)
                }
            },
            reconcileRunCaptures: { runs in
                _Concurrency.Task { [runCaptureCoordinator] in
                    await runCaptureCoordinator.reconcile(runs: runs)
                }
            },
        )
    }
}
