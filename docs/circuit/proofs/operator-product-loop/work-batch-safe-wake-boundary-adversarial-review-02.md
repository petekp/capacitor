# Work Batch Safe Wake Boundary Adversarial Review 02

Date: 2026-05-26

## Scope

Re-reviewed the final safe-wake boundary, legacy daemon cleanup, and CI coverage changes after the first review finding was resolved.

Reviewed files:

- `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchDeliveryPolicyTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `apps/swift/Tests/CapacitorTests/AppStateRuntimeSnapshotEffectTests.swift`
- `scripts/dev/restart-app.sh`
- `tests/dev-scripts/restart-app.bats`
- `.github/workflows/ci.yml`
- `docs/circuit/work-batch-task-delivery-policy.md`
- `docs/circuit/proofs/operator-product-loop/work-batch-safe-wake-boundary-2026-05-26.md`

## Findings

No medium, high, or critical findings.

## Low Findings

1. Low: production proactive wake remains intentionally disabled
   - Evidence: `WorkBatchAutoRouter` defaults `safeWakeBoundaryAllowsInput` to `false`, and `WorkBatchDeliveryPolicy` returns `safe_wake_deferred` for exact live sessions unless `safeWakeBoundarySatisfied` is true.
   - Why it matters: queued Tasks will not be proactively injected into a live Claude Code prompt until a real safe-boundary detector is implemented.
   - Decision: acceptable for this hardening step. The safer product behavior is to queue and mirror Tasks rather than risk sending text into an active Claude tool run or partial prompt.

2. Low: the safe-boundary proof hook is test-only scaffolding, not the final detector
   - Evidence: focused tests inject `safeWakeBoundaryAllowsInput`, but production code does not yet derive that signal from transcript/runtime state.
   - Why it matters: this prevents unsafe wakeups now, but the intended UX still needs a later detector that can wake sessions at an idle prompt boundary.
   - Decision: acceptable and documented as the next product hardening step.

## Resolved Prior Finding

- The legacy `com.capacitor.daemon` LaunchAgent cleanup now removes the plist after unloading/removing the service.
- `tests/dev-scripts/restart-app.bats` asserts the plist is gone and that the expected `launchctl bootout` route was attempted.
- `.github/workflows/ci.yml` now runs `bats tests/dev-scripts`, so the restart cleanup coverage is protected in CI rather than only by local manual runs.

## Verification Reviewed

Current local verification evidence for this final state:

- `bats tests/dev-scripts` passed.
- `bats tests/release-scripts` passed.
- `./scripts/ci/swiftformat-lint.sh` passed.
- `git diff --check` passed.
- `bash scripts/ci/test-surface-audit.sh --check` passed.
- `cargo fmt --check` passed.
- `cargo clippy -- -D warnings -W dead_code` passed.
- `cargo test --lib --bins --tests` passed.
- `./scripts/verify/verify.sh --layers 1` passed.

## Result

The safe-wake guardrail and daemon cleanup are sound enough to build on. The implementation moves the product toward reliable automatic Task delivery by preferring durable queue state over unsafe terminal injection, while preserving a narrow, testable path for future safe-boundary wakeups.
