# Analysis: Terminal Interaction Strategy

## Tradeoff Matrix

| Criterion | 1a: AppleScript | 1b: Ghostty Intents | 2a: AX Retry (Current) | 2b: AX Bookmark | 3a: tmux -CC | 3c: Process Tree | 4a: Pre-Switch Bookmark | 4b: ProcTree + AX | 5a: SwiftTerm |
|-----------|----------------|--------------------|-----------------------|-----------------|-------------|-----------------|------------------------|-------------------|--------------|
| **MUST: <500ms p95 focus** | ~100ms | Unknown | ~200ms typical, 3s worst | ~50ms | ~50ms (event-driven) | ~100ms + AX | ~50ms typical | ~150ms | ~0ms |
| **MUST: Ghostty works** | ❌ No dictionary | ❌ Not shipped | ✅ | ✅ | ✅ (session only, not tab) | ❌ (window only) | ✅ | ✅ | N/A (replaces Ghostty) |
| **MUST: Survives session switch** | ✅ (TTY stable) | Unknown | ✅ (with retry) | ✅ (pre-captured) | ✅ | ✅ | ✅ | ✅ | ✅ |
| **MUST: Graceful degradation** | ✅ | N/A | ✅ | ✅ | ⚠️ (connection failure = no events) | ✅ | ✅ | ✅ | N/A |
| **SHOULD: No race conditions** | ✅ (deterministic) | Likely ✅ | ❌ (retry-based) | ✅ (bookmark path) | ✅ (event-driven) | ✅ | ✅ (bookmark path) | ✅ | ✅ |
| **SHOULD: iTerm2 + Terminal.app** | ✅ | ❌ | ❌ (Ghostty only) | ❌ (Ghostty only) | ⚠️ (session only) | ⚠️ (window only) | Ghostty; others via existing AppleScript | ✅ | ❌ |
| **SHOULD: Testable** | ⚠️ (script mocking) | Unknown | ✅ (static + stubs) | ✅ | ⚠️ (connection mocking) | ✅ | ✅ | ✅ | ✅ |
| **SHOULD: Minimal per-terminal code** | ❌ (one script per terminal) | ✅ (if comprehensive) | ❌ (reader + matcher) | ❌ (reader + matcher + bookmark) | ✅ (terminal-agnostic) | ✅ (universal) | ❌ (Ghostty-specific + general) | ✅ | ✅ |
| **NICE: New terminal support** | ❌ (needs new script) | ❌ (Ghostty only) | ❌ (Ghostty only) | ❌ (Ghostty only) | ✅ | ✅ | ⚠️ (falls back) | ✅ | N/A |
| **NICE: No TCC permission** | ✅ | Likely ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ⚠️ (AX still needed for Ghostty tabs) | ✅ |
| **NICE: Instant focus** | ✅ | Likely ✅ | ❌ | ✅ | ✅ | ❌ (window only) | ✅ | ❌ | ✅ |

## Eliminated

- **1a (AppleScript alone):** Eliminated because Ghostty has no scriptable dictionary. Fails MUST criterion "Ghostty works."
- **1b (Ghostty App Intents):** Eliminated because it doesn't exist yet. Cannot build on a future API with no ship date.
- **1c (kitty Remote Control):** Eliminated because kitty is not a primary target. Low user base overlap.
- **2c (AX + CGWindowList):** Eliminated because CGWindowList provides no tab-level granularity. Doesn't solve the core problem.
- **3a (tmux Control Mode):** Eliminated because it solves session awareness but not tab focus — still needs AX for Ghostty tab selection. Adds significant connection management complexity for marginal benefit over the current polling approach (which is already fixed).
- **3b (tmux Hooks):** Eliminated because hooks only solve client discovery timing (Bug 1), which is already fixed by polling. Doesn't address tab focus (Bug 2).
- **5a (SwiftTerm):** Eliminated because it fundamentally changes the product from a coordinator to a terminal app. Massive scope expansion.
- **5b (Libghostty):** Eliminated because it doesn't exist yet and timeline is unknown.

## Finalists

1. **Approach 2a: AX Retry (Current, with improved timing)** — from Paradigm 2. Selected because it works today, the timing fixes we just made address the known bugs, and it's already in production with 255 passing tests. Represents the "ship what works" option.

2. **Approach 4a: Pre-Switch Tab Bookmark** — from Paradigm 4 (Hybrid). Selected because it eliminates the title race condition for the most common case (session switching) by capturing the tab reference BEFORE the switch. Represents the "fix the root cause" option.

3. **Approach 4b: Process Tree + AX** — from Paradigm 4 (Hybrid). Selected because it makes terminal detection universal (no per-terminal AppleScript TTY queries) while keeping AX for Ghostty tab focus. Represents the "improve the architecture" option.

## Key differentiator

**The single question:** Does bookmarking the tab before `tmux switch-client` reliably survive the switch and produce correct tab focus?

If yes → Approach 4a eliminates the title race at the root. If the AX element reference or tab index is reliable across the switch → we can focus instantly without any retry.

If no (AX references go stale, tab indices shift) → Approach 2a (current with improved timing) is the pragmatic choice.

## Open risks

1. **AXUIElement reference lifetime** — Do AX element references for Ghostty tabs remain valid across a tmux session switch? If Ghostty recreates tab elements when the title changes, the bookmark goes stale.

2. **Tab index stability** — The "remember tab index" variant (from non-obvious options) assumes tab indices are stable during a session switch. Need to verify Ghostty doesn't reorder tabs.

3. **Ghostty App Intents timeline** — If Ghostty ships a scripting API in the next 3-6 months, approach 1b would render both 2a and 4a obsolete. Worth monitoring Discussion #10201.

4. **Multi-window Ghostty** — Current bookmarking assumes a single Ghostty window. If the user has multiple windows, the bookmarked tab might be in a different window than expected.

## Recommendation

**Short-term (now): Stay with Approach 2a** — the timing fixes we just made (15×200ms retry) are working. The cold-start poll and pre-activation recovery handle Bug 1, and the increased AX retry handles Bug 2. Ship this.

**Medium-term (next migration): Implement Approach 4a (Pre-Switch Bookmark)** — this is a clean incremental improvement:
1. Before `ensureAndSwitch`, do one AX read to find the current tmux tab
2. Store the tab's index (not AX element reference — indices are more stable)
3. After `ensureAndSwitch`, focus tab at stored index directly
4. Fallback to current title-matching retry if index-based focus fails

This eliminates the retry for ~95% of session switches while keeping the retry as a safety net. The implementation is ~50 lines of additional code in `activateGhosttyWithAXRouting`.

**Long-term: Monitor Ghostty App Intents** — when Discussion #10201 ships, evaluate replacing GhosttyAXReader entirely with deterministic API calls. This would be the ideal end state.

**Opportunistic: Add process-tree TTY detection (Approach 4b partially)** — replacing the `discoverTerminalOwningTTY` method's per-terminal AppleScript queries with `lsof`-based process tree walking. This is an independent improvement that makes terminal detection universal. Low risk, moderate value.
