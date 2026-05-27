# Adversarial Review 32: Project Detail Case File

Date: 2026-05-24

## Scope

Reviewed the Project Detail case-file slice. The goal was narrow: make Project Detail rehydrate the run story before the operator reads the checkpoint timeline, using existing runtime, checkpoint, timeline, and operator-view-state facts.

Out of scope: broad memory, end-of-day closure, checkpoint relay, queues, retries, task DAGs, flow-engine behavior, old Circuit runtime usage, SaaS workflow, generalized host abstraction, and new terminal/editor behavior.

## Findings

No medium, high, or critical findings remain.

## Evidence Checked

- `ProjectCaseFileProjection` is pure projection code over `Project`, `RuntimeRunState`, `RunCheckpointTimelineProjection`, and `OperatorViewStateStore.Snapshot`.
- Current state is derived from run status, status message, phase progress, and active checkpoint title.
- Since-last-looked uses the latest existing seen timestamp across project, run, and checkpoint IDs.
- Recent decisions come from archived timeline entries, newest first.
- Open risks are derived only from runtime facts: paused active checkpoints, failed/cancelled runs, capture state, revision relationships, and outstanding request-changes notes.
- Project Detail records seen state through the existing narrow operator-view-state store and does not mutate the loaded snapshot used for the current brief.
- The existing checkpoint timeline remains the evidence trail below the case-file brief.
- No old Circuit runtime path or deferred platform subsystem was introduced.

## Checks

- Focused case-file suite - 7 XCTest cases passed.
- Focused Swift product-loop suite - 117 XCTest cases passed.
- Protocol checks passed:
  - `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
  - `python3 scripts/circuit/plan-goal-packet.py --check`
  - `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift` - 732 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `git diff --check -- . ':!.claude/dead-code-report.md'`
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live process check: `CapacitorDebug` PID 46671 and `hud-hook serve --port 7474` PID 46739.

## Residual Risk

Low: the case-file section is covered by projection and accessibility-label tests, but there is not yet a screenshot/UI automation proof of the rendered layout.

Low: this is still run/checkpoint-local memory, not full project memory across unrelated sessions.
