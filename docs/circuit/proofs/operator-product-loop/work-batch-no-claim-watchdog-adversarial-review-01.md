# Work Batch No-Claim Watchdog - Adversarial Review 01

Date: 2026-05-26 local.

Scope: reviewed the no-claim watchdog implementation against the product rule that Capacitor should bias toward automatic Task delivery without pretending Claude Code has picked up work it has not acknowledged.

Reviewed files:

- `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchDeliveryPolicyTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `docs/circuit/work-batch-task-delivery-policy.md`
- `docs/circuit/proofs/operator-product-loop/work-batch-no-claim-watchdog-2026-05-26.md`

## Finding Fixed During Review

Medium: the first router implementation used the generic waiting-state helper. That made the status honest, but repeated refreshes through the same timed-out delivery generation could rewrite `updatedAt`, making stale unclaimed work look newly active.

Resolution:

- Replaced the generic waiting helper with `markBatchPickupTimedOut`.
- The helper saves only when the status, summary, or task status actually changes.
- Added test coverage that a second timed-out follow-through does not launch, wake, or mutate state.

## Final Findings

No medium, high, or critical findings remain in this review.

Residual low risk: the visual copy was not forced through a real live Work Batch timeout in the UI. The behavior is covered by pure policy and router tests, and the live app restart/log check verifies the app still relaunches and ingests runtime snapshots normally.
