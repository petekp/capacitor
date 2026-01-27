# Session 12: hud-hook System Audit

**Date:** 2026-01-27
**Scope:** `hud-hook` CLI hook handler (handle, cwd, lock-holder, logging, entrypoint) + direct hud-core dependencies used by the hook.
**Files analyzed:**
- `core/hud-hook/src/main.rs`
- `core/hud-hook/src/handle.rs`
- `core/hud-hook/src/cwd.rs`
- `core/hud-hook/src/lock_holder.rs`
- `core/hud-hook/src/logging.rs`
- `core/hud-core/src/state/types.rs` (HookInput/HookEvent + cwd resolution)
- `core/hud-core/src/state/lock.rs` (session locks, count/release)
- `core/hud-core/src/state/store.rs` (session state persistence)
- `core/hud-core/src/activity.rs` (activity store format conversion)

**Related audits (already cover sub-parts):**
- `02-lock-holder.md` (lock-holder lifecycle)
- `05-tombstone-system.md` (tombstones in handle.rs)
- `06-shell-cwd-tracking.md` (cwd.rs)
- `09-activity-files.md` (activity format + duplication)
- `10-hook-configuration.md` (settings.json hooks)

---

## Subsystem Decomposition

| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Hook event ingestion + state updates | `handle.rs`, `state/store.rs`, `state/types.rs`, `state/lock.rs` | FS: `sessions.json`, `file-activity.json`, tombstones, lock dirs, heartbeat; spawn lock-holder | High |
| 2 | Lock holder daemon | `lock_holder.rs`, `state/lock.rs` | FS: lock dirs; process liveness checks | High |
| 3 | Shell CWD tracking | `cwd.rs` | FS: `shell-cwd.json`, `shell-history.jsonl` | Medium |
| 4 | Logging pipeline | `logging.rs` | FS: `hud-hook-debug.{date}.log` | Low |
| 5 | CLI entrypoint | `main.rs` | Process spawn + subcommand routing | Low |

---

## Sequential Analysis

### 1) Hook Event Ingestion + State Updates (handle.rs)
**Correctness:** Matches canonical hook→state mapping in `state/types.rs`. `SessionEnd` deletes record, tombstones, activity cleanup, then releases lock. `SessionStart`/`UserPromptSubmit` ensure locks via `spawn_lock_holder()`.

**Atomicity:**
- `sessions.json` uses `StateStore::save()` with temp-file + rename (atomic).
- `file-activity.json` now uses `write_file_atomic()` (temp-file + rename) for both record and removal.

**Concurrency:**
- Still last-writer-wins for `sessions.json` (acceptable per Session 3). No lock-level synchronization.
- Activity file writes are now atomic but still read-modify-write with no cross-process lock (format drift risk remains, not corruption).

**Cleanup:** Tombstones and lock release order preserves UI consistency (record removed before lock release). Activity removed on SessionEnd when no other locks exist for the same session.

**Notes:** Activity implementation remains duplicated vs `ActivityStore` (conversion on read). See Finding 1.

---

### 2) Lock Holder Daemon (lock_holder.rs)
**Correctness:** The previous 24h timeout bug is fixed in current code (lock is not released on timeout). The holder exits without releasing on timeout, and relies on PID liveness to release.

**Race conditions:** Same as prior audit: tiny window between lock creation and holder start; acceptable due to cleanup fallback.

**Cleanup:** Holder exits if lock dir disappears; startup cleanup handles stale lock dirs.

---

### 3) Shell CWD Tracking (cwd.rs)
Already analyzed in Session 6. No new issues found beyond the documented, acceptable TOCTOU race on concurrent shell writes.

---

### 4) Logging (logging.rs)
**Correctness:** File logging with daily rotation + 7-day retention. Falls back to stderr on failure.

**Potential issue:** Non-blocking guard is intentionally leaked; for a short-lived process, this can drop final buffered log entries and contradicts the comment about “flush before exit.” See Finding 3.

---

### 5) CLI Entrypoint (main.rs)
Simple subcommand dispatch with error handling. No issues found.

---

## Findings

### [HANDLE/ACTIVITY] Finding 1: Activity Format Duplication Still Exists

**Severity:** Medium
**Type:** Design flaw
**Location:** `core/hud-hook/src/handle.rs:414-521`, `core/hud-core/src/activity.rs:98-200`

**Problem:**
`hud-hook` still writes the legacy “files” format, while `hud-core` expects the “activity” format and converts on load. This leaves two parallel implementations and incurs conversion overhead on every read.

**Evidence:**
- `handle.rs` writes sessions `{ "files": [...] }` (no `project_path`).
- `ActivityStore::load()` detects and converts the hook format by running boundary detection for every entry.

**Recommendation:**
Unify on a single format. Prefer using `ActivityStore` from `hud-core` directly in `hud-hook` (or duplicate only the minimal conversion logic but write the native format).

---

### [HANDLE/LOCKS] Finding 2: Error Reading Lock Dir Can Tombstone Active Sessions

**Severity:** Medium
**Type:** Bug (error handling)
**Location:** `core/hud-hook/src/handle.rs:166-196`, `core/hud-core/src/state/lock.rs:693-697`

**Problem:**
`count_other_session_locks()` returns `0` on any `read_dir` error. `handle.rs` interprets `0` as “no other locks,” which triggers tombstone creation and session record deletion. If the lock directory is temporarily unreadable (permissions, transient FS error), active sessions sharing the same `session_id` can be tombstoned and stop updating.

**Evidence:**
```rust
// lock.rs:693-697
let entries = match fs::read_dir(lock_base) {
    Ok(e) => e,
    Err(_) => return 0,
};
```
```rust
// handle.rs:171-186
let other_locks = count_other_session_locks(&lock_base, &session_id, ppid);
let preserve_record = other_locks > 0;
if !preserve_record { create_tombstone(...); store.remove(...); }
```

**Recommendation:**
Treat read errors as “unknown” and preserve the record (fail-safe). For example:
- Return `Result<usize>` from `count_other_session_locks()` and treat `Err` as “preserve.”
- Or, return `usize::MAX` on error and treat `>0` as preserve.

---

### [LOGGING] Finding 3: Leaked Non-blocking Guard Can Drop Final Logs

**Severity:** Low
**Type:** Stale docs / Observability risk
**Location:** `core/hud-hook/src/logging.rs:25-30`

**Problem:**
`tracing_appender::non_blocking()` returns a guard whose Drop flushes the queue. The code intentionally leaks the guard while claiming it “flush[es] before exit.” In a short-lived process, this can lose the final buffered log entries.

**Evidence:**
```rust
let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);
std::mem::forget(_guard);
// comment: “short-lived process and we want logs to flush before exit”
```

**Recommendation:**
Keep the guard alive in a static and let it drop on process exit, or explicitly drop it at the end of `main()` to force a flush. If you want to keep the current behavior, update the comment to reflect that logs may be dropped on exit.

---

## Summary

**Findings by severity:**
- Critical: 0
- High: 0
- Medium: 2
- Low: 1

**Top issues (priority order):**
1. Activity format duplication between `hud-hook` and `hud-core` (maintenance + conversion overhead)
2. Lock dir read errors can tombstone active sessions (error handling safety)
3. Logging guard leak may drop final logs (observability)

**Recommended fix order:**
1. Handle lock-dir read errors fail-safe (preserve record on uncertainty).
2. Unify activity format/writer to remove conversion and duplication.
3. Decide on logging flush strategy and align the comment with behavior.
