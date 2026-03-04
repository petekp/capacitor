# Charter: Terminal Abstraction Layer

## Mission

Extract Ghostty-specific terminal activation from the generic orchestrator (`TerminalLauncher`) into a pluggable `TerminalActivator` protocol, then add iTerm2 and Terminal.app implementations.

## Invariants

1. All existing tests pass at every slice boundary
2. Ghostty activation behavior is identical (AX retry timing, tab matching, window raise fallback)
3. No user-facing regression — click project card still focuses correct terminal tab
4. `swift build` compiles clean at every slice boundary

## Non-Goals

- Rewriting GhosttyAXReader internals (it works; GhosttyActivator calls it as-is)
- Rewriting tmux orchestration (it's terminal-agnostic already)
- Supporting terminals beyond Ghostty/iTerm2/Terminal.app in this migration
- Adding Rust-side changes (ParentApp enum already has the variants we need)

## Guardrails

- Guard script (`scripts/ci/terminal-abstraction-guard.sh`) enforces ratchet budgets
- Each slice deletes replaced code in the same change (no vestigial code)
- Denylist patterns prevent reintroduction of removed names

## Translation Guide

| Old (TerminalLauncher) | New | Notes |
|---|---|---|
| `isGhosttyRunningInternal()` | `TerminalActivation.isRunning(bundleId:)` | Universal, works for any terminal |
| `activateAppByName("Ghostty")` | `TerminalActivation.activateApp(bundleId:)` | NSRunningApplication, ~5ms vs 300-2100ms |
| `activateGhosttyWithAXRouting(...)` | `activator.focusSession(sessionName:tty:)` | Protocol dispatch per terminal |
| `resolveGhosttyAXRouting(...)` | Internal to `GhosttyActivator` | No longer on TerminalLauncher |
| `GhosttyAXRoutingResolution` enum | Internal to `GhosttyActivator` | No longer on TerminalLauncher |
| `open -a Ghostty.app` | `open -a \(activator.appName).app` | Parameterized by activator |
| `ghosttyWindowReader` in TerminalLauncher init | Owned by `GhosttyActivator` | Removed from orchestrator |
| `tell application "X" to activate` | `NSRunningApplication.activate()` | Universal fast path |
