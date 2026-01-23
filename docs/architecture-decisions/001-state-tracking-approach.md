# ADR-001: State Tracking Approach

**Status:** Accepted
**Date:** 2026-01-11
**Context:** How to track Claude's "thinking" state for the HUD display

## Decision

**Use hooks for local TUI sessions, reserve daemon for future remote/mobile use.**

## Context

We investigated multiple approaches to track Claude's thinking state:

1. **Hooks** (UserPromptSubmit, Stop, PostToolUse) - Event-based, works with Claude's TUI
2. **Daemon with `--output-format stream-json`** - Message-based, precise but replaces TUI
3. **Fetch interception** - Patches global.fetch, unreliable due to undici

We also studied Happy Engineering's implementation which uses a **mode-switching loop**:
- Local mode: Interactive TUI with fetch interception
- Remote mode: Stream-json with custom Ink UI
- User switches between modes with double-spacebar

## Analysis

### Hooks Approach
```
User runs claude → Hooks fire → State file updated → Swift HUD reads
```

**Pros:**
- Works with Claude's native TUI
- Non-invasive (user keeps normal workflow)
- Already implemented and working

**Cons:**
- Event-based (less precise than message-level)
- Small gaps between events (milliseconds)

### Daemon Approach
```
User runs hud-claude-daemon → Spawns Claude with stream-json → Parses messages → State file
```

**Pros:**
- Precise state tracking from message types
- Better for programmatic use

**Cons:**
- Replaces Claude's TUI with JSON output
- Requires custom UI or programmatic consumption
- More complex architecture

### Why Not Both Simultaneously?

Claude's `--output-format stream-json` **replaces** the TUI entirely. You cannot have both Claude's interactive TUI and structured JSON output from the same process.

Happy solves this by mode-switching, but that adds complexity and requires building a custom terminal UI.

## Decision Rationale

For the current phase of Claude HUD development:

1. **Primary use case is local desktop** - Users work in terminal, Swift HUD shows status
2. **Hooks are "good enough"** - The precision difference is milliseconds, imperceptible in HUD
3. **Daemon adds complexity without immediate benefit** - No mobile client yet
4. **Keep it simple** - Complexity can be added when needed

## Consequences

### What We're Doing

1. **Local sessions**: Use regular `claude` command with hooks for state tracking
2. **State file**: `~/.capacitor/sessions.json` updated by hooks
3. **Lock files**: `~/.capacitor/sessions/{hash}.lock/` created by hook script
4. **Swift HUD**: Reads both to resolve current state

## File Structure

```
~/.capacitor/               # Capacitor namespace (we own this)
├── sessions.json           # State file written by hooks
├── config.json             # Pinned projects, settings
└── projects/{encoded}/     # Per-project ideas, order

~/.claude/                  # Claude Code namespace (read-only for Capacitor)
├── projects/               # Session transcripts
└── settings.json           # Contains hook configuration pointing to ~/.local/bin/hud-hook
```

## References

- Happy CLI implementation: `~/Code/happy-cli/src/claude/`
- Happy's mode-switching loop: `loop.ts`, `claudeLocalLauncher.ts`, `claudeRemoteLauncher.ts`
- Claude Code `--output-format stream-json` documentation
