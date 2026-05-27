# Work Batch Routing Adversarial Review 01

Date: 2026-05-25

Scope: `docs/circuit/task-work-batch-routing-edge-case-plan.md` against the Goal for Task-to-Work-Batch routing, with emphasis on automatic execution, related/unrelated Task routing, batch worktrees, Claude Code session reuse/resume, stale bindings, manual intervention, duplicate sessions, and visible batch-card behavior.

## Checks

- Re-read Task capture and automatic routing entry points in `AppState.swift` and `AppState+Projects.swift`.
- Re-read `WorkBatchAutoRouter`, `WorkBatchClassifier`, `WorkBatchState`, and `WorkBatchTaskSession`.
- Re-read worktree creation, RuntimeSession mapping, Ghostty managed-worktree matching, terminal launch/focus behavior, and Work Batch card projection.
- Checked the plan against the explicit non-goals: no old Circuit runtime, runner, flow engine, task DAG, broad memory, generalized multi-host routing, or SaaS workflow framing.

## Findings

- No medium, high, or critical findings after the stale-summary gap was added to the plan.

Low residual risks:

- The plan intentionally does not solve live prompt injection into an already busy Claude Code session because the current terminal driver surface exposes focus/launch, not a safe cross-terminal "send this to the existing Claude prompt" operation.
- The plan keeps manual root-session adoption out of the next slice. That is the right ownership boundary, but it means a user who starts work manually in the project root will still see Capacitor create a managed batch session for a new Task.

## Fix Applied Before Clean Result

- Added an explicit stale/unrelated visible-summary edge case, source-backed by current Work Batch summary generation and projection behavior.
- Added acceptance criteria for the exact failure mode where a newly captured Task leaves the visible card saying unrelated older work.

## Result

Clean for medium-or-above findings.
