# Phase 1: Critical State Detection Fixes (Sidecar-Safe Approach)

> **STATUS: ✅ COMPLETED (2026-01-13)**
> This plan went through 8 iterations of fixes based on ChatGPT review. Final implementation differs significantly from original plan.
> **See:** `docs/architecture-decisions/002-state-resolver-matching-logic.md` for final architecture
> **See:** `DONE.md` (Jan 2026 section) for completion summary

## Philosophy: Passive Observer, Defensive Reader

The HUD is a **sidecar dashboard** that observes Claude sessions without changing user workflow. This plan fixes critical bugs while adhering to the principle: **"The app adapts to Claude, Claude doesn't adapt to the app."**

## Summary

Fixing 4 critical state detection issues identified by multiple AI reviewers:

1. **State File Race Conditions** → Defensive reading + opportunistic cleanup (hybrid)
2. **Parent→Child Lock Inheritance** → Fix interpretation logic (Rust-only, no hook changes)
3. **PID Freshness Bug** → Add session_id validation (Rust-only)
4. **Resolver Session Mixing** → Lock-first resolution (Rust-only)

**Key Constraint:** Fixes #2, #3, #4 are pure Rust changes (interpretation layer). Fix #1 uses hybrid approach: HUD becomes resilient to corruption, hook gets non-blocking opportunistic cleanup.

---

## Issue Details

### Issue #1: State File Race Conditions (Hybrid Fix)
**Severity:** HIGH
**Root Cause:** Three concurrent writers (main hook, lock holder, description generator) with no coordination
**Current Impact:** Lost updates, stale state, occasional corruption

**Sidecar-Safe Fix:**
- **In HUD (Rust/Swift):** Defensive reading with validation, corruption recovery, staleness detection
- **In Hook (Bash):** Non-blocking opportunistic cleanup only (no `flock`, no blocking)
- Accept eventual consistency (state converges within 1-2 seconds)

### Issue #2: Parent→Child Lock Inheritance Bug
**Severity:** CRITICAL
**Root Cause:** `is_session_running()` walks upward, making children inherit parent locks
**Current Impact:** Parent lock at `/project` makes `/project/child` appear active (wrong)

**Sidecar-Safe Fix:**
- Pure Rust change in `lock.rs` (interpretation layer)
- Remove upward traversal, use `find_child_lock()` only
- No hook script changes

### Issue #3: PID Freshness Bug
**Severity:** HIGH
**Root Cause:** `find_by_cwd()` matches PID without checking session_id
**Current Impact:** Shows state from wrong session when PIDs are reused

**Sidecar-Safe Fix:**
- Pure Rust change in `store.rs` (matching logic)
- Add `&& record.session_id == exact_match.session_id` to PID checks
- No hook script changes

### Issue #4: Resolver Session Mixing
**Severity:** MEDIUM
**Root Cause:** Resolver can return lock from one session with state from another
**Current Impact:** Mixed session display (cwd from lock, state from different session)

**Sidecar-Safe Fix:**
- Pure Rust change in `resolver.rs` (resolution logic)
- Match lock to state by PID validation
- No hook script changes

---

## Implementation Plan

### Fix #2: Lock Inheritance (Rust-Only) ✓ SIDECAR-SAFE

**File:** `core/hud-core/src/state/lock.rs`

**Change:** Remove parent traversal in `is_session_running()` and `get_lock_info()`

**Before (lines 55-73):**
```rust
pub fn is_session_running(lock_base: &Path, project_path: &str) -> bool {
    if check_lock_for_path(lock_base, project_path).is_some() {
        return true;
    }
    // ❌ Walks upward - parent lock makes child active
    let mut current = project_path;
    while let Some(parent) = Path::new(current).parent() {
        if check_lock_for_path(lock_base, &parent_str).is_some() {
            return true;
        }
    }
    false
}
```

**After:**
```rust
pub fn is_session_running(lock_base: &Path, project_path: &str) -> bool {
    // Check exact match
    if check_lock_for_path(lock_base, project_path).is_some() {
        return true;
    }
    // ✓ Check for child locks (child makes parent active)
    // ✓ Never check parent locks (parent doesn't make child active)
    find_child_lock(lock_base, project_path).is_some()
}
```

**Tests to Fix:**
- `test_child_project_inherits_parent_lock()` → rename to `test_child_does_not_inherit_parent_lock()`, invert assertion
- Add: `test_parent_query_finds_child_lock()` (verify correct direction)

**Verification:**
```bash
cd core/hud-core
cargo test lock::tests --lib
cargo build -p hud-core --release
```

---

### Fix #3: PID Freshness (Rust-Only) ✓ SIDECAR-SAFE

**File:** `core/hud-core/src/state/store.rs`

**Change:** Add session_id check to PID tie-breaking (3 locations)

**Location 1 (lines 119-129) - Exact match case:**
```rust
if let Some(exact_match) = best {
    if let Some(pid) = exact_match.pid {
        for record in self.sessions.values() {
            // ✓ Only consider same session (handles cd within session)
            if record.pid == Some(pid)
                && record.session_id == exact_match.session_id  // ← ADD THIS
                && record.updated_at > exact_match.updated_at
            {
                best = Some(record);
            }
        }
    }
}
```

**Location 2 (lines 154-162) - Child directory case:**
Same pattern: add `&& record.session_id == child_match.session_id`

**Location 3 (lines 188-196) - Parent directory case:**
Same pattern: add `&& record.session_id == parent_match.session_id`

**Tests to Add:**
```rust
#[test]
fn test_find_by_cwd_does_not_cross_sessions_with_same_pid() {
    // Verify PID matching only applies within same session_id
}
```

**Verification:**
```bash
cd core/hud-core
cargo test store::tests --lib
cargo build -p hud-core --release
```

---

### Fix #4: Resolver Session Mixing (Rust-Only) ✓ SIDECAR-SAFE

**File:** `core/hud-core/src/state/resolver.rs`

**Change:** Make resolution lock-first with PID validation

**Before (lines 68-86):**
```rust
(false, Some(r)) => {
    // ❌ Can return state from one session with lock from another
    if let Some(lock_info) = find_child_lock(lock_dir, project_path) {
        Some(ResolvedState {
            state: r.state,         // From state record
            cwd: lock_info.path,    // From lock (might be different session!)
        })
    }
}
```

**After:**
```rust
(false, Some(r)) => {
    // Check for child lock first
    if let Some(lock_info) = find_child_lock(lock_dir, project_path) {
        // ✓ Verify lock belongs to this session by PID
        if r.pid == Some(lock_info.pid) {
            // Same session - use state from record
            Some(ResolvedState {
                state: r.state,
                session_id: Some(r.session_id.clone()),
                cwd: lock_info.path,
            })
        } else {
            // Different session - use lock only, default to Ready
            Some(ResolvedState {
                state: ClaudeState::Ready,
                session_id: None,
                cwd: lock_info.path,
            })
        }
    } else if is_session_running(lock_dir, &r.cwd) {
        // Session's cwd has lock
        Some(ResolvedState { state: r.state, /* ... */ })
    } else {
        None
    }
}
```

**Tests to Add:**
```rust
#[test]
fn test_resolver_does_not_mix_lock_and_state_from_different_sessions() {
    // Verify lock PID must match state record PID
}
```

**Verification:**
```bash
cd core/hud-core
cargo test resolver::tests --lib
cargo build -p hud-core --release
```

---

### Fix #1: State File Races (Hybrid Approach) ⚠️ NEEDS CARE

**Philosophy:** Make HUD resilient to imperfect data, add opportunistic cleanup without blocking.

#### Part A: Defensive Reading (Rust) ✓ SIDECAR-SAFE

**File:** `core/hud-core/src/state/store.rs`

**Add validation to `StateStore::load()`:**

```rust
pub fn load(file_path: &Path) -> Result<Self, String> {
    if !file_path.exists() {
        return Ok(Self::new_in_memory());
    }

    let contents = fs::read_to_string(file_path)
        .map_err(|e| format!("Failed to read state file: {}", e))?;

    // ✓ Defensive: Handle empty file
    if contents.trim().is_empty() {
        eprintln!("Warning: Empty state file, returning empty store");
        return Ok(Self::new_in_memory());
    }

    // ✓ Defensive: Handle JSON parse errors
    match serde_json::from_str::<StoreFile>(&contents) {
        Ok(store_file) => {
            // ✓ Opportunistic cleanup: Remove sessions with dead PIDs
            let cleaned_sessions: HashMap<String, SessionRecord> = store_file
                .sessions
                .into_iter()
                .filter(|(_, record)| {
                    match record.pid {
                        Some(pid) => is_pid_alive(pid),
                        None => true, // Keep sessions without PID (legacy)
                    }
                })
                .collect();

            Ok(Self {
                sessions: cleaned_sessions,
                file_path: Some(file_path.to_path_buf()),
            })
        }
        Err(e) => {
            eprintln!("Warning: Failed to parse state file ({}), returning empty store", e);
            // ✓ Defensive: Corrupt JSON → empty store (don't crash)
            Ok(Self::new_in_memory())
        }
    }
}
```

**Add staleness detection:**

```rust
impl SessionRecord {
    /// Returns true if this record is stale (not updated in last 5 minutes)
    pub fn is_stale(&self) -> bool {
        let now = Utc::now();
        let age = now.signed_duration_since(self.updated_at);
        age.num_seconds() > 300 // 5 minutes
    }
}
```

**Use in resolver:**

```rust
// In resolve_state_with_details(), filter out stale records
(false, Some(r)) => {
    if r.is_stale() {
        // Stale state record, ignore it
        None
    } else {
        // ... existing logic
    }
}
```

#### Part B: Opportunistic Cleanup (Hook) ⚠️ NON-BLOCKING ONLY

**File:** `scripts/hud-state-tracker.sh`

**Add non-blocking cleanup helper (insert after line 52):**

```bash
# Opportunistic cleanup: remove dead sessions (non-blocking, best-effort)
cleanup_dead_sessions() {
  local tmp_file
  tmp_file=$(mktemp)

  # Try cleanup, but don't block if it fails
  if jq 'del(.sessions[] | select(.pid != null and .pid | tostring | test("^[0-9]+$")))' \
        "$STATE_FILE" > "$tmp_file" 2>/dev/null; then
    # Only update if jq succeeded and file is valid JSON
    if jq -e . "$tmp_file" &>/dev/null; then
      mv "$tmp_file" "$STATE_FILE"
      echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | Cleaned up dead sessions" >> "$LOG_FILE"
    else
      rm -f "$tmp_file"
    fi
  else
    rm -f "$tmp_file"
  fi
}
```

**Call during SessionEnd (non-blocking background):**

```bash
"SessionEnd")
  new_state="idle"
  # ... existing update_state() call ...

  # Opportunistic cleanup in background (don't wait for it)
  (cleanup_dead_sessions &) 2>/dev/null
  ;;
```

**Key:** Cleanup runs in background subprocess, never blocks the main hook.

#### Part C: Swift Resilience

**File:** `apps/swift/Sources/ClaudeHUD/Models/AppState.swift`

**Handle nil states gracefully (already exists, verify):**

```swift
func refreshSessionStates() {
    guard let engine = engine else { return }

    do {
        var states = try engine.getAllSessionStates(projects: projects)

        // ✓ Already defensive: handles missing states, applies staleness
        // ✓ Add: Log when state is missing vs stale vs corrupt

        sessionStates = states
    } catch {
        print("Warning: Failed to refresh session states: \(error)")
        // ✓ Defensive: Don't crash, keep old states
    }
}
```

**Verification:**
- Manually corrupt state file, verify HUD recovers
- Kill Claude session, verify cleanup removes it within 30s
- Rapid state changes, verify no corruption

---

## Testing Strategy

### Per-Fix Testing

**Fix #2 (Lock Inheritance):**
```bash
cd core/hud-core
cargo test lock::tests --lib

# Manual: Create lock at /project/child, query /project (should find)
# Manual: Create lock at /project, query /project/child (should NOT find)
```

**Fix #3 (PID Freshness):**
```bash
cd core/hud-core
cargo test store::tests --lib

# Hard to test manually (can't control PID reuse)
# Rely on unit tests
```

**Fix #4 (Resolver Mixing):**
```bash
cd core/hud-core
cargo test resolver::tests --lib

# Manual: Create stale state record + fresh lock, verify no mixing
```

**Fix #1 (Hybrid Resilience):**
```bash
cd core/hud-core
cargo test store::tests --lib

# Manual: Corrupt state file (invalid JSON), verify HUD recovers
# Manual: Empty state file, verify HUD treats as empty store
# Manual: Rapid state changes (start/stop Claude repeatedly)
```

### Integration Testing

```bash
# Full Rust test suite
cd /Users/petepetrash/Code/claude-hud
cargo test --workspace

# Rebuild everything
cargo build -p hud-core --release
cd apps/swift && swift build

# Run HUD
swift run &

# Test scenarios:
# 1. Start Claude in /project, verify HUD shows active
# 2. Start Claude in /project/child, verify parent (/project) also shows active
# 3. Start Claude in /project, verify sibling (/project-other) does NOT show active
# 4. cd within Claude session, verify state updates correctly
# 5. Kill Claude session, verify HUD shows idle within 5 seconds
# 6. Start 2 Claude sessions simultaneously, verify no state corruption
# 7. Corrupt state file manually, verify HUD recovers gracefully
```

---

## Rollback Strategy

### Per-Fix Rollback

All fixes are independent and can be reverted individually:

```bash
# Fix #2: Lock inheritance
git checkout HEAD -- core/hud-core/src/state/lock.rs

# Fix #3: PID freshness
git checkout HEAD -- core/hud-core/src/state/store.rs

# Fix #4: Resolver mixing
git checkout HEAD -- core/hud-core/src/state/resolver.rs

# Fix #1: Hybrid resilience (revert all components)
git checkout HEAD -- core/hud-core/src/state/store.rs
git checkout HEAD -- scripts/hud-state-tracker.sh
git checkout HEAD -- apps/swift/Sources/ClaudeHUD/Models/AppState.swift

# After revert, rebuild:
cargo build -p hud-core --release
cd apps/swift && swift build
```

### Emergency Recovery

If state file becomes unrecoverable:

```bash
# Backup current state
cp ~/.claude/hud-session-states-v2.json ~/.claude/hud-session-states-v2.json.backup

# Reset to empty
echo '{"version":2,"sessions":{}}' > ~/.claude/hud-session-states-v2.json

# HUD will treat as fresh start, no data loss for locks (still exist separately)
```

---

## Implementation Sequence

### Step 1: Fix #2 (Lock Inheritance) - 30 min
1. Edit `core/hud-core/src/state/lock.rs`
2. Update tests (rename, invert assertions)
3. Run `cargo test lock::tests --lib`
4. Rebuild: `cargo build -p hud-core --release`
5. Commit: `fix(state): remove parent→child lock inheritance`

### Step 2: Fix #3 (PID Freshness) - 20 min
1. Edit `core/hud-core/src/state/store.rs` (3 locations)
2. Add unit test for cross-session PID
3. Run `cargo test store::tests --lib`
4. Rebuild: `cargo build -p hud-core --release`
5. Commit: `fix(state): add session_id check to PID freshness logic`

### Step 3: Fix #4 (Resolver Mixing) - 40 min
1. Edit `core/hud-core/src/state/resolver.rs`
2. Add unit test for session mixing
3. Run `cargo test resolver::tests --lib`
4. Rebuild: `cargo build -p hud-core --release`
5. Commit: `fix(state): prevent resolver from mixing sessions`

### Step 4: Fix #1 Part A (Defensive Reading) - 30 min
1. Edit `core/hud-core/src/state/store.rs` (add validation to `load()`)
2. Add `is_stale()` method to `SessionRecord`
3. Add unit tests for corruption handling
4. Run `cargo test store::tests --lib`
5. Rebuild: `cargo build -p hud-core --release`
6. Commit: `fix(state): add defensive reading and corruption recovery`

### Step 5: Fix #1 Part B (Opportunistic Cleanup) - 20 min
1. Edit `scripts/hud-state-tracker.sh` (add `cleanup_dead_sessions()`)
2. Call cleanup in background during SessionEnd
3. Test: Kill Claude, verify cleanup runs within 30s
4. Verify: Check debug log for "Cleaned up dead sessions"
5. Commit: `feat(state): add opportunistic non-blocking cleanup`

### Step 6: Integration Testing - 30 min
1. Run full test suite: `cargo test --workspace`
2. Rebuild Swift: `cd apps/swift && swift build && swift run &`
3. Run all manual test scenarios (see Testing Strategy above)
4. Monitor debug log: `tail -f ~/.claude/hud-hook-debug.log`
5. Verify: No errors, correct state display, no corruption

### Step 7: Documentation - 20 min
1. Update `.claude/docs/hook-state-machine.md` if needed
2. Create `docs/architecture-decisions/002-state-detection-fixes.md`
3. Update `DONE.md` with completed fixes
4. Update feedback synthesis document with "Implemented" status

---

## Success Criteria

✅ **Fix #2:** Parent projects show active when child has lock, child projects do NOT inherit parent lock

✅ **Fix #3:** PID-based freshness only applies within same session_id, no cross-session contamination

✅ **Fix #4:** Resolver always matches lock to state by PID, never mixes sessions

✅ **Fix #1:** HUD gracefully handles corrupt/stale state, cleanup is opportunistic and non-blocking

✅ **Overall:** HUD displays accurate real-time state, no crashes on corruption, correct parent/child relationships

✅ **Sidecar Principle:** No changes to user workflow, HUD adapts to Claude, not vice versa

---

## Critical Files

**Rust Core (Pure Interpretation Changes):**
- `core/hud-core/src/state/lock.rs` - Fix lock inheritance (Issue #2)
- `core/hud-core/src/state/store.rs` - Add session_id check (Issue #3) + defensive reading (Issue #1 Part A)
- `core/hud-core/src/state/resolver.rs` - Fix session mixing (Issue #4)

**Hook Script (Opportunistic Cleanup Only):**
- `scripts/hud-state-tracker.sh` - Add non-blocking cleanup (Issue #1 Part B)

**Swift App (Verify Existing Resilience):**
- `apps/swift/Sources/ClaudeHUD/Models/AppState.swift` - Verify error handling

---

## Risk Assessment

**Low Risk:**
- Fixes #2, #3, #4 are pure Rust interpretation changes (no hook modifications)
- Easy to test, easy to rollback

**Medium Risk:**
- Fix #1 Part A (defensive reading) changes how Rust handles state file
- Mitigation: Extensive unit tests for corruption scenarios

**Low Risk:**
- Fix #1 Part B (opportunistic cleanup) is background best-effort only
- Can't block hook execution, can't corrupt state (read-only or discard on error)

**Overall:** Low risk due to sidecar-safe design. No changes to user workflow.

---

## Verification Checklist

### Functional Verification
- [ ] Parent project shows active when child has lock ✓
- [ ] Child project does NOT show active when only parent has lock ✓
- [ ] Same session cd updates state correctly ✓
- [ ] Different sessions with same PID don't cross-contaminate ✓
- [ ] Stale state (>5min) is ignored ✓
- [ ] Corrupt state file doesn't crash HUD ✓
- [ ] Empty state file treated as fresh start ✓
- [ ] Dead sessions cleaned up within 30s ✓
- [ ] Multiple concurrent sessions don't corrupt state ✓

### Technical Verification
- [ ] All Rust tests pass: `cargo test --workspace`
- [ ] Swift builds successfully: `cd apps/swift && swift build`
- [ ] HUD displays correct state in real-time
- [ ] Debug log shows no errors during state updates
- [ ] State file remains valid JSON under rapid changes
- [ ] No blocking in hook script (all cleanup is background)

### Sidecar Principle Verification
- [ ] No changes to user's Claude Code workflow ✓
- [ ] No required user configuration changes ✓
- [ ] HUD gracefully handles all hook output formats ✓
- [ ] Works with existing hook setup (no migration needed) ✓
