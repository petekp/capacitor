# Adversarial Review 26: Revision Continuity

Date: 2026-05-24

## Scope

Reviewed the new Scene 10 revision-continuity slice for run checkpoints. The goal was narrow: if the operator requested changes and a later checkpoint arrives for the same run and phase, the active checkpoint review should lead with the prior ask, the apparent worker response, evidence, and remaining risk.

Out of scope: broad memory, checkpoint relay, retries, task DAGs, flow-engine behavior, old Circuit runtime usage, generalized host abstraction, SaaS workflow, and project case-file history.

## Findings

No medium, high, or critical findings.

## Evidence Checked

- Continuity is derived only from `RuntimeRunState.pastCheckpoints`, `RuntimeCheckpointState.decision`, `phaseId`, `historyOrdinal`, timestamps, and the existing operator brief.
- The projection requires the latest prior same-phase checkpoint decision to be `request_changes` with a non-empty note.
- A later approval suppresses stale continuity, so an old request-changes note does not leak into unrelated later checkpoints.
- Different phases do not cross-link.
- History ordinals drive ordering when both sides have them; mixed missing ordinals fall back to decision timestamps.
- The review window renders continuity before the ordinary operator brief without changing the approve/request-changes mutation contract.
- No new persistence, runner, retry, queue, flow engine, broad memory, or old Circuit runtime dependency was introduced.

## Checks

- Focused checkpoint suite: 29 XCTest cases passed.
- Focused Swift product-loop suite: 105 XCTest cases passed.
- Protocol checks passed:
  - `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
  - `python3 scripts/circuit/plan-goal-packet.py --check`
  - `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift` - 720 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live process check: `CapacitorDebug` PID 872 and `hud-hook serve --port 7474` PID 956.

## Residual Risk

Low: the agent response is inferred from the active checkpoint summary or existing brief claim. There is no explicit structured `agent_response_to_prior_ask` field yet.

Low: the project timeline can show decision notes, but it does not yet visually link a request-changes entry to the later revision checkpoint.
