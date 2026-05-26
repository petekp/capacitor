# Work Batch Task Delivery Implementation Spec Adversarial Review 01

Date: 2026-05-25

Scope: `docs/circuit/work-batch-task-delivery-implementation-spec.md` against the Goal for deciding the best implementation path and producing a detailed sequential spec for Work Batch Task delivery.

## Checks

- Rechecked the spec against `CONTEXT.md` product language for Task, Work Batch, Checkpoint, Non-Disruptive Delivery, and Model Discretion.
- Rechecked routing and existing-binding behavior in `WorkBatchAutoRouter`.
- Rechecked context mirror, Claude Code launch/resume, and prompt behavior in `WorkBatchTaskSession`.
- Rechecked binding reconciliation and duplicate/stale handling in `WorkBatchBindingReconciler`.
- Rechecked canonical state/projection/open-action behavior in `WorkBatchState`.
- Rechecked Done and Checkpoint callback stores and ingestion paths.
- Rechecked project/batch UI and AppState follow-through paths.
- Rechecked the spec for forbidden scope: old Circuit runtime, runner, flow engine, task DAG, broad memory, generalized multi-host abstraction, new terminal/editor, SaaS workflow framing, and default live terminal injection.

## Findings

- No medium, high, or critical findings.

Low residual risks:

- The spec defers exact idle/input-boundary wakeups. That is acceptable for this slice because the first working solution is queue + mirror + claim + safe resume, but manual testing must confirm the UX still feels responsive enough when Claude is busy.
- The spec allows claims without delivery generation for compatibility. This is acceptable because `claimedAt >= task.updatedAt` still gates freshness, but implementation should prefer generated claims once Phase 2 is complete.
- Manual verification depends on the local app refresh/ingest cadence. If claims do not appear promptly during manual testing, the implementation should add a debug refresh affordance or document the expected refresh trigger before proceeding.

## Pre-Review Fixes Applied

- Made `WorkBatchContextMirror.deliveryGeneration` optional during the claim-contract phase so Phase 1 can land before canonical delivery state.
- Required Done and Checkpoint artifacts to beat Task claims for the same Task when artifacts arrive in one refresh.
- Required the router mirror-write helper to return delivery generation so persistence has a clear implementation hook.
- Added an explicit test for Done/Checkpoint artifacts overriding a Task claim.

## Result

Clean for medium-or-above findings.
