# Session 2: Lock Holder Audit

**Files analyzed:**
- `core/hud-hook/src/lock_holder.rs` (109 lines)
- `core/hud-hook/src/handle.rs` — `spawn_lock_holder()` (331-373)
- `core/hud-hook/src/main.rs` — CLI entry point (86-93)
- `core/hud-core/src/state/cleanup.rs` — Orphan cleanup (43-104)

**Analysis date:** 2025-01-26

---

## Analysis Checklist Results

| Check | Status | Notes |
|-------|--------|-------|
| Correctness | ❌ Bug | 24h timeout releases lock while PID alive |
| Atomicity | ✅ Pass | Lock creation is atomic |
| Race conditions | ⚠️ Minor | Window between spawn and monitor start |
| Cleanup | ✅ Pass | Multiple cleanup paths work together |
| Error handling | ✅ Pass | Graceful fallbacks |
| Documentation accuracy | ⚠️ Minor | Comment says "PID exited" but timeout case exists |
| Dead code | ⚠️ Minor | `cwd` param only used for logging |

---

## Findings

### [LOCK-HOLDER] Finding 1: 24h Timeout Releases Lock While PID Alive — **BUG**

**Severity:** High
**Type:** Bug
**Location:** `lock_holder.rs:33-41, 71-101`

**Problem:**
When the lock holder hits the 24h timeout, it releases the lock even though the monitored Claude process may still be alive.

```rust
// Monitor the PID until it exits
while is_pid_alive(pid) {
    // Safety timeout: exit after 24 hours to prevent perpetually running lock holders
    if start.elapsed().as_secs() > MAX_LIFETIME_SECS {
        tracing::info!(..., "Lock holder exceeded max lifetime (24h), exiting");
        break;  // Breaks out while PID is STILL ALIVE
    }
    ...
}

// PID has exited - release this session's lock  ← COMMENT IS WRONG
let lock_base = home.join(".capacitor/sessions");
release_lock_by_session(&lock_base, session_id, pid)  // ← RELEASES LOCK INCORRECTLY
```

**Impact:**
- Claude sessions running >24h lose their lock
- UI would show session as inactive/ended while Claude is still running
- Potential state inconsistency

**Recommendation:**
Only release lock when PID actually exits, not on timeout:

```rust
let pid_exited = loop {
    if !is_pid_alive(pid) {
        break true;  // PID actually exited
    }
    if start.elapsed().as_secs() > MAX_LIFETIME_SECS {
        tracing::info!(..., "Lock holder exceeded max lifetime (24h), exiting");
        break false;  // Timeout, PID still alive
    }
    if !lock_dir.exists() { return; }
    if let Some(lock_pid) = read_lock_pid(lock_dir) {
        if lock_pid != pid { return; }
    }
    thread::sleep(Duration::from_secs(1));
};

// Only release if PID actually exited
if pid_exited {
    release_lock_by_session(&lock_base, session_id, pid);
}
```

---

### [LOCK-HOLDER] Finding 2: Race Window Between Spawn and Monitor

**Severity:** Low
**Type:** Race condition (theoretical)
**Location:** `handle.rs:331-362`

**Problem:**
There's a timing window between:
1. `create_session_lock()` creates the lock directory
2. Lock holder daemon starts and enters monitoring loop

If Claude exits during this window (process spawn + initialization), the lock may not be released.

```rust
fn spawn_lock_holder(...) {
    let lock_dir = create_session_lock(...)?;  // Lock created

    // ... window starts here

    Command::new(current_exe)
        .args(["lock-holder", ...])
        .spawn();  // Holder spawned, but hasn't started monitoring yet

    // ... window ends when holder's while loop starts
}
```

**Analysis:**
This is a very small window (milliseconds). In practice:
- If Claude dies, the lock holder will detect it immediately on first `is_pid_alive()` check
- The startup cleanup will catch any orphaned locks on next app launch

**Recommendation:**
No immediate action needed. Document as known acceptable race.

---

### [LOCK-HOLDER] Finding 3: Unused `cwd` Parameter

**Severity:** Low
**Type:** Dead code
**Location:** `lock_holder.rs:29`

**Problem:**
The `cwd` parameter is accepted but only used for logging, not for any operational logic:

```rust
pub fn run(session_id: &str, cwd: &str, pid: u32, lock_dir: &Path) {
    // cwd is only used in tracing:: calls
    tracing::info!(session = %session_id, cwd = %cwd, "Lock holder exceeded...");
    tracing::debug!(session = %session_id, cwd = %cwd, "Lock directory removed...");
    // etc.
}
```

**Analysis:**
The parameter provides useful debugging context in logs. Not strictly dead code, but could cause confusion if someone thinks it affects behavior.

**Recommendation:**
Keep for logging context. Consider renaming to `_cwd` or adding a comment noting it's for diagnostics only.

---

### [LOCK-HOLDER] Finding 4: Misleading Comment

**Severity:** Low
**Type:** Stale docs
**Location:** `lock_holder.rs:71`

**Problem:**
Comment states "PID has exited" but this isn't true when the timeout path is taken:

```rust
// PID has exited - release this session's lock
```

**Recommendation:**
Update comment to reflect both exit conditions (or fix Finding 1 which makes this moot):

```rust
// Loop exited - either PID died or timeout reached
```

---

### [LOCK-HOLDER] Finding 5: No SIGTERM Handler

**Severity:** Low
**Type:** Design note
**Location:** `lock_holder.rs` (entire file)

**Problem:**
The lock holder doesn't install a SIGTERM handler. When `cleanup_orphaned_lock_holders()` sends SIGTERM, the process terminates immediately without running cleanup code.

**Analysis:**
This is actually correct behavior:
1. Cleanup only kills holders whose monitored PID is dead
2. After killing, `cleanup_stale_locks()` removes the lock directory
3. The holder doesn't need to clean up—the cleanup system does it

The two cleanup paths are complementary:
- **Normal exit:** Holder detects PID death → releases lock
- **Orphan cleanup:** SIGTERM kills holder → startup cleanup removes lock

**Recommendation:**
No action needed. Consider adding a comment in `cleanup.rs` explaining this interaction.

---

### [LOCK-HOLDER] Finding 6: Defensive Lock Directory Validation

**Severity:** Low
**Type:** Design suggestion
**Location:** `lock_holder.rs:29`, `main.rs:86-93`

**Problem:**
The lock holder receives `lock_dir` as a command-line argument without validating it's a legitimate lock directory under `~/.capacitor/sessions/`.

```rust
Commands::LockHolder { lock_dir, .. } => {
    lock_holder::run(&session_id, &cwd_path, pid, &lock_dir);
    // No validation that lock_dir is valid
}
```

**Analysis:**
Low risk because:
- Lock holder is spawned by `handle.rs`, not user-invokable
- Worst case: it monitors a non-lock directory and does nothing

**Recommendation:**
Add defensive validation (optional, low priority):

```rust
if !lock_dir.extension().is_some_and(|e| e == "lock") {
    tracing::error!("Invalid lock directory: {}", lock_dir.display());
    return;
}
```

---

## Lifecycle Analysis

### Normal Flow

```
SessionStart/UserPromptSubmit hook
        │
        ▼
spawn_lock_holder()
        │
        ├─► create_session_lock()  → FS: mkdir + write pid/meta.json
        │
        ▼
Command::spawn("hud-hook lock-holder ...")
        │
        ▼
lock_holder::run()
        │
        ▼
while is_pid_alive(pid) {
    sleep(1s)
}                           ◄─────────────┐
        │                                  │
        ▼ PID exits                        │
release_lock_by_session()  → FS: rm -r    │
        │                                  │
        ▼                                  │
Lock holder process exits                  │
                                           │
Meanwhile, Claude running ─────────────────┘
```

### Orphan Cleanup Flow

```
App Launch
    │
    ▼
run_startup_cleanup()
    │
    ├─► cleanup_orphaned_lock_holders()
    │       │
    │       ├─► Find all "hud-hook lock-holder" processes
    │       │
    │       ├─► Parse --pid argument
    │       │
    │       ├─► If monitored PID dead → SIGTERM holder
    │       │
    │       ▼
    │
    ├─► cleanup_stale_locks()
    │       │
    │       ├─► Find all *.lock dirs
    │       │
    │       ├─► If lock's PID dead → rm -r
    │       │
    │       ▼
    │
    ▼
Cleanup complete
```

---

## Summary

| Severity | Count | Issues |
|----------|-------|--------|
| Critical | 0 | — |
| High | 1 | **24h timeout bug** — releases lock while Claude running |
| Medium | 0 | — |
| Low | 5 | Unused param, stale comment, race window, design notes |

**Overall assessment:** One significant bug (Finding 1) that causes incorrect lock release after 24h. Should be fixed before next release.

---

## Recommended Actions

### Immediate (before next release)
1. **Fix 24h timeout bug** (Finding 1) — Only release lock when PID actually exits

### Near-term
2. Add comment explaining `cwd` is for logging only (Finding 3)
3. Update misleading "PID has exited" comment (Finding 4)

### Backlog
4. Add defensive lock_dir validation (Finding 6)
