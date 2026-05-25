# Work Batch Checkpoint Adversarial Review 01

Date: 2026-05-25

Scope:

- Checkpoint request/response transport under the Batch Worktree.
- Work Batch state/projection changes for pending and answered checkpoints.
- Runtime snapshot ingestion ordering.
- Batch card checkpoint response UI.
- Binding reconciliation for live, stale, and missing Claude Code sessions.

## Findings

No active medium, high, or critical findings remain.

## Findings Found And Resolved During Review

1. [Medium] Already answered checkpoints could be submitted again.
   - Evidence: The response path originally accepted any stored checkpoint by id, then rewrote the response and forced the batch summary back to a waiting continuation state.
   - Fix: `submitCheckpointResponse` now rejects non-pending checkpoints with `checkpointAlreadyAnswered`.
   - Code: `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:456`
   - Test: `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:1083`

2. [Medium] Missing Batch Cockpit Binding could mark a checkpoint answered without writing a response to the Batch Worktree.
   - Evidence: If the binding record was gone, the previous response path skipped writing the response file but still mutated state.
   - Fix: `submitCheckpointResponse` now requires the Batch Cockpit Binding before state mutation and returns `bindingNotFound` otherwise.
   - Code: `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:473`
   - Test: `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:1132`

3. [Medium] Stale binding reconciliation could hide a pending checkpoint behind reconnect copy.
   - Evidence: Manual arc-design-studio proof showed a pending checkpoint was ingested, then the missing-session reconciler changed the batch summary to `Claude Code session needs reconnect.`
   - Fix: pending checkpoint or `needs_you` task state keeps the user-facing checkpoint summary path, while the binding can still be marked stale internally.
   - Code: `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:97`
   - Tests: `apps/swift/Tests/CapacitorTests/WorkBatchBindingReconcilerTests.swift`

## Checks

- `swift test --package-path apps/swift --filter WorkBatchCheckpointExchangeTests --filter WorkBatchStateTests --filter WorkBatchTaskSessionTests --filter WorkBatchAutoRouterTests --filter WorkBatchBindingReconcilerTests --filter AppStateRuntimeSnapshotEffectTests`
- `swift test --package-path apps/swift`
- Manual arc-design-studio checkpoint ingest proof in `work-batch-checkpoint-manual-test-01.md`

## Residual Risk

The manual proof covered real-project checkpoint ingest and summary behavior, while response submission is covered by focused unit tests. A later UI dogfood pass should still exercise typing and submitting an answer directly through the visible app.
