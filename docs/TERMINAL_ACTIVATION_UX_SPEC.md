# Terminal Activation UX Spec (Runtime Snapshot)

- Canonical path: `docs/TERMINAL_ACTIVATION_UX_SPEC.md`
- Companion QA guide: `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md`

## UX Contract

When a project card is activated:

1. Prefer reuse of an already-running terminal context for that project.
2. Prefer deterministic routing over best-effort heuristics.
3. Fall back once, clearly, without fan-out window spam.
4. Honor latest-intent-wins for rapid repeated clicks.

## Runtime Authority

Routing decisions come from:

1. Runtime shell snapshot (`AppSnapshot.shells`)
2. Runtime routing projection (`AppSnapshot.routing`)
3. Current tmux context queried at execution time

Swift executes OS actions; Rust (`capacitor-core`) owns decision policy.

## Behavioral Rules

1. Reuse-first: if a matching active shell context exists, activate it.
2. Scoped tmux recovery: if snapshot lookup fails, attempt path/session-safe tmux recovery.
3. Single fallback: at most one fallback action when the primary action fails.
4. Staleness guard: ignore stale decision contexts after a newer click.

## Required Automated Coverage

1. `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`
2. `core/capacitor-core/src/runtime_activation/mod.rs` unit tests
3. `bash scripts/ci/non-demo-ax-smoke.sh` for end-user interaction path

## Acceptance Signals

For release sign-off, evidence should show:

1. No unexpected `launchNewTerminal` in reuse scenarios.
2. Deterministic behavior across repeated runs of the same scenario.
3. No stale-request action execution after a newer click is accepted.
