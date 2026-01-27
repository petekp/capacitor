# Side Effects Analysis Plan

**Status: ✅ COMPLETE (2026-01-27)**

Systematic audit of Capacitor's side effects to identify latent issues causing state detection regressions and shell integration problems.

## Methodology

### Isolation Principle
Each subsystem analyzed in a **separate session** to prevent context pollution. Findings documented immediately after each session.

### Analysis Checklist (per subsystem)
For each side effect subsystem, verify:

1. **Correctness** — Does the code do what the documentation says?
2. **Atomicity** — Can partial writes corrupt state?
3. **Race conditions** — Can concurrent access cause inconsistency?
4. **Cleanup** — Are resources properly released on all exit paths?
5. **Error handling** — Do failures leave the system in a valid state?
6. **Documentation accuracy** — Do comments match behavior?
7. **Dead code** — Are there unused code paths that could cause confusion?

### Findings Format
Each issue documented as:
```
## [SUBSYSTEM] Issue: Brief title

**Severity:** Critical / High / Medium / Low
**Type:** Bug / Stale docs / Dead code / Race condition / Design flaw
**Location:** file.rs:line_range

**Problem:**
What's wrong and why it matters.

**Evidence:**
Code snippets or reasoning.

**Recommendation:**
Specific fix or removal.
```

---

## Analysis Order (Priority-Based)

### Phase 1: State Detection Core ✅ COMPLETE
These directly cause the "wrong state shown" regressions.

| Session | Subsystem | Files | Focus | Status |
|---------|-----------|-------|-------|--------|
| 1 | **Lock System** | `lock.rs` | Lock creation, verification, exact-match policy | ✅ |
| 2 | **Lock Holder** | `lock_holder.rs`, `handle.rs:spawn_lock_holder` | Lifecycle, exit detection, orphan prevention | ✅ |
| 3 | **Session State Store** | `store.rs`, `types.rs` | State transitions, atomic saves, keying | ✅ |
| 4 | **Cleanup System** | `cleanup.rs` | Stale lock removal, startup cleanup | ✅ |
| 5 | **Tombstone System** | `handle.rs` tombstone functions | Race prevention, cleanup timing | ✅ |

### Phase 2: Shell Integration ✅ COMPLETE
These cause "wrong project activated" or "shell not tracked" issues.

| Session | Subsystem | Files | Focus | Status |
|---------|-----------|-------|-------|--------|
| 6 | **Shell CWD Tracking** | `cwd.rs` | PID tracking, dead shell cleanup | ✅ |
| 7 | **Shell State Store (Swift)** | `ShellStateStore.swift` | Reading/parsing, timestamp handling | ✅ |
| 8 | **Terminal Launcher** | `TerminalLauncher.swift` | TTY matching, AppleScript reliability | ✅ |

### Phase 3: Supporting Systems ✅ COMPLETE
Lower priority but can cause subtle issues.

| Session | Subsystem | Files | Focus | Status |
|---------|-----------|-------|-------|--------|
| 9 | **Activity Files** | `handle.rs` activity functions | File tracking accuracy | ✅ |
| 10 | **Hook Configuration** | `setup.rs` | settings.json modification safety | ✅ |
| 11 | **Project Resolution** | `ActiveProjectResolver.swift` | Focus override logic | ✅ |

---

## Pre-Analysis: Known Issues from CLAUDE.md

These documented gotchas indicate areas of historical trouble:

1. **Session-based locks (v4)** — Complex keying scheme `{session_id}-{pid}` ✅ Verified correct
2. **Exact-match-only** — Recent policy change, docs may be stale ✅ Fixed in Session 1
3. **hud-hook symlink** — Must point to dev build, stale hooks create stale locks ✅ Documented
4. **Async hooks require both fields** — `async: true` AND `timeout: 30` ✅ Verified in Session 10
5. **Swift timestamp decoder** — Needs `.withFractionalSeconds` ✅ Verified in Session 7
6. **Focus override** — Only clears for active sessions ✅ Verified in Session 11

---

## Session 1 Findings

From initial read of `lock.rs`:

### Finding 1: Stale Documentation ✅ FIXED (2026-01-27)
**Severity:** Medium
**Type:** Stale docs
**Location:** `lock.rs:42-46`

**Problem:**
Module docstring claims child→parent inheritance:
> "A lock at `/project/src` makes `/project` appear active"

But code implements exact-match-only (lines 377, 414-421). This could mislead future maintainers.

**Resolution:** Fixed in commit `3d78b1b`. Documentation now correctly states exact-match-only policy.

### Finding 2: Misleading Function Name
**Severity:** Low
**Type:** Stale naming
**Location:** `lock.rs:435`

**Problem:**
`find_matching_child_lock` doesn't find child locks anymore — it only does exact matching. Name is vestige from inheritance model.

---

## Output Artifacts

All audit documents created in `.claude/docs/audit/`:

| Document | Session | Key Findings |
|----------|---------|--------------|
| `01-lock-system.md` | 1 | Stale docs fixed, function naming vestige |
| `02-lock-holder.md` | 2 | Lock holder lifecycle verified |
| `03-session-store.md` | 3 | Atomic saves, state transitions verified |
| `04-cleanup-system.md` | 4 | Startup cleanup verified |
| `05-tombstone-system.md` | 5 | Race prevention verified |
| `06-shell-cwd-tracking.md` | 6 | PID tracking, dead shell cleanup verified |
| `07-shell-state-store.md` | 7 | Timestamp handling verified |
| `08-terminal-launcher.md` | 8 | TTY matching, AppleScript reliability |
| `09-activity-files.md` | 9 | File tracking accuracy verified |
| `10-hook-configuration.md` | 10 | settings.json modification safety verified |
| `11-project-resolution.md` | 11 | Focus override logic verified, no bugs |

---

## Summary of Findings

### Issues Fixed During Audit
1. **Stale documentation in lock.rs** — Fixed in commit `3d78b1b`

### Design Validations (No Action Needed)
1. **Session-based lock keying** — Correctly implements `{session_id}-{pid}` pattern
2. **Exact-match-only policy** — Correctly prevents child→parent inheritance confusion
3. **Focus override anti-racing** — Clever mechanism to prevent timestamp racing
4. **Shell child-path matching** — Correctly differs from lock exact-match (by design)
5. **Active/passive session priority** — Working sessions beat Ready sessions

### Low-Priority Items (Optional)
1. **Function rename**: `find_matching_child_lock` → `find_lock_for_path` (vestigial name)

---

## Next Steps

1. ~~Create `docs/audit/SUMMARY.md`~~ (findings summarized above)
2. Consider renaming `find_matching_child_lock` (low priority)
3. Archive this plan as reference
