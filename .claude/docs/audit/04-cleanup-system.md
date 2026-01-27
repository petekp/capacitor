# Session 4: Cleanup System Audit

**Date:** 2026-01-26
**Files:** `core/hud-core/src/state/cleanup.rs`
**Focus:** Stale lock removal, startup cleanup, race conditions

---

## Overview

The cleanup system runs once per app launch to remove stale artifacts:

1. Kill orphaned lock-holder processes (monitored PID is dead)
2. Remove legacy MD5-hash locks with dead PIDs
3. Remove session-based locks with dead PIDs
4. Remove orphaned session records (no active lock, stale >5min)
5. Remove old session records (>24 hours)
6. Remove old tombstones (>1 minute)

**Caller:** `HudEngine::run_startup_cleanup()` in `engine.rs:745`

---

## Findings

### Finding 1: Race Condition in Session File Updates

**Severity:** High
**Type:** Race condition
**Location:** `cleanup.rs:309-358` and `cleanup.rs:446-483`

**Problem:**
`cleanup_orphaned_sessions()` and `cleanup_old_sessions()` both follow the pattern:
1. Load `sessions.json` from disk
2. Modify in memory (remove entries)
3. Save back to disk

Meanwhile, `hud-hook` writes to the same file on every Claude event. If a hook event occurs between load and save, those changes are lost.

**Evidence:**
```rust
// cleanup.rs:312-320
let mut store = match StateStore::load(state_file) {
    Ok(s) => s,
    Err(e) => { ... }
};
// ... modify store ...
// cleanup.rs:351
if let Err(e) = store.save() { ... }
```

No file locking or compare-and-swap mechanism exists.

**Risk:**
- Cleanup runs at app launch (low frequency)
- Hook events are high frequency during active sessions
- Window is small (milliseconds) but non-zero
- Lost events could cause wrong state display until next event

**Recommendation:**
Consider one of:
1. File locking with `flock()` during cleanup
2. Read-modify-write with optimistic locking (check mtime before save)
3. Accept the race as low-probability and document it

---

### Finding 2: Module Docstring Outdated

**Severity:** Medium
**Type:** Stale docs
**Location:** `cleanup.rs:1-9`

**Problem:**
Module docstring lists 3 cleanup operations:
```
//! 1. **Lock cleanup**: Removes locks with dead PIDs
//! 2. **Orphaned session cleanup**: Removes session records without active locks
//! 3. **Session cleanup**: Removes records older than 24 hours
```

But `run_startup_cleanup()` actually performs 6 operations:
1. Kill orphaned lock-holder processes
2. Remove legacy MD5-hash locks
3. Remove session-based locks
4. Remove orphaned session records
5. Remove old session records
6. Remove old tombstones

**Recommendation:**
Update docstring to reflect actual cleanup operations, including:
- Process killing (step 0)
- Legacy vs modern lock distinction
- Tombstone cleanup

---

### Finding 3: Confusing "Stale" Terminology

**Severity:** Low
**Type:** Documentation ambiguity
**Location:** Multiple constants and comments

**Problem:**
The word "stale" means different things in different contexts:

| Context | Meaning | Threshold |
|---------|---------|-----------|
| `STALE_THRESHOLD_SECS` | Session record not updated | 300s (5 min) |
| `SESSION_MAX_AGE_HOURS` | Session record too old | 24 hours |
| `TOMBSTONE_MAX_AGE_SECS` | Tombstone file age | 60s |
| Stale lock | PID is dead | N/A |

Comment at line 307-308 says "stale (> 5 minutes old)" but this refers to the `is_stale()` method's threshold, not the 24-hour age limit.

**Recommendation:**
- Use "stale" only for the 5-minute update threshold
- Use "expired" or "aged out" for the 24-hour cleanup
- Use "orphaned" for lock-holder processes with dead monitored PIDs

---

### Finding 4: Test Uses Legacy Lock Format

**Severity:** Low
**Type:** Test quality
**Location:** `cleanup.rs:491-501`

**Problem:**
The test helper `create_lock_with_pid` creates MD5-hash format locks (legacy), not session-based locks (v4):

```rust
fn create_lock_with_pid(lock_base: &Path, path: &str, pid: u32) {
    let hash = format!("{:x}", md5::compute(path));  // Legacy format
    let lock_dir = lock_base.join(format!("{}.lock", hash));
    // ...
}
```

This means tests for `cleanup_stale_locks` are actually testing behavior on legacy locks, not the modern `{session_id}-{pid}.lock` format.

**Impact:**
Tests pass because `cleanup_stale_locks` handles both formats (scans all `*.lock` directories), but test coverage for the v4 format is indirect.

**Recommendation:**
Add a `create_session_lock_for_test` helper that creates v4-format locks:
```rust
fn create_session_lock(lock_base: &Path, session_id: &str, pid: u32, path: &str) {
    let lock_dir = lock_base.join(format!("{}-{}.lock", session_id, pid));
    // ...
}
```

---

### Finding 5: Process Kill Race Window

**Severity:** Low
**Type:** Race condition (theoretical)
**Location:** `cleanup.rs:71-100`

**Problem:**
Between checking `is_pid_alive(monitored)` and `libc::kill(holder_pid, ...)`, the monitored PID could theoretically be reused by a new process.

```rust
// Line 71: Check if monitored is alive
if is_pid_alive(monitored) {
    continue;
}
// Lines 78-100: Kill the holder
// Race window: new process could reuse monitored PID here
libc::kill(holder_pid, libc::SIGTERM)
```

**Impact:**
Extremely unlikely in practice:
- Requires PID reuse in millisecond window
- Requires the new process to also be a lock-holder monitoring the same PID
- Result would be killing a legitimate lock-holder (they'd recreate anyway)

**Recommendation:**
Document the theoretical race but don't fix—complexity outweighs benefit.

---

### Finding 6: Good Practice - Independent Cleanup Operations

**Severity:** N/A
**Type:** Positive finding
**Location:** `cleanup.rs:142-184`

Each cleanup operation is independent:
- Returns its own `CleanupStats`
- Errors don't stop other operations
- Stats are merged at the end

This is robust error handling that prevents one failure from blocking all cleanup.

---

### Finding 7: Atomic Writes Used Correctly

**Severity:** N/A
**Type:** Positive finding
**Location:** `store.rs:152-182`

`StateStore::save()` uses temp file + rename pattern via `tempfile::NamedTempFile`, ensuring atomic writes. This prevents partial write corruption.

---

## Architecture Notes

### Cleanup Execution Order

```
run_startup_cleanup()
    │
    ├─► cleanup_orphaned_lock_holders()  ──► Kill first (prevents lock recreation)
    │
    ├─► cleanup_legacy_locks()           ──► MD5-hash format (v3 compatibility)
    │
    ├─► cleanup_stale_locks()            ──► Session-based format (v4)
    │
    ├─► cleanup_orphaned_sessions()      ──► Records without locks
    │
    ├─► cleanup_old_sessions()           ──► Records >24 hours old
    │
    └─► cleanup_old_tombstones()         ──► Tombstones >1 minute old
```

The order is deliberate:
1. Kill processes FIRST so they can't recreate locks we're about to clean
2. Clean locks before session records (session cleanup depends on lock presence)
3. Tombstones are independent

### Dependencies

```
cleanup.rs
    ├── lock.rs (is_pid_alive, read_lock_info)
    ├── store.rs (StateStore)
    ├── types.rs (SessionRecord.is_stale())
    └── sysinfo (process enumeration)
```

---

## Checklist Summary

| Check | Status | Notes |
|-------|--------|-------|
| Correctness | ⚠️ Partial | Docstring outdated |
| Atomicity | ⚠️ Partial | Race with hook writes |
| Race conditions | ⚠️ Medium risk | Session file race is real |
| Cleanup | ✅ Good | No resource leaks |
| Error handling | ✅ Good | Independent operations |
| Documentation accuracy | ⚠️ Partial | Multiple issues |
| Dead code | ✅ None | All paths reachable |

---

## Recommendations Priority

1. **High**: Consider mitigating session file race (Finding 1)
2. **Medium**: Update module docstring (Finding 2)
3. **Low**: Standardize "stale" terminology (Finding 3)
4. **Low**: Add v4-format test helpers (Finding 4)
