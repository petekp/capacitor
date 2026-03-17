# Agent Docs

> Doc role: `task-runbook`
> Status: Routing table only. For architecture, start at `.claude/docs/architecture-primer.md`.

This folder is the local runbook surface for coding agents working in Capacitor.

## Read Path

1. `CLAUDE.md` for commands, verification workflow, and repo conventions
2. `.claude/docs/architecture-primer.md` for architecture hierarchy and routing
3. `docs/channel-profile-workflow.md` when channel/profile behavior matters
4. The specific runbook in this folder that matches the task

## Default Verification Set

Run these before calling an architecture or runtime change complete:

```bash
./scripts/ci/runtime-reliability-guard.sh --status
cargo test -p capacitor-core
cargo test -p hud-hook
cd apps/swift && swift test
```

## Picking The Right Runbook

- `ax-automation.md`: canonical AX/project-card automation interface, failure modes, and CI behavior
- `debugging-guide.md`: runtime, hook, snapshot, routing, or activation debugging
- `gotchas.md`: implementation hazards and easy-to-miss repo conventions
- `release-guide.md`: release build, notarization, bundling, and preflight verification
- `terminal-activation-ux-spec.md`: source of truth for terminal activation behavior and tests
