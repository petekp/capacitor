# Session 9: Activity Files Audit

**Date:** 2026-01-27
**Files:** `core/hud-hook/src/handle.rs` (functions: `extract_file_activity`, `record_file_activity`, `remove_session_activity`), `core/hud-core/src/activity.rs`
**Focus:** File tracking accuracy, atomicity, race conditions, architectural duplication

---

## Overview

The activity tracking system records which files Claude edits during sessions. This enables **monorepo package tracking** — when Claude is running in `/monorepo` but editing files in `/monorepo/packages/auth`, the auth package can show as "Working" even though the lock is at the parent.

**Data Flow:**

```
PostToolUse (Edit/Write/Read/NotebookEdit)
    │
    ▼
hud-hook: record_file_activity()     ──► ~/.capacitor/file-activity.json
    │                                     (writes "files" format)
    ▼
hud-core: ActivityStore::load()      ──► Reads file, converts to "activity" format
    │                                     (boundary detection at load-time)
    ▼
sessions.rs: detect_session_state()  ──► Falls back to activity when no lock found
```

**Key Consumer:** `sessions.rs:86-118` uses `has_recent_activity_in_path()` as fallback for state detection.

---

## Findings

### Finding 1: Non-Atomic Writes Create Race Condition

**Severity:** High
**Type:** Race condition + data corruption risk
**Location:** `handle.rs:476-486`

**Problem:**
`record_file_activity()` uses direct `fs::write()`:

```rust
// handle.rs:478
if let Err(e) = fs::write(activity_file, content) {
    tracing::warn!(error = %e, "Failed to write activity file");
}
```

Compare to `ActivityStore::save()` which uses atomic temp-file + rename:

```rust
// activity.rs:214-236
let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
tmp.write_all(content.as_bytes())?;
tmp.flush()?;
tmp.persist(path)?;
```

**Risk:**
1. **Crash corruption:** Power loss/crash during write leaves partial JSON
2. **Race condition:** Multiple hooks can fire simultaneously (e.g., Read followed by Edit), causing read-modify-write races
3. **Lost data:** Concurrent writers overwrite each other's changes

**Evidence:**
```rust
// handle.rs:430-433 — non-atomic read-modify-write
let mut activity: Value = fs::read_to_string(activity_file)
    .ok()
    .and_then(|s| serde_json::from_str(&s).ok())
    .unwrap_or_else(|| json!({"version": 1, "sessions": {}}));
// ... modify ...
fs::write(activity_file, content)  // Window for race here
```

**Recommendation:**
Use atomic writes in `record_file_activity()`:
```rust
use tempfile::NamedTempFile;
let mut tmp = NamedTempFile::new_in(dir)?;
tmp.write_all(content.as_bytes())?;
tmp.flush()?;
tmp.persist(activity_file)?;
```

Or better: migrate to use `ActivityStore` methods from hud-core.

---

### Finding 2: Architectural Duplication — Two Separate Implementations

**Severity:** High
**Type:** Design flaw
**Location:** `handle.rs:413-520` vs `activity.rs:244-385`

**Problem:**
Two completely separate implementations exist:

| Feature | hud-hook (handle.rs) | hud-core (activity.rs) |
|---------|---------------------|------------------------|
| Record activity | `record_file_activity()` | `ActivityStore::record_activity()` |
| Remove session | `remove_session_activity()` | `ActivityStore::remove_session()` |
| Cleanup old | ❌ Not implemented | `ActivityStore::cleanup_old_entries()` |
| Atomic writes | ❌ No | ✅ Yes |
| Format | "files" array | "activity" array with project_path |

**Evidence:**
`ActivityStore::record_activity()` is only called from tests:
```
core/hud-core/src/activity.rs:463:        store.record_activity(  // test
core/hud-core/src/activity.rs:497:        store.record_activity(  // test
... (all other calls are in #[cfg(test)] blocks)
```

Production hook uses the separate implementation in `handle.rs`.

**Impact:**
1. Bug fixes must be made in both places
2. Features like cleanup never run (hud-hook doesn't call `cleanup_old_entries()`)
3. Different atomicity guarantees
4. Conversion overhead on every read

**Recommendation:**
Option A: Have hud-hook depend on hud-core and use `ActivityStore` methods directly
Option B: Keep hud-hook minimal, but ensure it uses atomic writes

---

### Finding 3: Format Mismatch Requires Load-Time Conversion

**Severity:** Medium
**Type:** Inefficiency + potential confusion
**Location:** `activity.rs:98-200`

**Problem:**
Hook writes in "files" format (no project_path):
```json
{
  "version": 1,
  "sessions": {
    "session-123": {
      "cwd": "/monorepo",
      "files": [
        {"file_path": "/monorepo/packages/auth/login.ts", "tool": "Edit", "timestamp": "..."}
      ]
    }
  }
}
```

ActivityStore expects "activity" format (with project_path):
```json
{
  "version": 1,
  "sessions": {
    "session-123": {
      "cwd": "/monorepo",
      "activity": [
        {"project_path": "/monorepo/packages/auth", "file_path": "...", "tool": "Edit", "timestamp": "..."}
      ]
    }
  }
}
```

**Evidence:**
`ActivityStore::load()` at line 143-200 detects format and converts:
```rust
// activity.rs:174-188
for file in hook_session.files {
    // Determine project path using boundary detection
    let project_path = find_project_boundary(&file.file_path)
        .map(|b| b.path)
        .unwrap_or_else(|| hook_session.cwd.clone());
    // ...
}
```

**Impact:**
Boundary detection (filesystem checks for .git, package.json, CLAUDE.md) runs on every file entry, on every load. For sessions with 100 files (the truncation limit), this means 100 filesystem probes per state check.

**Recommendation:**
Either:
1. Have hook write "activity" format directly (do boundary detection at write-time)
2. Cache converted format to disk after first conversion
3. Accept the overhead (it's bounded at 100 entries per session)

---

### Finding 4: No Cleanup of Old Activity Entries

**Severity:** Medium
**Type:** Resource leak
**Location:** `handle.rs` (missing call)

**Problem:**
`ActivityStore::cleanup_old_entries()` exists (activity.rs:361-370) but is never called:

```rust
// activity.rs:361-370
pub fn cleanup_old_entries(&mut self, threshold: Duration) {
    for session in self.sessions.values_mut() {
        session.activity.retain(|a| is_within_threshold(&a.timestamp, threshold));
    }
    self.sessions.retain(|_, s| !s.activity.is_empty());
}
```

The hook truncates to 100 entries per session (handle.rs:470) but never cleans up old entries across sessions. Over time, `file-activity.json` accumulates entries from ended sessions.

**Evidence:**
- `remove_session_activity()` is called on SessionEnd (handle.rs:194)
- But if SessionEnd hook fails or doesn't fire, entries persist indefinitely
- No startup cleanup like we have for locks/sessions

**Recommendation:**
Add activity cleanup to `run_startup_cleanup()` in cleanup.rs:
```rust
let activity_file = storage.file_activity_file();
let mut activity_store = ActivityStore::load(&activity_file);
activity_store.cleanup_old_entries(CLEANUP_THRESHOLD);
activity_store.save(&activity_file)?;
```

---

### Finding 5: Tool Name Extraction is Restrictive

**Severity:** Low
**Type:** Missed functionality
**Location:** `handle.rs:255-265`

**Problem:**
`extract_file_activity()` only tracks 4 tools:
```rust
match tool_name.as_deref() {
    Some("Edit" | "Write" | "Read" | "NotebookEdit") => {
        file_path.clone().zip(tool_name.clone())
    }
    _ => None,
}
```

Other file-touching tools are ignored:
- `Glob` (file discovery)
- `Grep` (content search)
- `LS` (directory listing)
- Custom tools via MCP

**Impact:**
File activity only tracks modifications, not reads/discoveries. This is arguably correct (we care about "working on" not "browsing"), but worth documenting.

**Recommendation:**
Document this as intentional in the function's docstring:
```rust
/// Extracts file activity info from file-modifying tools.
///
/// Only tracks Edit, Write, Read, and NotebookEdit — tools that indicate
/// active work on specific files. Discovery tools (Glob, Grep) are excluded.
```

---

### Finding 6: Good Practice — Activity Used as Secondary Signal

**Severity:** N/A
**Type:** Positive finding
**Location:** `activity.rs:13`, `sessions.rs:86-118`

The design explicitly treats activity as a **fallback** signal:
```rust
// activity.rs:13
//! - **Secondary signal**: Activity is a secondary signal; lock/state data takes precedence when present.
```

And in `sessions.rs:86-88`:
```rust
// No session found via lock or fresh record - check for file activity
// This enables monorepo package tracking where cwd != project_path
```

This is good defensive design — activity enhances detection but doesn't override more authoritative signals.

---

### Finding 7: Good Practice — Graceful Degradation

**Severity:** N/A
**Type:** Positive finding
**Location:** `handle.rs:430-444`, `activity.rs:105-109`

Both implementations gracefully handle missing/corrupt files:

```rust
// handle.rs:430-433 — defaults to empty store
let mut activity: Value = fs::read_to_string(activity_file)
    .ok()
    .and_then(|s| serde_json::from_str(&s).ok())
    .unwrap_or_else(|| json!({"version": 1, "sessions": {}}));

// activity.rs:106-109 — same pattern
let content = match std::fs::read_to_string(path) {
    Ok(c) => c,
    Err(_) => return Self::new(),  // Empty store, not error
};
```

---

## Architecture Notes

### Data Flow Diagram

```
Claude Code (PostToolUse event)
    │
    │ stdin JSON: {"tool_name": "Edit", "tool_input": {"file_path": "/path/to/file"}}
    │
    ▼
hud-hook process
    │
    ├─► extract_file_activity()    Checks if tool is Edit/Write/Read/NotebookEdit
    │
    ├─► record_file_activity()     Writes to ~/.capacitor/file-activity.json
    │       │
    │       ├─ Read existing JSON
    │       ├─ Insert new entry (newest first)
    │       ├─ Truncate to 100 entries
    │       └─ Write back (NON-ATOMIC!)
    │
    └─► On SessionEnd: remove_session_activity()
```

### Consumer Path

```
HudEngine::get_session_state(project_path)
    │
    └─► sessions.rs::detect_session_state()
            │
            ├─► Check for lock at project_path    ◄── Primary signal
            ├─► Check for fresh state record      ◄── Secondary signal
            │
            └─► NO lock or record found?
                    │
                    └─► ActivityStore::load()
                            │
                            ├─ Detect format (hook vs native)
                            ├─ Convert hook format → native
                            │   └─ find_project_boundary() on each file
                            │
                            └─► has_recent_activity_in_path()
                                    │
                                    └─► Returns Working if file edits
                                        within 5 minutes match project_path
```

### File Format (Hook-Written)

```json
{
  "version": 1,
  "sessions": {
    "ab123-cd456-session-id": {
      "cwd": "/Users/pete/monorepo",
      "files": [
        {
          "file_path": "/Users/pete/monorepo/packages/auth/login.ts",
          "tool": "Edit",
          "timestamp": "2026-01-27T10:30:00Z"
        },
        {
          "file_path": "/Users/pete/monorepo/packages/auth/types.ts",
          "tool": "Write",
          "timestamp": "2026-01-27T10:29:55Z"
        }
      ]
    }
  }
}
```

---

## Checklist Summary

| Check | Status | Notes |
|-------|--------|-------|
| Correctness | ✅ Good | Logic is sound, tracks files correctly |
| Atomicity | ❌ Missing | Direct `fs::write()` risks corruption |
| Race conditions | ⚠️ High risk | Read-modify-write without locking |
| Cleanup | ⚠️ Partial | Per-session truncation but no global cleanup |
| Error handling | ✅ Good | Graceful degradation everywhere |
| Documentation accuracy | ✅ Good | Docstrings accurate |
| Dead code | ⚠️ Medium | `ActivityStore::record_activity()` unused in prod |

---

## Recommendations Priority

1. **High**: Fix atomic writes in `record_file_activity()` (Finding 1)
2. **High**: Decide on architecture — consolidate or document separation (Finding 2)
3. **Medium**: Add activity cleanup to startup cleanup (Finding 4)
4. **Low**: Consider write-time boundary detection to avoid load-time overhead (Finding 3)
5. **Low**: Document tool filtering as intentional (Finding 5)
