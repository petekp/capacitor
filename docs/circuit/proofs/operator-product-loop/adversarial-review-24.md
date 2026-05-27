# Adversarial Review 24: Checkpoint Decision Follow-Through

Date: 2026-05-24

## Scope

Reviewed the new Scene 9 follow-through slice for run checkpoints. The goal was narrow: after the operator approves or requests changes, Capacitor must show whether the decision was accepted, the run resumed, the worker is revising, the same checkpoint looks stuck, or the run failed.

Out of scope: checkpoint relay, retries, task DAGs, broad memory, flow-engine behavior, old Circuit runtime usage, generalized host abstraction, and useful agent work beyond the existing receipt proof.

## Findings

No medium, high, or critical findings.

## Evidence Checked

- The runtime mutation contract is unchanged: checkpoint decisions still submit `approve` or `request_changes`.
- The review window now records a submitted decision target before switching to the submitted state.
- The submitted window no longer disappears just because the checkpoint clears from the active snapshot.
- Follow-through state is derived from the latest `RuntimeRunState`, not from a new queue or background runner.
- A still-visible matching checkpoint becomes suspicious after the delay and offers terminal inspection.
- A failed or cancelled run after submission becomes an explicit failed follow-through state.
- Request-changes after checkpoint clear tells the operator that revision is expected, without pretending Scene 10 continuity exists yet.

## Checks

- Focused Swift product-loop suite: 87 XCTest cases passed.
- `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization` - 14 tests passed.
- `python3 scripts/circuit/plan-goal-packet.py --check`
- `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift` - 713 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live process check: `CapacitorDebug` PID 76209 and `hud-hook serve --port 7474` PID 76287.

## Residual Risk

Low: follow-through is snapshot-based. If the runtime accepts a decision but cannot produce a fresh snapshot quickly, the UI shows accepted until the suspicious delay passes.

Low: request-changes follow-through says revision is expected, but the next checkpoint is not yet linked back to the exact operator note. That belongs to Scene 10.
