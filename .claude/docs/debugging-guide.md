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
./scripts/dev/agent-observe.sh errors      # Recent errors from debug log
./scripts/dev/agent-observe.sh hooks       # Hook status + recent events
./scripts/dev/agent-observe.sh briefing    # Agent-friendly summary
./scripts/dev/agent-observe.sh snapshot    # Full runtime snapshot
./scripts/dev/agent-observe.sh smoke       # Run all smoke checks
```

## Activation Debugging

1. Reproduce with a known project card click.
2. Inspect routing block in snapshot (`.routing`).
3. Verify shell evidence in `.shells` and session evidence in `.sessions`.
4. Run `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` when policy changes.

## Hook Debugging

1. Run `./scripts/dev/agent-observe.sh hooks` for status.
2. Verify binary: `~/.local/bin/hud-hook --help`
3. Verify hook install via setup screen / hook diagnostics.
4. Confirm snapshot updates after shell cwd changes.

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
