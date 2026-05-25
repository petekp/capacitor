# Adversarial Review 31: Second Pass After Compatibility Hardening

Date: 2026-05-24

## Scope

Second consecutive review after the revision-continuity compatibility patch from Review 30. Re-checked for stale continuity, timeline mismatch, proof overclaiming, and accidental scope expansion.

## Findings

No medium, high, or critical findings.

## Evidence Checked

- The compatibility patch is limited to recognizing `request_changes` and legacy `rejected` as request-changes decisions for active revision continuity.
- The patch does not change the checkpoint decision submission contract.
- Scene 9 follow-through remains snapshot-based and still shows accepted, resumed, revising, suspicious, and failed states.
- Scene 10 continuity still requires same phase plus a non-empty prior operator note.
- Project Detail timeline relationships remain compact row hints, not a new memory system.
- The protocol layer remains headless and in-repo; no old `/Users/petepetrash/Code/capacitor-circuit` runtime path was reintroduced.
- No queue, retry platform, task DAG, flow engine, broad memory store, SaaS workflow, new terminal/editor, or generalized host abstraction was added.

## Checks

- Focused checkpoint suite - 37 XCTest cases passed.
- Focused Swift product-loop suite - 111 XCTest cases passed.
- Protocol checks passed:
  - `python3 -m unittest tests.circuit_protocol.test_goal_packet_planning tests.circuit_protocol.test_agent_event_normalization`
  - `python3 scripts/circuit/plan-goal-packet.py --check`
  - `python3 scripts/circuit/normalize-agent-event.py --check`
- `swift test --package-path apps/swift` - 726 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `git diff --check -- . ':!.claude/dead-code-report.md'`
- Restart passed with `./scripts/dev/restart-alpha-stable.sh --swift-only`.
- Live process check: `CapacitorDebug` PID 15827 and `hud-hook serve --port 7474` PID 15897.

## Residual Risk

Low: the proof still depends on projection and accessibility tests rather than UI automation screenshots for the revision continuity block.

Low: full project case-file memory and end-of-day closure remain deferred product slices.
