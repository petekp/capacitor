# Side Effects Analysis Plan

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

### Phase 1: State Detection Core
These directly cause the "wrong state shown" regressions.

| Session | Subsystem | Files | Focus |
|---------|-----------|-------|-------|
| 1 | **Lock System** | `lock.rs` | Lock creation, verification, exact-match policy |
| 2 | **Lock Holder** | `lock_holder.rs`, `handle.rs:spawn_lock_holder` | Lifecycle, exit detection, orphan prevention |
| 3 | **Session State Store** | `store.rs`, `types.rs` | State transitions, atomic saves, keying |
| 4 | **Cleanup System** | `cleanup.rs` | Stale lock removal, startup cleanup |
| 5 | **Tombstone System** | `handle.rs` tombstone functions | Race prevention, cleanup timing |

### Phase 2: Shell Integration
These cause "wrong project activated" or "shell not tracked" issues.

| Session | Subsystem | Files | Focus |
|---------|-----------|-------|-------|
| 6 | **Shell CWD Tracking** | `cwd.rs` | PID tracking, dead shell cleanup |
| 7 | **Shell State Store (Swift)** | `ShellStateStore.swift` | Reading/parsing, timestamp handling |
| 8 | **Terminal Launcher** | `TerminalLauncher.swift` | TTY matching, AppleScript reliability |

### Phase 3: Supporting Systems
Lower priority but can cause subtle issues.

| Session | Subsystem | Files | Focus |
|---------|-----------|-------|-------|
| 9 | **Activity Files** | `handle.rs` activity functions | File tracking accuracy |
| 10 | **Hook Configuration** | `setup.rs` | settings.json modification safety |
| 11 | **Project Resolution** | `ActiveProjectResolver.swift` | Focus override logic |

---

## Pre-Analysis: Known Issues from CLAUDE.md

These documented gotchas indicate areas of historical trouble:

1. **Session-based locks (v4)** — Complex keying scheme `{session_id}-{pid}`
2. **Exact-match-only** — Recent policy change, docs may be stale
3. **hud-hook symlink** — Must point to dev build, stale hooks create stale locks
4. **Async hooks require both fields** — `async: true` AND `timeout: 30`
5. **Swift timestamp decoder** — Needs `.withFractionalSeconds`
6. **Focus override** — Only clears for active sessions

---

## Session 1 Preliminary Findings

From initial read of `lock.rs` (before user interrupted):

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

## Execution Plan

### For Each Session:
1. Read the primary file(s) completely
2. Trace all callers of public functions
3. Trace all callees (dependencies)
4. Document findings using the format above
5. Commit findings to `docs/audit/` before next session

### Output Artifacts:
- `docs/audit/01-lock-system.md`
- `docs/audit/02-lock-holder.md`
- `docs/audit/03-session-store.md`
- ... etc.

### Final Synthesis:
After all sessions complete, create:
- `docs/audit/SUMMARY.md` — Cross-cutting issues, recommended fix order
- GitHub issues for each actionable finding

---

## Ready to Begin

Start with **Session 1: Lock System** when ready. Command:
```
Analyze lock.rs in isolation. Document all findings per the analysis checklist.
```
