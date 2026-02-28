# Debugging Guide (Runtime Snapshot)

## Core Model

Capacitor is runtime-snapshot based:

1. `hud-hook` ingests events.
2. `capacitor-core` projects state.
3. Swift reads typed snapshot data and renders UI.

## Useful Commands

```bash
# Runtime snapshot
cat ~/.capacitor/runtime/app_snapshot.json | jq

# Runtime observer endpoints
curl -s http://localhost:9133/runtime-snapshot | jq
curl -s "http://localhost:9133/agent-briefing?limit=200" | jq

# Reliability gates
bash scripts/ci/session-state-gate.sh
bash scripts/ci/non-demo-ax-smoke.sh
```

## Activation Debugging

1. Reproduce with a known project card click.
2. Inspect routing block in snapshot (`.routing`).
3. Verify shell evidence in `.shells` and session evidence in `.sessions`.
4. Run `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` when policy changes.

## Hook Debugging

1. Verify binary: `~/.local/bin/hud-hook --help`
2. Verify hook install via setup screen / hook diagnostics.
3. Confirm snapshot updates after shell cwd changes.

## If State Looks Wrong

1. Validate reducer determinism (`cargo test -p capacitor-core --test replay_diff`).
2. Validate mapping integrity (`cargo test -p hud-hook --test session_state_mapping_gate`).
3. Capture `runtime-snapshot` payload and attach to bug report.
