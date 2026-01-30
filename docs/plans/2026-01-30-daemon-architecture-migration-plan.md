# Daemon-Based Architecture Migration Plan (End-to-End)

This document is an **exhaustive, agent-ready plan** to migrate Capacitor's state tracking and activation pipeline from multi-writer JSON files to a **single-writer daemon** with transactional storage. It includes context, invariants, data model, IPC contract, rollout strategy, and detailed implementation steps.

## 0. Why This Migration Exists

### Current Pain (confirmed in audits)

- Multiple processes (hud-hook, hud-core cleanup, Swift UI) **read-modify-write the same JSON files**.
- PID liveness is verified inconsistently across subsystems (cleanup uses PID-only; lock logic uses proc_started).
- State corruption or parse errors can result in **silent resets** (e.g., `sessions.json` becomes empty).
- Lock metadata writes are not atomic; crash can leave half-written directories.
- Activity tracking is atomic but **last-writer-wins** under concurrency.

### Target Outcome

- **Single writer** for all state (daemon).
- **Transactional storage** (SQLite/WAL) with replayable event log.
- Hooks + App become clients (IPC), no user-facing daemon command.
- Backwards compatible during rollout: file-based **fallback** remains until stabilized.

---

## 1. Current System Map (for reference)

### Primary Artifacts (current)

| Artifact                                         | Writer(s)                                 | Reader(s)                         | Notes                                         |
| ------------------------------------------------ | ----------------------------------------- | --------------------------------- | --------------------------------------------- |
| `~/.capacitor/sessions.json`                     | `hud-hook handle`, `hud-core cleanup`     | Swift UI, `hud-core` resolver     | Multi-writer, RMW; parse error => empty store |
| `~/.capacitor/sessions/{session_id}-{pid}.lock/` | `hud-hook handle`, `hud-hook lock-holder` | `hud-core` lock/resolver, cleanup | Liveness proof, PID checks vary               |
| `~/.capacitor/ended-sessions/{session_id}`       | `hud-hook handle`, `hud-core cleanup`     | `hud-hook handle`                 | Tombstones to block late events               |
| `~/.capacitor/file-activity.json`                | `hud-hook handle`                         | `hud-core ActivityStore`          | Atomic writes but last-writer-wins            |
| `~/.capacitor/shell-cwd.json`                    | `hud-hook cwd`                            | Swift activation                  | Atomic, RMW                                   |
| `~/.capacitor/shell-history.jsonl`               | `hud-hook cwd`                            | Swift (debug)                     | Append-only                                   |
| `~/.capacitor/hud-hook-heartbeat`                | `hud-hook handle`                         | Setup UI                          | Heartbeat for hook health                     |
| `~/.claude/settings.json`                        | `hud-core setup`                          | Claude                            | Must preserve other settings                  |
| `~/.local/bin/hud-hook`                          | `hud-core setup` / Swift installer        | hooks                             | Symlink required (Gatekeeper)                 |

---

## 2. Target Architecture (Daemon-Based)

### Core idea

A **local daemon** is the **only writer** of state. Hooks and the Swift app become **clients** via IPC. The daemon persists to SQLite (WAL) + an append-only event log for replay.

### Responsibilities

- Ingest events from hooks (SessionStart, PostToolUse, ShellCwd, etc.)
- Maintain canonical state (sessions, activity, shell state, tombstones)
- Verify PID liveness and process identity consistently
- Expose read APIs for the Swift app
- Export JSON snapshots for backwards compatibility (optional during migration)

### Non-Goals

- No change to user CLI workflow (`claude`, `codex`, etc.)
- No new user-facing daemon commands
- No breaking change to hook installation or symlink strategy

---

## 3. Invariants (Must Hold During Migration)

1. **No user command changes**: `claude`, `codex`, hook triggers continue unchanged.
2. **Single writer**: once daemon is enabled, all writes go through it.
3. **Fallback always available**: if daemon is down, hook/app can use file-based mode.
4. **Symlink strategy stays**: `~/.local/bin/hud-hook` must remain a symlink.
5. **Exact-path session correctness**: session state is never inferred from parent directories.
6. **Activity is secondary**: activity should never override explicit session state.
7. **Daemon is invisible**: must auto-start and auto-recover without user action.

---

## 4. IPC Contract (Initial Draft)

### Transport

- Unix Domain Socket at `~/.capacitor/daemon.sock`.
- Newline-delimited JSON (one request per line) for phase 1.

### Message Types

**Event Ingest**

- `Event.SessionStart`
- `Event.UserPromptSubmit`
- `Event.PostToolUse`
- `Event.SessionEnd`
- `Event.Stop`
- `Event.ShellCwd`

**Queries**

- `GetSessions`
- `GetShellState`
- `GetActivity`
- `GetHealth`

**Response format**

- `{ "ok": true, "data": ... }`
- `{ "ok": false, "error": { "code": "...", "message": "..." } }`

### Versioning

- All messages include `protocol_version`.
- Daemon rejects or downgrades if version mismatch.

---

## 5. Data Model (SQLite)

### Tables

1. `events`
   - id (pk)
   - recorded_at (RFC3339 string)
   - event_type (snake_case string from protocol serialization)
   - session_id
   - pid
   - payload (full `EventEnvelope` JSON)

2. `sessions`
   - session_id
   - pid
   - state
   - cwd
   - updated_at
   - state_changed_at
   - metadata (working_on, project_dir, permission_mode, etc.)

3. `activity`
   - session_id
   - project_path
   - file_path
   - tool
   - timestamp

4. `shell_state`
   - pid
   - cwd
   - tty
   - parent_app
   - tmux_session
   - tmux_client_tty
   - updated_at

5. `process_liveness`
   - pid
   - proc_started
   - last_seen_at

6. `tombstones`
   - session_id
   - created_at
   - expires_at

### Notes

- `session_id + pid` is the **unique key** for sessions.
- Session-level rollups can be computed on query.
- Activity remains bounded by count/time windows per session.
- Phase 3 persists only `events` + `shell_state`; other tables are added in later phases.
- Always derive `event_type` strings using the shared protocol serializer (avoid hardcoding).

---

## 6. Migration Phases

### Phase 0 — Design & Spec (1–2 days)

- Write a short spec for IPC, data model, and fallback behavior.
- Decide whether JSON snapshots are produced by daemon or removed entirely.
- Confirm launchd strategy (LaunchAgent + auto-restart).

### Phase 1 — Daemon MVP (2–4 days)

- Create new crate `core/daemon`.
- Add shared protocol crate `core/daemon-protocol` to prevent schema drift.
- Implement IPC server + in-memory state (shell CWD first).
- Implement `get_health` + `get_shell_state`.
- Add logging to `~/.capacitor/daemon.log` (or tracing defaults during dev).

### Phase 2 — Hook Client (3–5 days)

- Add a small IPC client to `hud-hook`.
- On event: send to daemon; on failure, **fallback to current file writes**.
- Add env flag `CAPACITOR_DAEMON_ENABLED=1` (default off in prod initially).
- Allow socket override via `CAPACITOR_DAEMON_SOCKET`.

### Phase 3 — App Client + SQLite Persistence (4–7 days)

- Add `DaemonClient` in Swift (Unix socket, newline framing, timeout/size limits).
- App reads daemon state if available, otherwise fallback to JSON.
- Wire first read path to daemon (`ShellStateStore` → `get_shell_state`).
- Surface daemon status in Setup/Diagnostics UI.
- Replace in-memory state with SQLite WAL.
- Append to `events` table for replay.
- Rebuild state on startup if cache tables empty/corrupt.
- Add replay integration test (event log → rebuilt state).

### Phase 4 — Liveness + Locks Simplification (2–4 days)

- Centralize PID+proc_started logic in daemon.
- Deprecate lock directories or keep as compatibility shim only.
- Add `process_liveness` table and update per incoming event.

### Phase 5 — Launchd + Reliability (2–4 days)

- Add LaunchAgent (auto-start + auto-restart).
- Add health checks; fallback if daemon down.
- Add crash loop backoff.

### Phase 6 — Cleanup & Removal (1–3 days)

- Remove file-based writes from hooks.
- Remove JSON-based cleanup logic.
- Keep JSON snapshots as read-only cache if desired.

---

## 7. Implementation Checklist (Detailed)

### Repository changes

- Add `core/daemon/` crate
- Add `core/daemon-protocol/` shared IPC schema crate
- Update workspace `Cargo.toml`
- Add logging config for daemon (tracing)
- Add SQLite dependency (rusqlite or sqlx)

### Hook changes

- Add IPC client (connect to `~/.capacitor/daemon.sock`)
- Feature flag guard (`CAPACITOR_DAEMON_ENABLED`)
- Socket override (`CAPACITOR_DAEMON_SOCKET`)
- Fallback to file writes on IPC failure

### Swift changes

- Add `DaemonClient.swift` (socket client + response framing)
- Integrate in `ShellStateStore` (daemon-first, JSON fallback)
- Add UI status indicator for daemon health

### Docs

- Update system map, side-effects map, and gotchas
- Add daemon install/health notes

---

## 8. Testing Plan

### Unit Tests

- Daemon event parsing
- State transitions per event type
- SQLite persistence + replay
- Event log → `shell_state` rebuild (tempfile-backed integration test)

### Integration Tests

- `hud-hook` -> daemon -> query
- Daemon down -> fallback to file mode
- Daemon restart with replay

### Regression Tests

- Activation matrix (Swift)
- Hook health + heartbeat logic
- Multi-shell same session_id handling

---

## 9. Rollout Strategy

- **Alpha**: daemon optional, disabled by default
- **Beta**: daemon enabled by default, fallback on failure
- **Stable**: daemon required, fallback removed (or hidden)

---

## 10. Definition of Done

- Daemon receives all hook events in prod builds
- App reads state from daemon with fallback
- SQLite WAL persistence with replay is stable
- All prior audit issues (JSON race, PID reuse, silent wipe) are eliminated
- Launchd auto-start is reliable and documented

---

## 11. Open Questions

- Should JSON snapshots be kept forever (debug) or phased out?
- Should daemon export metrics (Prometheus-style) or just logs?
- How should event schema evolve without breaking old hooks?
- Do we need any legacy disk seeding now that replay from the event log restores shell state?
- Do we need an in-app toggle for daemon enablement (GUI apps don’t inherit shell env vars)?

---

## 12. Quick Start for Agents

1. Create `core/daemon` with minimal IPC loop.
2. Implement `GetHealth` and `Event.SessionStart`.
3. Add IPC client in `hud-hook` with fallback.
4. Add Swift daemon client and read integration.
5. Enable via `CAPACITOR_DAEMON_ENABLED=1` for dev.

---

This plan is intended to be authoritative for migration work. Any deviation should update this document to keep agent context aligned.
