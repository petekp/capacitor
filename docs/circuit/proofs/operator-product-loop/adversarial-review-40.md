# Adversarial Review 40: Ordinary Useful Receipt Run

Date: 2026-05-24

Scope: the planner and method-copy slice that lets ordinary captured ideas ask
Claude Code to do bounded useful work before returning a receipt.

## Checks

- Verified the legacy Codex fixture path still emits the original transport
  proof packet for `idea-receipt-first-001`.
- Verified ordinary `claude_code` GoalPackets now include the captured intent,
  success criteria, a bounded useful-work instruction, permission for focused
  file inspection/edits, focused verification, and the `CIRCUIT_RECEIPT`
  contract.
- Verified the prompt tells Claude to return `blocked` instead of guessing when
  owner direction is needed.
- Verified the method selector copy now describes a bounded run from the idea,
  not only a receipt loop.
- Verified the change does not introduce a runner, flow engine, task DAG,
  queue/retry platform, broad memory store, SaaS workflow, new terminal/editor,
  generalized host abstraction, or old `/Users/petepetrash/Code/capacitor-circuit`
  runtime dependency.

## Findings

- No medium, high, or critical findings.

Low residual risk:

- This slice is prompt-level and fake-tested. A manual end-to-end ordinary idea
  run is still required before claiming the full product loop is complete.

## Verification

- `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization` - 15 tests passed.
- `python3 scripts/circuit/plan-goal-packet.py --check`
- `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift --filter 'CircuitReceiptGoalPacketMethodTests|CircuitReceiptProductLoopTests|MethodRunCoordinatorTests|MethodRunContextTests|IdeaRunIntentProjectionTests|ReceiptLoopRunStateTests|ReceiptProofRenderingTests'` - 32 XCTest cases passed.
- Focused product-loop suite - 156 XCTest cases passed.
- `swift test --package-path apps/swift` - 745 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live after restart: `CapacitorDebug` PID 70529 and `hud-hook serve --port 7474` PID 70598.
- `git diff --check -- . ':!.claude/dead-code-report.md'`
