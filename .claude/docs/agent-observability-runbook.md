# Agent Observability Runbook (Runtime Snapshot)

Use this runbook for quick runtime visibility while debugging Capacitor behavior.

## Start Observability Server

```bash
node scripts/transparent-ui-server.mjs
```

Server: `http://localhost:9133`

## High-Value Endpoints

```bash
curl -s http://localhost:9133/runtime-snapshot | jq
curl -s "http://localhost:9133/agent-briefing?limit=200" | jq
curl -s http://localhost:9133/telemetry | jq
```

## Runtime Files

```bash
ls -la ~/.capacitor/runtime
cat ~/.capacitor/runtime/app_snapshot.json | jq '.projects | length, .sessions | length, .shells | length'
```

## Fast Health Checks

```bash
cargo test -p capacitor-core --test replay_diff
bash scripts/ci/session-state-gate.sh
bash scripts/ci/non-demo-ax-smoke.sh
```

## Troubleshooting Order

1. Check `runtime-snapshot` endpoint payload shape.
2. Check `~/.capacitor/runtime/app_snapshot.json` freshness.
3. Re-run replay/session-state gates.
4. Reproduce with AX smoke for UI-level symptoms.
