# Lock System Side Effects

Deep analysis of all side effects in the lock subsystem.

**Files analyzed:**
- `core/hud-core/src/state/lock.rs` — Lock creation, reading, verification, release
- `core/hud-hook/src/lock_holder.rs` — Background daemon monitoring
- `core/hud-hook/src/handle.rs` — Hook handler (lock spawning)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         LOCK LIFECYCLE                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  SessionStart/UserPromptSubmit Hook Event                              │
│                    │                                                    │
│                    ▼                                                    │
│  ┌─────────────────────────────────┐                                   │
│  │     spawn_lock_holder()          │                                   │
│  │     (handle.rs:331)              │                                   │
│  └────────────┬────────────────────┘                                   │
│               │                                                         │
│               ▼                                                         │
│  ┌─────────────────────────────────┐    ┌────────────────────────────┐ │
│  │   create_session_lock()          │───▶│ FS: mkdir {sid}-{pid}.lock │ │
│  │   (lock.rs:500)                  │    │ FS: write pid              │ │
│  └────────────┬────────────────────┘    │ FS: write meta.json        │ │
│               │                          └────────────────────────────┘ │
│               ▼                                                         │
│  ┌─────────────────────────────────┐    ┌────────────────────────────┐ │
│  │   Command::spawn() → lock-holder │───▶│ PROC: spawn daemon         │ │
│  │   (handle.rs:347-362)            │    └────────────────────────────┘ │
│  └─────────────────────────────────┘                                   │
│                                                                         │
│  ════════════════════════════════════════════════════════════════════  │
│                                                                         │
│  Lock Holder Daemon Running                                            │
│                    │                                                    │
│                    ▼                                                    │
│  ┌─────────────────────────────────┐    ┌────────────────────────────┐ │
│  │   while is_pid_alive(pid) {      │───▶│ PROC: kill(pid, 0)         │ │
│  │       sleep(1s)                  │    │ FS: exists(lock_dir)       │ │
│  │   }                              │    │ FS: read pid               │ │
│  │   (lock_holder.rs:33-69)         │    └────────────────────────────┘ │
│  └────────────┬────────────────────┘                                   │
│               │ PID exits                                               │
│               ▼                                                         │
│  ┌─────────────────────────────────┐    ┌────────────────────────────┐ │
│  │   release_lock_by_session()      │───▶│ FS: rm -r {sid}-{pid}.lock │ │
│  │   (lock.rs:730)                  │    └────────────────────────────┘ │
│  └─────────────────────────────────┘                                   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## File System Side Effects

### Lock Directory Creation

| Function | Location | Side Effect |
|----------|----------|-------------|
| `create_session_lock()` | `lock.rs:500-597` | Creates `~/.capacitor/sessions/{session_id}-{pid}.lock/` |
| `create_lock()` | `lock.rs:606-688` | Creates `~/.capacitor/sessions/{hash}.lock/` (legacy) |

**Lock directory structure:**
```
{session_id}-{pid}.lock/
├── pid          # Plain text: the Claude process ID
└── meta.json    # { pid, path, session_id, proc_started, created, lock_version }
```

**Atomicity:** Uses `mkdir` which fails atomically if directory exists, preventing race conditions.

### File System Reads

| Function | Location | Reads | Frequency |
|----------|----------|-------|-----------|
| `read_lock_info()` | `lock.rs:212-322` | `pid`, `meta.json` | Per UI refresh |
| `read_lock_pid()` | `lock_holder.rs:104-108` | `pid` only | Every 1s (daemon) |
| `has_any_active_lock()` | `lock.rs:346-364` | All `*.lock/` dirs | Hook health check |
| `find_all_locks_for_path()` | `lock.rs:399-427` | All `*.lock/` dirs | Session counting |
| `find_matching_child_lock()` | `lock.rs:435-487` | All `*.lock/` dirs | State resolution |
| `count_other_session_locks()` | `lock.rs:694-723` | Filtered by prefix | Session cleanup |

### File System Deletions

| Function | Location | Deletes | Trigger |
|----------|----------|---------|---------|
| `release_lock_by_session()` | `lock.rs:730-738` | `{session_id}-{pid}.lock/` | PID exit, SessionEnd |
| `release_lock()` | `lock.rs:745-754` | `{hash}.lock/` (legacy) | Legacy cleanup |
| `create_session_lock()` | `lock.rs:549, 572` | Stale locks | Takeover |
| `create_lock()` | `lock.rs:669, 677` | Stale locks | Takeover |
| `lock_holder::run()` | `lock_holder.rs:81` | Lock dir (fallback) | No home dir |

### File System Updates

| Function | Location | Updates | Notes |
|----------|----------|---------|-------|
| `write_lock_metadata()` | `lock.rs:776-822` | `pid`, `meta.json` | Creates or overwrites |
| `update_lock_pid()` | `lock.rs:757-773` | Lock metadata | Handoff (preserves session_id) |
| `create_lock()` | `lock.rs:647-657` | In-place takeover | Avoids rm+mkdir race |

---

## Process Side Effects

### Process Spawning

| Function | Location | Spawns | Characteristics |
|----------|----------|--------|-----------------|
| `spawn_lock_holder()` | `handle.rs:331-373` | `hud-hook lock-holder` | Detached daemon |

**Daemon properties:**
- stdin/stdout/stderr → `/dev/null`
- Long-running (monitors until PID exits)
- Self-terminating on monitored PID death
- Max lifetime: 24 hours (safety valve)

### Process Queries

| Function | Location | Query | Purpose |
|----------|----------|-------|---------|
| `is_pid_alive()` | `lock.rs:82-97` | `libc::kill(pid, 0)` | POSIX liveness check |
| `get_process_start_time()` | `lock.rs:102-117` | `sysinfo::refresh_process_specifics()` | PID verification |
| `is_pid_alive_with_legacy_checks()` | `lock.rs:138-184` | Process name + cmd | Legacy lock validation |
| `get_ppid()` | `handle.rs:375-387` | `libc::getppid()` | Get Claude's PID |

---

## Memory Side Effects

### Thread-Local Cache

```rust
// lock.rs:57-59
thread_local! {
    static SYSTEM_CACHE: RefCell<Option<sysinfo::System>> = const { RefCell::new(None) };
}
```

| Property | Value |
|----------|-------|
| Scope | Per-thread |
| Lifetime | Process duration |
| Initialization | Lazy (first PID query) |
| Cleanup | Automatic on thread exit |
| Purpose | Efficient O(1) per-PID queries instead of O(n) full process scans |

---

## Side Effects by Function

### `create_session_lock()` (lock.rs:500-597)

**Inputs:** `lock_base`, `session_id`, `project_path`, `pid`

**Side effects:**
1. `fs::create_dir_all(lock_base)` — Ensure parent exists
2. `fs::create_dir(&lock_dir)` — Atomic lock acquisition
3. `write_lock_metadata()` → `fs::write(pid)`, `fs::write(meta.json)`
4. On failure: `fs::remove_dir_all(&lock_dir)` — Cleanup

**Error recovery:**
- If lock exists with stale PID: `fs::remove_dir_all()` then retry
- If metadata write fails: `fs::remove_dir_all()` cleanup

### `release_lock_by_session()` (lock.rs:730-738)

**Inputs:** `lock_base`, `session_id`, `pid`

**Side effects:**
1. `fs::remove_dir_all(&lock_dir)` — Delete entire lock directory

**Idempotency:** Returns `true` if lock doesn't exist (already released).

### `spawn_lock_holder()` (handle.rs:331-373)

**Inputs:** `lock_base`, `session_id`, `cwd`, `pid`

**Side effects:**
1. `create_session_lock()` — File system effects above
2. `Command::new().spawn()` — Spawn background process

**Process arguments:**
```
hud-hook lock-holder
  --session-id {session_id}
  --cwd {cwd}
  --pid {pid}
  --lock-dir {lock_dir}
```

### `lock_holder::run()` (lock_holder.rs:29-102)

**Inputs:** `session_id`, `cwd`, `pid`, `lock_dir`

**Side effects (loop, every 1s):**
1. `is_pid_alive(pid)` — Process query
2. `lock_dir.exists()` — File system check
3. `read_lock_pid()` — File read

**Side effects (on exit):**
1. `release_lock_by_session()` → `fs::remove_dir_all()`
2. OR `fs::remove_dir_all(lock_dir)` — Direct fallback

---

## Timing & Frequency

| Operation | Frequency | Context |
|-----------|-----------|---------|
| Lock creation | Once per session start | Hook event |
| Lock check (daemon) | Every 1 second | Background |
| Lock directory scan | Every UI refresh (~16ms) | SwiftUI |
| Lock release | Once per session end | PID exit |
| PID liveness check | Every 1s (daemon) + UI refresh | Mixed |

---

## Error Handling

### Recoverable Errors

| Error | Recovery | Location |
|-------|----------|----------|
| Lock exists (stale) | Remove and retry | `lock.rs:547-556` |
| Metadata unreadable | Remove and retry | `lock.rs:571-578` |
| No home directory | Direct remove | `lock_holder.rs:73-82` |

### Non-Recoverable Errors

| Error | Behavior | Location |
|-------|----------|----------|
| Lock exists (live holder) | Return None, log warning | `lock.rs:561-569` |
| Create failed (permissions) | Return None, log warning | `lock.rs:587-595` |

---

## Concurrency Considerations

### Race Conditions Mitigated

1. **Lock acquisition race:** `mkdir` is atomic — only one process succeeds
2. **Takeover race:** In-place metadata update avoids rm+mkdir gap (`lock.rs:647`)
3. **PID reuse:** `proc_started` timestamp verification (`lock.rs:189-210`)

### Potential Issues

1. **Directory scan during modification:** No locking on `read_dir()` iterations
2. **Metadata read during write:** No file-level locking (atomic write mitigates)

---

## Testing Coverage

| Test | Location | Tests |
|------|----------|-------|
| `test_no_lock_dir_means_not_running` | `lock.rs:944` | Empty state |
| `test_lock_with_dead_pid_means_not_running` | `lock.rs:951` | Stale detection |
| `test_lock_with_live_pid_means_running` | `lock.rs:958` | Live detection |
| `test_create_lock_returns_none_when_already_owned` | `lock.rs:1021` | Idempotency |
| `test_create_lock_takeover_from_live_process` | `lock.rs:1148` | Takeover |
| `test_session_lock_release_only_own_lock` | `lock.rs:1202` | Isolation |
| `test_count_other_session_locks` | `lock.rs:1233` | Concurrent sessions |

---

## Summary Table

| Category | Function | Side Effect | Reversible? |
|----------|----------|-------------|-------------|
| **FS Create** | `create_session_lock` | `mkdir + write` | Yes (delete) |
| **FS Create** | `create_lock` | `mkdir + write` | Yes (delete) |
| **FS Write** | `write_lock_metadata` | Overwrite files | Yes (restore) |
| **FS Delete** | `release_lock_by_session` | `rm -r` directory | No |
| **FS Delete** | `release_lock` | `rm -r` directory | No |
| **FS Read** | `read_lock_info` | None (pure read) | N/A |
| **Process** | `spawn_lock_holder` | Spawn daemon | Yes (kill) |
| **Process** | `is_pid_alive` | Query only | N/A |
| **Memory** | `SYSTEM_CACHE` | Thread-local alloc | Auto (thread exit) |
