# Session State Store Audit

**Subsystem:** Session State Store
**Files:** `core/hud-core/src/state/store.rs`, `core/hud-core/src/state/types.rs`
**Date:** 2026-01-26
**Focus:** State transitions, atomic saves, keying

---

## Architecture Overview

```
Claude Code hooks → hud-hook binary → sessions.json (via StateStore) + locks
                                              ↓
Swift UI ← engine.rs ← sessions.rs ← resolver.rs ← StateStore (read-only)
```

### Key Components

| File | Role |
|------|------|
| `state/store.rs` | `StateStore` struct - JSON persistence layer |
| `state/types.rs` | `SessionRecord`, `HookInput`, `HookEvent`, `LockInfo` |
| `state/resolver.rs` | Combines locks + store to determine session state |
| `hud-hook/handle.rs` | Hook binary that WRITES state on Claude Code events |
| `sessions.rs` | High-level API that calls resolver |

### Data Flow

1. Claude Code fires hook (stdin JSON)
2. `hud-hook` parses event, calls `StateStore::load()` → `update()` → `save()`
3. Swift polls via `detect_session_state()` → `resolve_state_with_details()`
4. Resolver combines lock existence + state record to determine final state

---

## Checklist Analysis

### ✅ Correctness
The implementation correctly:
- Uses atomic writes via `NamedTempFile` + `persist()` (rename)
- Validates schema version (only loads version 3)
- Handles empty/corrupt files defensively (returns empty store)

### ✅ Atomicity
Writes are atomic:
```rust
// store.rs:169-179
let mut temp_file = NamedTempFile::new_in(parent_dir)?;
temp_file.write_all(content.as_bytes())?;
temp_file.flush()?;
temp_file.persist(file_path)?;
```
No partial write risk on crash.

### ✅ Race Conditions
Acceptable for use case:
- Multiple `hud-hook` processes could race on save (last-writer-wins)
- Hook events from same Claude session are sequential
- Concurrent sessions use different session IDs, so their records don't conflict

### ✅ Cleanup
StateStore has no cleanup needs - file handles closed immediately after each operation.

### ✅ Error Handling
Defensive everywhere:
- `load()` returns empty store on JSON errors
- `save()` returns `Result` with descriptive errors
- Missing file → empty store (not error)

---

## Findings

### Finding 1: Stale Module Docstring (store.rs)

**Severity:** Medium
**Type:** Stale docs
**Location:** `store.rs:1-4`

**Problem:**
Module docstring says "this module only reads":
```rust
//! Reads session records from `~/.capacitor/sessions.json` (written by the hook script).
//! The hook script is the authoritative writer; this module only reads.
```

But `StateStore` has both read AND write methods (`update()`, `save()`). The hud-hook binary uses `StateStore` to write.

**Evidence:**
- `hud-hook/handle.rs:118` calls `StateStore::load()` then `store.update()` and `store.save()`
- `cleanup.rs:312-449` also writes via StateStore

**Recommendation:**
Update docstring to reflect actual architecture:
```rust
//! File-backed session state persistence.
//!
//! **Writers:** hud-hook binary, cleanup routines
//! **Readers:** Swift UI via resolver module
```

---

### Finding 2: Stale Path Matching Documentation (store.rs)

**Severity:** Medium
**Type:** Stale docs
**Location:** `store.rs:18-27`

**Problem:**
Docstring describes child/parent path matching:
```rust
//! # Path Matching
//!
//! When looking up sessions by path, we check three relationship types:
//! 1. **Exact match**: Query path equals session's `cwd` or `project_dir`
//! 2. **Child match**: Session is in a subdirectory of the query path
//! 3. **Parent match**: Session is in a parent directory of the query path
```

But `resolver.rs:find_fresh_record_for_path()` (the actual production code path) uses **exact match only**:
```rust
// resolver.rs:204-206
/// Find a fresh (non-stale) record that exactly matches the given path.
/// Only considers exact matches - no child inheritance.
/// Each project shows only sessions started at that exact path.
```

**Evidence:**
- `sessions.rs:44` calls `resolve_state_with_details()` which uses `find_fresh_record_for_path()` (exact only)
- `find_by_cwd()` (with child/parent matching) is never called in production code
- Comment in `agents/claude.rs:125-126` says "Use the resolved session_id to look up metadata, NOT find_by_cwd"

**Recommendation:**
Either:
1. Update `store.rs` docstring to match actual exact-match-only behavior, OR
2. Remove `find_by_cwd()` entirely if it's truly unused

---

### Finding 3: Potentially Dead Code (find_by_cwd)

**Severity:** Low
**Type:** Dead code
**Location:** `store.rs:238-327`

**Problem:**
`find_by_cwd()` implements child/parent path matching (100+ lines of code) but is never called in production:

**Evidence:**
```
$ grep -r "find_by_cwd" core/ | grep -v test | grep -v "\.rs:#"
core/hud-core/src/agents/claude.rs:125:// Use the resolved session_id to look up metadata, NOT find_by_cwd.
```

Only usages are:
- Tests in `store.rs`
- Comment warning NOT to use it in `agents/claude.rs`

**Recommendation:**
Mark as `#[deprecated]` or remove entirely. The 100+ lines of child/parent matching logic adds maintenance burden for unused functionality.

---

### Finding 4: Stale Lock Path Documentation (mod.rs)

**Severity:** Low
**Type:** Stale docs
**Location:** `state/mod.rs:20-21`

**Problem:**
Documentation says:
```rust
//! 1. **Lock files** (primary): Directories in `~/.capacitor/sessions/{hash}.lock/`
```

But per CLAUDE.md, v4 uses session-based locks:
> Locks are keyed by `{session_id}-{pid}`, NOT path hash.

**Recommendation:**
Update to:
```rust
//! 1. **Lock files** (primary): Directories in `~/.capacitor/sessions/{session_id}-{pid}.lock/`
```

---

### Finding 5: Duplicate normalize_path Functions

**Severity:** Low
**Type:** Code smell
**Location:** Multiple files

**Problem:**
`normalize_path` function exists in multiple places:
- `state/store.rs:57-59` (wrapper)
- `state/types.rs:134-141` (simple implementation)
- `state/resolver.rs:17-19` (wrapper)
- `state/path_utils.rs` (canonical implementation)

**Evidence:**
```rust
// store.rs - wrapper
fn normalize_path(path: &str) -> String {
    normalize_path_for_comparison(path)
}

// types.rs - different implementation (no symlink resolution)
fn normalize_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() { "/" } else { trimmed.to_string() }
}
```

The `types.rs` version doesn't use the canonical `path_utils.rs` implementation, so it lacks case normalization (macOS) and symlink resolution.

**Recommendation:**
Remove local `normalize_path` functions and use `normalize_path_for_comparison` from `path_utils.rs` consistently. The `types.rs` version in `HookInput::resolve_cwd()` should either:
1. Use `normalize_path_simple()` from path_utils (no FS access), or
2. Use full `normalize_path_for_comparison()` for consistency

---

## Summary

| Finding | Severity | Type | Action |
|---------|----------|------|--------|
| Stale "read-only" docstring | Medium | Stale docs | Update |
| Stale path matching docs | Medium | Stale docs | Update |
| Dead `find_by_cwd()` code | Low | Dead code | Deprecate/Remove |
| Stale lock path docs | Low | Stale docs | Update |
| Duplicate normalize_path | Low | Code smell | Consolidate |

**Overall Assessment:** The core persistence logic is solid (atomic writes, defensive parsing). The main issues are documentation drift and potentially dead code from the evolution to exact-match-only and session-based locks.
