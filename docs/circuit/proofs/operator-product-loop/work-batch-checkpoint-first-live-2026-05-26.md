# Work Batch Checkpoint-First Live Proof

Date: 2026-05-26

## Scenario

Pending Work Batch checkpoints should interrupt cockpit re-entry and present an answer field in Capacitor. This is the alignment safeguard for the Task-to-Work-Batch model.

The live proof used a temporary, reversible checkpoint in the existing `parable-school` Work Batch state:

```text
Project: /Users/petepetrash/Code/parable-school
Batch: Typeface unification from source parable
Checkpoint: cp-live-checkpoint-routing-2026-05-26
```

Before injection, the original state was backed up to:

```text
/private/tmp/capacitor-parable-work-batches-state.before-checkpoint-live.json
```

After verification, the original state was restored and the temporary response artifact was removed.

## Intended Behavior

- The project card should show the checkpoint summary.
- Clicking the project card should open the checkpoint path before any Claude cockpit path.
- Project Detail should show the Work Batch as Waiting.
- The checkpoint card should show the question, reason, recommended action, answer field, and submit button.
- The answer field should receive focus.
- Submitting an answer should write a local checkpoint response artifact and close the pending checkpoint.
- The flow should not launch Ghostty, create a tmux session, or start Claude.

## Source Changes

- `WorkBatchOpenActionResolver` already resolves pending checkpoints before cockpit re-entry.
- `AppState.openWorkBatch` logs `route="checkpoint_review"`, opens Project Detail, and sets `workBatchCheckpointFocusTarget`.
- `WorkBatchListSection` now displays the checkpoint `recommendedAction` as `Recommended: ...` so the decision UI carries the worker's intended next step.
- `check-terminal-activation-state.sh` now reads frontmost app name, PID, and path from one AppleScript call to avoid split-sample focus evidence.

## Live Evidence

Injected checkpoint state after answer:

```json
{
  "batch_id": "batch-typeface-unification-from-source-parable-01ksfw1",
  "id": "cp-live-checkpoint-routing-2026-05-26",
  "question": "For live verification, should Capacitor show this checkpoint before opening Claude?",
  "reason": "This temporary proof checkpoint verifies that checkpoint-first routing interrupts the cockpit path with an answer field.",
  "recommended_action": "Answer yes, then confirm the checkpoint closes cleanly.",
  "requested_at": "2026-05-26T22:38:24Z",
  "responded_at": "2026-05-26T22:38:52Z",
  "response": "Yes. Checkpoint-first routing is working in the live Debug app.",
  "status": "answered",
  "task_id": "01KSK2QPJEJVNWY12ATPPEAQ3X",
  "updated_at": "2026-05-26T22:38:52Z"
}
```

Terminal activation trace:

```text
[2026-05-26T22:38:40.865Z] [TerminalActivation] surface="project_card" route="work_batch_primary" action="open_work_batch" outcome="checkpoint" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" evidence="pending_checkpoint"
[2026-05-26T22:38:40.865Z] [TerminalActivation] surface="project_card" route="checkpoint_review" action="show_checkpoint" outcome="needs_input" project_path="/Users/petepetrash/Code/parable-school" project="parable-school" batch_id="batch-typeface-unification-from-source-parable-01ksfw1" batch="Typeface unification from source parable" evidence="pending_checkpoint,project_detail_form" reason="cp-live-checkpoint-routing-2026-05-26"
```

Response artifact before cleanup:

```json
{
  "checkpoint_id" : "cp-live-checkpoint-routing-2026-05-26",
  "responded_at" : "2026-05-26T22:38:52Z",
  "response" : "Yes. Checkpoint-first routing is working in the live Debug app.",
  "task_id" : "01KSK2QPJEJVNWY12ATPPEAQ3X"
}
```

Final cleanup evidence:

```text
jq '[.checkpoints[] | select(.id=="cp-live-checkpoint-routing-2026-05-26")] | length' .../state.json
0

temporary response removed
```

Final live diagnostic:

```text
capacitor_debug_processes:
34706 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor

capacitor_release_processes:

claude_processes:
```

## Verification

Passed:

```bash
swift test --package-path apps/swift --filter 'AppStateWorkBatchOpenTests|WorkBatchOpenActionResolverTests|WorkBatchCheckpointExchangeTests|WorkBatchAutoRouterTests/testIngestCheckpointRequestsMarksBatchWaitingForUser|WorkBatchAutoRouterTests/testSubmitCheckpointResponseWritesResponseAndQueuesTask|WorkBatchAutoRouterTests/testSubmitCheckpointResponseForDoneTaskClosesStaleCheckpoint'
./scripts/ci/swiftformat-lint.sh
bats tests/dev-scripts/check-terminal-activation-state.bats
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh
```

Observed results:

```text
12 focused Swift checkpoint/open-action tests passed
SwiftFormat reported 0 files needing formatting
4 diagnostic Bats tests passed
canonical Debug restart passed
live checkpoint-first route passed
```

## Result

Pass. A pending checkpoint became the primary project-card path, opened Project Detail, focused the answer field, accepted a response, wrote the local response artifact, and returned the batch to its non-checkpoint state without launching a terminal or worker.

Remaining risk: the project card still presented the project as `Idle` even while its summary showed `Checkpoint ready`. The Work Batch row itself showed `Waiting`, and routing was correct, but project-card visual status may need a future attention projection pass.
