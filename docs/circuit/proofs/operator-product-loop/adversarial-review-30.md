# Adversarial Review 30: Revision Continuity Compatibility Hardening

Date: 2026-05-24

## Scope

Reviewed the accumulated operator product-loop slice after the Project Detail timeline relationship work. The review focused on active checkpoint revision continuity, timeline compatibility, the Claude receipt boundary, and whether the current proof still tracks the storyboard spine without adding deferred platform behavior.

Out of scope: old Circuit runtime usage, checkpoint relay, queues, retries, task DAGs, flow-engine behavior, broad memory, SaaS workflow, generalized host abstraction, and full project case-file memory.

## Findings

No medium, high, or critical findings remain.

Low finding fixed during this pass:

- Active revision continuity recognized only `request_changes`, while the timeline already treated legacy `rejected` as changes requested and the Rust reducer normalizes `rejected` to `request_changes`.
- Fix: `RunCheckpointRevisionContinuityProjection` now accepts both `request_changes` and `rejected`.
- Regression: `RunCheckpointRevisionContinuityProjectionTests.testBuildsContinuityFromLegacyRejectedDecisionInSamePhase`.

## Evidence Checked

- Scene 10 continuity still appears only for the latest prior same-phase request-changes decision with a non-empty note.
- Later approvals still suppress continuity, so stale asks do not leak into unrelated checkpoints.
- Different phases and blank notes still do not produce continuity.
- Project Detail timeline relationships remain local to checkpoint rows and do not create broad memory.
- The receipt planner's Codex fixture default remains adapter compatibility; the live Swift receipt path still asks for `claude_code`.
- Scope search found no new old Circuit runtime dependency or deferred platform subsystem.

## Checks

- `RunCheckpointRevisionContinuityProjectionTests` - 8 XCTest cases passed.
- Focused checkpoint suite - 37 XCTest cases passed.
- Focused Swift product-loop suite - 111 XCTest cases passed.
- Protocol checks passed:
  - `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
  - `python3 scripts/circuit/plan-goal-packet.py --check`
  - `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift` - 726 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `git diff --check -- . ':!.claude/dead-code-report.md'`
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live process check: `CapacitorDebug` PID 15827 and `hud-hook serve --port 7474` PID 15897.

## Residual Risk

Low: timeline action normalization is still based on exact runtime action strings, but the reducer normalizes accepted decision actions before they reach the snapshot. The new active continuity test covers the legacy action path directly.

Low: revision continuity remains checkpoint-local and does not yet roll up into full project case-file memory.
