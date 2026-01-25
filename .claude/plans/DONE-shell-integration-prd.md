# Shell Integration: Product Requirements

**Status:** Done
**Completed:** January 2026
**See also:** DONE-shell-integration-engineering.md (technical spec)

## Summary

Product vision for shell integration: transform Capacitor from a reactive session monitor into an ambient development companion that always knows where you're working.

## Problem Solved

**Before:** Capacitor only knew about work during Claude sessions or tmux usage.

**After:** Capacitor tracks your active project across any terminal by listening to shell CWD changes.

## Key Features Shipped

### Tier 1: Core (v1.0) ✓

- **Always-accurate project highlighting** — Right card highlights when you `cd`
- **Works everywhere** — iTerm, Terminal, Ghostty, VSCode, Cursor, etc.
- **Parent app awareness** — Knows if you're in Cursor vs iTerm

### Tier 2: Intelligence (v1.1) — Future

- Session context inheritance
- Project return briefings
- Time tracking

### Tier 3: Proactive AI (v2.0) — Future

- Contextual nudges ("Exploring my-project? Start Claude to help")
- Predictive session preparation

## User Setup

1. Setup card appears in app
2. User copies shell snippet to ~/.zshrc (or bash/fish equivalent)
3. Restarts terminal
4. Verification: cd to project, see highlight

## Privacy

- Opt-in (user adds snippet)
- Local-only (never transmitted)
- Transparent (user can inspect files)
- Deletable (clear history anytime)
