# Debugging Guide

## Core Model

Capacitor is runtime-snapshot based:

1. `hud-hook` ingests events.
2. `capacitor-core` projects state.
3. Swift reads typed snapshot data and renders UI.

## Canonical Diagnostic Tool

```bash
# One-shot full diagnostic summary
./scripts/dev/agent-observe.sh diagnose

# Individual commands
./scripts/dev/agent-observe.sh check       # Validate runtime paths
./scripts/dev/agent-observe.sh health      # Runtime health from snapshot
./scripts/dev/agent-observe.sh freshness   # Snapshot age + staleness
./scripts/dev/agent-observe.sh sessions    # Session summaries
./scripts/dev/agent-observe.sh projects    # Project summaries
./scripts/dev/agent-observe.sh shells      # Shell summaries
./scripts/dev/agent-observe.sh routing-snapshot <path> [ws]  # Routing entry
./scripts/dev/agent-observe.sh session <id> # Full detail for one session
./scripts/dev/agent-observe.sh shell-audit  # Cross-validate shells: PID, TTY, liveness
./scripts/dev/agent-observe.sh errors      # Recent error/warning lines from debug log
./scripts/dev/agent-observe.sh hooks       # Hook binary + heartbeat age + recent events
./scripts/dev/agent-observe.sh activation-traces  # Recent activation decision traces
./scripts/dev/agent-observe.sh briefing    # Agent-friendly summary
./scripts/dev/agent-observe.sh snapshot    # Full runtime snapshot
./scripts/dev/agent-observe.sh smoke       # Run all smoke checks
```

## Activation Debugging

1. Reproduce with a known project card click.
2. Run `./scripts/dev/agent-observe.sh activation-traces` to see the decision trace
   (shows candidates, ranking keys, policy order, selected PID).
3. Inspect routing block in snapshot (`.routing`).
4. Verify shell evidence in `.shells` and session evidence in `.sessions`.
5. Run `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` when policy changes.

Traces are always written to the debug log — no env var needed.

## Hook Debugging

1. Run `./scripts/dev/agent-observe.sh hooks` for status.
2. Verify binary: `~/.local/bin/hud-hook --help`
3. Verify hook install via setup screen / hook diagnostics.
4. Confirm snapshot updates after shell cwd changes.

## Event Loss Debugging

The reducer silently skips events in several categories. Skip counters in
`diagnostics` make this visible:

- `stale_events_skipped` — events older than the session's last update
- `informational_events_skipped` — WorktreeCreate/Remove, ConfigChange, Unknown
- `reducer_events_skipped` — stop_guard, session_start_already_active, idle_prompt_tools_in_flight, etc.
- `events_skipped` — total (sum of above)

Check via: `./scripts/dev/agent-observe.sh diagnose` (shows skip counters + skip rate).

If skip rate is high (>30%), investigate which category dominates — stale events
suggest clock skew or event replay; reducer skips suggest heavy subagent activity.

## If State Looks Wrong

1. Run `./scripts/dev/agent-observe.sh diagnose` first.
2. Validate reducer determinism (`cargo test -p capacitor-core --test replay_diff`).
3. Validate mapping integrity (`cargo test -p hud-hook --test session_state_mapping_gate`).
4. Check reliability gates (`bash scripts/ci/session-state-gate.sh`).
5. Capture snapshot payload and attach to bug report.

## Optional: Transparent UI Server

For browser-based exploration (not required for CLI diagnostics):

```bash
node scripts/transparent-ui-server.mjs  # http://localhost:9133
```

Endpoints: `/runtime-snapshot`, `/agent-briefing`, `/telemetry`, `/telemetry-stream`
