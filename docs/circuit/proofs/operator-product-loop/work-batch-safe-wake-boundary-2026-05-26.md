# Work Batch Safe Wake Boundary Proof

Date: 2026-05-26

## Scenario

Capacitor should not send text into a live Claude Code cockpit merely because a related Task was queued into that Work Batch. A wake prompt is only allowed after the caller proves both:

- the exact bound cockpit target, and
- a safe Claude input boundary.

Without that proof, the durable queue and context mirror are enough; the Task stays visible as queued until Claude writes a claim, checkpoint, or done artifact.

## Changes

- `WorkBatchDeliveryPolicyInput` now has `safeWakeBoundarySatisfied` as a separate signal from `exactLiveSessionExists`.
- Running, waiting, stale, or done bindings with an exact live session now return `safe_wake_deferred` unless the safe wake boundary is explicitly satisfied.
- `WorkBatchAutoRouter` defaults safe wake permission to closed through `safeWakeBoundaryAllowsInput`.
- The existing Ghostty wake path still exists, but it is no longer reachable from normal Work Batch delivery unless the safe-boundary hook says yes.

## Verification

Focused command:

```bash
swift test --package-path apps/swift --filter 'WorkBatchDeliveryPolicyTests|WorkBatchAutoRouterTests|AppStateRuntimeSnapshotEffectTests'
```

Result:

- 61 focused tests passed.
- `WorkBatchDeliveryPolicyTests` proves an exact live running session defers wake without a safe boundary and wakes only when the boundary is explicit.
- `WorkBatchAutoRouterTests` proves a related Task routed to a live process-backed batch queues without terminal input by default, and still wakes when the safe-boundary hook is explicitly enabled.
- `AppStateRuntimeSnapshotEffectTests` proves runtime snapshot reconciliation marks the binding running without sending a wake prompt by default.

Broader commands:

```bash
./scripts/ci/swiftformat-lint.sh
git diff --check
bash scripts/ci/test-surface-audit.sh --check
swift test --package-path apps/swift
bats tests/dev-scripts/restart-app.bats
./scripts/verify/verify.sh --layers 1
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh
```

Results:

- SwiftFormat reported 0 files requiring formatting.
- Diff whitespace check passed.
- Test surface audit passed.
- Full Swift suite passed: 916 XCTest tests, 1 skipped, 0 failures; 19 Swift Testing tests, 0 failures.
- Dev restart script Bats suite passed all 3 tests, including legacy `capacitor-daemon` LaunchAgent cleanup.
- Structural verifier exited successfully.
- App restart completed and live evidence showed one `CapacitorDebug` process plus `hud-hook serve --port 7474`.
- A stale local `com.capacitor.daemon` LaunchAgent was found respawning the legacy daemon. The restart cleanup now unloads and removes it, and live process evidence after cleanup showed no `capacitor-daemon` process.

## Residual Risk

This is a guardrail, not the final safe-wake implementation. Capacitor still needs a stronger live input-boundary detector before enabling production wakeups for ready Claude sessions. Until then, queue, mirror, claim, checkpoint, done, and resume recovery remain the reliable path.
