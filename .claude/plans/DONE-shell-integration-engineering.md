# Shell Integration

**Status:** Done
**Completed:** January 2026
**See also:** DONE-shell-integration-prd.md (product requirements)

## Summary

Shell precmd hooks push CWD changes to Capacitor, enabling ambient project awareness in any terminal—not just when Claude is running.

## Core Insight

Every `cd` is a signal of intent. Instead of polling tmux and guessing, the shell tells us exactly when and where you navigate.

## What Was Built

**`hud-hook cwd` Subcommand** (`core/hud-hook/src/cwd.rs`)
- Called by shell precmd hook
- Writes to `~/.capacitor/shell-cwd.json`
- Appends to `~/.capacitor/shell-history.jsonl`
- Detects parent app (Cursor, VSCode, iTerm, etc.)
- Cleans up dead PIDs
- Target: <15ms execution

**ShellStateStore** (`ShellStateStore.swift`)
- Reads shell-cwd.json with 500ms polling
- Provides `mostRecentShell` for resolution

**ActiveProjectResolver** (`ActiveProjectResolver.swift`)
- Single source of truth for active project
- Priority: Claude session > most recent shell CWD

**Shell Snippets** (user adds to shell config)
```bash
# zsh (~/.zshrc)
_capacitor_precmd() {
  "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$TTY" 2>/dev/null &!
}
precmd_functions+=(_capacitor_precmd)
```

## Data Files

| File | Purpose |
|------|---------|
| `~/.capacitor/shell-cwd.json` | Current state (active shells + CWD) |
| `~/.capacitor/shell-history.jsonl` | Append-only CWD change history (30-day retention) |

## What Was Deleted

- `TerminalTracker.swift` (tmux polling)
- Process tree walking for terminal detection
- Fuzzy session name matching

## Files

| Component | Location |
|-----------|----------|
| Hook subcommand | `core/hud-hook/src/cwd.rs` |
| Shell state store | `ShellStateStore.swift` |
| Project resolver | `ActiveProjectResolver.swift` |
| Setup instructions | SetupCard in app |
