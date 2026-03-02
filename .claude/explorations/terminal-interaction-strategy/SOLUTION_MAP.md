# Solution Map: Terminal Interaction Strategy

## Paradigm 1: Per-Terminal Native APIs
**Core bet:** Each terminal's own API provides the most reliable and deterministic control.

### Approach 1a: AppleScript Dictionaries (Current for iTerm2/Terminal.app)
- **How it works:** Query iTerm2/Terminal.app via `osascript` — iterate windows → tabs → sessions, match by TTY property, select the matching tab. Both terminals expose `tty` as a scriptable property.
- **Gains:** Deterministic tab selection (no guessing by title). TTY is a stable identifier that doesn't change after session switch. No retry needed — the tab's TTY is constant.
- **Gives up:** Only works for terminals with scriptable dictionaries. Ghostty has none today. Each `osascript` call adds ~50-100ms. Requires terminal to be running (not just the process, but the scripting engine).
- **Shines when:** The terminal has a rich scripting dictionary (iTerm2 is the gold standard).
- **Risks:** Terminal updates can break scripts. Ghostty's future AppleScript support is uncertain in scope and timeline.
- **Complexity:** Simple per-terminal, but O(n) terminals to maintain.

### Approach 1b: Ghostty App Intents / Future AppleScript
- **How it works:** When Ghostty ships App Intents (wrapping into AppleScript bindings), use them for deterministic tab targeting — likely by UUID or surface-level identifier rather than title matching.
- **Gains:** Would eliminate the AX title race entirely. UUID-based targeting is immune to async title updates. Would be the "golden path" for Ghostty.
- **Gives up:** Doesn't exist yet. Active community effort (Discussion #10201) but no ship date. Betting on this means living with the current AX approach until it ships.
- **Shines when:** Ghostty's App Intents API ships with tab/window targeting.
- **Risks:** API scope might not include tab-level control. Could ship as read-only (query but not activate). Timeline unknown.
- **Complexity:** Simple once available — would replace GhosttyAXReader entirely.

### Approach 1c: kitty Remote Control Protocol
- **How it works:** kitty exposes `kitten @` CLI with JSON-over-escape-sequences protocol. Full window/tab/pane control with `--match` selectors and encrypted auth.
- **Gains:** Most complete programmatic terminal API available. Could match windows by PID, title, env vars, or ID.
- **Gives up:** Only works for kitty. Requires user opt-in (`allow_remote_control` in config). Not relevant for Ghostty users.
- **Shines when:** Users run kitty as their primary terminal.
- **Risks:** Low priority — kitty is not a primary Capacitor target.
- **Complexity:** Moderate (protocol integration, auth setup).

## Paradigm 2: Accessibility APIs (Current for Ghostty)
**Core bet:** AX APIs provide universal window/tab access without terminal cooperation.

### Approach 2a: AX Title Matching with Retry (Current Implementation)
- **How it works:** Read Ghostty's AX tree to enumerate windows and tabs. Extract tab titles. Match against project path, session name, or tmux session hint. Retry up to 15×200ms for title propagation after session switch.
- **Gains:** Works today. No terminal-side changes needed. Handles multiple tabs/windows. Three-tier matching (path, session name, session hint) covers many title formats.
- **Gives up:** Fundamentally race-condition-prone — title updates are asynchronous. Requires TCC Accessibility permission. AX tree structure can change between Ghostty versions. Title parsing is fragile (depends on shell prompt format).
- **Shines when:** No better API exists (Ghostty's current state).
- **Risks:** Ghostty AX tree changes could break window/tab reading. Shell prompt customization can defeat title matching. 3s worst-case retry adds latency.
- **Complexity:** Complex (444-line GhosttyAXReader + matching algorithm + retry logic).

### Approach 2b: AX with Pre-Switch Tab Bookmarking
- **How it works:** Before `tmux switch-client`, record which tab is currently matched (by AX element reference or index). After the switch, focus that SAME tab directly — don't re-match by title. The tab hasn't moved; only its title will change.
- **Gains:** Eliminates the title race condition entirely for the common case (switching sessions in an existing tab). No retry needed — the tab reference is captured before the switch.
- **Gives up:** AX element references can become stale if tabs are reordered/closed between capture and use. Doesn't help for first activation (no prior match to bookmark). Requires plumbing the "pre-switch tab" through the activation flow.
- **Shines when:** Session switching is the primary use case (which it is in the single-client model).
- **Risks:** Tab reordering between capture and use (user drags tabs). Tab closure. AXUIElement reference invalidation.
- **Complexity:** Moderate — adds state to track the "last matched tab" but removes retry logic.

### Approach 2c: AX with CGWindowList Correlation
- **How it works:** Use `CGWindowListCopyWindowInfo` to get window owner PIDs and bounds, then correlate with AX windows by position/size. Use the PID to confirm window ownership without AX title matching.
- **Gains:** CGWindowList is faster than AX traversal. Could confirm "this window belongs to Ghostty" without TCC Accessibility (though Screen Recording permission is needed for window names).
- **Gives up:** No tab-level granularity — CGWindowList only sees windows, not tabs. Different permission requirement (Screen Recording vs Accessibility). Less information than AX.
- **Shines when:** You only need window-level activation (single-tab Ghostty usage).
- **Risks:** Doesn't solve tab matching at all. Permission requirement is arguably worse than Accessibility.
- **Complexity:** Simple for window-level, but doesn't replace tab matching.

## Paradigm 3: tmux as Universal Abstraction
**Core bet:** tmux is the stable, terminal-agnostic coordination layer — lean on it harder instead of per-terminal APIs.

### Approach 3a: tmux Control Mode (-CC)
- **How it works:** Open a persistent tmux control mode connection (`tmux -CC attach`). Receive real-time notifications: `%session-changed`, `%window-renamed`, `%client-session-changed`. React to events instead of polling.
- **Gains:** Event-driven instead of poll-based — no retry windows needed. Know IMMEDIATELY when a client attaches, a session switches, or a window changes. Works regardless of terminal emulator.
- **Gives up:** Requires managing a persistent connection (reconnection logic, error handling). Control mode output parsing is text-based and fragile. iTerm2 monopolizes control mode when using tmux integration — potential conflict. Significant architectural change.
- **Shines when:** You want real-time session awareness without polling.
- **Risks:** Connection management complexity. iTerm2 conflict. Control mode protocol is not well-documented. Adds a persistent resource (the tmux client connection).
- **Complexity:** Complex (persistent connection, event parser, reconnection).

### Approach 3b: tmux Hooks for Event-Driven Client Discovery
- **How it works:** Set tmux hooks (`set-hook -g client-attached 'run-shell "..."'`, `client-session-changed`, etc.) that write to a known file or signal when events occur. Capacitor watches the file or listens for the signal.
- **Gains:** Eliminates post-launch polling. Know immediately when a client attaches. Works with any terminal. Lighter than control mode (no persistent connection).
- **Gives up:** Still can't solve the "focus the right tab" problem — only tells you tmux-side events, not which terminal tab to activate. Requires hook installation (could conflict with user's tmux config). File-watching or signal-handling adds a new subsystem.
- **Shines when:** The main problem is client discovery timing (Bug 1, which is already fixed by polling).
- **Risks:** User tmux config conflicts. Hook persistence across tmux restarts. Race between hook firing and file read.
- **Complexity:** Moderate (hook management + file/signal watching).

### Approach 3c: tmux Client TTY → Process Tree → Terminal Window
- **How it works:** After `tmux switch-client`, use the managed client TTY to walk the process tree: `lsof /dev/ttysNNN` → shell PID → parent PID → terminal PID → `NSRunningApplication(pid:)` → activate. This identifies which terminal OWNS the TTY without querying each terminal.
- **Gains:** Terminal-agnostic TTY ownership. Works for ANY terminal (not just iTerm2/Terminal.app). Could replace the current `discoverTerminalOwningTTY` which only checks iTerm2 and Terminal.app via AppleScript. Deterministic — no title matching, no retries.
- **Gives up:** Only gets you to the window level, not the tab level. Process tree walking is ~50ms. Doesn't solve Ghostty tab focus (one window, multiple tabs). May fail if shell is not a direct child of the terminal process.
- **Shines when:** You need to know which terminal app owns a TTY without per-terminal scripting.
- **Risks:** Process tree structure varies (tmux → shell → nested shell). Intermediate processes (tmux server) can obscure the terminal PID. Works for window activation but not tab selection.
- **Complexity:** Moderate (process tree walking, PID resolution).

## Paradigm 4: Hybrid — tmux for Coordination, AX Only for Tab Selection
**Core bet:** Split responsibilities cleanly: tmux handles all session logic, AX handles only the "last mile" tab focus.

### Approach 4a: Pre-Switch Bookmark + Post-Switch Confidence (Recommended Hybrid)
- **How it works:**
  1. BEFORE `tmux switch-client`: read AX to find the currently-matched tmux tab. Store its AX element reference and index.
  2. Execute `tmux switch-client` (session switch happens in the SAME tab).
  3. AFTER switch: focus the bookmarked tab directly by stored reference. No title matching needed.
  4. Fallback: if the stored reference is stale, do one AX read with the new session hint (title may have propagated by now). If still no match, raise the window.
- **Gains:** Eliminates the title race for the common case (session switch in existing tab). The bookmarked tab is 100% correct because session switching doesn't change which tab hosts the tmux client. Retry only needed for edge cases (tab was closed/reordered).
- **Gives up:** Requires plumbing a "lastMatchedTab" through the activation flow. First activation (no prior bookmark) still needs title matching. AX element references can go stale.
- **Shines when:** The primary workflow is switching between sessions (which it is in single-client mode).
- **Risks:** AXUIElement reference invalidation if Ghostty recycles elements. Tab reordering.
- **Complexity:** Moderate — adds ~50 lines of bookmarking state, removes ~50 lines of retry logic. Net complexity neutral.

### Approach 4b: Process Tree for Terminal Detection + AX for Tab Focus
- **How it works:**
  1. Use managed TTY → `lsof` → process tree → terminal PID to detect which terminal app owns the TTY (replaces per-terminal AppleScript TTY queries).
  2. If terminal is Ghostty, use AX for tab focus (with current matching or bookmarking).
  3. If terminal is iTerm2/Terminal.app, use AppleScript for tab focus (TTY-based, deterministic).
  4. If terminal is unknown, activate by PID (generic window raise).
- **Gains:** Universal terminal detection without per-terminal scripts. Cleaner separation: detection (process tree) vs activation (terminal-specific API). Would support new terminals automatically at the window level.
- **Gives up:** Still needs per-terminal activation for tab-level focus. Process tree walking adds ~50ms to the detection path.
- **Shines when:** Users run various terminals and want them all to work at window level.
- **Risks:** Process tree resolution edge cases. Marginal improvement over current approach for Ghostty (still needs AX for tabs).
- **Complexity:** Moderate — replaces iTerm/Terminal AppleScript TTY queries with one universal mechanism.

## Paradigm 5: Embedded Terminal
**Core bet:** Eliminate the coordination problem by owning the terminal.

### Approach 5a: SwiftTerm Embedded View
- **How it works:** Embed a VT100/Xterm terminal view (via SwiftTerm library) directly in Capacitor's UI. Each project card opens an inline terminal. No external terminal app coordination needed.
- **Gains:** Complete control over tab focus (it's our own view). No AX, no AppleScript, no process tree. Perfect tab tracking because we own the terminal. Zero-latency tab switching.
- **Gives up:** Capacitor becomes a terminal app — massive scope expansion. Must compete with Ghostty/iTerm on rendering, performance, font rendering, key handling, etc. Users lose their preferred terminal's features and configuration. Fundamentally changes the product vision.
- **Shines when:** The product is reimagined as an integrated development environment rather than a coordinator.
- **Risks:** Years of development to reach feature parity with mature terminals. Users don't want another terminal app.
- **Complexity:** Extreme — this is building a terminal emulator.

### Approach 5b: Libghostty Embedding (Future)
- **How it works:** When Mitchell Hashimoto releases libghostty (announced, timeline unknown), embed Ghostty's terminal rendering directly. Get Ghostty's quality without the coordination overhead.
- **Gains:** Ghostty-quality rendering with full programmatic control. No AX needed.
- **Gives up:** Doesn't exist yet. Would create a hard dependency on Ghostty's library. Unclear API surface.
- **Shines when:** Libghostty ships with a stable embedding API.
- **Risks:** Indefinite timeline. API might not support the embedding model Capacitor needs.
- **Complexity:** Unknown — depends on libghostty's API design.

## Non-obvious options

### "Do Nothing" — Accept the Retry Window
The current approach with 15×200ms retry is already working. The title propagation race is a 500ms-1s phenomenon, and the retry handles it. The bugs we fixed were about the retry window being too SHORT (500ms instead of 3s), not about the retry strategy being wrong. Maybe the right answer is: the current architecture is correct, just with better-calibrated timing.

### Hybrid: Remember the Tab Index, Not the AX Element
Instead of bookmarking the AX element reference (which can go stale), remember the tab INDEX. After `tmux switch-client`, the tab index doesn't change. Focus tab at the remembered index directly. This is simpler than AX element bookmarking and survives most edge cases (only fails if tabs are reordered or closed, which is rare during a session switch).

### Escape Sequence Side-Channel
Write a custom tmux hook that, after `switch-client`, sends a known escape sequence (e.g., `OSC 1337;CapacitorReady=<session_name> ST`). Capacitor could listen for this via the managed TTY (if we had a PTY watcher). This would give deterministic, timing-proof notification that the switch completed. However, this requires PTY watching infrastructure that Capacitor doesn't have.

## Eliminated early

- **Warp API** — Cloud-only, no local terminal control. Not relevant.
- **CGWindowList alone** — No tab-level granularity. Can't solve the core problem.
- **Screen Recording permission** — Arguably worse UX than Accessibility permission, and provides less information.
- **Terminal.app as primary** — Terminal.app is scriptable but its tmux integration is poor. Not a realistic primary target.
