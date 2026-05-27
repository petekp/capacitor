# Current Hardening Scenario Ledger: Adversarial Review 02

Date: 2026-05-26

## Scope

Reviewed the current Work Batch, Task routing, checkpoint, terminal/session activation, Debug-build guardrail, storage-key, and live Ready projection hardening slice.

Primary artifacts reviewed:

```text
docs/circuit/proofs/operator-product-loop/current-hardening-scenario-ledger-2026-05-26.md
docs/circuit/terminal-activation-state-machine.md
docs/circuit/work-batch-task-delivery-policy.md
apps/swift/Sources/Capacitor/Models/RuntimeSnapshotApplicator.swift
apps/swift/Sources/Capacitor/Models/SessionStateManager.swift
apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift
apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift
apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift
apps/swift/Sources/Capacitor/Models/WorkBatchAutoRouter.swift
apps/swift/Sources/Capacitor/Models/WorkBatchBindingReconciler.swift
scripts/dev/check-terminal-activation-state.sh
scripts/dev/restart-app.sh
```

## Findings

No medium, high, or critical findings.

## Low / Follow-Up Risks

1. Real duplicate-Claude Ghostty matrix coverage is still partial.
   - Current proof uses controlled duplicate processes and focused tests.
   - This is acceptable for the current slice because the product behavior is guarded: explain ambiguity and refuse to guess.

2. Natural agent-created checkpoint coverage is still thinner than controlled checkpoint coverage.
   - Current tests and controlled live proof cover checkpoint-first routing, answer focus, response writing, and cleanup.
   - A future dogfood pass should capture a real Claude-created checkpoint once the batch/task loop is stable enough for routine use.

3. Long-poll `unchanged` responses do not refresh volatile process evidence directly.
   - The running app still performs periodic snapshot fetches, and the rebuilt live proof showed volatile refresh clearing `Ready`.
   - If the periodic fetch path is removed later, long-poll unchanged handling should get an explicit volatile-refresh method.

## Verification Reviewed

Passed in this hardening pass:

```bash
swift test --package-path apps/swift --filter RuntimeSnapshotApplicatorTests
swift test --package-path apps/swift --filter 'RuntimeSnapshotApplicatorTests|SessionStateManagerTests|AppStateRuntimeSnapshotEffectTests'
./scripts/ci/swiftformat-lint.sh
git diff --check
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
swift test --package-path apps/swift
```

Final Swift result:

```text
953 XCTest cases, 1 skipped, 0 failures.
19 Swift Testing tests, 0 failures.
```

## Conclusion

The current slice is still aligned with the agreed UX: Task capture biases toward automatic routing, related work joins visible Work Batches, checkpoints interrupt before cockpit re-entry, ambiguous sessions are explained instead of guessed, the Debug build guard prevents wrong-binary manual tests, and active Claude-like cockpits remain visible as `Ready` while clearing back to `Idle` when the process disappears.
