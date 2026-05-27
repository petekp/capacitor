# Adversarial Review 44: Receipt Capture Hardening And Manual Ordinary Run

Date: 2026-05-24

Review scope:

- `ReceiptFirstProofAdapter` capture readiness, transcript extraction, and
  timeout behavior.
- `validate-receipt-first-loop.py` after allowing ordinary captured ideas.
- Focused regression tests for stale captures, prompt-only receipts, and product
  loop fake captures.
- Manual ordinary captured-idea run:
  `goal-packet-01ksdz0q8rckjzw6fkg94bvyz8`.

## Checks

- Confirmed `captureIsReady` rejects stale artifacts unless the adapter result
  matches the current GoalPacket id, current body SHA, inserted-body path, and
  raw-receipt path.
- Confirmed shell-side receipt extraction can no longer capture the inserted
  GoalPacket body because fallback transcript scanning starts after
  `AGENT_CLI_OUTPUT`.
- Confirmed the default capture timeout is 600 seconds for ordinary useful
  work.
- Confirmed the manual ordinary run completed through Capacitor and rendered the
  current useful receipt, not the old transport receipt.
- Confirmed the validator passes against the ordinary captured-idea proof and
  checks the inserted-body hash.

## Findings

- No medium, high, or critical findings.

Low residual risk:

- The live receipt proof surface still uses a fixed latest-proof artifact path.
  The manual evidence is copied to
  `docs/circuit/proofs/operator-product-loop/manual-ordinary-receipt-run-01/`
  so this run remains durable, but a historical in-app proof browser is still
  deferred.

## Verification

- `swift test --package-path apps/swift --filter 'ReceiptFirstProofAdapterTests|CircuitReceiptProductLoopTests|AppStateReceiptLoopRunStateTests'`
  - 22 XCTest cases passed.
- `swift test --package-path apps/swift`
  - 749 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases
    passed.
- `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
  - 15 tests passed.
- `python3 scripts/circuit/plan-goal-packet.py --check`
- `python3 scripts/circuit/normalize-agent-event.py --check`
- `python3 scripts/circuit/validate-receipt-first-loop.py --write docs/circuit/proofs/receipt-first-product-loop/validation-result-verified.json`
- `git diff --check -- . ':!.claude/dead-code-report.md'`
- Manual Capacitor run rendered
  `event-receipt-01ksdz0q8rckjzw6fkg94bvyz8`.
