# ADR-004: Simplify State Storage (Per-Session Directories vs Event Log)

**Status:** Proposed (recommended option selected, pending implementation)\n
**Date:** 2026-01-27\n
**Context:** Reduce regressions by reducing shared mutable state and duplicated writers.

## Why this ADR exists

The current implementation works “decently well,” but it has **high regression pressure** because it relies on multiple subsystems with overlapping side effects. Fixing one edge case can easily violate assumptions elsewhere.

The biggest structural sources of instability identified in the side-effects audits are:

- **Shared-file races**: multiple processes write whole-file snapshots (e.g., cleanup vs hook updates to `sessions.json`).
- **Non-atomic, read-modify-write JSON**: `file-activity.json` is written by `hud-hook` with non-atomic writes and no locking.
- **Duplicated implementations**: activity tracking exists in both `hud-hook` and `hud-core`, with different atomicity and cleanup behavior.
- **Background process complexity**: `lock-holder` is operationally convenient but adds lifecycle edge cases and has at least one correctness bug (24h timeout releasing locks while PID is alive).

**Goal:** Reduce the number of side-effect “authoritative sources” and make the remaining writes easier to reason about, test, and repair.

## Current system (baseline)

See canonical map: [`.claude/docs/audit/00-current-system-map.md`](../../.claude/docs/audit/00-current-system-map.md).

In short, today we have **multiple stores**:
- `~/.capacitor/sessions.json` (session records)
- `~/.capacitor/sessions/*.lock/` (locks + pid verification)
- `~/.capacitor/ended-sessions/*` (tombstones)
- `~/.capacitor/file-activity.json` (monorepo activity fallback)
- shell tracking and activation state (separate, still needed)

## Decision drivers

We will prefer an approach that:

- **Eliminates shared mutable maps** written by multiple processes (primary driver).
- **Makes writes atomic or append-only**, with clear recovery if partial/corrupt.
- **Supports monorepo package “working” detection** without duplicating logic.
- **Preserves sidecar boundaries**: read from `~/.claude/`, write only to `~/.capacitor/` (plus `~/.local/bin/hud-hook` and hooks in `~/.claude/settings.json`).
- **Improves explainability**: ability to show “why is this project highlighted / working?”
- **Allows staged migration** (dual-write + compare), so we don’t ship a blind rewrite.

## Option B (Recommended): Per-session directories with per-session event log

### Summary

Each Claude session becomes a **self-contained directory** under `~/.capacitor/sessions/`.

Hooks write **append-only events** for that session (and minimal immutable metadata). The app/core derives state from those events.

This removes the need for:
- Global `sessions.json` (shared snapshot map)
- Global `file-activity.json` (shared read-modify-write map)
- Tombstones (SessionEnd in the log provides ordering)

### On-disk layout

```text
~/.capacitor/sessions/
  {session_id}/
    meta.json              # immutable-ish (pid, proc_started, project_dir, created_at)
    events.jsonl           # append-only event stream (one JSON object per line)
    derived.json           # optional: app-written derived snapshot for fast reads (single-writer)

  legacy/                  # optional: any migration staging / quarantined old artifacts
  {session_id}-{pid}.lock/ # (v4 legacy) removed after migration
```

### Event schema (example)

Each line in `events.jsonl` is one JSON object:

```json
{
  "v": 1,
  "event_id": "2026-01-27T18:22:11.123Z-12345-8f2c",
  "recorded_at": "2026-01-27T18:22:11.123Z",
  "session_id": "A_UUID",
  "pid": 12345,
  "proc_started": 123456789,
  "event": "PostToolUse",
  "cwd": "/repo",
  "state_hint": "working",
  "tool_name": "Edit",
  "file_path": "/repo/packages/auth/login.ts"
}
```

Notes:
- `event_id` is generated to be unique without coordination (timestamp + pid + random).
- `proc_started` is included whenever available (helps PID reuse verification).
- `state_hint` is optional; the derived state is computed by the reconciler, not trusted blindly.

### Derived state (single-writer)

The HUD app (or `hud-core`) becomes the **single writer** of `derived.json` (optional but recommended).

The derived file is a snapshot such as:

```json
{
  "v": 1,
  "session_id": "A_UUID",
  "project_dir": "/repo",
  "last_cwd": "/repo",
  "state": "working",
  "state_changed_at": "2026-01-27T18:22:11.123Z",
  "updated_at": "2026-01-27T18:22:20.555Z",
  "recent_activity": [
    { "project_path": "/repo/packages/auth", "updated_at": "2026-01-27T18:22:20.555Z" }
  ]
}
```

### Resolution behavior

- **Session liveness**: derived from `(pid, proc_started)` stored in `meta.json` and/or events.
- **Per-project state**: derived from sessions whose `project_dir` exactly equals project path.
- **Monorepo package state**: derived from recent file activity events, mapped to `project_path` via boundary detection (single implementation in `hud-core`).
- **Late events**: if SessionEnd event exists, subsequent events in the log are ignored (unless a new SessionStart begins a new “generation,” which is rare for UUID ids).

### Failure modes & recovery

- **Partial/corrupt last line in `events.jsonl`**: reader ignores the last line if it fails JSON parsing.
- **Concurrent appends**: can be handled with `flock()` on `events.jsonl` per session.\n  - This is localized per session; concurrent sessions don’t contend on one global lock.
- **No SessionEnd**: session is considered ended when PID is dead and no new events arrive.
- **App not running**: hooks still append events; derived state is recomputed when app starts.

### Why this is simpler than today

- No global shared state maps written by multiple writers.
- No duplicated activity writer implementations; activity is just events.
- Tombstone concept becomes a derived rule, not an extra store.
- Lock-holder can be removed entirely (liveness is derived from pid verification).

## Option C: Global append-only event log + reconciliation

### Summary

All sessions append to one file: `~/.capacitor/events.jsonl`. The app maintains a derived snapshot.

### On-disk layout

```text
~/.capacitor/
  events.jsonl                 # global append-only event stream
  derived-state.json           # single-writer derived snapshot
  derived-state.cursor.json    # last processed offset, etc.
```

### Pros

- One place to look for “what happened” (excellent debugging story).
- Derivation is centralized; compaction strategy is uniform.

### Cons

- Requires either:\n  - a **global file lock** (contention under concurrent sessions), or\n  - acceptance of platform-dependent append atomicity.\n
- Compaction becomes mandatory over time (file will grow without bound).

## Recommendation

Choose **Option B (Per-session directories + per-session event log)**.

Rationale:
- Achieves the primary driver: eliminate shared mutable snapshot maps.
- Avoids a global write hotspot and global lock contention.
- Enables deleting entire sessions cleanly (directory boundary is the unit of cleanup).
- Makes monorepo activity a first-class part of session history without a separate global activity store.

## Migration plan (staged, low-risk)

### Phase 0: Add new writers (dual-write)

- Keep existing behavior intact.\n
- Additionally write:\n  - `~/.capacitor/sessions/{session_id}/meta.json` on SessionStart.\n  - append to `~/.capacitor/sessions/{session_id}/events.jsonl` on all hook events.\n
- Do not change UI behavior yet.

### Phase 1: Build derived state + compare (shadow mode)

- App builds derived state from per-session logs.\n
- For each project, compare:\n  - old resolver result (locks + `sessions.json` + `file-activity.json`) vs\n  - new derived result.\n
- Record mismatches in a debug/diagnostics pane and/or a local log in `~/.capacitor/`.

### Phase 2: Switch reads (dual-read)

- UI reads from new derived state.\n
- Old system remains as fallback if derived state is unavailable/corrupt.

### Phase 3: Remove old stores

- Stop writing:\n  - `~/.capacitor/sessions.json`\n  - `~/.capacitor/file-activity.json`\n  - `~/.capacitor/ended-sessions/*`\n  - `~/.capacitor/sessions/*.lock/` and lock-holder process\n
- Keep a one-click “Reset Capacitor State” to delete old artifacts if present.

## Consequences

### Positive

- Side effects shrink to a small number of predictable artifacts.\n
- Debugging becomes “inspect the session directory” instead of reconciling multiple stores.\n
- Fewer places for agents to introduce regressions.\n
- Recovery is straightforward: delete session dirs / derived snapshot and rebuild.

### Negative / Tradeoffs

- Requires new reconciliation logic in core/app.\n
- Needs careful handling of out-of-order async events (but this is already a reality today, handled via tombstones and heuristics).\n
- Requires a clear retention/cleanup policy for session dirs and event logs.

## Open questions (to be settled during implementation)

- Should hooks also write a tiny `latest.json` snapshot (atomic) to speed up reads, or should only the app write derived snapshots?\n
- How much event history do we retain per session (size cap vs time-based)?\n
- Do we need a per-session file lock (`flock`) for append to guarantee correctness on all macOS filesystems?

