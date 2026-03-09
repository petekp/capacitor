# Agent Docs

This folder is the local runbook surface for coding agents working in Capacitor.

It is not the architecture source of truth by itself. Read in this order:

1. `architecture/CHARTER.md`
2. `architecture/DECISIONS.md`
3. `docs/architecture/OVERVIEW.md`
4. `docs/architecture/REFERENCE.md`
5. The specific runbook in this folder that matches the task

## Current Architecture Snapshot

- Rust owns domain semantics, persisted runtime truth, setup validation, and file-backed behavior.
- `core/capacitor-hook/` is a thin ingest adapter. It sends hook and shell-cwd signals into `capacitor-core`.
- Swift owns projection, interaction flow, terminal activation execution, and macOS integrations.
- `apps/swift/Sources/Capacitor/Composition/AppState.swift` is the shell environment hub. It exposes collaborators but does not own live-world assembly or duplicate domain policy.
- Historical material belongs under `docs/archive/`. Do not treat archived documents as active guidance.

## Default Verification Set

Run these before calling an architecture or runtime change complete:

```bash
scripts/architecture/check_architecture_guards.sh --status
scripts/ci/runtime-reliability-guard.sh --status
cargo test -p capacitor-core
cargo test -p capacitor-hook
cd apps/swift && swift test
```

## Picking The Right Runbook

- `debugging-guide.md`: runtime, hook, snapshot, routing, or activation debugging
- `gotchas.md`: implementation hazards and easy-to-miss repo conventions
- `release-guide.md`: release build, notarization, bundling, and preflight verification
- `terminal-activation-ux-spec.md`: source of truth for terminal activation behavior and tests
