# Work Batch Task Delivery Implementation Adversarial Review 01

Date: 2026-05-25
Reviewer stance: hostile review of the in-flight Work Batch Task delivery implementation.

## Scope Reviewed

Reviewed the Swift changes for:

- Task claim callback storage and ingestion.
- Delivery generation state.
- Delivery policy extraction.
- Router integration for capture route, Done follow-through, checkpoint response, and Unresolve.
- AppState runtime snapshot integration.
- Work Batch projection summary changes.
- Tests covering routing, claims, policy, runtime snapshot effects, and project card summaries.

Excluded `.claude/dead-code-report.md` because it was pre-existing unrelated local dirt.

## Findings

No medium, high, or critical findings.

## Attack Notes

1. Claim freshness and state precedence
   - Evidence: `WorkBatchAutoRouter.ingestTaskClaims` only mutates queued Tasks, requires `claimedAt >= task.updatedAt`, and rejects mismatched delivery generations.
   - Evidence: `AppState.applyRuntimeSnapshot` ingests claims before Done and Checkpoint artifacts, so Done/Checkpoint still win in the same refresh cycle.
   - Verification: `WorkBatchAutoRouterTests.testIngestTaskClaimIgnoresForeignDoneNeedsYouStaleAndWrongGenerationClaims`; `AppStateRuntimeSnapshotEffectTests.testRuntimeSnapshotApplyIngestsWorkBatchTaskClaims`.

2. Repeated resume suppression
   - Evidence: `WorkBatchDeliveryPolicy.alreadyAttemptedCurrentGeneration` suppresses only when the recorded resume attempt is at or after the current context write.
   - Evidence: `markResumeStarted` records the delivery attempt when a resume succeeds.
   - Verification: `WorkBatchDeliveryPolicyTests.testExistingDeliveryAttemptSuppressesRepeatedResume`; `WorkBatchDeliveryPolicyTests.testOlderDeliveryAttemptDoesNotSuppressNewGeneration`; `WorkBatchAutoRouterTests.testDoneIngestWithQueuedTaskRunsDeliveryPolicy`.

3. Checkpoint-first behavior
   - Evidence: `applyDeliveryPolicy` handles `waitForCheckpoint` by restoring the batch to waiting with a checkpoint summary.
   - Verification: `WorkBatchAutoRouterTests.testPendingCheckpointPreventsResumeAfterNewRelatedTask`; `WorkBatchOpenActionResolverTests.testOpenActionAnswersNewestPendingCheckpointBeforeOpeningCockpit`.

4. Duplicate cockpit behavior
   - Evidence: delivery policy maps duplicate cockpit reconciliation issues to `waitForDuplicateCockpit`.
   - Evidence: router marks the batch waiting and does not resume.
   - Verification: `WorkBatchAutoRouterTests.testRelatedTaskDoesNotResumeWhenDuplicateBatchCockpitExists`; `WorkBatchBindingReconcilerTests.testDifferentSessionInSameBatchWorktreeFlagsDuplicateInsteadOfAdopting`.

5. New Ghostty window/session regression
   - Evidence: healthy running bindings return `queueOnly` when the exact live session exists.
   - Evidence: route tests assert no terminal launch for an existing running binding.
   - Verification: `WorkBatchAutoRouterTests.testRoutesRelatedTaskToExistingBatchAndUpdatesContextWithoutStartingNewSession`.

## Checks Run

```bash
swift test --package-path apps/swift --filter 'WorkBatch(TaskClaim|DeliveryPolicy|TaskSession|State|BindingReconciler|AutoRouter|CheckpointExchange|CompletionReport)Tests|AppStateRuntimeSnapshotEffectTests|ProjectCardContextLineResolverTests'
swift test --package-path apps/swift
./scripts/dev/restart-alpha-stable.sh
```

## Residual Risk

The slice still relies on Claude Code complying with the generated mirror instructions. That is an accepted product risk for this phase because the claim callback is the proof of pickup and Done/Checkpoint remain the authoritative terminal states.
