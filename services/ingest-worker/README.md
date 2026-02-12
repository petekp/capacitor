# Capacitor Ingest Worker

Cloudflare Worker + D1 ingestion backend for Capacitor alpha feedback + telemetry.

## Endpoints

- `POST /v1/feedback`
- `POST /v1/telemetry`
- `GET /health`

`/v1/telemetry` only persists a strict allowlist:

- `quick_feedback_opened`
- `quick_feedback_field_completed`
- `quick_feedback_submit_attempt`
- `quick_feedback_submit_success`
- `quick_feedback_submit_failure`
- `quick_feedback_abandoned`
- `quick_feedback_submitted`
- `activation_decision`
- `activation_outcome`
- `daemon_ipc_error`
- `routing_snapshot_refresh_error`

Other telemetry event types return `202` with a dropped response and are not written to D1.
Duplicate diagnostics (`activation_*` / daemon routing errors) within a short window are also dropped with `202` and `reason=duplicate_throttled`.

Telemetry retention is enforced by a scheduled worker task:

- Non-allowlisted legacy telemetry: 1 day
- High-volume quick-feedback interaction events: 30 days
- Diagnostic + submitted feedback telemetry: 90 days

`/v1/*` endpoints require bearer auth:

- `Authorization: Bearer <INGEST_KEY>`

## Setup

1. Install dependencies:

```bash
cd services/ingest-worker
npm install
```

2. Create a D1 database and capture its `database_id`:

```bash
npx wrangler d1 create capacitor-alpha
```

3. Update `wrangler.toml`:

- Set `database_id` in `[[d1_databases]]`.

4. Apply schema:

```bash
npx wrangler d1 migrations apply capacitor-alpha --remote
```

5. Set the ingest key secret:

```bash
npx wrangler secret put INGEST_KEY
```

6. Deploy:

```bash
npm run deploy
```

## Local dev

```bash
npm run dev
```

## Weekly triage report

Generate markdown report from D1 (last 7 days):

```bash
npm run triage -- --db capacitor-alpha --out ./reports/weekly-triage.md
```

Use `--local` to run against local D1.
