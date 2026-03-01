# Diagnostics Audit: Single Pane of Glass

**Date:** 2026-03-01
**Status:** Approved
**Scope:** Dev-time agent diagnostics tooling

## Problem

Capacitor has 5 overlapping diagnostic layers built up incrementally during architecture transitions (daemon → direct-core). Coding agents working ON Capacitor face:

- Fragile dependencies (CLI requires Node server for basic queries)
- Dead artifacts referencing removed SQLite/daemon modes
- Two overlapping docs with partial coverage each
- Stuck-session diagnostics gated behind `#if DEBUG`
- No single "just tell me what's wrong" command

## Design

### Canonical Entry Point

`./scripts/dev/agent-observe.sh` is the single diagnostic tool. Everything else either feeds into it or gets deleted.

### Deletions

| Artifact | Reason |
|----------|--------|
| `observe-sql` (Makefile + agent-observe.sh) | No SQLite in direct-core mode |
| `observe-tail-daemon-stderr/stdout` | Daemon-era logs don't exist |
| `/routing-rollout` endpoint (transparent-ui-server.mjs) | Returns null, dead code |
| `docs/transparent-ui/` directory | Vestigial HTML explorer |
| All 18 Makefile observe-* targets | Pure indirection; CLAUDE.md points to agent-observe.sh |

### Self-Sufficient CLI

Remove transparent-ui-server dependency from core commands:

- `briefing` → read snapshot file directly, format as agent summary
- `telemetry` → read from telemetry.jsonl if exists, else report unavailable
- `snapshot` → always read from file (remove server proxy)
- `stream` → keep as server-dependent, clearly documented
- `check` → remove server reachability check (server is optional)

### New Commands

| Command | Purpose |
|---------|---------|
| `diagnose` | One-shot: freshness → health → stuck sessions → recent errors → routing |
| `freshness` | Snapshot age in seconds + staleness warning |
| `errors [limit]` | Last N error/fail/crash lines from app-debug.log |
| `hooks` | Hook binary status + recent hook debug log entries |

### Documentation Merge

Merge `agent-observability-runbook.md` into `debugging-guide.md`. Delete runbook. Update CLAUDE.md references.

### DiagnosticsSnapshotLogger Promotion

Remove `#if DEBUG` gate. Add 5MB rotation (matching DebugLog retained size). Critical for agents diagnosing stuck sessions in release builds.

### CLAUDE.md Update

Simplify Telemetry section to reference only `agent-observe.sh`. Remove Makefile references.

## Out of Scope

- DebugLog.swift internals (already solid)
- transparent-ui-server.mjs core functionality (stays as optional browser tool)
- Rust core diagnostics (runtime internals, not dev-time tooling)
- CI reliability gates (session-state-gate.sh, non-demo-ax-smoke.sh)
