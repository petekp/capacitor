# Terminal Activation Simplification Decisions

Append-only. Reversals are new entries that reference the superseded decision.

---

## Decision 1: `open -a` (no `-n`) to avoid dock icon duplication

- **Date:** 2026-03-02
- **Status:** Active
- **Context:** The original activation code used `open -na Ghostty.app` to ensure a new instance. The `-n` flag creates a separate process, which macOS renders as a separate dock icon. This was the root cause of the dock-icon-duplication bug that motivated most of the current complexity (keystroke simulation to avoid `open -n`, managed TTY to track which process, orphan detection for stale processes).
- **Decision:** Use `open -a Ghostty.app /path` (without `-n`). This sends an Apple Event to the existing Ghostty instance, which opens a new tab at the specified path. No new process, no new dock icon. Ghostty registers as a `public.directory` handler in its Info.plist `CFBundleDocumentTypes`, so passing a directory path opens a shell in that directory.
- **Alternatives considered:** (a) AppleScript `tell application "Ghostty" to open ...` — works but requires separate AX focus management. (b) Ghostty CLI `ghostty --new-tab` — not available as of current Ghostty version. (c) Keep keystroke simulation — brittle, timing-dependent.
- **Consequences:** Eliminates the need for keystroke simulation (Cmd+T → delay → type command). Also eliminates the need for `open -na` entirely. The only remaining need for AppleScript/AX is typing the tmux command into the new tab and focusing tabs after session switching.
- **Supersedes:** None (new migration)

## Decision 2: Ghostty-only support (remove multi-terminal fallback)

- **Date:** 2026-03-02
- **Status:** Active
- **Context:** TerminalLauncher contains fallback paths for iTerm, Terminal.app, and generic terminals. The user exclusively uses Ghostty. These fallback paths add ~24 pattern matches of complexity and are untested against real terminal behavior.
- **Decision:** Remove all multi-terminal detection and fallback code. Hard-code Ghostty as the target terminal.
- **Alternatives considered:** Keep fallbacks behind a config — adds complexity for a use case that doesn't exist.
- **Consequences:** Simpler code. If terminal support is ever needed for other apps, it would be a new feature, not a restoration of the removed code (which was never properly working).
- **Supersedes:** None

## Decision 3: Remove orphan detection and bookmark system

- **Date:** 2026-03-02
- **Status:** Active
- **Context:** TAv2 decisions D-005 through D-009 added a bookmark-based orphan detection system to handle a ~5-second window where a tmux client persists after its Ghostty tab is closed. This system stores tab indices, validates tab titles, cross-checks against window titles, and uses bookmark-clearing as an orphan signal. It's ~200 lines of subtle state management.
- **Decision:** Remove the entire bookmark/orphan detection system. The simplified flow handles the orphan case naturally: if `tmux switch-client` targets a stale TTY, the command fails (non-zero exit), and the flow falls through to the "no client" branch which launches a fresh tab via `open -a`.
- **Alternatives considered:** Keep bookmark for the 34x speedup (7ms vs 238ms) — but the 238ms was for 5×200ms AX title retry which we're also simplifying. With `open -a` creating tabs deterministically, the retry window is only needed after `tmux switch-client`, where title propagation is ~200ms typical.
- **Consequences:** Loss of the bookmark fast-path. AX routing after session switch returns to retry-based title matching. Acceptable because: (a) 200ms is imperceptible for a card click, (b) eliminates 200+ lines of fragile state tracking.
- **Supersedes:** TAv2 D-005, D-007, D-008, D-009

## Decision 4: Remove Rust resolver from activation hot path

- **Date:** 2026-03-02
- **Status:** Active
- **Context:** The Rust `runtime_activation` resolver is called during every card click in `launchTerminalAsync`. Its result is logged for telemetry but not used to drive any activation decision (that's all Swift-side now per TAv2 D-001). The FFI call adds latency to every card click.
- **Decision:** Remove the `resolveActivationDecision` call from the card-click path entirely. If telemetry is needed, log the Swift-side decision instead.
- **Alternatives considered:** Move to background — still adds complexity for telemetry that isn't actively monitored.
- **Consequences:** The `runtime_activation` Rust module becomes unused from Swift. It can be pruned in a later slice or kept for potential future use. The old `activate/` module (178 lines, already superseded by `runtime_activation`) should be deleted.
- **Supersedes:** None (TAv2 D-001 already moved decision-making to Swift; this removes the vestigial FFI call)
