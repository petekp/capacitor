# Work Batch No-Claim Watchdog - 2026-05-26

## Scenario

A related Task is queued into an existing Work Batch and Capacitor has already made one safe delivery attempt by waking or resuming the bound Claude Code cockpit. If Claude Code does not write a Task claim for the current delivery generation, Capacitor should stop implying that pickup happened.

## Product Decision

After a five-minute retry window with no current-generation claim:

- keep the Task queued
- mark the Work Batch `Waiting`
- show plain copy: `Claude Code has not picked up <Task> yet. Click to re-enter.`
- do not send another wake/resume prompt for the same delivery generation

This keeps the UX biased toward action without pretending. The operator sees that the Task is still managed, but also sees that the worker has not acknowledged it.

## Source-Backed Changes

- `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift`
  - adds `wait_for_pickup_timeout`
  - adds a five-minute pickup-claim timeout
  - uses existing delivery watermarks: context write, delivery attempt, and claim time
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
  - passes `now` into the pure delivery policy
  - turns `wait_for_pickup_timeout` into a `Waiting` Work Batch without repeating wake/resume
- `docs/circuit/work-batch-task-delivery-policy.md`
  - records the first no-claim watchdog implementation note

## Automated Verification

Command:

```bash
swift test --package-path apps/swift --filter 'WorkBatchDeliveryPolicyTests|WorkBatchAutoRouterTests'
```

Result:

- 53 tests passed
- 0 failures

New coverage:

- current-generation wake attempt remains suppressed before timeout
- current-generation wake attempt becomes `wait_for_pickup_timeout` after timeout when no claim exists
- a current-generation claim prevents the timeout path
- router marks the batch Waiting and does not wake or launch again
- repeated timeout follow-through does not rewrite unchanged state or make stale work look freshly updated

Broader command:

```bash
swift test --package-path apps/swift --filter 'WorkBatchDeliveryPolicyTests|WorkBatchAutoRouterTests|AppStateRuntimeSnapshotEffectTests|WorkBatchStateTests'
```

Result:

- 68 tests passed
- 0 failures

Full Swift command:

```bash
swift test --package-path apps/swift
```

Result:

- 913 XCTest tests passed
- 1 XCTest skipped
- 19 Swift Testing tests passed
- 0 failures

Hygiene:

```bash
./scripts/ci/swiftformat-lint.sh
git diff --check
```

Both passed.

## Live App Verification

Command:

```bash
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh
tail -n 180 ~/.capacitor/runtime/app-debug.log
```

Observed:

- Capacitor Debug relaunched from `/Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor`.
- `check-terminal-activation-state.sh` reported one Capacitor Debug process and no release Capacitor process.
- Runtime snapshot logs continued to apply after relaunch.
- No live Claude Code worker process was present during this final check, so the visible project cards correctly remained `Idle` instead of manufacturing a Ready state.

## Remaining Manual Check

This behavior is mostly a state-machine guard and is covered with temporary project roots. A later live dogfood run should verify the visual copy after forcing a real Work Batch into the timed-out state and refreshing Capacitor Debug.

## Adversarial Review

- `work-batch-no-claim-watchdog-adversarial-review-01.md`
