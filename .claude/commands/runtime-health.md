# /runtime-health

Check Capacitor runtime service health, snapshot freshness, and session state.
Useful with `/loop` for continuous background monitoring during development.

## Usage

```
/runtime-health
/loop 5m /runtime-health
```

## What it checks

Run the following diagnostics and report results:

```bash
./scripts/dev/agent-observe.sh health
./scripts/dev/agent-observe.sh freshness
```

Summarize:
1. **Runtime service status** — is the service reachable?
2. **Snapshot freshness** — how old is the latest snapshot? Flag if stale (>5 minutes).
3. **Active sessions** — how many sessions are being tracked?

If either command fails, report the error and suggest running `./scripts/dev/agent-observe.sh diagnose` for full diagnostics.

Keep the output concise — this is meant for at-a-glance health checks, not deep investigation.
