# Debugging Guide

> Doc role: `task-runbook`
> Status: Debugging runbook only. For current architecture, start at `.claude/docs/architecture-primer.md`.

Use this guide for runtime and activation debugging only.

## Runtime Surfaces

These are the runtime paths you will touch while debugging:

- Runtime service connection: `~/.capacitor/runtime/runtime-service.json`
- Setup marker: `~/.capacitor/setup_complete`
- Hook binary: `~/.local/bin/hud-hook`
- Persisted runtime artifact: `~/.capacitor/runtime/app_snapshot.json`
- Runtime directory: `~/.capacitor/runtime/`

## First Response Checklist

Start here before opening source files:

```bash
./scripts/dev/agent-observe.sh diagnose
./scripts/ci/runtime-reliability-guard.sh --status
```

If the problem smells like reducer correctness:

```bash
cargo test -p capacitor-core --test replay_diff
```

If the problem smells like hook-event mapping or ingest:

```bash
cargo test -p hud-hook --test session_state_mapping_gate
```

If the problem smells like Swift projection or activation:

```bash
cd apps/swift && swift test
```

If the problem smells like project-card AX automation, start with:

```bash
bash scripts/ci/ax-automation-verify.sh --runs 1 --skip-details
```

## Canonical Diagnostic Tool

`./scripts/dev/agent-observe.sh` is the default observability surface for coding agents.

```bash
./scripts/dev/agent-observe.sh diagnose
./scripts/dev/agent-observe.sh check
./scripts/dev/agent-observe.sh paths
./scripts/dev/agent-observe.sh health
./scripts/dev/agent-observe.sh freshness
./scripts/dev/agent-observe.sh sessions
./scripts/dev/agent-observe.sh projects
./scripts/dev/agent-observe.sh shells
./scripts/dev/agent-observe.sh activity 50
./scripts/dev/agent-observe.sh routing-snapshot <project_path> [workspace_id]
./scripts/dev/agent-observe.sh routing-diagnostics
./scripts/dev/agent-observe.sh session <session_id>
./scripts/dev/agent-observe.sh shell-audit
./scripts/dev/agent-observe.sh errors 20
./scripts/dev/agent-observe.sh hooks
./scripts/dev/agent-observe.sh briefing
./scripts/dev/agent-observe.sh snapshot
./scripts/dev/agent-observe.sh smoke [project_path] [workspace_id]
```

## Activation Debugging

When the terminal opens, focuses the wrong target, or fails to switch sessions:

1. Reproduce with a known project card click.
2. Run `./scripts/dev/agent-observe.sh paths` to print the current app-log and runtime paths.
3. Use `./scripts/dev/agent-observe.sh tail app` in a second terminal while reproducing.
4. Inspect `.routing`, `.shells`, and `.sessions` via `snapshot` or `routing-snapshot`.
5. Check the current activation source files:
   - `apps/swift/Sources/Capacitor/Models/AppState.swift`
   - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
   - `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift`
6. Run the focused Swift tests:

```bash
cd apps/swift && swift test --filter 'TerminalLauncherTests|Ghostty.*Tests'
```

The reliable activation evidence is the app debug log plus the runtime service snapshot payload.
Do not assume `activation-traces` is populated in normal production flows.

## AX Automation Debugging

Use `.claude/docs/ax-automation.md` as the detailed runbook when the issue is specifically:

- project cards missing from the AX tree
- `ax.project-card.*` or `ax.project-details.*` timeouts
- AX relaunch flakes
- `[WindowAX]` lifecycle health failures

Quick triage rule:

1. `Timed out waiting ... for app com.capacitor.app.debug`
   Treat this as a bundle/launch problem.
2. `Timed out waiting ... for AX identifier ax.project-card.*`
   Treat this as “wrong app surface or missing card” first.
3. `No AX windows were found`
   Treat this as a window visibility / trust / AX-surface problem.

## Hook Debugging

When session or shell updates stop arriving:

1. Run `./scripts/dev/agent-observe.sh hooks`.
2. Verify the installed binary:

```bash
~/.local/bin/hud-hook --help
```

3. If the binary is missing or stale, run:

```bash
./scripts/sync-hooks.sh --force
```

4. Verify hook install state in the app setup UI or via setup diagnostics.
   Distinguish `NotInstalled`, `PartiallyConfigured`, and `SettingsUnreadable`
   rather than treating every configuration problem as "hooks missing."
5. Confirm that shell cwd changes produce new runtime snapshot data.

## Setup And First-Run Debugging

When onboarding or setup gating looks wrong:

1. Check whether `~/.capacitor/setup_complete` exists.
2. `isFirstRun` is derived from that marker, not from hook health or "no hook events seen."
3. Hook install/repair failures should now surface as diagnostics and degraded state, not a startup block.
4. Only missing Claude CLI and explicit hook policy blocks should keep the app in setup.

## Event Loss Debugging

The reducer tracks skip counters in `diagnostics`:

- `stale_events_skipped`: events older than the session's last update
- `informational_events_skipped`: non-state-changing events
- `reducer_events_skipped`: guardrail or policy skips
- `events_skipped`: total skipped events

Inspect them with:

```bash
./scripts/dev/agent-observe.sh diagnose
```

If skip rate is high, identify which category dominates before changing code.
High stale-event counts suggest replay or clock problems. High reducer-skip counts
suggest policy interactions such as stop guards or in-flight tool suppression.

## If State Looks Wrong

Use this order:

1. `./scripts/dev/agent-observe.sh diagnose`
2. `cargo test -p capacitor-core --test replay_diff`
3. `cargo test -p hud-hook --test session_state_mapping_gate`
4. `bash scripts/ci/session-state-gate.sh`
5. Capture the snapshot payload and relevant app-log lines before changing code

## Optional: Transparent UI Server

For browser-based exploration:

```bash
node scripts/transparent-ui-server.mjs
```

Useful endpoints:

- `/runtime-snapshot`
- `/agent-briefing`
- `/telemetry`
- `/telemetry-stream`
