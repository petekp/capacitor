# Terminal Activation v2 Decisions

Append-only. Reversals are new entries that reference the superseded decision.

---

## D-001: Unified Swift-side flow over Rust-driven dispatch

**Date:** 2026-03-01
**Context:** The v1 model had Rust resolve an ActivationActionKind, then Swift dispatch to separate handlers (switchTmuxSession, ensureTmuxSession, launchNewTerminal). This caused mismatches — Rust would say "switch" but Swift had no matching tab for the target session.
**Decision:** One unified Swift flow: resolve client → ensure session + switch → focus. Rust resolver retained for telemetry only.
**Rationale:** Swift has the real-time state (managed TTY, Ghostty AX tree). Letting Swift drive the decision tree eliminates the mismatch between Rust's snapshot-based decision and runtime reality.

## D-002: Managed-TTY affinity as stored state

**Date:** 2026-03-01
**Context:** TTY values were transient locals passed through method parameters. No persistence across card clicks.
**Decision:** Add `managedClientTty: String?` as a stored property on TerminalLauncher. Cleared when stale, updated when adopting a new client.
**Rationale:** The spec (B6) requires remembering which TTY Capacitor uses. Without persistence, every card click re-resolves from scratch, which can adopt wrong clients.

## D-003: Session-swap not tab-spawn

**Date:** 2026-03-01
**Context:** Old code opened new Ghostty tabs for new projects. User confirmed: one tab, swap sessions within it.
**Decision:** Card clicks always use `tmux switch-client -c <tty> -t <session>`. New tabs only created when zero tmux clients exist.
**Rationale:** Multiple tabs per project creates cognitive overhead and window clutter. Session swapping is tmux's native multi-project model.

## D-004: Keep ActivationActionExecutor during migration, delete in final slice

**Date:** 2026-03-01
**Context:** ActivationActionExecutor has dedicated tests and is referenced from TerminalLauncher.
**Decision:** Don't delete ActivationActionExecutor until the unified flow is fully wired and tested. Final slice removes it.
**Rationale:** Incremental migration — keep old paths working until new paths are proven, then delete atomically.

## D-005: Pre-switch tab bookmark over pure retry

**Date:** 2026-03-01
**Context:** After `tmux switch-client`, Ghostty's AX tab title updates asynchronously (500ms–1s). The retry-based AX routing (15×200ms) works but adds latency and is fundamentally race-prone. Solution exploration (`.claude/explorations/terminal-interaction-strategy/`) identified a better approach.
**Decision:** Before `ensureAndSwitch`, do one AX read to find the currently-matched tmux tab and store its index. After the switch, focus that tab directly by index — the tab hasn't moved, only its title changed. Retry-based title matching remains as a fallback for edge cases (stale index, first activation with no prior bookmark).
**Rationale:** In the single-client model (D-003), session switching happens within the same tab. The tab's position doesn't change — only its title updates asynchronously. Bookmarking the tab index before the switch gives instant, deterministic focus without waiting for title propagation. The retry window is reduced from 15×200ms to 5×200ms since it only handles edge cases.

## D-006: Cross-check managed TTY against tmux clients

**Date:** 2026-03-01
**Context:** After closing a Ghostty tab, the TTY device file (`/dev/ttys000`) persists for minutes while the tmux client has already detached. `isTtyAlive` (which only checks `FileManager.fileExists`) returns true for the stale TTY. `resolveTmuxClient` returns this stale TTY as a valid client, causing `ensureAndSwitch` to fail silently and card clicks to do nothing.
**Decision:** `resolveTmuxClient` now cross-checks the managed TTY against `resolveAnyClientTty` (which runs `tmux list-clients`). If the device file exists but no tmux client is attached, the TTY is treated as stale and the flow correctly launches a new terminal.
**Rationale:** The device file check is a necessary but not sufficient proxy for client liveness. The TTY device file can outlive the tmux client by minutes (macOS doesn't immediately reclaim device files). Cross-checking against `tmux list-clients` costs ~5ms but eliminates the stale window entirely.

## D-007: Bookmark-based orphaned client detection

**Date:** 2026-03-01
**Context:** D-006 handles the case where the tmux client has fully detached (~seconds after tab closure). But there's a ~5-second window after tab closure where the tmux client is still registered with the tmux server. During this window, `resolveTmuxClient` returns the dying client, `ensureAndSwitch` succeeds, but the terminal tab is already gone. The AX routing falls to `window_raise` (raises a Ghostty window without finding the right tab), which previously returned `true` — causing "nothing happens" for ~5 seconds until the client fully detaches and D-006 kicks in.
**Decision:** Use the pre-switch tab bookmark (D-005) as an orphan discriminator. When `bookmarkWasCleared` (the previously-bookmarked tab index is gone) AND the retry loop resolves to `window_raise` (no tab title match), the tab was closed — orphaned client. Return `false` from `activateGhosttyWithAXRouting`, which triggers `performUnifiedActivation` to clear managed state and launch a fresh terminal. When no bookmark existed (cold start / first activation), `window_raise` continues to return `true` (preserves the normal AX title race fallback).
**Rationale:** The bookmark is a strong prior: if we previously focused a tab at index (w, t) and that index no longer resolves, the tab was removed. Combined with `window_raise` (no title match after 5×200ms retry), this is a definitive orphan signal with zero false positives during normal operation. The normal happy path (bookmark hit → `tabPress`) is unaffected. Additionally, `completeTerminalActivationAfterTmuxSwitch` now returns `false` from the generic `activateTerminalApp()` fallback, and `performUnifiedActivation` handles `activateTerminal` returning `false` by clearing `managedClientTty` and relaunching.

## D-008: Window title fallback for unmatched tab routing

**Date:** 2026-03-01
**Context:** D-007 requires a prior bookmark to detect orphaned clients. But bookmarks are only established when `bestGhosttyTabMatch` finds a tab title match. Some Ghostty tabs show only `✳ Claude Code` without a tmux session prefix, making them unmatchable. Without a match, no bookmark is set, D-007 never fires, and `window_raise` returns `true` — masking the orphan.
**Decision:** Add `title: String?` to `GhosttyWindowSnapshot`, populated from `kAXTitleAttribute` on the window AX element. When the AX route is `.windowRaise` (regardless of `tabCount`), check if any window's title matches the session (via `ghosttyWindowTitleMatchesSession`, which reuses the same path/session/hint matching logic as `bestGhosttyTabMatch`). Match → session is visible → `window_raise` is valid. No match → orphaned client → return `false` → relaunch.
**Rationale:** Ghostty's window title reflects the active tab's title. After the 1-second retry window (5×200ms), the title has propagated in the normal case (200–500ms typical). In the orphaned case, the window either closed (handled by `windowCount=0`) or shows an unrelated session. Originally gated on `tabCount == 0`, but extended to all cases because Claude Code can override tab titles to `✳ Claude Code` (removing the tmux session prefix), making tab-level matching unreliable even when tabs are enumerable.

## D-009: Bookmark title validation to detect tab index shifts

**Date:** 2026-03-01
**Context:** D-005's bookmark fast path stores (windowIndex, tabIndex) to avoid the title propagation race. But after tab closure, remaining tab indices shift. The tab at the bookmarked index is now a different tab. `tryBookmarkedGhosttyTab` finds it, `focusTab` succeeds, returns `.tabPress` → activation "succeeds" but the wrong tab is focused. D-007's `bookmarkWasCleared` never becomes true because the bookmark "hit."
**Decision:** Store the tab's title alongside the bookmark index: `(windowIndex, tabIndex, tabTitle)`. On subsequent activations, compare the stored title to the current tab's title at the bookmarked index. Mismatch → tab shifted → treat as bookmark miss → `bookmarkWasCleared = true` → D-007 fires.
**Rationale:** In the happy path, the tab at the bookmarked index is the SAME physical tab (title is stale but identical to what was stored). After tab closure and index shift, the tab at the bookmarked index is a DIFFERENT physical tab with a different title. Simple string equality catches the shift with zero false positives in normal operation.

## D-010: Auto-attach to detached tmux sessions

**Date:** 2026-03-01
**Context:** When no tmux client is attached but a tmux session exists for the project (detached from a previous terminal closure), `performUnifiedActivation` always launched a new Ghostty tab via `tmux new-session -A`. If Ghostty was already running with an idle shell tab, this created a second tab — violating D-003 ("one tab, swap sessions within it").
**Decision:** Before launching a new terminal, check `tmux has-session -t <name>`. If the session exists, auto-attach via `tmux attach-session -t <name>` typed into the current active Ghostty tab (no Cmd+T). If no session exists, create one in a new tab as before. Two new parameters on `performUnifiedActivation`: `hasExistingSession` (checks session existence) and `attachToExistingSession` (reuses current tab).
**Rationale:** Separating "attach to existing" from "create new" makes the intent explicit and enables tab reuse. `tmux new-session -A` combined both operations, but its `-c` flag (working directory) is silently ignored during attach, making the code misleading. The explicit split also enables D-003-aligned behavior: when a Ghostty tab already exists, reuse it for the tmux attachment instead of spawning a new tab.
