# Transparent UI (Runtime Explorer)

Transparent UI is a local runtime observer for Capacitor's snapshot-based architecture.

## Start

```bash
scripts/run-transparent-ui.sh
```

This launches:

1. `scripts/transparent-ui-server.mjs` on `http://localhost:9133`
2. `docs/transparent-ui/capacitor-interfaces-explorer.html`

## Endpoints

- `GET /runtime-snapshot` — normalized runtime snapshot payload
- `GET /agent-briefing` — compact summary for coding-agent context
- `GET /telemetry` — recent telemetry buffer
- `GET /telemetry-stream` — SSE telemetry stream

## Notes

This tool is strictly local and intended for development diagnostics.
