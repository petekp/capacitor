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
- 🔄 Implemented (needs testing)
- N/A Not applicable

---

## Single Terminal App Scenarios

### iTerm2

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 1 | Direct shell | 1 tab | nil | Activate iTerm | ✅ | |
| 2 | Direct shell | 2+ tabs, project in tab 2 | nil | Activate iTerm, select tab 2 | ✅ | |
| 3 | Direct shell | 2+ tabs, project in tab 2 | "iTerm2" | Activate iTerm, select tab 2 | ❓ | |
| 4 | tmux session | 1 tab | "tmux" | Activate iTerm w/ tmux | 🔄 | Phase 2: Uses tmux_client_tty for host terminal discovery |
| 5 | tmux session | 2+ tabs | "tmux" | Activate iTerm, switch tmux session | 🔄 | Phase 2: Runs `tmux switch-client -t <session>` |
| 6 | tmux + direct | 2 tabs (1 tmux, 1 direct) | mixed | Prefer direct shell tab | ✅ | By design |

### Ghostty

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 7 | Direct shell | 1 tab | nil | Activate Ghostty | 🔄 | Phase 1: TTY discovery queries terminals |
| 8 | Direct shell | 1 tab | "Ghostty" | Activate Ghostty | ✅ | |
| 9 | Direct shell | 2+ tabs | nil | Activate Ghostty, select tab | ⚠️ | No tab selection API |
| 10 | Direct shell | 2+ tabs | "Ghostty" | Activate Ghostty, select tab | ⚠️ | No tab selection API |
| 11 | tmux session | any | "tmux" | Activate Ghostty w/ tmux | 🔄 | Phase 2: Uses tmux_client_tty + TTY discovery |

### Terminal.app

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 12 | Direct shell | 1 tab | nil | Activate Terminal | 🔄 | Phase 1: TTY discovery queries both iTerm & Terminal |
| 13 | Direct shell | 2+ tabs | nil | Activate Terminal, select tab | 🔄 | Phase 1: TTY discovery + AppleScript tab selection |
| 14 | Direct shell | 2+ tabs | "Terminal" | Activate Terminal, select tab | ❓ | |
| 15 | tmux session | any | "tmux" | Activate Terminal w/ tmux | 🔄 | Phase 2: Uses tmux_client_tty + TTY discovery |

### Warp

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 16 | Direct shell | 1 tab | nil | Activate Warp | ⚠️ | Falls to priority order |
| 17 | Direct shell | 1 tab | "Warp" | Activate Warp | ❓ | |
| 18 | Direct shell | 2+ tabs | any | Activate Warp, select tab | ⚠️ | No tab selection API |

### kitty

| # | Context | Tabs | parent_app | Expected | Current | Notes |
|---|---------|------|------------|----------|---------|-------|
| 19 | Direct shell | 1 tab | nil | Activate kitty | 🔄 | Phase 1: TTY discovery (falls back if kitty not queryable) |
| 20 | Direct shell | 1 tab | "kitty" | Activate kitty | 🔄 | Phase 3: `kitty @ focus-window --match pid:` |
| 21 | Direct shell | 2+ tabs | any | Activate kitty, select tab | 🔄 | Phase 3: Uses shell PID for window focus |

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
| 25 | iTerm + Ghostty | iTerm | nil | Activate iTerm | 🔄 | Phase 1: TTY discovery finds correct owner |
| 26 | iTerm + Ghostty | Ghostty | nil | Activate Ghostty | 🔄 | Phase 1: TTY discovery queries both terminals |
| 27 | iTerm + Ghostty | Ghostty | "Ghostty" | Activate Ghostty | ✅ | |
| 28 | iTerm + Terminal | iTerm | nil | Activate iTerm | 🔄 | Phase 1: TTY discovery |
| 29 | iTerm + Terminal | Terminal | nil | Activate Terminal | 🔄 | Phase 1: TTY discovery queries both terminals |
| 30 | Ghostty + Terminal | Ghostty | nil | Activate Ghostty | 🔄 | Phase 1: TTY discovery (Ghostty not queryable, falls back) |
| 31 | 3+ terminals | varies | nil | Activate correct one | 🔄 | Phase 1: Queries iTerm + Terminal, others by priority |

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
1. ✅ **Fix parent_app=nil with multiple terminals** (#26, 29, 30, 31)
   - Root cause: Guessing terminal when parent_app unknown
   - Fix: Phase 1 — TTY discovery via AppleScript queries to iTerm/Terminal
   - Status: **Implemented** — Needs manual testing

2. ✅ **Handle tmux sessions** (#4, 5, 11, 15)
   - Root cause: Skipping tmux shells entirely
   - Fix: Phase 2 — Capture tmux_session + tmux_client_tty in hook, use `tmux switch-client`
   - Status: **Implemented** — Needs manual testing

### Medium Impact
3. ⏳ **Add tab selection for Ghostty** (#9, 10)
   - Depends on Ghostty's AppleScript/API support
   - Status: Not addressable until Ghostty exposes tab API

4. ✅ **Add tab selection for kitty** (#21)
   - Fix: Phase 3 — `kitty @ focus-window --match pid:<shell_pid>`
   - Status: **Implemented** — Needs manual testing (requires `allow_remote_control yes`)

### Low Impact (Rare scenarios)
5. **Handle screen sessions** (#40)
6. **IDE terminal handling** (#37, 38)

---

## Implementation Status

**Phase 1: TTY-Based Terminal Discovery** — ✅ Complete
- Added `discoverTerminalOwningTTY(tty:)` in `TerminalLauncher.swift`
- Queries iTerm2 and Terminal.app via AppleScript to find TTY owner
- Falls back to priority order if discovery fails (e.g., Ghostty)

**Phase 2: Tmux Session Support** — ✅ Complete
- Added `tmux_session` and `tmux_client_tty` fields to `ShellEntry` (Rust + Swift)
- Hook detects tmux context via `tmux display-message -p '#S'` and `tmux list-clients`
- `TerminalLauncher` uses `tmux_client_tty` for host terminal discovery
- Runs `tmux switch-client -t <session>` after activating host terminal

**Phase 3: kitty Remote Control** — ✅ Complete
- Added `activateKittyWindow(shellPid:)` in `TerminalLauncher.swift`
- Uses `kitty @ focus-window --match pid:<pid>` for tab selection
- Requires user to have `allow_remote_control yes` in kitty config

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
