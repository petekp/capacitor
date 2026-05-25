# Adversarial Review 25: Second Pass On Follow-Through

Date: 2026-05-24

## Scope

Second consecutive review of the Scene 9 follow-through slice after Review 24. Re-checked for silent dismissal, stale state, accidental old Circuit runtime coupling, scope expansion, and copy that overclaims revision continuity.

## Findings

No medium, high, or critical findings.

## Evidence Checked

- Silent dismissal: submitted review state is preserved when the active checkpoint clears and the window target becomes temporarily unresolved.
- Stale state: a changed target resets the review phase, note, manifest state, and submitted follow-through state unless the submitted target has simply cleared.
- Suspicious state: the same checkpoint remaining visible after the delay is treated as a reason to inspect the terminal.
- Failure state: failed and cancelled runs are surfaced as failed follow-through, not hidden behind a generic accepted message.
- Scope boundary: no retry loop, queue, task DAG, broad memory store, old Circuit runtime invocation, or generalized host abstraction was added.
- Product boundary: request-changes copy stops at "revision expected" and does not claim the worker remembered the operator note. That is the next storyboard gap.

## Checks

- Focused Swift product-loop suite: 87 XCTest cases passed.
- `swift test --package-path apps/swift` - 713 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- Protocol checks passed:
  - `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
  - `python3 scripts/circuit/plan-goal-packet.py --check`
  - `python3 scripts/circuit/normalize-agent-event.py --check`
- Restart passed with `./scripts/dev/restart-alpha-stable.sh --swift-only`.

## Residual Risk

Low: no UI automation opens the actual checkpoint window and waits through the submitted state. Current confidence comes from projection tests, full Swift compilation, and the restart check.

Low: the app can explain immediate follow-through, but it does not yet build the later "You asked / Agent response" continuity packet from Scene 10.
