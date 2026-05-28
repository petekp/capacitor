# Work Batch In-Session Task Request Manual Test

Date: 2026-05-27 local / 2026-05-28 UTC

## Goal

Prove that a Task request written from inside a bound Work Batch worktree is picked up by the live Capacitor Debug app, becomes canonical Work Batch state, is reflected in the context mirror, and continues through the existing claim/Done lifecycle without requiring the user to understand the plumbing.

## Preflight

- Rebuilt and relaunched with `./scripts/dev/restart-alpha-stable.sh`.
- Confirmed correct app with `./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost`.
- The guard reported:
  - front app: `Capacitor`
  - app path: `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app`
  - no release, preview, or non-debug Capacitor process.

## Initial State

Project data:

```text
/Users/petepetrash/.capacitor/projects/p2_%2FUsers%2Fpetepetrash%2FCode%2Fcapacitor
```

Target Work Batch:

```text
batch-verify-work-batch-delivery-queue-functionality-0
```

Before the test:

- Batch status: `idle`
- Binding status: `done`
- Bound Claude session: `969b6a42-db35-47fe-b30d-b150af9a9c27`
- Worktree: `/Users/petepetrash/Code/capacitor/.capacitor/worktrees/batch-verify-work-batch-delivery-queue`
- Existing batch task count: 1
- Tracked worktree changes: none

## Test Input

Seeded the same artifact a Claude Code session is instructed to write:

```text
/Users/petepetrash/Code/capacitor/.capacitor/worktrees/batch-verify-work-batch-delivery-queue/.capacitor/work-batch-task-requests/task-manual-in-session-request-smoke-20260528.json
```

Request:

```json
{
  "body": "Manual live smoke test for Capacitor's in-session Task request callback. Do not edit files; claim and mark this task done after confirming the context mirror includes it.",
  "requested_at": "2026-05-28T02:44:30Z",
  "source": "manual_user_instruction",
  "task_id": "task-manual-in-session-request-smoke-20260528",
  "title": "Manual in-session request smoke test"
}
```

## Observed Result

Within one live app polling window, Capacitor:

- Added `task-manual-in-session-request-smoke-20260528` to the existing Work Batch.
- Added a classification record with `target_kind: existing`, `confidence: 1`, and rationale pointing at the request artifact.
- Rewrote `.capacitor/work-batch-context.md`.
- Resumed the existing bound Claude session `969b6a42-db35-47fe-b30d-b150af9a9c27`.
- Received a Task claim artifact.
- Received a Done artifact.
- Marked the Task `done`.
- Left the batch visible as `ready`.

The context mirror contained:

```text
Task request path: .capacitor/work-batch-task-requests/<task-id>.json
- [done] Manual in-session request smoke test (`task-manual-in-session-request-smoke-20260528`)
```

Claim artifact:

```text
.capacitor/work-batch-claims/task-manual-in-session-request-smoke-20260528.json
```

Done artifact:

```text
.capacitor/work-batch-completions/task-manual-in-session-request-smoke-20260528.json
```

The Done report said no project files were edited, and `git -C <batch-worktree> status --short` returned clean.

## Issue Found And Fixed

Manual testing exposed a real gap before this proof passed: Work Batch artifact ingestion only ran when the runtime snapshot version advanced. A local request file does not necessarily change the runtime service snapshot version, so the app could miss request files during ordinary duplicate-version polling.

Fix:

- `AppState.applyRuntimeSnapshot` now polls Work Batch artifacts for both fresh runtime snapshots and duplicate-version volatile refreshes.
- Added `AppStateRuntimeSnapshotEffectTests.testRuntimeSnapshotDuplicateVersionPollsWorkBatchTaskRequests`.

## Verification Commands

```text
swift test --package-path apps/swift --filter 'AppStateRuntimeSnapshotEffectTests|WorkBatchTaskRequestTests|WorkBatchAutoRouterTests/testIngestTaskRequest'
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
git -C /Users/petepetrash/Code/capacitor/.capacitor/worktrees/batch-verify-work-batch-delivery-queue status --short
```

Focused Swift verification passed: 14 tests, 0 failures.

## Result

Pass. The live Debug app ingested an in-session Task request from the bound batch worktree, delivered it through the existing Work Batch lifecycle, and kept the session/project state honest.
