# Alpha Feedback + Telemetry Loop (Cloudflare Worker + D1)

This project keeps GitHub issues as the human-facing feedback channel while optionally sending structured feedback/telemetry to one low-ops backend.

Feedback form UX v2 spec:

- `/Users/petepetrash/Code/capacitor/docs/feedback-form-v2.md`

## App environment variables

Set these in the app process environment:

- `CAPACITOR_FEEDBACK_API_URL`
  Optional. Example: `https://<worker-domain>/v1/feedback`.
- `CAPACITOR_TELEMETRY_URL`
  Optional. Defaults to `http://localhost:9133/telemetry`. For production ingest, set to `https://<worker-domain>/v1/telemetry`.
- `CAPACITOR_INGEST_KEY`
  Optional but required for authenticated remote ingest. Sent as `Authorization: Bearer <CAPACITOR_INGEST_KEY>` for feedback and telemetry requests.
- `CAPACITOR_TELEMETRY_DISABLED`
  Optional. Set to `1` to disable telemetry emitter entirely.
- `CAPACITOR_TELEMETRY_INCLUDE_PATHS`
  Optional. Set to `1` only when explicit raw-path sharing is intended for remote telemetry.

## Local dev wiring (done)

- Runtime loader:
  - `/Users/petepetrash/Code/capacitor/scripts/dev/load-runtime-env.sh`
- Local env file (git-ignored):
  - `/Users/petepetrash/Code/capacitor/scripts/dev/capacitor-ingest.local`
- Template:
  - `/Users/petepetrash/Code/capacitor/scripts/dev/capacitor-ingest.local.example`

The loader is sourced automatically by:

- `/Users/petepetrash/Code/capacitor/scripts/dev/restart-app.sh`
- `/Users/petepetrash/Code/capacitor/scripts/dev/reset-for-testing.sh`

It exports variables for shell launches and also sets `launchctl` env so GUI launches from `open -n` inherit the same values.

## Privacy behavior

- Quick feedback defaults to telemetry-on, project-paths-off.
- Quick feedback payload paths are already redacted unless user opts in.
- Generic remote telemetry now applies centralized path redaction by default.
- Local telemetry endpoints (for local debugging) are not auto-redacted.
- Every quick feedback submission has a `feedback_id` correlated across:
  - feedback POST payload (`feedback_id`)
  - GitHub issue title/body metadata
  - `quick_feedback_submitted` telemetry event payload

## Backend service

Worker code lives in:

- `/Users/petepetrash/Code/capacitor/services/ingest-worker`

It exposes:

- `POST /v1/feedback`
- `POST /v1/telemetry`

Remote ingest hardening:

- Worker-side `/v1/telemetry` persists a strict allowlist:
  - quick-feedback events (`quick_feedback_*`)
  - activation diagnostics (`activation_decision`, `activation_outcome`)
  - ingest-path diagnostics (`runtime_transport_error`, `routing_snapshot_refresh_error`)
- App-side telemetry routing policy uses the same allowlist when the endpoint path is `/v1/telemetry`.
- Non-allowlisted events are dropped with HTTP `202` and not stored.
- Duplicate diagnostics in a short window are dropped with HTTP `202` (`reason=duplicate_throttled`).
- Worker scheduled retention prunes telemetry to keep storage bounded:
  - non-allowlisted telemetry: 1 day
  - high-volume interaction telemetry: 30 days
  - diagnostics/submission telemetry: 90 days

D1 schema is in:

- `/Users/petepetrash/Code/capacitor/services/ingest-worker/migrations/`

## Weekly triage

- SQL query bundle:
  - `/Users/petepetrash/Code/capacitor/services/ingest-worker/sql/weekly-triage.sql`
- Markdown report generator:
  - `/Users/petepetrash/Code/capacitor/services/ingest-worker/scripts/weekly-triage-report.mjs`

Example:

```bash
cd services/ingest-worker
npm run triage -- --db capacitor-alpha --out ./reports/weekly-triage.md
```
