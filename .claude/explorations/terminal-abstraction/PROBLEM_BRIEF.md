# Problem Brief: Terminal Abstraction Layer

## Problem statement

Capacitor currently only activates Ghostty terminals. This undermines its core value proposition as a **companion app that works alongside any terminal** — the key differentiator vs. integrated terminal replacements like cmux (which embed libghostty). Without multi-terminal support, Ghostty users have no reason to choose Capacitor over deeper-integrated alternatives, and non-Ghostty users can't use Capacitor at all.

The underlying need: a clean interface that lets Capacitor detect, activate, and manage sessions across multiple terminal emulators without each terminal's quirks leaking into the orchestration layer.

## Dimensions

1. **Integration depth per terminal** — Ghostty has AX tab routing; iTerm2 has a rich AppleScript API; Terminal.app has basic AppleScript. Each terminal offers different capabilities. The abstraction must handle this asymmetry.

2. **Complexity budget** — The previous multi-terminal code was removed (2,281 lines) because it was too complex to maintain alongside Ghostty AX debugging. The new abstraction must be simpler.

3. **Activation fidelity** — "Focus the right window/tab for this project" ranges from exact (Ghostty AX tab press) to approximate (bring app to front). Different terminals support different levels of precision.

4. **Detection reliability** — Knowing which terminal a session lives in. Currently hardcoded to Ghostty; needs to work across terminals and handle edge cases (multiple terminals running, user switches terminals mid-session).

5. **Tmux coupling** — Current flow assumes tmux as the session multiplexer. The abstraction should consider whether tmux is always in the picture.

6. **Maintenance surface** — Each terminal strategy is a maintenance commitment. Apple changes AppleScript APIs, terminals change AX hierarchies, new terminals emerge.

7. **Launch vs. activate** — Two distinct operations: starting a new terminal session vs. focusing an existing one. These may have different abstraction needs.

## Success criteria

### Must
- Support Ghostty, iTerm2, and Terminal.app activation (focus existing session)
- No regression in Ghostty activation quality (AX tab routing preserved)
- Clean separation: terminal-specific code isolated from orchestration logic
- Auto-detect which terminal to use (no manual config required)
- Ship with < 500 lines of new code (excluding tests)

### Should
- Make adding a new terminal (e.g., Kitty, Warp, Alacritty) require only a single new file/type
- Graceful degradation when a terminal doesn't support precise tab focus
- Reuse existing Rust `ParentApp` enum for detection
- Keep orchestration logic (`TerminalLauncher`) largely unchanged

### Nice
- Support launching new sessions (not just activating existing ones) across terminals
- Terminal preference ordering (user configures preferred terminal)
- Ability to test terminal strategies in isolation (mockable)

## Assumptions

1. **Tmux is always used** — Capacitor's session model assumes tmux. Sessions are tmux sessions, not raw terminal tabs. — status: confirmed (deeply baked into current architecture)
2. **Only one terminal per session** — A given project session lives in one terminal app at a time. — status: unconfirmed (could a user have Ghostty AND iTerm running?)
3. **macOS only** — AX APIs, AppleScript, NSWorkspace are all macOS. No Linux/Windows needed for alpha. — status: confirmed
4. **Terminal detection from hook data** — The hud-hook already detects parent terminal app. This data flows to the snapshot. — status: confirmed (hud-hook/cwd.rs detects iTerm, Ghostty, Terminal)
5. **AppleScript is sufficient for iTerm2/Terminal.app** — We don't need AX-level integration for non-Ghostty terminals. — status: unconfirmed (need to verify iTerm2 AppleScript API richness)

## Constraints

- Swift 6.2 strict concurrency (all new code must be Sendable-safe)
- Existing `TerminalLauncher.swift` is 815 lines — refactor, don't rewrite
- `GhosttyAXReader` and related AX code is well-tested and stable — preserve it
- Previous multi-terminal code was removed for good reason — don't reintroduce the same complexity
- Alpha timeline — this should be shippable in days, not weeks
