# Work Batch Safe Wake Boundary Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the in-flight safe-wake boundary and live runtime cleanup changes:

- `apps/swift/Sources/Capacitor/Models/WorkBatchDeliveryPolicy.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchDeliveryPolicyTests.swift`
- `apps/swift/Tests/CapacitorTests/WorkBatchAutoRouterTests.swift`
- `apps/swift/Tests/CapacitorTests/AppStateRuntimeSnapshotEffectTests.swift`
- `scripts/dev/restart-app.sh`
- `tests/dev-scripts/restart-app.bats`
- `docs/circuit/work-batch-task-delivery-policy.md`
- `docs/circuit/proofs/operator-product-loop/work-batch-safe-wake-boundary-2026-05-26.md`

## Findings

No medium, high, or critical findings.

## Low Findings

1. Low: production safe-wake remains intentionally closed
   - Evidence: `WorkBatchAutoRouter` defaults `safeWakeBoundaryAllowsInput` to `false`; the only enabled wake path in tests injects the proof hook.
   - Why it matters: this avoids unsafe terminal input, but ready Claude sessions will not be proactively nudged until a real input-boundary detector is added.
   - Decision: acceptable for this hardening slice. The product remains reliable because queue, mirror, claim, checkpoint, done, and stale-session resume still carry delivery.

2. Low: legacy daemon LaunchAgent cleanup originally unloaded but did not delete the plist
   - Evidence: the initial cleanup only called `launchctl bootout` or `launchctl remove`, leaving `~/Library/LaunchAgents/com.capacitor.daemon.plist` in place.
   - Why it matters: a future login could reload the legacy daemon if the plist remained.
   - Resolution: fixed in this slice. The cleanup now removes the legacy plist after unloading the service, and the Bats test asserts the file is gone.

## Verification Reviewed

- Focused Swift policy/router/AppState tests passed.
- Full Swift test suite passed.
- Dev restart Bats test passed.
- SwiftFormat lint, diff whitespace check, test-surface audit, and structural verifier passed.
- Live process check after cleanup showed `CapacitorDebug` and `hud-hook serve --port 7474`, with no `capacitor-daemon`.

## Result

The slice is sound enough to continue building on. It moves Capacitor toward the intended UX by preventing surprise terminal input while preserving durable Task delivery and recovery.
