# Current Hardening Scenario Ledger Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the current safe-wake guardrails, scenario ledger, live project-card re-entry trace, and verification evidence for the active Work Batch hardening goal.

## Findings

No medium, high, or critical findings.

Low: The live `parable-school` re-entry proof used Capacitor activation traces, process evidence, and `lsof` cwd evidence rather than a fresh screenshot of Ghostty foregrounding. This is acceptable for this pass because the trace records `focused_existing` for the exact batch worktree/session and process count stayed at one, but the broader live activation matrix should still include more Ghostty/tmux/frontmost-app permutations before the full goal is closed.

Low: The new current ledger is a proof map, not a replacement for the older implementation plan. Some older docs still describe already-implemented behavior in future tense. That is not a behavior risk, but it can slow future readers unless we eventually mark the older plan as superseded or update its status.

## Rechecked Requirements

- Related ready batch wake remains narrow: the positive path requires exact runtime/binding evidence, and the process-backed exception requires awaiting-input and tool-count evidence.
- Process-only evidence does not trigger terminal input.
- Project-card click uses Work Batch primary routing before legacy terminal routing.
- Work Batch cockpit re-entry focuses the bound batch worktree/session before any resume path.
- Active live Claude cockpit visibility remains projected as `Ready`.
- Full Swift verification passed after the new tests.

## Verdict

Clean for this milestone. Do not mark the full goal complete yet because duplicate-cockpit live reproduction, a fresh live checkpoint pass, and broader terminal activation permutations remain open in the scenario ledger.
