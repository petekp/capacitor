# macOS Preview Work Scenario Ledger Adversarial Review 01

Date: 2026-05-27
Scope: `docs/circuit/preview-work-macos-scenarios.md`
Result: clean after fixes; no medium, high, or critical findings remain.

## Method

- Checked the ledger against the active goal: many macOS cases, current
  Capacitor source grounding, primary Apple/tooling references, product policy,
  user-facing behavior, and implementation-driving acceptance criteria.
- Re-read the relevant Capacitor source/docs: `CONTEXT.md`,
  `docs/ARCHITECTURE.md`, `WorktreeService.swift`,
  `WorkBatchTaskSession.swift`, `WorkBatchCompletionReport.swift`,
  `scripts/dev/restart-app.sh`, and
  `scripts/dev/check-terminal-activation-state.sh`.
- Checked the scenario set against primary docs for bundle identity, Launch
  Services, `LSUIElement`, Xcode build outputs, UserDefaults, sandboxing,
  signing, logging, and crash reports.
- Ran `git diff --check` and a trailing-whitespace scan over the new artifact.

## Findings

No medium, high, or critical findings remain.

## Fixed During Review

- Clarified that the first implementation should support one active native
  preview per preview identity, not imply that arbitrary simultaneous previews
  are safe just because each Work Batch has its own record.

## Residual Risk

The ledger is a planning artifact. The next proof must build a real Capacitor
preview app from a Batch Worktree and prove path/pid/bundle identity at launch.
