# Adversarial Review 12: Ordinary Receipt Loop Attention

Date: 2026-05-24

## Scope

Reviewed the ordinary captured-idea receipt loop wiring from method selection through UI-local receipt run state, project active-run fallback, operator attention projection, field-of-work placement, and receipt rendering compatibility.

Primary files reviewed:

- `apps/swift/Sources/Capacitor/Models/ReceiptLoopRunState.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+ReceiptLoopRuns.swift`
- `apps/swift/Sources/Capacitor/Models/AppState+MethodRunner.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- `apps/swift/Tests/CapacitorTests/AppStateReceiptLoopRunStateTests.swift`
- `apps/swift/Tests/CapacitorTests/OperatorAttentionProjectionTests.swift`

## Findings

No medium, high, or critical findings remain.

## Review Notes

- The first pass found a real race risk: two ordinary receipt loops could be launched for the same project while proof artifacts and UI state are single-slot per project. This is now guarded by `beginReceiptLoopRun`, and `runClaudeReceiptGoalPacketOnIdea` returns early with a plain toast when a project already has a running receipt loop.
- Older completion/failure callbacks cannot overwrite a newer visible receipt run because terminal state updates require the matching receipt run ID.
- Running receipt loops surface as `Running Normally` with commitment copy. Fresh completed receipts surface as `Recently Changed`. Fresh failed receipts surface as exceptions with `Inspect receipt`.
- The change stays Swift/UI-local and does not mutate Rust runtime run truth, invoke the old Circuit runtime, or introduce queues, retries, task DAGs, or a flow engine.

## Checks

- `swift test --package-path apps/swift --filter AppStateReceiptLoopRunStateTests`
- `swift test --package-path apps/swift --filter 'AppStateReceiptLoopRunStateTests|ReceiptLoopRunStateTests|OperatorAttentionProjectionTests|OperatorFieldOfWorkProjectionTests|CircuitReceiptProductLoopTests|ReceiptProofRenderingTests|ReceiptFirstProofAdapterTests'`
- `swift test --package-path apps/swift`
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- `pgrep -fl CapacitorDebug`
- `pgrep -fl hud-hook`
- `git diff --check -- . ':!.claude/dead-code-report.md'`

## Residual Risk

Low: a running receipt loop is still treated as healthy until the task completes or throws. Turning the `~20m` healthy silence copy into actual stale-loop detection belongs to the later Scene 5 / Scene 12 lifecycle work.
