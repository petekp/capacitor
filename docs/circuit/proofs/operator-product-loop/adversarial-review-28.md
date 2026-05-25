# Adversarial Review 28: Project Detail Revision Relationships

Date: 2026-05-24

## Scope

Reviewed the Project Detail checkpoint timeline revision-relationship slice. The goal was narrow: show when a later checkpoint responds to a prior same-phase request-changes note, so the operator can reconstruct the revision loop from the timeline without reopening every checkpoint packet.

Out of scope: broad memory, queues, retries, task DAGs, flow-engine behavior, old Circuit runtime usage, SaaS workflow, generalized host abstraction, and full project case-file summaries.

## Findings

No medium, high, or critical findings.

## Evidence Checked

- Timeline relationships use only existing `pastCheckpoints`, decision action/note, phase id, history ordinal, timestamps, and current timeline entries.
- A relationship appears only when there is an outstanding same-phase `request_changes` decision with a non-empty note.
- A later approval can show that it responded to the request, then clears the relationship for future checkpoints.
- Different phases do not cross-link.
- Blank request notes do not create relationship copy.
- The timeline row renders the link as "Responds to round N" with the operator note, without replacing the existing decision pill, summary, note, or timestamp.
- Accessibility labels include the revision relationship.
- Scene 9 follow-through and Scene 10 active-review continuity tests still pass.

## Checks

- Focused checkpoint suite: 36 XCTest cases passed.
- Focused Swift product-loop suite: 110 XCTest cases passed.
- Protocol checks passed:
  - `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
  - `python3 scripts/circuit/plan-goal-packet.py --check`
  - `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift` - 725 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live process check: `CapacitorDebug` PID 7498 and `hud-hook serve --port 7474` PID 7567.

## Residual Risk

Low: relationship copy is intentionally local to checkpoint rows. It does not yet roll up into a richer project case-file summary.

Low: no UI automation screenshots the Project Detail timeline; current evidence is projection tests, accessibility-label tests, full Swift verification, and live restart.
