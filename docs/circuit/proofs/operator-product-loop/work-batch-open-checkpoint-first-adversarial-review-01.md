# Work Batch Open Checkpoint-First Adversarial Review 01

Date: 2026-05-25

Scope:

- `apps/swift/Sources/Capacitor/Models/UIState.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/WorkBatchListSection.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchOpenActionResolverTests.swift`
- `apps/swift/Tests/CapacitorTests/AppStateWorkBatchOpenTests.swift`
- `docs/circuit/proofs/operator-product-loop/work-batch-open-checkpoint-first-manual-test-01.md`

Goal under review:

When a Work Batch is Waiting on a pending Checkpoint, primary Open Batch should surface the needed decision UI before opening or reconnecting the Claude Code cockpit. Direct cockpit access should remain available without reintroducing method selection, old Circuit runtime, runner/flow-engine/task-DAG behavior, broad memory, generalized multi-host abstraction, or SaaS framing.

## Findings

No medium, high, or critical findings.

## Attack Notes

- Open-action routing is centralized in `WorkBatchOpenActionResolver`, and it selects the first pending Checkpoint from the projection before falling through to cockpit opening.
- Pending Checkpoints are sorted ahead of answered Checkpoints and newest-first by `WorkBatchProjectionBuilder`, so the resolver's first pending Checkpoint is deterministic.
- `AppState.openWorkBatch` sets `workBatchCheckpointFocusTarget` and a neutral Checkpoint toast when a pending Checkpoint exists, so a missing cockpit binding cannot mask the required decision.
- `ProjectDetailView` filters the focus target by Project path before passing it to the Work Batch list.
- `WorkBatchListSection` filters the focus target by Work Batch ID before passing it to a Checkpoint card.
- The primary row content and terminal icon are separate buttons, so direct cockpit access does not also trigger checkpoint-first Open Batch.
- `submitWorkBatchCheckpointResponse` clears the focus target only when Project, Work Batch, and Checkpoint all match.

## Verification

- `swift test --package-path apps/swift --filter WorkBatchOpenActionResolverTests --filter AppStateWorkBatchOpenTests --filter WorkBatchAutoRouterTests --filter WorkBatchStateTests --filter WorkBatchCheckpointExchangeTests --filter WorkBatchTaskSessionTests --filter AppStateRuntimeSnapshotEffectTests`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh`

## Residual Risk

This review is fixture-backed rather than a live click-through with a real pending Checkpoint in the app. The remaining risk is visual/focus polish, not the routing decision or state transition.
