# Session 5: Tombstone System Audit

**Files Analyzed:** `core/hud-hook/src/handle.rs` (tombstone functions), `core/hud-core/src/state/cleanup.rs` (tombstone cleanup)

**Purpose:** Prevent race conditions where late-arriving events (post-SessionEnd) could recreate deleted sessions.

---

## System Overview

```
SessionEnd arrives
    │
    ▼
create_tombstone()  ──► ~/.capacitor/ended-sessions/{session_id}
    │
    ▼
Remove session record from sessions.json
    │
    ▼
Release lock (LAST)

---

Late event arrives (UserPromptSubmit, PreToolUse, etc.)
    │
    ▼
has_tombstone() check  ──► Exists? → SKIP event
    │                            │
    No tombstone                 └──► Session stays deleted
    │
    ▼
Process normally

---

Cleanup (every few seconds)
    │
    ▼
cleanup_old_tombstones()  ──► Removes tombstones >60 seconds old
```

### Key Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `has_tombstone` | `handle.rs:522-524` | Checks if tombstone exists |
| `create_tombstone` | `handle.rs:526-538` | Creates empty tombstone file |
| `remove_tombstone` | `handle.rs:540-549` | Removes tombstone (for SessionStart reuse) |
| `cleanup_old_tombstones` | `cleanup.rs:395-440` | Removes tombstones older than 60 seconds |

### Tombstone Lifecycle

1. **Created:** On SessionEnd (if no other locks for same session_id)
2. **Checked:** Before processing any event (except SessionStart/SessionEnd)
3. **Cleared:** On new SessionStart for same session_id, OR by cleanup after 60 seconds

---

## Findings

### Finding 1: Documentation Has Wrong Function Names

**Severity:** Medium
**Type:** Stale docs
**Location:** `.claude/docs/side-effects-map.md:101,108-109`

**Problem:**
Documentation references non-existent functions:
- `write_tombstone()` → actual name is `create_tombstone()`
- `clear_tombstone()` → actual name is `remove_tombstone()`

**Evidence:**
```markdown
// From side-effects-map.md (WRONG)
- **Writer:** `handle.rs` via `write_tombstone()` / `clear_tombstone()`

fn write_tombstone(tombstones_dir: &Path, session_id: &str) { ... }
fn clear_tombstone(tombstones_dir: &Path, session_id: &str) { ... }
```

```rust
// Actual code in handle.rs
fn create_tombstone(tombstones_dir: &Path, session_id: &str) { ... }
fn remove_tombstone(tombstones_dir: &Path, session_id: &str) { ... }
```

**Recommendation:**
Update side-effects-map.md to use correct function names.

---

### Finding 2: Documentation Has Wrong Tombstone Path Format

**Severity:** Medium
**Type:** Stale docs
**Location:** `.claude/docs/side-effects-map.md:100`

**Problem:**
Documentation claims tombstones are at `{session_id}.tombstone`, but actual files have no extension.

**Evidence:**
```markdown
// From side-effects-map.md (WRONG)
#### Tombstones (`~/.capacitor/sessions/{session_id}.tombstone`)
```

```rust
// Actual code in handle.rs:33
const TOMBSTONES_DIR: &str = ".capacitor/ended-sessions";

// handle.rs:523 - joins session_id directly, no extension
tombstones_dir.join(session_id).exists()
```

Actual path: `~/.capacitor/ended-sessions/{session_id}` (no `.tombstone` extension, different directory)

**Recommendation:**
Update docs to reflect actual path: `~/.capacitor/ended-sessions/{session_id}`

---

### Finding 3: Documentation Lists Wrong Trigger for Tombstone Clearing

**Severity:** Low
**Type:** Stale docs
**Location:** `.claude/docs/side-effects-map.md:102`

**Problem:**
Documentation says "Warmup" clears tombstones. Code shows:
- `SessionStart` clears tombstones for session reuse (handle.rs:102-104)
- `cleanup_old_tombstones()` removes old tombstones (cleanup.rs)

No "Warmup" event or trigger exists.

**Evidence:**
```markdown
// From side-effects-map.md (WRONG)
- **Trigger:** SessionEnd (write), Warmup (clear)
```

```rust
// Actual clearing in handle.rs:101-104
if event == HookEvent::SessionStart && has_tombstone(&tombstones_dir, &session_id) {
    remove_tombstone(&tombstones_dir, &session_id);
}
```

**Recommendation:**
Update docs: `- **Trigger:** SessionEnd (create), SessionStart (clear for reuse), cleanup_old_tombstones (clear after 60s)`

---

### Finding 4: TOCTOU Race in `remove_tombstone`

**Severity:** Low
**Type:** Race condition
**Location:** `handle.rs:540-549`

**Problem:**
Time-of-check-to-time-of-use (TOCTOU) race between existence check and removal:

```rust
fn remove_tombstone(tombstones_dir: &Path, session_id: &str) {
    let tombstone_path = tombstones_dir.join(session_id);
    if tombstone_path.exists() {           // CHECK
        if let Err(e) = fs::remove_file(&tombstone_path) {  // USE
            // Might fail if cleanup removed it between check and remove
```

**Impact:** Benign - if cleanup removes the file between check and remove, the remove fails with a warning log but the system continues correctly (tombstone is already gone).

**Recommendation:**
Could simplify to unconditional remove with NotFound handling, but current implementation is fine:
```rust
fn remove_tombstone(tombstones_dir: &Path, session_id: &str) {
    let tombstone_path = tombstones_dir.join(session_id);
    match fs::remove_file(&tombstone_path) {
        Ok(()) => tracing::debug!(...),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => { /* Already gone */ }
        Err(e) => tracing::warn!(...),
    }
}
```

---

### Finding 5: Theoretical Race on Session ID Reuse

**Severity:** Low
**Type:** Race condition (theoretical)
**Location:** `handle.rs:101-104`

**Problem:**
If a new SessionStart arrives for the same session_id while late events from the old session are still in flight:

1. SessionEnd → creates tombstone
2. Late UserPromptSubmit → blocked by tombstone ✓
3. New SessionStart (same ID) → clears tombstone
4. Another late UserPromptSubmit (from OLD session) → passes through (tombstone gone) ✗

**Impact:** Minimal in practice because:
- Claude Code generates unique UUIDs for session IDs
- Session ID reuse is rare (only happens if user explicitly creates sessions with same ID)
- The window between tombstone clear and next event is tiny

**Evidence:**
The test at `tombstone.bats:146-159` documents this behavior as intentional:
```bash
@test "new SessionStart for same session_id works after tombstone" {
    # ...SessionStart should work regardless - tombstone only blocks non-SessionStart events
```

**Recommendation:**
No code change needed. Add a comment explaining this is intentional and rare:
```rust
// If SessionStart arrives for a tombstoned session, clear the tombstone.
// This allows session_id reuse. Note: if late events from the OLD session
// arrive after this, they'll pass through. This is acceptable because:
// 1. Session IDs are UUIDs, so reuse is rare
// 2. The new session will handle the event correctly anyway
```

---

## Checklist Summary

| Criterion | Status | Notes |
|-----------|--------|-------|
| **Correctness** | ✓ | Core logic is correct; blocks late events effectively |
| **Atomicity** | ✓ | Tombstone is empty file; no data corruption possible |
| **Race conditions** | ⚠ | Minor TOCTOU (benign), theoretical session reuse race (minimal impact) |
| **Cleanup** | ✓ | Tombstones removed after 60 seconds by cleanup system |
| **Error handling** | ✓ | Failures logged, system continues in valid state |
| **Documentation accuracy** | ✗ | Three documentation errors found (Findings 1-3) |
| **Dead code** | ✓ | No dead code detected |

---

## Recommended Actions

### Immediate (Documentation Fixes)

1. **Update side-effects-map.md** with correct function names, paths, and triggers
2. **Add comment** explaining session_id reuse behavior

### Optional (Code Improvements)

3. **Simplify `remove_tombstone`** to eliminate TOCTOU (if desired, low priority)

---

## Test Coverage

The test suite at `tests/hud-hook/tombstone.bats` provides good coverage:
- Basic lifecycle (SessionStart, SessionEnd)
- Tombstone creation on SessionEnd
- Late event blocking (UserPromptSubmit, PreToolUse, PostToolUse)
- Multiple late events
- Session ID reuse
- Cross-session isolation

**Missing coverage:**
- Cleanup of old tombstones (unit test exists in cleanup.rs, but no integration test)
- Error handling paths (directory creation failure, file write failure)
