# Decisions

## Decision 1: Single-method protocol at the tab-focus boundary

**Date:** 2026-03-04
**Status:** accepted

The `TerminalActivator` protocol has a single method: `focusSession(sessionName:tty:) async -> Bool`. This targets the exact boundary where terminals genuinely diverge (tab/session focus), while keeping everything else universal (app activation, window raise, tmux switching).

**Why:** Gen 1-2 abstractions failed because they were too broad (multi-method strategy protocols, adapter layers). The divergence point is narrow — only tab focus differs per terminal.

## Decision 2: AX for Ghostty, AppleScript for iTerm2/Terminal.app

**Date:** 2026-03-04
**Status:** accepted

Each terminal requires a different automation channel based on what it exposes:
- Ghostty: AX only (no AppleScript dictionary, no IPC on macOS)
- iTerm2: AppleScript only (AX doesn't expose individual tabs meaningfully)
- Terminal.app: AppleScript (more precise via TTY matching)

**Why:** This is a hard constraint of terminal capabilities, not a design choice.

## Decision 3: Universal app activation via NSRunningApplication

**Date:** 2026-03-04
**Status:** accepted

Replace `tell application "X" to activate` (~300-2100ms) with `NSRunningApplication.activate()` (~5ms). The existing `GhosttyAXReader.activateOwningApplication()` already uses this pattern successfully (line 157-170).

**Why:** 40-400x faster. The existing `activateAppByName()` comment about NSRunningApplication failing is stale — the AX reader proves the pattern works when combined with window raise.
