# Adversarial Review 19: Final Pass on Attention Action Routing

Date: 2026-05-24

## Scope

Second consecutive adversarial pass after Review 18 and the final verification commands. Re-checked the attention action resolver, projection targets, `ProjectsView` routing, AppState checkpoint target mutation, receipt-loop concurrency guard, and receipt proof-window safety.

## Findings

No medium, high, or critical findings.

## Evidence Checked

- The field-of-work row passes its `attentionItem` into the active card tap path, while legacy and hidden-card paths keep the existing project action behavior.
- The action resolver routes checkpoint recommendations to the exact run/checkpoint identity, routes delegation reviews through the existing delegation primary-action policy, and keeps running/dormant work on the default project action.
- Receipt proof opening is gated by an explicit `.receiptProof` target, so stale completed receipt cards do not open the single latest-proof window by accident.
- Failed receipt attention currently recommends terminal inspection unless a future path can prove a renderable receipt proof exists.
- AppState can set a run checkpoint review target directly from the attention item, and the run checkpoint review window still resolves the run/checkpoint from runtime state.
- `beginReceiptLoopRun` blocks a second running receipt loop across projects, preserving the one-visible-Claude-receipt-session boundary.

## Checks

- Focused Swift slice passed: 58 XCTest cases across the attention resolver/projection, field-of-work projection, project primary action, AppState checkpoint routing, AppState receipt-loop state, and receipt rendering tests.
- Full Swift suite passed: 705 XCTest cases, 1 skipped, 0 failures, plus 19 Swift Testing cases.
- Diff hygiene passed with `.claude/dead-code-report.md` excluded as pre-existing unrelated dirty work.
- Swift-only restart passed. Live processes after restart: `CapacitorDebug` PID `16490`; `hud-hook serve --port 7474` PID `16565`.

## Residual Risk

Low: receipt proof rendering is still a latest-proof surface, not a historical per-run receipt browser. The current action gate prevents opening the wrong old proof from the field of work, and durable per-run proof selection belongs to the richer artifact capture phase.
