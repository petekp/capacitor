# Agent Docs

This folder is the local runbook surface for coding agents working in Capacitor.

It is not the architecture source of truth by itself. Read in this order:

1. `CLAUDE.md`
2. `docs/ARCHITECTURE.md`
3. `docs/architecture-decisions/004-dedicated-local-runtime-service.md`
4. `docs/channel-profile-workflow.md` when channel/profile behavior matters
5. The specific runbook in this folder that matches the task

## Current Architecture Snapshot

- Rust owns domain semantics, persisted runtime truth, setup validation, and file-backed behavior.
- `core/hud-hook/` hosts the local runtime service and adapts Claude hook + shell-cwd inputs into `capacitor-core`.
- Swift owns projection, interaction flow, terminal activation execution, and macOS integrations.
- `apps/swift/Sources/Capacitor/Models/AppState.swift` is the shell environment hub. It exposes collaborators but does not own live-world assembly or duplicate domain policy.

## Default Verification Set

Run these before calling an architecture or runtime change complete:

```bash
./scripts/ci/runtime-reliability-guard.sh --status
cargo test -p capacitor-core
cargo test -p hud-hook
cd apps/swift && swift test
```

## Picking The Right Runbook

- `debugging-guide.md`: runtime, hook, snapshot, routing, or activation debugging
- `gotchas.md`: implementation hazards and easy-to-miss repo conventions
- `release-guide.md`: release build, notarization, bundling, and preflight verification
- `terminal-activation-ux-spec.md`: source of truth for terminal activation behavior and tests
