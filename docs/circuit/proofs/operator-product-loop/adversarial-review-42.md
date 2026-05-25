# Adversarial Review 42: Scene 14 Today Counters

Date: 2026-05-24

Scope: the Scene 14 closure slice that adds `Today:` counters from current
runtime history.

## Checks

- Verified completed-run counters come from `RuntimeRunState.updatedAt` on the
  current calendar day.
- Verified approval and requested-revision counters come from past checkpoint
  decisions with `decidedAt` on the current calendar day.
- Verified legacy `rejected` decisions count as requested revisions.
- Verified receipt-loop states feed the closure projection as synthetic run
  states, using the same existing receipt-loop state model.
- Verified the slice does not add broad memory, durable daily event storage,
  recovered stale-session counters, checkpoint relay, queues, retries, task
  DAGs, flow-engine behavior, or old Circuit runtime dependency.

## Findings

- No medium, high, or critical findings.

Low residual risk:

- Recovered stale-session counts are still absent because current runtime
  snapshots do not preserve that transition as an event. That should be a narrow
  future event-store slice, not a reason to block the current counters.

## Verification

- `swift test --package-path apps/swift --filter 'EndOfDayClosureProjectionTests|ReturnBriefContentTests|OperatorAttentionProjectionTests|OperatorFieldOfWorkProjectionTests|AccessibilityIdentifiersTests'` - 42 XCTest cases passed.
- Focused product-loop suite - 157 XCTest cases passed.
- `swift test --package-path apps/swift` - 746 XCTest cases passed, 1 skipped, 0 failures; 19 Swift Testing cases passed.
- `./scripts/dev/restart-alpha-stable.sh --swift-only`
- Live after restart: `CapacitorDebug` PID 77541 and `hud-hook serve --port 7474` PID 77614.
- `git diff --check -- . ':!.claude/dead-code-report.md'`
