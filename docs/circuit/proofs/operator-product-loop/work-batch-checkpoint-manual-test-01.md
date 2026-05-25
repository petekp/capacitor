# Work Batch Checkpoint Manual Test 01

Date: 2026-05-25

Project: `/Users/petepetrash/Code/ever/arc-design-studio`

Batch: `Mobile Prototype Polish`

Task: `01KSERAYXHGN3ATS8C4JRE50P9`

## Setup

Seeded a checkpoint request into the batch worktree:

`/Users/petepetrash/Code/ever/arc-design-studio/.capacitor/worktrees/batch-mobile-prototype-polish-01kseray/.capacitor/work-batch-checkpoints/manual-checkpoint-green-token.json`

The request asked:

`Should the green border use the production success token or a temporary debug color?`

The batch was temporarily placed in a working state with its existing Claude Code binding preserved.

## Verification

After restarting Capacitor with:

`./scripts/dev/restart-alpha-stable.sh`

Capacitor ingested the request into canonical Work Batch state:

- Batch status: `waiting`
- Batch summary: `Checkpoint needs your input.`
- Task status: `needs_you`
- Binding status: `stale`
- Context mirror included a pending checkpoint entry for `manual-checkpoint-green-token`

The stale binding is expected for this fixture because no matching live Claude Code process was present. The important UX behavior is that the batch card remains focused on the user-facing checkpoint, while stale/reconnect state stays implementation detail until the user responds or opens the cockpit.

## Regression Caught

The first manual run exposed that `WorkBatchBindingReconciler` could overwrite a pending checkpoint summary with `Claude Code session needs reconnect.` when the bound Claude session was missing.

Fixed behavior:

- Pending checkpoint state keeps the Task and Batch in the user-facing `Needs You` path.
- A missing Claude session can still mark the binding `stale`.
- Reconnect/stale summaries no longer hide the checkpoint from the batch card.

Regression tests added:

- `WorkBatchBindingReconcilerTests.testPendingCheckpointKeepsMissingBindingSummaryFocusedOnUserInput`
- `WorkBatchBindingReconcilerTests.testPendingCheckpointReclaimsReconnectSummary`

## Cleanup

The temporary project state, binding state, context mirror, completion artifact, and seeded checkpoint file were backed up before the test and restored after the test.
