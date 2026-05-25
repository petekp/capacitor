# Work Batch Open Checkpoint-First Manual Test 01

Date: 2026-05-25

Type: fixture-backed UI/state proof

## Product Rule

When a Work Batch is Waiting on a pending Checkpoint, the primary Open Batch action should surface the Checkpoint decision UI before opening or reconnecting the Claude Code cockpit.

Direct cockpit access remains available through the terminal button.

## Fixture

Used a Work Batch projection for `Mobile prototype` with:

- Work Batch status: `waiting`
- Task status: `needs_you`
- Pending Checkpoint: `checkpoint-green-token`
- No Batch Cockpit Binding in the AppState open-behavior test

The missing binding is intentional. If Open Batch incorrectly fell through to cockpit behavior, AppState would show the missing binding error instead of focusing the Checkpoint decision surface.

## Verification

Focused tests passed:

`swift test --package-path apps/swift --filter WorkBatchOpenActionResolverTests --filter AppStateWorkBatchOpenTests --filter WorkBatchAutoRouterTests --filter WorkBatchStateTests --filter WorkBatchCheckpointExchangeTests --filter WorkBatchTaskSessionTests --filter AppStateRuntimeSnapshotEffectTests`

Observed assertions:

- `WorkBatchOpenActionResolver` chooses the newest pending Checkpoint before cockpit opening.
- `AppState.openWorkBatch` sets `workBatchCheckpointFocusTarget` for the pending Checkpoint.
- `AppState.openWorkBatch` does not show the missing cockpit binding error when a pending Checkpoint exists.
- The Work Batch row separates the primary Open Batch hit target from the terminal button, so direct cockpit access does not also trigger checkpoint-first Open Batch.
- Repeated Open Batch attempts generate fresh focus requests so the same Checkpoint answer field can be refocused.
- Checkpoint focus targets are scoped to the current Project and Work Batch, so a matching Checkpoint ID elsewhere cannot steal focus.
- Work Batches without pending Checkpoints still fall through to the existing cockpit path.
- AppState checkpoint response follow-through clears the matching focus target after the answer is accepted.
- Router checkpoint response follow-through still writes the response, marks the Checkpoint answered, requeues the Task, and rewrites Work Batch Context.

Full Swift test suite passed:

`swift test --package-path apps/swift`

Observed total:

- 828 XCTest tests, 1 skipped, 0 failures.
- 19 Swift Testing tests, 0 failures.

## Result

Pass.

The primary Open Batch behavior is now checkpoint-first, while direct Agent Cockpit access remains available.
