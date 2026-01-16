# ADR-002: State Resolver Matching Logic

**Status:** Accepted
**Date:** 2026-01-13
**Deciders:** Core team + ChatGPT iterative review (8 rounds)

## Context

The HUD resolver matches session state records (updated by hooks) with lock files (created at session start) to determine project activity. When users `cd` within a Claude session, the state record updates but the lock file remains at the original path, requiring flexible matching logic.

### Original Issues

Through 8 rounds of ChatGPT review, we identified and fixed:

1. **Root path handling** - `format!("{}/", "/")` produced `"//"`, breaking `/` ↔ `/foo` matching
2. **PID-only fallback** - With multiple locks sharing a PID, could pair wrong lock to session
3. **Sibling matching contamination** - `cd ../sibling` enabled cross-project PID reuse contamination
4. **Exact lock exclusion** - PID-only search only checked children, missing exact matches
5. **Nondeterministic selection** - HashMap iteration determined which lock was picked
6. **Test coverage gaps** - Tests didn't validate timestamp selection or root nesting

## Decision

### Three-Way Matching (Removed Sibling)

Support three match types between `record.cwd` and `lock.path`:

```rust
enum MatchType {
    Parent = 0,  // record.cwd is parent of lock (cd .. scenario)
    Child = 1,   // record.cwd is child of lock (cd subdir scenario)
    Exact = 2,   // exact match - highest priority
}
```

**Rationale for removing sibling matching:**
- Without project-level identifiers, any depth threshold creates arbitrary boundaries
- `/Users/me/project1` and `/Users/me/project2` can share PIDs through reuse
- Depth >= 2 guard still permits contamination under common parents
- Safe tradeoff: `cd ../sibling` won't match until user cd's back to parent

### Root Descendant Matching

Root (`/`) matches **any** absolute path descendant, not just immediate children:

```rust
if lock_path_normalized == "/" {
    // Any absolute path is descendant of /
    if record_cwd_normalized.starts_with("/") && record_cwd_normalized != "/" {
        Some(MatchType::Child)
    }
}
```

**Rationale:**
- Enables arbitrary nesting: `/` ↔ `/a/b/c/d` works correctly
- Reflects actual parent/child relationship in filesystem
- No artificial restriction on cd depth from root

### Timestamp-Based Lock Selection

When multiple locks share a PID, select by `started` timestamp:

```rust
if info.started > current.started {
    best_match = Some(info);
}
```

**Rationale:**
- Locks accumulate when session cd's - newest represents current location
- ISO timestamps can be compared lexicographically
- Deterministic behavior prevents flaky tests

### Exact + Child Lock Scanning

`find_matching_child_lock()` checks both exact and child locks:

```rust
// Check for exact match OR child match
let is_match = info_path_normalized == project_path_normalized ||
               info.path.starts_with(&prefix);
```

**Rationale:**
- Prefix `/project/` doesn't match exact lock at `/project`
- With PID reuse, must consider exact lock alongside stale children
- Timestamp comparison applies fairly to all matching locks

### Priority Ordering

```
1. Freshness (record.updated_at) - always wins first
2. Match type (Exact > Child > Parent) - if timestamps equal
3. Session ID (lexicographic) - if timestamps and match type equal
```

## Consequences

### Positive

- ✅ **No cross-project contamination** - sibling matching removed
- ✅ **Deterministic** - timestamp-based selection, no HashMap iteration dependency
- ✅ **Root nesting works** - arbitrary depth from `/` supported
- ✅ **PID reuse safe** - considers exact locks, picks newest by timestamp
- ✅ **Well-tested** - 94 tests covering root nesting, multi-lock, cd scenarios

### Negative

- ❌ **cd ../sibling won't match** - sessions that cd to sibling directories won't be detected until they cd back to parent or original path
- Trade-off: Safety over convenience (user can manually check sibling directories)

### Neutral

- Lock creation remains at session start location (hook unchanged)
- State record updates on every cd (hook unchanged)
- HUD adapts interpretation, no workflow changes

## Orphaned Lock Handling

### The Problem

When multiple Claude sessions start at the same path, a race condition can occur:

1. Session A starts at `/path/project`, creates lock, background lock holder runs
2. Session A ends but lock holder stays alive (zombie or cleanup delay)
3. Session B starts at `/path/project`, sees live PID holding lock
4. Session B updates state file but can't acquire lock (different PID)
5. Resolver sees: lock PID ≠ state PID → fallback behavior needed

**Result without fix:** HUD shows "Ready" instead of Session B's actual state.

### The Solution (Two Layers)

**Layer 1: Resolver Trust-State Fallback** (`resolver.rs`)

When lock PID doesn't match state PID and no session exists for the lock PID, trust the state record:

```rust
// No session matches lock PID - likely an orphaned lock
// Trust the state record we found since it represents actual activity
// at this cwd with a different (newer) PID
Some(ResolvedState {
    state: r.state,
    session_id: Some(r.session_id.clone()),
    cwd: r.cwd.clone(),
})
```

**Rationale:** If the lock's PID has no corresponding state record anywhere, that PID isn't actively using Claude Code—the lock is orphaned. The state record represents the real activity.

**Layer 2: Proactive Reconciliation** (`lock.rs`, `engine.rs`)

When a project is added via `add_project()`, reconcile any orphaned lock:

```rust
pub fn reconcile_orphaned_lock(lock_base, state_store, project_path) -> bool {
    // Returns true if orphaned lock was removed
    // Orphaned = lock PID is alive but has NO state record anywhere
}
```

**Rationale:** Proactive cleanup when users add projects ensures correct state display immediately. The orphaned lock holder process will notice its lock directory is gone and exit gracefully.

### Detection Criteria

A lock is considered **orphaned** when ALL conditions are met:

1. Lock directory exists at `~/.claude/sessions/{hash}.lock`
2. Lock's PID is alive (verified with `proc_started` if available)
3. **No state record exists** for that PID anywhere in the state file

**Important:** We only reconcile when PID is verified alive. Dead PIDs are handled by the hook's normal cleanup in the background monitor loop.

### Files Modified

- `core/hud-core/src/state/resolver.rs` - Trust-state fallback when lock is orphaned
- `core/hud-core/src/state/lock.rs` - `reconcile_orphaned_lock()` function
- `core/hud-core/src/engine.rs` - Call reconciliation in `add_project()`

## Implementation

### Files Modified

- `core/hud-core/src/state/resolver.rs` - Three-way matching, root special-cases, tie-breaker logic
- `core/hud-core/src/state/lock.rs` - Timestamp-based selection, exact+child scanning
- `core/hud-core/src/state/store.rs` - PID freshness removed (session_id check removed from iteration 1)

### Test Coverage

94 tests including:
- `test_root_cd_to_nested_path()` - Root to arbitrary depth
- `test_nested_path_cd_to_root()` - Arbitrary depth back to root
- `test_multi_lock_cd_scenario()` - Timestamp-based selection
- `test_resolver_uses_session_id_as_stable_tiebreaker()` - Deterministic tie-breaking

### Code Characteristics

- **Matching logic:** ~60 lines per helper (2 helpers: state-only, state+details)
- **Lock selection:** ~50 lines (includes exact+child scanning, timestamp comparison)
- **Test coverage:** Comprehensive root, multi-lock, cd scenarios

## Alternatives Considered

### 1. Keep Sibling Matching with Project-Level Config

**Idea:** Allow sibling matching only within configured project roots

**Rejected because:**
- Requires user configuration (violates "passive observer" principle)
- Configuration can become stale (projects move, renamed)
- Complexity not justified for `cd ../sibling` convenience

### 2. Exact Lock Priority Over Newer Child Locks

**Idea:** When exact lock exists, always prefer it regardless of timestamp

**Rejected because:**
- Session might cd to child, creating newer child lock (correct current location)
- Timestamp reflects most recent activity, should guide selection
- Would pair state with wrong location when multiple locks exist

### 3. Immediate Children Only for Root

**Idea:** `/` matches `/foo` but not `/foo/bar`

**Rejected because:**
- Artificial restriction not reflecting filesystem semantics
- Breaks real cd scenarios (user cd's deeply from root)
- No technical justification for depth=1 limitation

## Related Documents

- `.claude/plans/gleaming-baking-wozniak.md` - Original plan (8 iterations)
- `core/hud-core/src/state/resolver.rs` - Implementation
- `.claude/docs/hook-state-machine.md` - Hook event flow
- `ADR-001: State Tracking Approach` - Hooks vs daemon decision

## Review History

- **Round 1-7:** Iterative fixes identified by ChatGPT
  - PID freshness removal
  - Lock-to-state matching
  - Multi-child lock handling
  - Path normalization
  - Sibling matching addition (later removed)
  - Root special-casing
  - Timestamp-based selection

- **Round 8 (Final):** All critical issues resolved
  - Exact lock inclusion in PID-only fallback
  - Test helper timestamp support
  - Documentation accuracy

## Notes

This ADR documents the **final state** after 8 rounds of review and fixes. The actual implementation went through significant evolution:

1. Started with PID freshness as tie-breaker
2. Added sibling matching with depth guard
3. Realized depth guard insufficient, removed sibling entirely
4. Fixed root to match any descendant (not just immediate children)
5. Made lock selection deterministic via timestamps
6. Ensured exact locks considered alongside children

The iterative process improved robustness significantly through external AI review.
