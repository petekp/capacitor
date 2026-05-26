# Work Batch Task Delivery Implementation Adversarial Review 02

Date: 2026-05-25
Reviewer stance: second independent hostile review, focused on contract drift and UX state leaks.

## Scope Reviewed

Reviewed the implementation against the agreed UX:

- Users add Tasks; Capacitor routes and manages delivery.
- Related Tasks join the right visible Work Batch/session.
- Healthy running Claude Code sessions are not duplicated.
- Checkpoints remain the alignment safeguard.
- Claude Code is the only worker host for this slice.

## Findings

No medium, high, or critical findings.

## Attack Notes

1. Mirror contract drift
   - Evidence: `WorkBatchContextMirror` now says the mirror is the current agent-readable view and that Capacitor keeps canonical state outside the worktree.
   - Evidence: `rg` found no remaining `source of truth` wording in the changed Work Batch mirror source; the test asserts that phrase is absent.
   - Verification: `WorkBatchTaskSessionTests.testContextMirrorRendersTasksAndCheckpointGuidance`.

2. Pickup callback contract
   - Evidence: mirror and initial/resume prompts tell Claude Code to write the Task claim before starting queued work.
   - Evidence: claim JSON includes `task_id`, `status`, `summary`, `claimed_at`, `context_updated_at`, and optional `delivery_generation`.
   - Verification: `WorkBatchTaskClaimTests`; `WorkBatchTaskSessionTests.testInitialPromptIsSingleLineForTerminalLaunchScripts`; `WorkBatchTaskSessionTests.testResumePromptIsSingleLineAndNudgesClaudeBackToBatchContext`.

3. AppState follow-through
   - Evidence: runtime snapshot application reconciles bindings, then ingests claims, Done reports, follow-through delivery, and checkpoint requests in that order.
   - Evidence: Unresolve and checkpoint response now call `followThroughWorkBatchDelivery` instead of duplicating a local resume rule.
   - Verification: `AppStateRuntimeSnapshotEffectTests`; `AppStateWorkBatchOpenTests.testCheckpointResponseClearsMatchingFocusTargetAfterFollowThrough`.

4. Visible copy cannot preserve unrelated stale summaries for queued work
   - Evidence: Work Batch projection synthesizes `Queued <Task>.` for working batches with queued work and no claimed working Task.
   - Evidence: Work Batch projection synthesizes `Working on <Task>. 1 queued.` when claimed work and queued work coexist.
   - Verification: `WorkBatchStateTests.testProjectionSummaryMentionsQueuedTaskWhenNotClaimed`; `WorkBatchStateTests.testProjectionSummaryPrefersClaimedWorkingTaskAndQueuedCount`; `ProjectCardContextLineResolverTests.testWorkBatchSummaryWinsOverLegacySessionSummary`.

5. Live app smoke
   - Evidence: `./scripts/dev/restart-alpha-stable.sh` rebuilt and relaunched the app.
   - Evidence: `pgrep -fl CapacitorDebug` showed both the app process and `hud-hook serve --port 7474`.
   - Evidence: Computer Use inspection showed the Capacitor project list rendered and `parable-school` displayed a Work Batch recovery summary.

## Checks Run

```bash
rg -n "source of truth|Task claim|delivery_generation|shouldResumeWorkBatchBinding|run method|Run Method" apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift apps/swift/Sources/Capacitor/Models/AppState+Projects.swift apps/swift/Sources/Capacitor/Models/AppState+Lifecycle.swift apps/swift/Sources/Capacitor/Models/WorkBatchState.swift apps/swift/Tests/CapacitorTests/WorkBatchTaskSessionTests.swift apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift
swift test --package-path apps/swift --filter 'WorkBatch(TaskClaim|DeliveryPolicy|TaskSession|State|BindingReconciler|AutoRouter|CheckpointExchange|CompletionReport)Tests|AppStateRuntimeSnapshotEffectTests|ProjectCardContextLineResolverTests'
swift test --package-path apps/swift
./scripts/dev/restart-alpha-stable.sh
```

## Residual Risk

The next risk is product-behavioral, not an implementation blocker: live Claude Code must consistently follow the mirror instructions and write claims. This implementation makes non-compliance visible by leaving Tasks queued rather than pretending they are working.
