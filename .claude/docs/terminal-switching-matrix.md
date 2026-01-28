# Terminal Switching Test Matrix

This document maps out all scenarios for the "click project → activate terminal" feature.

## Quick Reference: Tab Selection Support

| Terminal | Tab Selection | Method | Notes |
|----------|--------------|--------|-------|
| iTerm2 | ✅ Full | AppleScript | Query sessions by TTY, select window/tab |
| Terminal.app | ✅ Full | AppleScript | Query by TTY, select tab |
| kitty | ✅ Full | `kitty @` | Requires `allow_remote_control yes` |
| Ghostty | ❌ None | — | No external API (as of 2024) |
| Warp | ❌ None | — | No AppleScript/CLI API |
| Alacritty | N/A | — | No tabs, windows only |
| Cursor/VS Code | ⚠️ Window only | CLI | `cursor /path` activates window, no terminal panel focus |

**Fallback behavior:** When tab selection isn't available, we activate the app (brings all windows forward) but can't select the specific tab containing the project.

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

**Note:** Ghostty has no external API for window/tab selection (as of 2025). We use a window-count strategy:
- **1 window:** Activate app (it's the only one)
- **0 or multiple windows:** Launch new terminal (can't pick the right one)

| # | Context | Windows | parent_app | Expected | Current | Notes |
|---|---------|---------|------------|----------|---------|-------|
| 7 | Direct shell | 1 | nil | Activate Ghostty | ✅ | Window count = 1, safe to activate |
| 8 | Direct shell | 1 | "Ghostty" | Activate Ghostty | ✅ | |
| 9 | Direct shell | 2+ | nil | Activate Ghostty | ⚠️ | No window selection - activates app, may be wrong window |
| 10 | Direct shell | 2+ | "Ghostty" | Activate Ghostty | ⚠️ | No window selection - activates app, may be wrong window |
| 11 | tmux session | 1 | "tmux" | Activate Ghostty, switch session | ✅ | Window count = 1, activate + tmux switch-client |
| 11b | tmux session | 2+ | "tmux" | Launch new terminal | ✅ | Window count > 1, launch new to guarantee correct session |

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

## IDE Integrated Terminal Scenarios

IDEs like Cursor and VS Code have integrated terminals. When `parent_app` is detected as an IDE, we need different activation logic than standalone terminal apps.

### Cursor

| # | Context | Windows | parent_app | Expected | Current | Notes |
|---|---------|---------|------------|----------|---------|-------|
| 41 | Integrated terminal | 1 window | "cursor" | Activate Cursor | ❌ | Falls through, activates random terminal |
| 42 | Integrated terminal | 2+ windows | "cursor" | Activate correct Cursor window | ❌ | No window selection |
| 43 | Integrated + tmux | 1 window | "cursor" | Activate Cursor, switch tmux | ⚠️ | tmux switches, but Cursor not activated |
| 44 | Integrated + tmux | 2+ windows | "cursor" | Activate correct window, switch tmux | ❌ | Neither works |
| 45 | Integrated terminal | any | "cursor" | Focus terminal panel | ❌ | No terminal focus support |

### VS Code

| # | Context | Windows | parent_app | Expected | Current | Notes |
|---|---------|---------|------------|----------|---------|-------|
| 46 | Integrated terminal | 1 window | "vscode" | Activate VS Code | ❌ | Falls through, activates random terminal |
| 47 | Integrated terminal | 2+ windows | "vscode" | Activate correct VS Code window | ❌ | No window selection |
| 48 | Integrated + tmux | 1 window | "vscode" | Activate VS Code, switch tmux | ⚠️ | tmux switches, but VS Code not activated |
| 49 | Integrated + tmux | 2+ windows | "vscode" | Activate correct window, switch tmux | ❌ | Neither works |
| 50 | Integrated terminal | any | "vscode" | Focus terminal panel | ❌ | No terminal focus support |

### IDE + External Terminal

| # | Scenario | parent_app | Expected | Current | Notes |
|---|----------|------------|----------|---------|-------|
| 51 | User has Cursor open + iTerm shell for same project | "iterm2" | Activate iTerm (not Cursor) | ✅ | Correctly uses parent_app |
| 52 | User has Cursor open + iTerm shell for same project | nil | Activate iTerm (TTY discovery) | 🔄 | Phase 1 handles this |
| 53 | Cursor for Project A, iTerm for Project B | varies | Activate correct app per project | ✅ | parent_app per shell |

### Implementation Notes

**CLI-based window activation:**
- `cursor /path/to/project` — Opens or focuses window for that project
- `code /path/to/project` — Same for VS Code
- This handles multi-window scenarios (#42, #44, #47, #49)

**Terminal panel focus options:**
1. AppleScript keystroke `Ctrl+\`` — Toggles terminal (risky: might close)
2. No external API to run `workbench.action.terminal.focus`
3. User could bind custom key, but we can't assume this

**Detection already works:**
- `parent_app="cursor"` detected via process tree (cwd.rs lines 343-344)
- `parent_app="vscode"` detected similarly (lines 345-347)

---

## Edge Cases

| # | Scenario | Expected | Current | Notes |
|---|----------|----------|---------|-------|
| 32 | No terminal open with project | Open new terminal | ✅ | Falls through to bash script |
| 33 | Shell CWD is subdir of project | Activate that terminal | ✅ | Handled in findShellInProject |
| 34 | Multiple shells same project | Activate most recent? | ❓ | Uses first match |
| 35 | Stale shell entry (process dead) | Skip, find live shell | ✅ | kill(pid,0) check |
| 36 | TTY reused by different shell | Don't match wrong session | ✅ | PID check handles this |
| 37 | IDE integrated terminal (Cursor) | See IDE section (#41-45) | — | Moved to dedicated section |
| 38 | VS Code integrated terminal | See IDE section (#46-50) | — | Moved to dedicated section |
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

### Medium-High Impact (Growing use case)
5. ⏳ **IDE integrated terminal support** (#41-50)
   - Root cause: `TerminalApp(fromParentApp:)` returns nil for "cursor"/"vscode"
   - Fix: Phase 4 — Use IDE CLI to activate correct window (`cursor /path/to/project`)
   - Optional: Send keystroke to focus terminal panel (toggle risk)
   - Status: **Not started** — Detection works, activation doesn't

### Low Impact (Rare scenarios)
6. **Handle screen sessions** (#40)

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

**Phase 3b: Ghostty Window-Count Strategy** — ✅ Complete
- Ghostty has no API for window/tab selection (confirmed as of Jan 2025)
- Added `countGhosttyWindows()` using Accessibility API (AXUIElement)
- For tmux activation with Ghostty:
  - 1 window: Activate app + `tmux switch-client` (safe, it's the only window)
  - 0 or 2+ windows: Launch new terminal with tmux attach (guarantees correct session)
- **Session launch cache** (prevents duplicate windows on rapid clicks):
  - `recentlyLaunchedGhosttySessions` tracks launches for 30 seconds
  - If clicked again within 30s, just activates Ghostty + switches tmux client
  - Cache auto-cleans expired entries on each activation check
- **AppleScript activation** (critical fix):
  - `NSRunningApplication.activate()` can silently fail when SwiftUI windows steal focus
  - Use AppleScript `tell application "Ghostty" to activate` instead for reliable activation
- Documented decision: Reliable activation > avoiding duplicate windows

**Phase 4: IDE Integrated Terminal Support** — ⏳ Not Started
- Goal: Activate correct IDE window when `parent_app` is "cursor" or "vscode"
- Approach:
  1. Detect IDE via existing `parent_app` field (already works)
  2. Run `cursor /path/to/project` or `code /path/to/project` to focus correct window
  3. (Optional) Send keystroke to focus terminal panel
- Challenges:
  - Terminal focus: `Ctrl+\`` toggles (might close terminal)
  - No external API for `workbench.action.terminal.focus`
- Files to modify:
  - `TerminalLauncher.swift` — Add IDE case handling in `activateExistingTerminal()`
  - Possibly add `IDEApp` enum or extend `TerminalApp`

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
