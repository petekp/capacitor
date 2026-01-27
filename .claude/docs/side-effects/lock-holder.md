# Lock Holder Side Effects

Deep analysis of all side effects in the lock holder daemon subsystem.

**Files analyzed:**
- `core/hud-hook/src/lock_holder.rs` — Daemon logic
- `core/hud-hook/src/handle.rs` — `spawn_lock_holder()` function
- `core/hud-hook/src/main.rs` — CLI entry point
- `core/hud-core/src/state/cleanup.rs` — Orphan cleanup

---

## Architecture Overview

```
Hook Event (SessionStart/UserPromptSubmit)
            │
            ▼
spawn_lock_holder()
            │
            ├─► create_session_lock() → FS: mkdir + write pid/meta.json
            │
            ▼
Command::spawn("hud-hook lock-holder ...")
            │
            ▼
lock_holder::run()
            │
            ▼
while is_pid_alive(pid) {
    // check lock_dir exists      → FS: stat()
    // check pid file matches     → FS: read
    sleep(1s)
}
            │
            ▼ Exit conditions:
            │ • PID exits
            │ • Lock dir removed externally
            │ • Lock taken over (pid changed)
            │ • 24h timeout (BUG: releases anyway)
            │
            ▼
release_lock_by_session() → FS: rm -r {sid}-{pid}.lock
```

---

## Side Effects by Component

### spawn_lock_holder() (handle.rs:331-373)

**Process side effects:**

| Line | Side Effect | Description |
|------|-------------|-------------|
| 333 | `create_session_lock()` | Delegates to lock.rs (see lock-system.md) |
| 347-362 | `Command::spawn()` | Forks new process |

**Spawn characteristics:**
- stdin/stdout/stderr → `/dev/null` (detached)
- No parent tracking, runs until exit condition
- Uses `current_exe()` to find binary path

---

### lock_holder::run() (lock_holder.rs:29-102)

**Monitoring loop side effects:**

| Function | Line | Side Effect | Frequency |
|----------|------|-------------|-----------|
| `is_pid_alive()` | 33 | `libc::kill(pid, 0)` | Every 1s |
| `lock_dir.exists()` | 45 | `stat()` syscall | Every 1s |
| `read_lock_pid()` | 55 | `fs::read_to_string()` | Every 1s |
| `thread::sleep()` | 68 | Thread blocks | Every 1s |

**Exit side effects:**

| Exit Path | Side Effect | Location |
|-----------|-------------|----------|
| PID exits | `release_lock_by_session()` → `rm -r` | 87-93 |
| Lock dir removed | Early return (no cleanup needed) | 51 |
| Lock taken over | Early return (no cleanup needed) | 64 |
| 24h timeout | `release_lock_by_session()` → `rm -r` **[BUG]** | 87-93 |
| No home dir | `fs::remove_dir_all(lock_dir)` (fallback) | 81 |

---

### Orphan Cleanup (cleanup.rs:43-104)

**Process enumeration side effects:**

| Line | Side Effect | Description |
|------|-------------|-------------|
| 47-48 | `System::new()` + `refresh_processes_specifics()` | Scans all processes |
| 50-60 | Iterate `sys.processes()` | Memory-only |

**Termination side effects:**

| Line | Side Effect | Condition |
|------|-------------|-----------|
| 86 | `libc::kill(holder_pid, SIGTERM)` | Monitored PID is dead |

---

## Side Effects Summary Table

| Component | Type | Side Effect | Reversible? |
|-----------|------|-------------|-------------|
| **spawn_lock_holder** | Process | fork + exec | No |
| **spawn_lock_holder** | FS | Lock creation | Yes (delete) |
| **lock_holder::run** | Process | kill(pid, 0) check | N/A (query) |
| **lock_holder::run** | FS | stat() on lock_dir | N/A (query) |
| **lock_holder::run** | FS | Read pid file | N/A (query) |
| **lock_holder::run** | FS | rm -r lock directory | No |
| **cleanup_orphaned_lock_holders** | Process | SIGTERM | No |

---

## Timing and Frequency

| Operation | Frequency | Context |
|-----------|-----------|---------|
| Spawn lock holder | Once per SessionStart/UserPromptSubmit | Hook |
| PID liveness check | Every 1 second | Daemon |
| Lock release | Once (on exit) | Daemon termination |
| Orphan cleanup | Once per app launch | Startup |

---

## Error Handling

| Error | Behavior | Recovery |
|-------|----------|----------|
| Lock already exists | Returns early | None needed |
| current_exe() fails | No spawn | Lock orphaned until cleanup |
| No home directory | Direct rm -r | Fallback |
| SIGTERM fails (ESRCH) | Ignores | Already dead |

---

## Known Issues

| Issue | Severity | Status |
|-------|----------|--------|
| 24h timeout releases lock while PID alive | High | Bug |
| Race between spawn and monitor start | Low | Acceptable |
| cwd param unused for logic | Low | Design debt |
