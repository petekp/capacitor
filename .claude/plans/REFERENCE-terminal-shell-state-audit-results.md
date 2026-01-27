# Terminal/Shell State Detection System Audit Results

**Status:** COMPLETED
**Audit Date:** 2026-01-26
**Auditor:** Claude Code Audit

---

## Executive Summary

The plan documentation is **highly accurate**. All major flows, line numbers, and behaviors have been verified against the actual codebase. A few minor line number shifts and one notable architectural decision (intentional) were identified.

**Key Finding:** The system is well-designed with proper separation of concerns. The recently fixed tmux client detection issue has been properly addressed.

---

## 1. TERMINAL ACTIVATION FLOW — ✅ VERIFIED

### Entry Points — All Confirmed

| Location | Documented | Actual | Status |
|----------|------------|--------|--------|
| Active projects list | `ProjectsView.swift:80` | Line 80 | ✅ |
| Paused projects section | `ProjectsView.swift:139` | Line 139 | ✅ |
| Activity panel | `ActivityPanel.swift:191` | Line 191 | ✅ |
| Dock layout | `DockLayoutView.swift:106` | Line 106 | ✅ |

### AppState.launchTerminal — ✅ Confirmed at lines 420-425

```swift
func launchTerminal(for project: Project) {
    activeProjectResolver.setManualOverride(project)  // ✅ Line 421
    activeProjectResolver.resolve()                    // ✅ Line 422
    terminalLauncher.launchTerminal(for:...)          // ✅ Line 423
    objectWillChange.send()                           // ✅ Line 424
}
```

### TerminalLauncher Decision Tree — ✅ All Branches Verified

| Branch | Documented Line | Actual Line | Status |
|--------|-----------------|-------------|--------|
| `findTmuxSessionForPath` | 140 | 140 | ✅ |
| `switchToTmuxSessionAndActivate` | 141 | 141 | ✅ |
| `findExistingShell` | 146 | 146 | ✅ |
| `launchNewTerminal` | 149 | 149 | ✅ |
| Exact path match (tmux) | 266 | 266 | ✅ |
| `hasTmuxClientAttached` | 167-185 | 167-189 | ✅ (minor shift) |
| `launchTerminalWithTmuxSession` | NEW FIX | 163, 191-213 | ✅ |

### Activation Strategy Matrix — ✅ All Strategies Verified

All strategies in `ActivationConfig.swift:155-244` match the documented behavior. The `ScenarioBehavior.defaultBehavior(for:)` function correctly dispatches to category-specific handlers.

---

## 2. SHELL STATE TRACKING FLOW — ✅ VERIFIED

### Hook Handler (hud-hook/cwd.rs) — ✅ All Steps Confirmed

| Step | Documented | Actual Line | Status |
|------|------------|-------------|--------|
| `normalize_path(path)` | Line 104 | 104 | ✅ |
| `load_state()` | Line 105 | 105 | ✅ |
| `detect_parent_app(pid)` | Line 108 | 108 | ✅ |
| `detect_tmux_context()` | In ShellEntry::new | 78-82 | ✅ |
| Create/update shells entry | Line 110-113 | 110-113 | ✅ |
| `cleanup_dead_pids()` | Line 115 | 115 | ✅ |
| `write_state_atomic()` | Line 116 | 116 | ✅ |
| `append_history()` (if changed) | Line 119 | 118-126 | ✅ |
| `maybe_cleanup_history()` | Line 128 | 128 | ✅ |
| 1% cleanup chance | Documented | Line 225 | ✅ |

### ShellStateStore.swift — ✅ All Confirmed

| Parameter | Documented | Actual | Status |
|-----------|------------|--------|--------|
| Poll interval | 500ms | Line 29: `500_000_000` ns | ✅ |
| Staleness threshold | 10 minutes | Line 32: `10 * 60` | ✅ |
| Date format | ISO8601 + fractional | Lines 66-67 | ✅ |

### Storage Format — ✅ Matches Documentation

The `~/.capacitor/shell-cwd.json` structure matches the documented JSON schema exactly.

---

## 3. FOCUS RESOLUTION LOGIC — ✅ VERIFIED

### Priority Decision Tree (ActiveProjectResolver.swift) — ✅ Confirmed

| Priority | Documented | Actual Lines | Status |
|----------|------------|--------------|--------|
| P0: Manual Override | Lines 44-65 | 44-65 | ✅ |
| P1: Claude Session | Lines 70-74 | 70-74 | ✅ |
| P2: Shell CWD | Lines 79-83 | 79-83 | ✅ |
| Fallback: nil | Lines 85-86 | 85-86 | ✅ |

### Override Clear Logic — ✅ Critically Verified

The plan correctly documents the fix at lines 48-56:
- Override only clears when shell navigates to a project WITH `isLocked == true`
- This prevents timestamp racing between sessions

### Notable Finding: Intentional Path Matching Asymmetry

| Context | Matching Behavior |
|---------|-------------------|
| Lock resolution (`lock.rs`) | **Exact match only** |
| Shell→Project (`projectContaining`) | **Exact OR child match** |

This is **intentional and correct**:
- Locks: Monorepo independence (child sessions don't affect parent)
- Shell: User navigating to `/project/src` should highlight the `/project` card

---

## 4. STALENESS THRESHOLDS — ✅ VERIFIED

| Threshold | Documented | Actual | Location |
|-----------|------------|--------|----------|
| Active state (Working/Waiting) | 30 seconds | 30 seconds | `types.rs:150` |
| Records without locks | 5 minutes | 5 minutes | `types.rs:144` |
| Shell entries | 10 minutes | 10 minutes | `ShellStateStore.swift:32` |

**Note:** Compacting state is NOT subject to 30-second staleness (documented and verified at `types.rs:229-231`). This is correct because PreCompact fires once and compaction can take 30+ seconds.

---

## 5. EDGE CASES — VERIFICATION STATUS

### Currently Handled — ✅ All Confirmed

| Edge Case | Verification |
|-----------|--------------|
| Concurrent sessions same directory | `lock.rs:479-574` — Session-based locks `{session_id}-{pid}.lock` |
| Monorepo packages | `lock.rs:401-407`, `resolver.rs:221-224` — Exact match only |
| PID reuse after crash | `lock.rs:183-204` — `is_pid_alive_verified()` with process start time |
| Long-running text generation | `resolver.rs:160-177` — Lock existence trusted over timestamp |
| User interruption (Escape) | `types.rs:146-150` — 30-second staleness to Ready |
| Tmux client attached | `TerminalLauncher.swift:155` — `hasTmuxClientAttached()` |

### Recently Fixed — ✅ Both Verified

| Fix | Location | Status |
|-----|----------|--------|
| Tmux session exists, NO client | `TerminalLauncher.swift:161-163` → `launchTerminalWithTmuxSession` | ✅ |
| Override clear for inactive projects | `ActiveProjectResolver.swift:52-54` — `isLocked` check | ✅ |

### Silent Failure Points — Analysis

| Failure Point | Current Behavior | Risk Assessment |
|---------------|------------------|-----------------|
| TTY doesn't match terminal | AppleScript returns "not found", falls through | **Medium** — Could add user feedback |
| Process not running | `findRunningApp` returns nil, falls through | **Low** — Falls to priority order |
| tmux session gone | `2>/dev/null` swallows error | **Low** — Falls through gracefully |
| IDE CLI not in PATH | `try?` at line 500 swallows error | **Medium** — User gets no feedback |
| kitty @ unavailable | Returns `true` anyway (line 426-427) | **Medium** — Misleading success |

---

## 6. FILES REFERENCE — ✅ ALL ACCURATE

All file references in the documentation are accurate and point to the correct locations.

---

## 7. RECOMMENDATIONS

### No Immediate Action Required

The system is working correctly. All documented behaviors match the implementation.

### Future Improvements (Low Priority)

1. **Add feedback for silent failures**: When activation strategies fail silently, consider surfacing this to the user or logging it for debugging.

2. **kitty @ protocol check**: The `activateKittyRemote` function returns `true` unconditionally. Consider verifying the command actually succeeded.

3. **Test coverage for edge cases**: The plan identifies gaps not in the test matrix:
   - Tmux session exists, client in different terminal app
   - Multiple tmux clients attached
   - IDE integrated terminal after window close

---

## Conclusion

**The audit is PASSED.** The plan documentation accurately reflects the codebase. The system architecture is sound, with proper separation of concerns between:

- **Swift (UI Layer)**: Project cards, activation strategies, shell state polling
- **Rust (Core Logic)**: Lock management, state resolution, hook handling

The recently fixed edge cases (tmux without client, override clearing) have been properly implemented.
