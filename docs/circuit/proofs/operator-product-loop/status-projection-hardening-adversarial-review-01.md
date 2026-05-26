# Status Projection Hardening Adversarial Review 01 - 2026-05-25

## Scope

Reviewed the current Ready/Idle projection hardening changes in:

- `apps/swift/Sources/Capacitor/Models/WorkBatchClaudeProcessScanner.swift`
- `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift`
- `apps/swift/Sources/Capacitor/Models/RuntimeSnapshotApplicator.swift`
- `apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift`
- Related Swift tests
- `docs/circuit/proofs/operator-product-loop/status-projection-hardening-2026-05-25.md`

## Findings

1. [High] Physical click-through verification is blocked by the locked desktop.
   - Location: `docs/circuit/proofs/operator-product-loop/status-projection-hardening-2026-05-25.md`
   - Evidence: `screencapture` after `caffeinate -u -t 2` showed the macOS lock screen. CoreGraphics also reported `loginwindow` layer `2004` onscreen above Capacitor Debug and Ghostty windows.
   - Why it matters: The Goal requires live manual checks in the running Capacitor Debug app. Tests, logs, and state files prove the projection and activation policies, but they do not prove that a human click on the visible card foregrounds the intended Ghostty cockpit.
   - Recommended fix: Unlock the desktop, then rerun the physical click checklist against the live app.
   - Verification: Click a Ready project card, a Ready Work Batch row, and a checkpoint row; confirm the intended Ghostty tab or checkpoint surface is foregrounded, no new unnecessary Ghostty window is launched, and the activation trace records the chosen route/evidence/action.

## Checks Run

```bash
swift test --package-path apps/swift --filter 'WorkBatchClaudeProcessScannerTests|SessionStateManagerTests|RuntimeSnapshotApplicatorTests|WorkBatchBindingReconcilerTests'
swift test --package-path apps/swift --filter 'TerminalActivationCoordinatorTests|TerminalLauncherTests|GhosttyAutomationClientTests|GhosttyTerminalDriverTests|AppStateWorkBatchOpenTests|WorkBatchAutoRouterTests|WorkBatchTaskSessionTests|WorkBatchDeliveryPolicyTests|WorkBatchOpenActionResolverTests|WorkBatchStateTests|ProjectOrderingTests|OperatorFieldOfWorkProjectionTests|ProjectCardContextLineResolverTests|DockProjectCardPresentationTests'
swift test --package-path apps/swift --filter AppStateRuntimeSnapshotEffectTests
swift test --package-path apps/swift
git diff --check -- apps/swift/Sources/Capacitor/Models/WorkBatchClaudeProcessScanner.swift apps/swift/Sources/Capacitor/Models/SessionStateManager.swift apps/swift/Sources/Capacitor/Models/RuntimeSnapshotApplicator.swift apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift apps/swift/Tests/CapacitorTests/WorkBatchClaudeProcessScannerTests.swift apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift apps/swift/Tests/CapacitorTests/RuntimeSnapshotApplicatorTests.swift apps/swift/Tests/CapacitorTests/WorkBatchBindingReconcilerTests.swift docs/circuit/proofs/operator-product-loop/status-projection-hardening-2026-05-25.md
./scripts/dev/restart-alpha-stable.sh --swift-only
./scripts/dev/check-terminal-activation-state.sh
```

Results:

- 59 focused tests passed.
- 208 broader terminal/work-batch tests passed.
- `AppStateRuntimeSnapshotEffectTests` passed after updating the completed live-batch expectation to `ready`.
- Full Swift passed: 904 tests executed, 1 skipped, 0 failures.
- Diff check for the touched status-projection files passed.
- App relaunched as Capacitor Debug pid `78357`.
- App logs show `parable-school`, `arc-design-studio`, and `pete-2025` projected as `Ready`.

## Residual Risk

No code-level medium/high/critical finding was found in this review. The unresolved high finding is verification-only but blocks honest completion of the Goal because the live UI click scenarios could not be physically exercised while the desktop was locked.
