# Work Batch In-Session Task Request Spec

## Product Intent

A user should be able to steer a Claude Code Work Batch session in plain language and have Capacitor stay in sync. If the user says something like "also fix the empty state copy" inside the session, Claude should not edit Capacitor state directly and should not ask the user to go back to the app to add a Task. It should write a narrow local request artifact. Capacitor ingests that artifact, creates the canonical Task, updates the Work Batch mirror, and lets the existing delivery loop pick it up.

This is a local callback, not a new runner. Claude Code remains the only worker host for this slice, and Capacitor remains the source of truth.

## Source-Backed Starting Point

- The Work Batch context mirror already lives at `.capacitor/work-batch-context.md` and tells Claude to use Task claim, Done, and Checkpoint artifacts so Capacitor can stay in sync.
- Task claims already come from `.capacitor/work-batch-claims/<task-id>.json` and only mark known queued Tasks as working.
- Done reports already come from `.capacitor/work-batch-completions/<task-id>.json` and only mark known Tasks done.
- Checkpoint requests already come from `.capacitor/work-batch-checkpoints/<checkpoint-id>.json` and turn known Tasks into `Needs You`.
- `AppState.applyRuntimeSnapshot` reconciles Work Batch bindings, ingests artifacts, then follows through on open queued Tasks.

The missing piece is a narrow artifact for "please create a new Task in this same Work Batch."

## V1 Behavior

Claude may write:

```json
{
  "task_id": "task-empty-state-copy",
  "title": "Fix empty state copy",
  "body": "The user asked for clearer copy in the empty state.",
  "source": "manual_user_instruction",
  "requested_at": "2026-05-27T19:02:00Z"
}
```

to:

```text
.capacitor/work-batch-task-requests/<task-id>.json
```

Capacitor will:

1. Read task request artifacts from each bound Work Batch worktree.
2. Ignore invalid or blank requests.
3. Create a queued `WorkBatchTaskRecord` in the bound batch.
4. Use `source_idea_id = nil` because this Task was created from inside the session, not from `ideas.md`.
5. Add a classification audit record that says the Task was added to the current Work Batch from an in-session request.
6. Rewrite `.capacitor/work-batch-context.md` so the session sees the new canonical Task.
7. Let the existing delivery policy decide whether to wake, resume, defer, or leave the session alone.

## Policy Choices

- Same-batch only for V1. An in-session Task request is treated as belonging to the current Work Batch because it came from that cockpit. If it sounds unrelated, Claude should ask a checkpoint or the user can add it in Capacitor later.
- Idempotent by `task_id`. If the same artifact is ingested twice, Capacitor should not create duplicates.
- Canonical state stays outside the worktree. The artifact is a request, not authority.
- Agent-written `requested_at` is accepted only up to the ingest time so a bad future clock cannot make later claim artifacts look stale.
- Work Batch request artifacts are a local file side channel, so Capacitor polls them on both fresh runtime snapshots and duplicate-version volatile refreshes. Writing a request file should not depend on the runtime service snapshot version changing.
- No new UI flow is required for this slice. The visible effect is that the Task appears under the Work Batch and participates in the existing queued/working/done/checkpoint lifecycle.
- No old Circuit runtime, runner, flow engine, task DAG, broad memory platform, new terminal/editor, or generalized host abstraction.

## Files To Change

- Add `apps/swift/Sources/Capacitor/Models/WorkBatchTaskRequest.swift`.
- Update `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift` so the mirror and hidden instructions mention Task request artifacts.
- Update `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift` with `ingestTaskRequests(projects:now:)`.
- Update `apps/swift/Sources/Capacitor/Models/AppState+Lifecycle.swift` to ingest requests before claims/done/checkpoints.
- Update `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift` with a small toast handler.
- Add focused Swift tests for the store, router ingestion, idempotence, blank rejection, mirror content, and lifecycle ordering.

## Acceptance Criteria

- A valid task request JSON in a bound Work Batch worktree creates exactly one queued Task in that batch.
- Re-ingesting the same artifact does not duplicate the Task.
- Blank requests are ignored.
- The Work Batch context mirror shows the new Task and documents the task-request path.
- Existing claims, Done reports, and checkpoints still work unchanged.
- Runtime snapshot ingestion handles task requests before task claims so a newly requested Task can be claimed on the next pass.
- Duplicate-version runtime polling still ingests new task request files.
- Focused Swift tests pass.
