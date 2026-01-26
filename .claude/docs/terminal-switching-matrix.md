# Terminal Switching Test Matrix

This document maps out all scenarios for the "click project → activate terminal" feature.

## Dimensions

| Dimension | Values |
|-----------|--------|
| **Terminal App** | iTerm2, Ghostty, Terminal.app, Warp, kitty, Alacritty |
| **Shell Context** | Direct, tmux, screen |
| **parent_app** | Correct, Wrong, nil |
| **Multi-Terminal** | Single app, Multiple apps |
| **Tabs** | Single, Multiple |

## Test Scenarios

### Legend
- ✅ Works correctly
- ⚠️ Partial (activates app, wrong/no tab)
- ❌ Broken (wrong behavior)
- ❓ Untested
- N/A Not applicable

---

## Single Terminal App Scenarios

### iTerm2

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 1 | Direct shell | 1 tab | nil | Activate iTerm | ✅ | |
| 2 | Direct shell | 2+ tabs, project in tab 2 | nil | Activate iTerm, select tab 2 | ✅ | |
| 3 | Direct shell | 2+ tabs, project in tab 2 | "iTerm2" | Activate iTerm, select tab 2 | ❓ | |
| 4 | tmux session | 1 tab | "tmux" | Activate iTerm w/ tmux | ❌ | Opens new terminal |
| 5 | tmux session | 2+ tabs | "tmux" | Activate iTerm, switch tmux session | ❌ | Opens new terminal |
| 6 | tmux + direct | 2 tabs (1 tmux, 1 direct) | mixed | Prefer direct shell tab | ✅ | By design |

### Ghostty

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 7 | Direct shell | 1 tab | nil | Activate Ghostty | ⚠️ | May try iTerm first if running |
| 8 | Direct shell | 1 tab | "Ghostty" | Activate Ghostty | ✅ | |
| 9 | Direct shell | 2+ tabs | nil | Activate Ghostty, select tab | ⚠️ | No tab selection API |
| 10 | Direct shell | 2+ tabs | "Ghostty" | Activate Ghostty, select tab | ⚠️ | No tab selection API |
| 11 | tmux session | any | "tmux" | Activate Ghostty w/ tmux | ❌ | Opens new terminal |

### Terminal.app

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 12 | Direct shell | 1 tab | nil | Activate Terminal | ⚠️ | Only if iTerm not running |
| 13 | Direct shell | 2+ tabs | nil | Activate Terminal, select tab | ⚠️ | Only if iTerm not running |
| 14 | Direct shell | 2+ tabs | "Terminal" | Activate Terminal, select tab | ❓ | |
| 15 | tmux session | any | "tmux" | Activate Terminal w/ tmux | ❌ | Opens new terminal |

### Warp

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 16 | Direct shell | 1 tab | nil | Activate Warp | ⚠️ | Falls to priority order |
| 17 | Direct shell | 1 tab | "Warp" | Activate Warp | ❓ | |
| 18 | Direct shell | 2+ tabs | any | Activate Warp, select tab | ⚠️ | No tab selection API |

### kitty

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 19 | Direct shell | 1 tab | nil | Activate kitty | ⚠️ | Falls to priority order |
| 20 | Direct shell | 1 tab | "kitty" | Activate kitty | ❓ | |
| 21 | Direct shell | 2+ tabs | any | Activate kitty, select tab | ⚠️ | Has remote control API |

### Alacritty

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 22 | Direct shell | 1 window | nil | Activate Alacritty | ⚠️ | Falls to priority order |
| 23 | Direct shell | 1 window | "Alacritty" | Activate Alacritty | ❓ | |
| 24 | Note: Alacritty has no tabs | | | | N/A | Multiple windows only |

---

## Multiple Terminal Apps Scenarios

| # | Terminals Open | Project In | parent_app | Expected | Current | Notes |
|---|----------------|------------|------------|----------|---------|-------|
| 25 | iTerm + Ghostty | iTerm | nil | Activate iTerm | ⚠️ | Works by accident (iTerm checked first) |
| 26 | iTerm + Ghostty | Ghostty | nil | Activate Ghostty | ❌ | Activates iTerm (wrong!) |
| 27 | iTerm + Ghostty | Ghostty | "Ghostty" | Activate Ghostty | ✅ | |
| 28 | iTerm + Terminal | iTerm | nil | Activate iTerm | ✅ | iTerm checked first |
| 29 | iTerm + Terminal | Terminal | nil | Activate Terminal | ❌ | Activates iTerm |
| 30 | Ghostty + Terminal | Ghostty | nil | Activate Ghostty | ❌ | Activates Terminal |
| 31 | 3+ terminals | varies | nil | Activate correct one | ❌ | Guessing game |

---

## Edge Cases

| # | Scenario | Expected | Current | Notes |
|---|----------|----------|---------|-------|
| 32 | No terminal open with project | Open new terminal | ✅ | Falls through to bash script |
| 33 | Shell CWD is subdir of project | Activate that terminal | ✅ | Handled in findShellInProject |
| 34 | Multiple shells same project | Activate most recent? | ❓ | Uses first match |
| 35 | Stale shell entry (process dead) | Skip, find live shell | ✅ | kill(pid,0) check |
| 36 | TTY reused by different shell | Don't match wrong session | ✅ | PID check handles this |
| 37 | IDE integrated terminal (Cursor) | Activate Cursor? | ⚠️ | parent_app="cursor" |
| 38 | VS Code integrated terminal | Activate VS Code? | ⚠️ | parent_app detection? |
| 39 | SSH session | Don't try to activate | ❓ | How to detect? |
| 40 | Screen session (not tmux) | Similar to tmux | ❌ | Not handled |

---

## Priority Improvements

Based on matrix analysis:

### High Impact (Many scenarios affected)
1. **Fix parent_app=nil with multiple terminals** (#26, 29, 30, 31)
   - Root cause: Guessing terminal when parent_app unknown
   - Fix: Improve Rust hook detection OR query terminals for TTY ownership

2. **Handle tmux sessions** (#4, 5, 11, 15)
   - Root cause: Skipping tmux shells entirely
   - Fix: Find terminal containing tmux, use tmux switch-client

### Medium Impact
3. **Add tab selection for Ghostty** (#9, 10)
   - Depends on Ghostty's AppleScript/API support

4. **Add tab selection for kitty** (#21)
   - kitty has `kitty @ focus-window` remote control

### Low Impact (Rare scenarios)
5. **Handle screen sessions** (#40)
6. **IDE terminal handling** (#37, 38)

---

## Testing Protocol

To verify each scenario:

1. Set up the terminal configuration described
2. Ensure shell hook has reported CWD (`cat ~/.capacitor/shell-cwd.json`)
3. Click the project in Capacitor
4. Verify: correct app activates, correct tab selected
5. Record actual behavior in "Current" column

## Related Files

- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` — Activation logic
- `core/hud-hook/src/cwd.rs` — Shell state tracking & parent_app detection
- `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift` — Swift state reader
