# Unrelated Task Routing Live Proof

Date: 2026-05-26

## Scenario

Adding a Task that is unrelated to an existing Work Batch should create a separate visible Work Batch, with its own worktree and Claude Code session.

This proof used a disposable pinned project:

```text
/private/tmp/capacitor-operator-routing-fixture-20260526
```

The project already had one completed Work Batch:

```text
Batch: Typography Notes
Task: create typography-note.txt with one sentence about checking the headline type scale
Session: d18a4191-fa5e-46eb-8c1e-85365013c8b1
Worktree: /tmp/capacitor-operator-routing-fixture-20260526/.capacitor/worktrees/batch-typography-notes-01kskbemqay4b7q
```

Then the live Debug app added this second Task through the normal `Add Task...` UI:

```text
In this disposable routing fixture, create export-note.txt with one sentence about checking CSV export field ordering. Keep the change tiny and local.
```

## Source Fix Under Test

The earlier live run exposed a false grouping bug: the low-confidence relatedness guard treated two unrelated Tasks as related because both prompts shared project/scaffold words such as `disposable`, `fixture`, `create`, `note`, `sentence`, and `local`.

The fix keeps the model as the primary classifier, but makes the deterministic relatedness guard ignore project identity and generic scaffold words before overriding a low-confidence new-batch classification.

Covered source:

```text
apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift
apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift
```

Focused regression:

```bash
swift test --package-path apps/swift --filter 'WorkBatchAutoRouterTests/testLowConfidenceNewTypographyClassificationIsKeptInExistingActiveBatch|WorkBatchAutoRouterTests/testLowConfidenceNewUnrelatedClassificationIsNotOverriddenByProjectScaffoldWords|WorkBatchAutoRouterTests/testHighConfidenceUnrelatedNewClassificationStillStartsSeparateBatch'
```

Result:

```text
Executed 3 tests, with 0 failures.
```

## Live Debug Preconditions

Strict Debug-app preflight passed before the manual UI action:

```text
front_app_path: /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app

capacitor_debug_processes:
94828 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor

capacitor_release_processes:

capacitor_non_debug_processes:
```

## Live Result

Work Batch state after adding the second Task:

```json
{
  "batches": [
    {
      "id": "batch-typography-notes-01kskbemqay4b7qx7gxtbc6mv5",
      "name": "Typography Notes",
      "status": "ready",
      "taskIDs": ["01KSKBEMQAY4B7QX7GXTBC6MV5"]
    },
    {
      "id": "batch-export-notes-01kskbsfc4nd67fktagk6gk3qg",
      "name": "Export Notes",
      "status": "ready",
      "taskIDs": ["01KSKBSFC4ND67FKTAGK6GK3QG"]
    }
  ],
  "classifications": [
    {
      "taskID": "01KSKBSFC4ND67FKTAGK6GK3QG",
      "targetKind": "new",
      "confidence": 0.7,
      "rationale": "Different domain concern (CSV export field ordering) from existing batch (typography). Separate exploration areas within the fixture, though both follow the same note-creation pattern."
    }
  ]
}
```

Cockpit bindings after routing:

```json
[
  {
    "batchName": "Typography Notes",
    "claudeSessionID": "d18a4191-fa5e-46eb-8c1e-85365013c8b1",
    "worktreePath": "/tmp/capacitor-operator-routing-fixture-20260526/.capacitor/worktrees/batch-typography-notes-01kskbemqay4b7q"
  },
  {
    "batchName": "Export Notes",
    "claudeSessionID": "ec31e9ba-a76c-41f0-8cae-055f08d82963",
    "worktreePath": "/tmp/capacitor-operator-routing-fixture-20260526/.capacitor/worktrees/batch-export-notes-01kskbsfc4nd67fktag"
  }
]
```

Process evidence:

```text
98780 /Users/petepetrash/.local/bin/claude --session-id d18a4191-fa5e-46eb-8c1e-85365013c8b1 --permission-mode dontAsk --name Typography Notes --append-system-prompt-file .capacitor/work-batch-agent-instructions.md Assessing tasks...
10494 /Users/petepetrash/.local/bin/claude --session-id ec31e9ba-a76c-41f0-8cae-055f08d82963 --permission-mode dontAsk --name Export Notes --append-system-prompt-file .capacitor/work-batch-agent-instructions.md Assessing tasks...
```

Generated artifacts:

```text
/private/tmp/capacitor-operator-routing-fixture-20260526/.capacitor/worktrees/batch-export-notes-01kskbsfc4nd67fktag/export-note.txt
/private/tmp/capacitor-operator-routing-fixture-20260526/.capacitor/worktrees/batch-export-notes-01kskbsfc4nd67fktag/.capacitor/work-batch-claims/01KSKBSFC4ND67FKTAGK6GK3QG.json
/private/tmp/capacitor-operator-routing-fixture-20260526/.capacitor/worktrees/batch-export-notes-01kskbsfc4nd67fktag/.capacitor/work-batch-completions/01KSKBSFC4ND67FKTAGK6GK3QG.json
```

Done artifact:

```json
{
  "task_id": "01KSKBSFC4ND67FKTAGK6GK3QG",
  "status": "done",
  "summary": "Created export-note.txt with one sentence about checking CSV export field ordering",
  "evidence": [
    "export-note.txt contains: Verify that the CSV export writes columns in the expected field order before shipping."
  ]
}
```

Visible Debug UI evidence:

```text
Project card: capacitor-operator-routing-fixture-20260526, Ready for input
Project Detail: WORK BATCHES 0 queued tasks
Work Batch: Export Notes, Ready, 0 queued tasks
Work Batch: Typography Notes, Ready, 0 queued tasks
```

## Cockpit Re-entry Check

Clicking the `Export Notes` terminal icon focused the bound export cockpit:

```text
[2026-05-27T00:03:14.762Z] [TerminalActivation] surface="work_batch_session" route="work_batch_cockpit" action="focus_existing" outcome="focused" project_path="/tmp/capacitor-operator-routing-fixture-20260526/.capacitor/worktrees/batch-export-notes-01kskbsfc4nd67fktag" batch_id="batch-export-notes-01kskbsfc4nd67fktagk6gk3qg" batch="Export Notes" session="ec31e9ba-a76c-41f0-8cae-055f08d82963" evidence="batch_binding,visible_terminal"
[2026-05-27T00:03:14.763Z] [TerminalActivation] surface="terminal_icon" route="work_batch_cockpit" action="open_cockpit" outcome="focused_existing" project_path="/private/tmp/capacitor-operator-routing-fixture-20260526" batch_id="batch-export-notes-01kskbsfc4nd67fktagk6gk3qg" batch="Export Notes" session="ec31e9ba-a76c-41f0-8cae-055f08d82963" evidence="batch_binding,batch_worktree"
```

Diagnostic snapshot after the click:

```text
ghostty_windows:
* Export Notes

claude_processes:
98780 session_id=d18a4191-fa5e-46eb-8c1e-85365013c8b1 name="Typography Notes"
10494 session_id=ec31e9ba-a76c-41f0-8cae-055f08d82963 name="Export Notes"
```

## Path Note

For this `/private/tmp` fixture, Ideas were stored under the original `/private/tmp` project key while Work Batch state used the normalized `/tmp` project key. The live product projects under `/Users/petepetrash/Code/...` are not affected by this symlink alias, but the inconsistency is worth tracking if future tests depend on `/private/tmp`.

Follow-up hardening was completed in `project-storage-key-alias-hardening-2026-05-26.md`. Core per-project storage now normalizes `/private/tmp/...` to `/tmp/...` before choosing the live Capacitor storage key.

## Result

Pass.

- The unrelated CSV/export Task created a separate `Export Notes` Work Batch.
- The existing `Typography Notes` Work Batch stayed intact.
- Each Work Batch had its own task, worktree, binding, and Claude session.
- The Project Detail UI showed both batches as visible top-level Work Batch rows.
- The `Export Notes` terminal action focused its own bound cockpit instead of the typography cockpit.

## Cleanup

After recording evidence:

- Restored the original `~/.capacitor/projects.json` from the pre-test backup.
- Removed the disposable fixture project and both Capacitor project-state directories.
- Stopped both fixture Claude sessions.
- Relaunched Capacitor Debug with `./scripts/dev/restart-alpha-stable.sh --swift-only`.
- Closed leftover disposable Ghostty tabs.
- Re-ran the strict Debug preflight. It showed the repo Debug app frontmost, no non-Debug Capacitor processes, and no fixture Claude processes.
