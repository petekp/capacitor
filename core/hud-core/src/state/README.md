# State Detection Architecture (v3)

How Claude HUD detects whether Claude Code is running and what it's doing.

## The Sidecar Philosophy

Claude HUD follows a **sidecar pattern**: it observes Claude Code without interfering.

```
┌─────────────────┐     hooks      ┌──────────────────┐
│  Claude Code    │ ─────────────► │  Hook Script     │
│  (user's CLI)   │                │  (state writer)  │
└─────────────────┘                └────────┬─────────┘
                                            │ writes
                                            ▼
┌─────────────────┐     reads      ┌──────────────────┐
│  Claude HUD     │ ◄───────────── │  State Files     │
│  (Swift app)    │                │  + Lock Dirs     │
└─────────────────┘                └──────────────────┘
```

**Key principle:** The hook script is authoritative for state transitions. Rust is a passive reader.

## Data Flow

1. **User starts Claude Code** → Claude CLI creates session
2. **Hook fires (SessionStart)** → Hook script:
   - Writes state record to `~/.capacitor/sessions.json`
   - Spawns lock holder at `~/.claude/sessions/{hash}.lock/`
3. **User sends prompt** → Hook fires (UserPromptSubmit) → State becomes `working`
4. **Claude responds** → Hook fires (Stop) → State becomes `ready`
5. **Session ends** → Hook fires (SessionEnd) → State record deleted, lock released

## Two-Layer Liveness Detection

The resolver uses two signals to determine if a session is active:

### Layer 1: Lock Files (Primary)

Lock directories in `~/.claude/sessions/` indicate a running session:

```
~/.claude/sessions/
└── a1b2c3d4e5f6.lock/     # Hash of project path
    ├── pid                 # Claude process ID
    └── meta.json           # { pid, path, created, proc_started }
```

The lock holder is a background process that:
- Monitors the Claude process
- Releases the lock when Claude exits
- Handles session handoff (e.g., `claude --continue`)

### Layer 2: Fresh Record Fallback

If no lock exists but a state record is **fresh** (updated within 30 seconds), trust it:

```rust
const FRESH_RECORD_TTL: Duration = Duration::from_secs(30);
```

This handles edge cases:
- Lock creation in progress (race condition)
- Lock cleaned up but session still active
- Hook fired but lock holder hasn't spawned yet

**Important:** Fresh record fallback only applies to exact/child path matches, not parent matches.

## State File Format (v3)

```json
{
  "version": 3,
  "sessions": {
    "session-abc123": {
      "session_id": "session-abc123",
      "state": "working",
      "cwd": "/Users/me/project",
      "updated_at": "2026-01-21T10:30:00.123Z",
      "state_changed_at": "2026-01-21T10:29:55.000Z",
      "working_on": "Implementing feature X",
      "project_dir": "/Users/me/project",
      "last_event": {
        "event": "UserPromptSubmit",
        "timestamp": "2026-01-21T10:29:55.000Z"
      }
    }
  }
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `session_id` | Yes | Unique session identifier |
| `state` | Yes | One of: `working`, `ready`, `idle`, `compacting`, `waiting` |
| `cwd` | Yes | Current working directory |
| `updated_at` | Yes | Last update (including heartbeats) |
| `state_changed_at` | Yes | When state actually changed |
| `working_on` | No | User's current task description |
| `project_dir` | No | Stable project root (may differ from cwd) |
| `last_event` | No | Last hook event for debugging |

### State Values

| State | Meaning |
|-------|---------|
| `working` | Claude is thinking/generating |
| `ready` | Claude finished, waiting for input |
| `waiting` | Claude needs permission to proceed |
| `compacting` | Auto-compaction in progress |
| `idle` | No active session |

## State Machine

```
SessionStart         → ready
UserPromptSubmit     → working
PermissionRequest    → waiting
PostToolUse          → working (or heartbeat if already working)
Notification         → ready (only if notification_type="idle_prompt")
Stop                 → ready
PreCompact           → compacting (only when trigger="auto")
SessionEnd           → session deleted
```

## Resolution Algorithm

```rust
fn resolve_state(project_path) -> Option<ResolvedState> {
    // 1. Check for active lock (exact match or child)
    if is_session_running(lock_dir, project_path) {
        let lock = find_matching_child_lock(...);
        let record = find_record_for_lock_path(...);
        return ResolvedState {
            state: record.state,
            is_from_lock: true,
        };
    }

    // 2. Fallback: trust fresh records without locks
    let record = find_exact_or_child_record(store, project_path);
    if is_record_fresh(record) && record.state != Idle {
        return ResolvedState {
            state: record.state,
            is_from_lock: false,
        };
    }

    None // No active session
}
```

### Path Matching

When querying for `/project`:

| Record cwd | Match Type | Notes |
|------------|------------|-------|
| `/project` | Exact | Preferred |
| `/project/src` | Child | Session cd'd into subdir |
| `/` | Parent | Session started at root |

**Priority:** Exact > Child > Parent (for lock-based resolution)

**Fresh record fallback:** Only exact/child matches, never parent.

## Module Structure

```
state/
├── mod.rs        # Public exports
├── types.rs      # SessionRecord, LastEvent, LockInfo
├── store.rs      # StateStore - file persistence, version 3 schema
├── lock.rs       # Lock detection, PID verification
└── resolver.rs   # Fuses lock + state data, fresh record fallback
```

### Key Functions

```rust
// Check if any session is running at/under a path
pub fn is_session_running(lock_dir: &Path, project_path: &str) -> bool;

// Get detailed lock metadata
pub fn get_lock_info(lock_dir: &Path, project_path: &str) -> Option<LockInfo>;

// Resolve state with full details
pub fn resolve_state_with_details(...) -> Option<ResolvedState>;

// Simple state query
pub fn resolve_state(...) -> Option<SessionState>;
```

## Debugging

### Quick Commands

```bash
# Watch hook events in real-time
tail -f ~/.claude/hud-hook-debug.log

# View current session states
cat ~/.capacitor/sessions.json | jq .

# Check active locks
for lock in ~/.claude/sessions/*.lock; do
  [ -d "$lock" ] && echo "$lock:" && cat "$lock/meta.json" 2>/dev/null | jq .
done

# Run hook test suite
./scripts/test-hook-events.sh
```

### Common Issues

**Session stuck on "Ready" when it should be "Working":**
1. Check state file: `jq '.sessions' ~/.capacitor/sessions.json`
2. Check for lock: `ls ~/.claude/sessions/`
3. Check hook log: `tail -20 ~/.claude/hud-hook-debug.log`

**No session detected at all:**
1. Verify hook is installed: `jq '.hooks' ~/.claude/settings.json`
2. Check hook script exists: `ls ~/.claude/scripts/hud-state-tracker.sh`
3. Sync hooks: `./scripts/sync-hooks.sh --force`

## File Locations

| File | Purpose | Owner |
|------|---------|-------|
| `~/.capacitor/sessions.json` | State records | Hook script (write) |
| `~/.claude/sessions/*.lock/` | Lock directories | Hook script (create) |
| `~/.claude/scripts/hud-state-tracker.sh` | Hook script | Claude HUD |
| `~/.claude/hud-hook-debug.log` | Debug log | Hook script |

## References

- [Hook Operations Reference](/.claude/docs/hook-operations.md)
- [ADR-001: State Tracking Approach](/docs/architecture-decisions/001-state-tracking-approach.md)
- [ADR-002: State Resolver Matching Logic](/docs/architecture-decisions/002-state-resolver-matching-logic.md)
