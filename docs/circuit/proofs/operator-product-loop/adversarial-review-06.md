# Adversarial Review 06

Reviewed artifacts:

- `docs/circuit/storyboard-indexed-product-loop-plan.md`
- `docs/circuit/receipt-first-product-loop.md`
- `docs/circuit/migration-inventory.md`
- `docs/circuit/proofs/receipt-first-product-loop/evidence-log.md`
- `docs/circuit/proofs/operator-product-loop/adversarial-review-01.md`
- `docs/circuit/proofs/operator-product-loop/adversarial-review-02.md`
- `docs/circuit/proofs/operator-product-loop/adversarial-review-03.md`
- `docs/circuit/proofs/operator-product-loop/adversarial-review-04.md`
- `docs/circuit/proofs/operator-product-loop/adversarial-review-05.md`
- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Models/OperatorViewStateStore.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/OperatorAttentionProjection.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift`
- `apps/swift/Sources/Capacitor/Views/Projects/ReturnBriefView.swift`
- `apps/swift/Sources/Capacitor/Debug/ReceiptProofRendering.swift`
- Related Swift tests under `apps/swift/Tests/CapacitorTests/`

Review stance:

- Audit the recent product-loop work as a foundation for the next slice, not only as isolated passing tests.
- Look for places where the implementation passes superficially but undermines return/orient continuity, receipt-loop neutrality, or the owner-first boundary.

## Findings

No medium, high, or critical findings remain.

## Hardening Completed Before This Clean Pass

1. App-open view state is now real, not only theoretical.
   - `AppState` loads the previous `OperatorViewStateStore.Snapshot` for the visible brief, then records the current app opening for the next return.
   - `AppStateOperatorViewStateTests` verifies that the visible snapshot keeps the previous timestamp while persistence advances to the current timestamp.

2. Receipt rendering now accepts the neutral adapter exit-code field.
   - `ReceiptProofAdapterResult` decodes `agent_exit_code` without requiring legacy `codex_exit_code`.
   - It still writes and accepts `codex_exit_code` for existing proof artifacts.
   - `ReceiptProofRenderingTests` covers a neutral-only adapter result.

3. The storyboard plan no longer asks the return brief to overclaim evidence.
   - The example says "1 worker completed".
   - The plan explicitly says not to claim "completed with evidence" until a real evidence-ready signal exists.

## Checks

- Confirmed the return brief remains a compact re-entry surface above the existing project list, not a dashboard replacement.
- Confirmed operator view state persists under Capacitor's namespace and stores only narrow last-opened/last-seen metadata.
- Confirmed the attention projection remains Swift-side and uses existing projects, runs, checkpoints, sessions, and dormant markers.
- Confirmed the receipt loop remains local to `circuit_protocol/`, `scripts/circuit/`, proof artifacts, and one visible Claude Code CLI session.
- Confirmed no old `/Users/petepetrash/Code/capacitor-circuit` runtime dependency is introduced.
- Confirmed the work does not introduce a runner, queue/retry platform, task DAG, broad memory store, SaaS workflow, new terminal/editor, or generalized multi-host abstraction.

## Verification

- `swift test --package-path apps/swift --filter AppStateOperatorViewStateTests`
- `swift test --package-path apps/swift --filter ReceiptProofRenderingTests`
- `swift test --package-path apps/swift --filter ReturnBriefContentTests`
- `swift test --package-path apps/swift --filter OperatorViewStateStoreTests`
- `swift test --package-path apps/swift --filter OperatorAttentionProjectionTests`
- `swift test --package-path apps/swift --filter AccessibilityIdentifiersTests`
- `swift test --package-path apps/swift --filter CircuitReceiptProductLoopTests`
- `swift test --package-path apps/swift --filter ReceiptFirstProofAdapterTests`
- `swift test --package-path apps/swift`
- `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
- `python3 scripts/circuit/plan-goal-packet.py --check`
- `python3 scripts/circuit/normalize-agent-event.py --check`
- `python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result.json`
- `./scripts/dev/restart-alpha-stable.sh --swift-only`

## Residual Risk

The brief still summarizes current attention rather than filtering every line by "since you were away". That is now a clear next slice, backed by real app-open persistence.

## Result

Clean review: no medium-or-above findings.
