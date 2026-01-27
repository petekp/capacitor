# Session 1: Lock System Audit

**Files analyzed:**
- `core/hud-core/src/state/lock.rs` (1307 lines)

**Analysis date:** 2025-01-26

---

## Analysis Checklist Results

| Check | Status | Notes |
|-------|--------|-------|
| Correctness | ✅ Pass | Core logic works as intended |
| Atomicity | ✅ Pass | Uses `mkdir` for atomic acquisition |
| Race conditions | ⚠️ Minor | Directory scan during modification |
| Cleanup | ✅ Pass | All paths release resources |
| Error handling | ✅ Pass | Failures leave valid state |
| Documentation accuracy | ❌ Issues | Stale docs from inheritance era |
| Dead code | ⚠️ Minor | Vestigial naming, unused params |

---

## Findings

### [LOCK] Finding 1: Stale Module Documentation

**Severity:** Medium
**Type:** Stale docs
**Location:** `lock.rs:42-46`

**Problem:**
Module docstring claims child→parent inheritance behavior that was removed:

```rust
//! # Path Matching
//!
//! A lock at `/project/src` makes `/project` appear active (child → parent inheritance).
//! But a lock at `/project` does NOT make `/project/src` appear active.
```

But code implements **exact-match-only** policy (see lines 377, 414-421, 454-457):

```rust
// line 377 - is_session_running()
check_lock_for_path(lock_base, project_path).is_some()  // Exact match only

// line 417 - find_all_locks_for_path()
let is_exact = info_path_normalized == normalized;
if is_exact && is_pid_alive_verified(...) { ... }
```

**Evidence:**
The comments at lines 415-416 confirm the new policy:
```rust
// Only exact matches - no child inheritance.
// Each project card shows only sessions started at that exact path.
```

**Recommendation:**
Update module docstring (lines 42-46) to reflect exact-match-only policy.

---

### [LOCK] Finding 2: Misleading Function Name

**Severity:** Low
**Type:** Stale naming
**Location:** `lock.rs:435`

**Problem:**
Function `find_matching_child_lock` no longer finds child locks—it only performs exact matching. The name is a vestige from the inheritance model.

```rust
pub fn find_matching_child_lock(
    lock_base: &Path,
    project_path: &str,
    target_pid: Option<u32>,
    target_cwd: Option<&str>,
) -> Option<LockInfo>
```

**Evidence:**
Line 454-457 confirms exact-match-only:
```rust
// Only exact matches - no child inheritance.
// Each project shows only sessions started at that exact path.
if info_path_normalized != project_path_normalized {
    continue;
}
```

**Recommendation:**
Rename to `find_matching_lock` or `find_lock_for_path`. Update all callers.

---

### [LOCK] Finding 3: Unused Parameters in find_matching_child_lock

**Severity:** Low
**Type:** Dead code
**Location:** `lock.rs:438-440`

**Problem:**
Parameters `target_pid` and `target_cwd` are accepted but their matching logic (lines 460-461) is effectively redundant when `target_cwd.map_or(true, |cwd| cwd == info.path)` is checked *after* exact path matching already succeeded.

```rust
let pid_matches = target_pid.map_or(true, |pid| pid == info.pid);
let path_matches = target_cwd.map_or(true, |cwd| cwd == info.path);
```

**Evidence:**
If we reach line 460, we know `info_path_normalized == project_path_normalized` (from line 455). So `target_cwd` comparison is redundant unless there's normalization difference (unlikely).

**Recommendation:**
- Review all call sites to determine if `target_pid`/`target_cwd` filtering is needed
- If not, remove parameters and simplify function
- If yes, document why path is checked twice

---

### [LOCK] Finding 4: Legacy Lock Support Complexity

**Severity:** Low
**Type:** Design debt
**Location:** `lock.rs:134-184`, `lock.rs:256-319`

**Problem:**
Code maintains two parallel lock verification paths:
1. **Modern locks** (have `proc_started`): Verify via timestamp comparison
2. **Legacy locks** (no `proc_started`): Verify via process name + 24h expiry

This adds ~100 lines of complexity for backward compatibility.

**Evidence:**
```rust
// line 196-198
let Some(expected_start_time) = expected_start else {
    return is_pid_alive_with_legacy_checks(pid);  // Legacy path
};

// line 256-319
// Complex age-based expiry logic for legacy locks
```

**Recommendation:**
Consider deprecation timeline for legacy locks:
1. Add telemetry to track legacy lock encounters
2. After N months with zero hits, remove legacy support
3. Document migration path in release notes

---

### [LOCK] Finding 5: Thread-Local Cache Never Cleared

**Severity:** Low
**Type:** Design note (not a bug)
**Location:** `lock.rs:57-59`

**Problem:**
`SYSTEM_CACHE` thread-local is never explicitly cleared:

```rust
thread_local! {
    static SYSTEM_CACHE: RefCell<Option<sysinfo::System>> = const { RefCell::new(None) };
}
```

**Analysis:**
This is intentional—the cache stores a `sysinfo::System` that is refreshed per-PID on each query (`refresh_process_specifics` at line 113). The cache persists process metadata between queries, but each query fetches fresh data for the specific PID.

**Recommendation:**
No action needed. Add comment explaining the design:
```rust
// Cache persists for thread lifetime. Each PID query calls refresh_process_specifics()
// which fetches fresh data for that PID (O(1) instead of full process scan O(n)).
```

---

### [LOCK] Finding 6: Potential Race in Lock Takeover

**Severity:** Low
**Type:** Race condition (theoretical)
**Location:** `lock.rs:647-657`

**Problem:**
Legacy `create_lock()` does in-place takeover when lock held by live process:

```rust
// We update in place rather than remove+create to avoid race conditions.
if write_lock_metadata(&lock_dir, pid, project_path, None, Some(info.pid))
    .is_ok()
{
    tracing::info!(..., "Lock takeover");
    return Some(lock_dir);
}
```

The in-place update avoids rm+mkdir race, but there's a window where the old lock holder reads the new PID and exits while the new holder isn't yet running.

**Analysis:**
This is handled correctly: the old lock holder checks `read_lock_pid()` in its loop (lock_holder.rs:55-65) and exits gracefully if PID changed. The new session's lock holder is spawned immediately after `create_lock()` returns.

**Recommendation:**
No action needed. The handoff is correctly sequenced.

---

### [LOCK] Finding 7: compute_lock_hash Uses MD5

**Severity:** Low
**Type:** Design note
**Location:** `lock.rs:76-79`

**Problem:**
Legacy path-based locks use MD5 for hashing:

```rust
fn compute_lock_hash(path: &str) -> String {
    let normalized = normalize_path_for_hashing(path);
    format!("{:x}", md5::compute(normalized))
}
```

**Analysis:**
MD5 is fine here—it's used for directory naming, not security. Collision probability is negligible for the ~hundreds of projects a user might have. Session-based locks (v4) don't use this function.

**Recommendation:**
No action needed for correctness. If refactoring, consider using `xxhash` for speed, but low priority.

---

## Summary

| Severity | Count | Issues |
|----------|-------|--------|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 1 | Stale module docs |
| Low | 6 | Naming, dead code, design debt |

**Overall assessment:** Lock system is sound. Main action item is documentation cleanup to prevent future confusion about exact-match-only policy.

---

## Recommended Actions

### Immediate (before next release)
1. Update module docstring (Finding 1)

### Near-term (next sprint)
2. Rename `find_matching_child_lock` → `find_matching_lock` (Finding 2)
3. Review/remove unused parameters (Finding 3)

### Long-term (backlog)
4. Plan legacy lock deprecation (Finding 4)
