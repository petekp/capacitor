# Work Batch Holistic Review: Adversarial Review 02

Date: 2026-05-25
Scope: Second independent pass over the same final Work Batch change set after Review 01 found no medium-or-above issues.

## Findings

No medium, high, or critical findings.

## Scenario Matrix

| Scenario | Expected behavior | Evidence reviewed | Result |
| --- | --- | --- | --- |
| User clicks a stale bound batch whose Claude tab is still visible. | Focus the existing tab; do not run `claude --resume`. | `preferFocusBeforeResume` path at `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:485-512`; router call at `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:627-630`; tests at `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:148-230` and `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift:1328-1360`. | Pass. |
| User clicks a stale bound batch and no existing tab can be focused. | Resume the assigned Claude session in the batch worktree. | `allowResumeWhenFocusFails` fallback at `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:490-512`; regression test at `apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift:190-230`. | Pass. |
| Batch has all Tasks done while old duplicate Claude sessions are still present. | Keep the batch idle/done and do not surface duplicate cockpit attention. | Completion short-circuit at `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:82-91`; regression test at `apps/swift/Tests/CapacitorTests/WorkBatchBindingReconcilerTests.swift:200-228`. | Pass. |
| Batch has a pending checkpoint plus duplicate cockpit evidence. | Keep the checkpoint visible, but preserve duplicate-cockpit issue evidence. | Checkpoint-first duplicate branch at `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:69-79`; regression test at `apps/swift/Tests/CapacitorTests/WorkBatchBindingReconcilerTests.swift:269-312`. | Pass. |
| Tracked completed creation is opened from Activity. | Re-enter through project primary action, so Work Batch routing still applies. | `ActivityPanel.openProject` tracked branch at `apps/swift/Sources/Capacitor/Views/Projects/ActivityPanel.swift:204-208`; primary action behavior in `apps/swift/Sources/Capacitor/Models/AppState+Projects.swift:304-345`. | Pass. |
| Untracked ad hoc creation is opened from Activity. | Fall back to the legacy terminal path because no tracked Work Batch surface exists. | Explicit legacy fallback at `apps/swift/Sources/Capacitor/Views/Projects/ActivityPanel.swift:224-227`. | Pass. |

## Checks

- Re-read final diff for changed Work Batch source, tests, and proof docs.
- Confirmed reviewed files pass `git diff --check`.
- Confirmed focused Swift, full Swift, Rust core, app restart, and manual smoke evidence are recorded in `work-batch-holistic-review-2026-05-25.md`.

## Residual Risk

No remaining medium-or-above risk found. The next sensible cleanup is mechanical: split `WorkBatchState.swift` into smaller files without changing behavior.
