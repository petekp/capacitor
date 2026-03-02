# Problem Brief: Terminal Interaction Strategy

## Problem statement

Capacitor needs to reliably focus the correct terminal tab after a tmux session switch, across multiple terminal emulators (Ghostty, iTerm2, Terminal.app, and others). The current approach works but has timing-sensitive race conditions — we've just fixed two polling bugs where the retry windows were too short for real-world async propagation. The question is whether there's a fundamentally more reliable strategy than the current layered approach.

## Dimensions

| Dimension | Current State | Notes |
|-----------|--------------|-------|
| **Reliability** | Good after timing fixes, but still fundamentally race-condition-prone (AX title matching depends on async propagation) | The #1 pain point |
| **Terminal coverage** | Ghostty (AX), iTerm2 (AppleScript), Terminal.app (AppleScript), others (generic activation) | Ghostty is primary; iTerm2/Terminal.app are secondary |
| **Latency** | Immediate for cached matches; up to 3s retry window for slow AX title propagation | Users notice >500ms delays |
| **Complexity** | ~2200 lines across TerminalLauncher + GhosttyAXReader | High cognitive load for debugging |
| **Permissions** | Requires TCC Accessibility permission for AX APIs | Users must grant explicitly |
| **Maintenance** | Each terminal emulator requires separate integration code | Ghostty API is actively evolving |
| **Testability** | Static methods with injectable deps; AX layer is stubbed in tests | Good, but real AX behavior untestable |

## Success criteria

### Must
- Focus the correct terminal tab within 500ms of a card click (p95)
- Work with Ghostty (primary terminal) without requiring terminal-side configuration
- Survive tmux session switches (the tab showing session A must be focusable after switching to session B)
- Degrade gracefully when permissions are missing or terminal APIs change

### Should
- Eliminate polling/retry-based race conditions in the critical path
- Work with iTerm2 and Terminal.app at feature parity
- Be testable without real AX/AppleScript infrastructure
- Require minimal per-terminal integration code

### Nice
- Support future terminals (kitty, Warp, Alacritty) with minimal new code
- Avoid TCC Accessibility permission requirement
- Provide instant tab focus without any retry/poll loop

## Assumptions

1. **Ghostty is the primary terminal** — ~90% of Capacitor users use Ghostty. Status: confirmed (from project context)
2. **Single tmux client model** — one Ghostty tab runs one tmux client. Status: confirmed (spec v2 architecture)
3. **tmux is always available** — all project sessions use tmux. Status: confirmed (core architecture decision)
4. **Ghostty's AX tree exposes tab titles** — this is true today but could change. Status: confirmed (tested)
5. **Ghostty will eventually have a scripting API** — App Intents + AppleScript bindings are in active development (Discussion #2353, #10201). Status: unconfirmed (community effort, no ship date)
6. **AppleScript tab titles update asynchronously after tmux switch-client** — the root cause of Bug 2. Status: confirmed (measured 500ms-1s propagation)

## Constraints

- macOS only (Apple Silicon, macOS 14+)
- Swift/SwiftUI app — must integrate with Swift concurrency model
- Cannot modify terminal emulator source code (Ghostty, iTerm, etc.)
- Cannot require terminal-side plugins or configuration
- Must not slow down the common case (tab already matches) to improve the rare case (title race)
