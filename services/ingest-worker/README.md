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
- `runtime_transport_error`
- `routing_snapshot_refresh_error`

Other telemetry event types return `202` with a dropped response and are not written to D1.
Duplicate diagnostics (`activation_*` / runtime transport errors) within a short window are also dropped with `202` and `reason=duplicate_throttled`.

Feedback normalization persists the runtime health snapshot in `runtime_enabled`, `runtime_healthy`, and `runtime_version` columns.

Telemetry retention is enforced by a scheduled worker task:

- Non-allowlisted legacy telemetry: 1 day
- High-volume quick-feedback interaction events: 30 days
- Diagnostic + submitted feedback telemetry: 90 days

Retention is based on `received_at` (server-side timestamp), not client-provided `occurred_at`.

`/v1/*` endpoints require bearer auth:

- `Authorization: Bearer <INGEST_KEY>`

## Data stored

### Feedback submissions

| Field | Description |
|-------|-------------|
| `feedback_id` | Client-provided or auto-generated identifier |
| `submitted_at` | Client-provided submission timestamp |
| `received_at` | Server-side receive timestamp (auto-set) |
| `last_received_at` | Updated on upsert |
| `feedback_text` | User feedback text |
| `app_version` | App version string |
| `build_number` | Build number |
| `channel` | Release channel (e.g. alpha) |
| `os_version` | macOS version |
| `include_telemetry` | Whether user opted in to telemetry |
| `include_project_paths` | Whether user opted in to project path sharing |
| `runtime_enabled` | Runtime service enabled flag |
| `runtime_healthy` | Runtime service health flag |
| `runtime_version` | Runtime service version |
| `active_source` | Active project source |
| `project_count` | Number of projects |
| `session_*` | Session state counts (total, working, ready, waiting, compacting, idle, with_attached, thinking) |
| `activation_has_trace` | Whether activation trace is present |
| `activation_trace_digest` | Activation trace digest |
| `source_ip` | **Truncated SHA-256 hash** of the client IP (first 16 hex chars / 64 bits). Raw IP is never stored. |
| `user_agent` | User-Agent header (low-PII, useful for debugging) |

### Telemetry events

| Field | Description |
|-------|-------------|
| `id` | Auto-incrementing row ID |
| `received_at` | Server-side receive timestamp (auto-set) |
| `event_type` | Event type from allowlist |
| `message` | Event message |
| `occurred_at` | Client-provided event timestamp (advisory) |
| `feedback_id` | Associated feedback ID (if any) |
| `payload_json` | Structured event payload |
| `source_ip` | **Truncated SHA-256 hash** of the client IP (first 16 hex chars / 64 bits). Raw IP is never stored. |
| `user_agent` | User-Agent header |

**Note:** `raw_json` is no longer written. The column exists in the schema for backwards compatibility but is nullable and omitted from all INSERT statements.

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

This applies the runtime-era feedback column rename migration for existing deployments (`daemon_*` -> `runtime_*`) as part of the same migration history.

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
npx wrangler d1 migrations apply capacitor-alpha --local
npm run dev
```

## Weekly triage report

Generate markdown report from D1 (last 7 days):

```bash
npm run triage -- --db capacitor-alpha --out ./reports/weekly-triage.md
```

Use `--local` to run against local D1.
