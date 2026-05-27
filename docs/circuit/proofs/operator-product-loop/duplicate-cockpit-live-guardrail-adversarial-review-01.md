# Duplicate Cockpit Live Guardrail Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the controlled live duplicate-cockpit proof for `parable-school`, the current duplicate-cockpit source policy, focused duplicate tests, and terminal activation traces.

## Findings

No medium, high, or critical findings.

Low: The live reproduction used a controlled Claude-like process rather than two real Claude Code sessions in Ghostty. This is acceptable for this milestone because the production duplicate guard consumes process command, cwd, and session-id evidence, and the UI/logs proved the guard path in the running Debug app. It should not be treated as complete coverage for Ghostty window-selection behavior.

Low: The project card showed `Ready` while the controlled duplicate process existed, because project-level process projection treats a live Claude-like process inside the project as an active cockpit. That matches the current "active sessions stay visible" rule, but future UX may want a more explicit ambiguous/attention state when the live process is not the bound Work Batch session.

## Rechecked Requirements

- The project-card click did not guess among multiple Work Batches; it opened Project Detail.
- The Work Batch terminal/re-entry click refused the duplicate cockpit.
- The UI surfaced a plain error: `Multiple Claude Code sessions match Typeface unification from source parable`.
- Terminal activation logs recorded `outcome="failed"` with the duplicate reason.
- Live diagnostic showed no installed release Capacitor app, no Ghostty windows launched, and no new tmux session.
- Cleanup removed the controlled duplicate process.
- Focused duplicate tests passed after the live check.

## Verdict

Clean for this milestone. Do not mark the full hardening goal complete yet; pending checkpoint live UX, unrelated Task live recheck, project-level route evidence, and a real two-Claude Ghostty matrix remain open.
