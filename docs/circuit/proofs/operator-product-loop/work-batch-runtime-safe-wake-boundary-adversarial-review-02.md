# Work Batch Runtime Safe Wake Boundary Adversarial Review 02

Date: 2026-05-26

## Scope

Reviewed the follow-up change that lets a related queued Task wake an existing Work Batch Claude Code cockpit when the runtime snapshot has aged the assigned session into `signal_absence`, but direct process evidence proves the exact assigned Claude session is alive in the Batch Worktree and runtime still says Claude was awaiting input.

Files reviewed:

- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchBindingReconcilerTests.swift`
- `docs/circuit/work-batch-task-delivery-policy.md`
- `docs/circuit/proofs/operator-product-loop/work-batch-runtime-safe-wake-boundary-2026-05-26.md`

## Findings

No medium, high, or critical findings.

## Checks Reviewed

Passed:

```bash
swift test --package-path apps/swift --filter 'WorkBatchAutoRouterTests/testRoutesRelatedTaskToProcessBackedSignalAbsenceAwaitingInputWakesExactAssignedSession|WorkBatchAutoRouterTests/testRoutesRelatedTaskToRuntimeReadySignalAbsenceWakesExactAssignedSession|WorkBatchAutoRouterTests/testRoutesRelatedTaskToRuntimeWorkingExactSessionDefersWake|WorkBatchAutoRouterTests/testRoutesRelatedTaskToRuntimeReadyExactSessionWithToolInFlightDefersWake|WorkBatchBindingReconcilerTests|WorkBatchDeliveryPolicyTests|WorkBatchTaskSessionTests'
./scripts/ci/swiftformat-lint.sh
git diff --check
swift test --package-path apps/swift
bats tests/dev-scripts/check-terminal-activation-state.bats tests/dev-scripts/restart-app.bats
```

Manual live proof passed:

- Real project: `/Users/petepetrash/Code/parable-school`
- Real Work Batch: `batch-typeface-unification-from-source-parable-01ksfw1`
- Assigned Claude session: `23bb3c4f-286f-4957-869b-6d33a6c9fd3f`
- Result: the queued Task moved to `working`, wrote a claim artifact, wrote a Done artifact, and the batch returned to `ready`.

## Residual Risk

Low: The process-backed `signal_absence` path intentionally sends terminal input into an existing visible cockpit. The guard is narrow: exact assigned session id, exact Batch Worktree, direct process evidence, runtime `signal_absence`, no tools in flight, and runtime `meta_awaiting_input`. Keep this path narrow; do not generalize it into process-only wakeups.
