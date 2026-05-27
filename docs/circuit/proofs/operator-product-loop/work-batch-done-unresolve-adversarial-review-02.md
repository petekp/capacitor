# Work Batch Done And Unresolve Adversarial Review 02

Date: 2026-05-25

Scope: second clean adversarial review of the Work Batch Done and Unresolve slice after Review 01 fixes.

## Rechecked Failure Modes

- Done reports are narrow, local files in the Batch Worktree and do not require old Circuit runtime or a new runner.
- Report parsing is tolerant of malformed JSON and only ingests `status: done`.
- Done ingest updates canonical Work Batch state, source Task status, Batch summary, binding status, context mirror, and user notification.
- Done ingest is idempotent because already Done Tasks are skipped.
- Partial completion keeps the Work Batch active or waiting according to remaining open Tasks and binding state.
- Unresolve returns the Task to queued/open, deletes stale completion reports, keeps the same Work Batch, and reuses the existing Batch Cockpit Binding.
- Stale/waiting/done bindings can be resumed from the same Batch Worktree; running/launching bindings are not needlessly relaunched.
- A completed binding remains Done even if the terminal remains open with no open Tasks.
- Capacitor's `.capacitor/` mirror/report metadata is locally ignored through Git's common `info/exclude`, including real Git worktrees that use `.git` files plus `commondir`.
- The UI exposes Unresolve as a task action without making it a cockpit-open click target.
- The product language remains Task, Work Batch, Batch Cockpit Binding, Batch Worktree, Quiet Execution, Checkpoint, Done, and Unresolve.

## Evidence

- Source paths reviewed: `WorkBatchCompletionReport.swift`, `WorkBatchTaskSession.swift`, `WorkBatchAutoRouter.swift`, `WorkBatchBindingReconciler.swift`, `AppState+Lifecycle.swift`, `AppState+Projects.swift`, `ProjectDetailsManager.swift`, `WorkBatchListSection.swift`, `ProjectDetailView.swift`, and `CONTEXT.md`.
- Focused verification passed after the last code changes: `swift test --package-path apps/swift --filter WorkBatchCompletionReportTests --filter WorkBatchTaskSessionTests --filter WorkBatchAutoRouterTests --filter WorkBatchBindingReconcilerTests --filter AppStateRuntimeSnapshotEffectTests`.
- Full Swift verification passed after the last code changes: `swift test --package-path apps/swift`.
- App relaunch verification passed after the last code changes: `./scripts/dev/restart-alpha-stable.sh`.
- Live arc-design-studio worktree metadata check returned clean status for `.capacitor/work-batch-completions` and `.capacitor/work-batch-context.md`.

## Findings

No medium, high, or critical findings.

Low residual risks:

- The worker must still follow the context mirror and write the Done report. This is acceptable for this slice because the report format is explicit and Unresolve is the correction path.
- Done evidence is stored and ingested, but the current UI does not yet expose a rich evidence packet. That remains future checkpoint/evidence UI work, not a blocker for this narrow Done/Unresolve slice.
- The local metadata ignore writes to the repo's common Git exclude, which also ignores root `.capacitor/` metadata. That is intentional for Capacitor-owned runtime files and preferable to dirtying user worktrees.

## Result

Second consecutive clean adversarial review for medium-or-above findings.
