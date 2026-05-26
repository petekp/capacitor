# Work Batch Holistic Review: Adversarial Review 01

Date: 2026-05-25
Scope: In-flight Work Batch routing, reconciliation, cockpit re-entry, Activity panel Open behavior, tests, and proof notes. Excludes pre-existing unrelated `.claude/dead-code-report.md` dirt.

## Findings

No medium, high, or critical findings.

## Review Attacks

| Risk attacked | Evidence | Result |
| --- | --- | --- |
| Manual Work Batch open could still spawn a duplicate Claude/Ghostty cockpit when the visible tab already exists. | `WorkBatchAutoRouter.openCockpit` passes `preferFocusBeforeResume: true` at `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift:627-630`; `WorkBatchTaskSessionCoordinator.openExistingSession` tries `focusExistingTerminal` before resume at `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:485-512`. | Covered by `testManualOpenCanFocusStaleBindingBeforeResume`, `testManualOpenResumesStaleBindingWhenFocusFails`, and `testOpenCockpitFocusesVisibleStaleBindingBeforeResume`. |
| Automatic delivery might accidentally inherit manual focus-first behavior and stop waking/resuming queued Tasks. | `preferFocusBeforeResume` defaults to `false` at `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:485-489`; only user-initiated `openCockpit` passes `true`. | No regression found. Delivery policy remains queue/wake/resume based. |
| Completed batches could stay stuck in `Waiting` because stale duplicate cockpits are still visible. | All-done batches are marked done/idle before duplicate handling when the batch does not need the user at `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:82-91`; summary cleanup is limited by `shouldReplaceSummaryAfterCompletion` at `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:237-257` and `307-313`. | Covered by `testDoneBindingStaysDoneWhenTerminalIsStillAliveAndAllTasksAreDone` and `testDoneBatchIgnoresDuplicateOldCockpitsWhenAllTasksAreDone`. |
| Checkpoint UI could be hidden by all-done cleanup or duplicate-cockpit summaries. | `needsUser` is computed before cleanup at `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:52-54`; pending decisions win over duplicate summaries at `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:69-79`; all-done cleanup requires `!needsUser` at `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift:82-91`. | Covered by `testPendingCheckpointPreventsAllDoneCleanupEvenWhenTaskWasMarkedDone` and `testPendingCheckpointSummaryWinsOverDuplicateCockpitSummary`. |
| Activity panel Open could bypass Work Batch routing and launch a legacy project terminal. | Tracked projects now call `handlePrimaryProjectAction(for:)` at `apps/swift/Sources/Capacitor/Views/Projects/ActivityPanel.swift:204-208`; only ad hoc untracked creations retain the legacy launch fallback at `apps/swift/Sources/Capacitor/Views/Projects/ActivityPanel.swift:224-227`. | No regression found. This preserves legacy fallback only where no tracked project exists. |

## Checks

- `git diff --check -- <reviewed files>` passed.
- `swift test --package-path apps/swift --filter 'WorkBatchBindingReconcilerTests|WorkBatchTaskSessionTests|WorkBatchAutoRouterTests|WorkBatchProjectPrimaryActionResolverTests|AppStateWorkBatchOpenTests'` passed: 79 tests, 0 failures.
- `swift test --package-path apps/swift` passed: 886 XCTest tests, 1 skipped, 0 failures; 19 Swift Testing tests passed.
- `CARGO_INCREMENTAL=0 cargo test -p capacitor-core -j1 --quiet` passed.
- `./scripts/dev/restart-alpha-stable.sh` completed and left `CapacitorDebug.app` plus `hud-hook serve --port 7474` running.

## Residual Risk

The final checkpoint-priority hardening was verified by automated tests rather than a fresh UI click path because it covers an inconsistent runtime state. The user-visible click/no-new-window behavior was already manually smoked and recorded in `manual-work-batch-holistic-review-2026-05-25T1711.png`.
