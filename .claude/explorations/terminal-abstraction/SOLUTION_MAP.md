# Solution Map: Terminal Abstraction Layer

## Paradigm 1: Strategy Protocol Pattern
**Core bet:** Clean OOP abstraction makes each terminal independently testable and extensible.

This is the "textbook" approach — define a Swift protocol, one conforming type per terminal, a factory that picks the right strategy based on detected terminal.

### Approach 1a: Full Strategy Protocol

A protocol captures all terminal operations: detect, activate, launch, focus tab.

```swift
protocol TerminalStrategy: Sendable {
    var appName: String { get }
    var bundleId: String { get }
    func isRunning() -> Bool
    func activateWindow(forTty: String?) async -> ActivationResult
    func focusTab(sessionName: String, tty: String?) async -> Bool
    func launchSession(named: String, at path: String) async -> Bool
}
```

- **How it works:** `GhosttyStrategy` uses AX tab routing. `ITermStrategy` uses AppleScript TTY matching. `TerminalAppStrategy` uses AppleScript tab TTY matching. A `TerminalStrategyResolver` picks the right one based on `ParentApp` from the runtime snapshot.
- **Gains:** Each terminal is isolated. Adding Kitty = add one file. Mockable for testing.
- **Gives up:** Protocol overhead. The previous adapter layer (Gen 2) had 4 files and 1,200 lines of tests for what was essentially a switch statement. Risk of over-engineering.
- **Shines when:** Supporting 5+ terminals with meaningfully different capabilities.
- **Risks:** History repeats — this is structurally similar to the deleted `ActivationActionExecutor` + adapters. The protocol surface area grows as terminal capabilities diverge (splits, profiles, etc.).
- **Complexity:** Moderate (~300-400 lines of new code)

### Approach 1b: Minimal Strategy (Activate-Only Protocol)

Narrow the protocol to the one thing that actually varies: focusing the right window/tab.

```swift
protocol TerminalActivator: Sendable {
    func activate(tty: String?, sessionName: String?) async -> Bool
}
```

Everything else (tmux orchestration, session creation, launch via `open -a`) stays in the existing `TerminalLauncher`. Only the "last mile" — bring the right window to front — is dispatched.

- **How it works:** `TerminalLauncher.performUnifiedActivation()` calls `activator.activate(tty:sessionName:)` instead of hardcoded Ghostty AX logic. Three activators: Ghostty (AX), iTerm (AppleScript), Terminal.app (AppleScript).
- **Gains:** Minimal surface area. Existing orchestration untouched. ~100 lines per activator.
- **Gives up:** Can't customize launch behavior per terminal (all use `open -a`). No per-terminal tab creation.
- **Shines when:** The primary goal is "bring the right window to front" and everything else can be generic.
- **Risks:** May need to widen the protocol later if terminals need custom launch logic.
- **Complexity:** Simple (~150-200 lines total)

---

## Paradigm 2: Rust Resolver Reintegration
**Core bet:** The decision logic already exists in Rust and is well-tested — don't rebuild it in Swift.

The Rust `runtime_activation/mod.rs` (2,345 lines) already resolves the correct `ActivationAction` for any terminal type. It was disconnected from Swift in the simplification pass. Reconnect it.

### Approach 2a: FFI Bridge to Rust Resolver

Call the Rust resolver from Swift via UniFFI, get back an `ActivationAction` enum, execute it in Swift with minimal per-terminal handlers.

- **How it works:** Swift calls `resolve_activation(shell_states, tmux_context)` via FFI. Rust returns `ActivateByTty { tty, terminal_type }` or `ActivateApp { app_name }` or `ActivateKittyWindow { pid }`. Swift has a simple switch on the action type, with per-terminal execution (AppleScript for iTerm/Terminal, AX for Ghostty, `kitty @` for Kitty).
- **Gains:** Leverages 2,345 lines of existing, tested Rust code. Policy logic (shell ranking, path specificity, tmux preference) is already correct. Single source of truth for activation decisions.
- **Gives up:** FFI call on every activation (data conversion overhead). Swift must still execute the action. Couples activation latency to Rust bridge. Previous removal cited "FFI on the hot path" as a problem.
- **Shines when:** The activation decision logic is complex and needs to handle edge cases (multiple shells, worktrees, IDE windows).
- **Risks:** The Rust resolver was removed for a reason — it added latency and the data conversion was fragile. The Swift side has evolved since; data shapes may no longer match.
- **Complexity:** Moderate (bridge code + action executors, but leverages existing Rust logic)

### Approach 2b: Port Rust Resolver Logic to Swift

Instead of FFI, translate the Rust resolver's decision tree into Swift. Keep the Rust code as reference/tests.

- **How it works:** A pure-Swift `ActivationResolver` implements the same policy: rank shells by liveness, path specificity, tmux preference, known parent. Returns a lightweight action enum. Swift executes directly.
- **Gains:** No FFI overhead. Pure Swift, no bridge complexity. Can evolve independently.
- **Gives up:** Code duplication between Rust and Swift. Drift risk as logic evolves. ~300-400 lines of Swift to rewrite.
- **Shines when:** FFI overhead is unacceptable and the decision logic needs to be tightly integrated with Swift state.
- **Risks:** Logic drift between Rust (tested) and Swift (new) implementations.
- **Complexity:** Moderate-High (rewriting tested Rust logic in Swift)

---

## Paradigm 3: TTY-Centric Dispatch
**Core bet:** TTY is the universal key. Every terminal allocates PTYs, tmux knows client TTYs, and both iTerm2 and Terminal.app can focus tabs by TTY via AppleScript. Don't abstract terminals — abstract the "focus by TTY" operation.

### Approach 3a: AppleScript TTY Lookup (Broadcast)

A single function tries to find and focus the tab owning a TTY across ALL running terminal apps.

```swift
func focusTerminalTab(tty: String) async -> Bool {
    // Try each running terminal's AppleScript in priority order
    if await focusITermTab(tty: tty) { return true }
    if await focusTerminalAppTab(tty: tty) { return true }
    if await focusGhosttyTab(tty: tty) { return true }  // AX fallback
    return false
}
```

- **How it works:** Capacitor already knows the tmux client TTY (`resolveAnyTmuxClientTty()`). It runs a short AppleScript per terminal app (iTerm: iterate sessions matching `tty`; Terminal.app: iterate tabs matching `tty`). For Ghostty, falls back to AX routing since Ghostty doesn't expose TTY via AppleScript. First match wins.
- **Gains:** Dead simple. No protocols, no strategies, no factory. Just "find who owns this TTY." ~30 lines of AppleScript per terminal. Total new code: ~100 lines.
- **Gives up:** No abstraction for future terminals. Ghostty is special-cased (AX vs. AppleScript). Broadcast approach is O(n) over running terminals.
- **Shines when:** You support 2-3 terminals and the primary operation is "focus the right tab."
- **Risks:** Doesn't scale if you add 5+ terminals. Ghostty's AX routing is fundamentally different from AppleScript TTY matching, so it's not truly unified. Priority ordering is implicit (code order).
- **Complexity:** Simple (~100-150 lines)

### Approach 3b: TTY Lookup with Terminal Hint

Same as 3a, but use the `ParentApp` from the runtime snapshot to skip the broadcast — go directly to the right terminal.

```swift
func focusTerminalTab(tty: String, hint: ParentApp?) async -> Bool {
    switch hint {
    case .iTerm:    return await focusITermTab(tty: tty)
    case .terminal: return await focusTerminalAppTab(tty: tty)
    case .ghostty:  return await focusGhosttyTab(sessionName: name)
    default:        return await broadcastFocusByTty(tty: tty)
    }
}
```

- **How it works:** The hud-hook already detects `TERM_PROGRAM` and stores it as `parent_app` in the shell state. The runtime snapshot includes this. Swift reads the hint and dispatches directly. Falls back to broadcast if hint is missing.
- **Gains:** O(1) dispatch when hint is available. Uses data Capacitor already collects. Simple switch statement.
- **Gives up:** Still not a proper abstraction — just a switch with inline AppleScript calls. Adding a new terminal means adding a case + a function.
- **Shines when:** The primary need is activation, not launch customization. You want minimal code and fast iteration.
- **Risks:** The switch statement grows. Functions for each terminal live in... where? TerminalLauncher becomes a grab bag.
- **Complexity:** Simple (~150-200 lines)

---

## Paradigm 4: Observation-First (De-emphasize Activation)
**Core bet:** Terminal activation is a secondary feature. The real value is the dashboard/observation layer. Ship basic activation for all terminals and invest elsewhere.

### Approach 4a: Generic `open -a` for All Terminals

Don't try to focus the exact tab. Just bring the terminal app to the front.

```swift
func activateTerminal(appName: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/\(appName).app"))
}
```

- **How it works:** Detect which terminal is running (from snapshot or NSWorkspace). `open -a` brings it to front. User manually selects the right tab. For Ghostty, keep the existing AX routing as a bonus.
- **Gains:** Zero per-terminal code for basic activation. Works for ANY terminal. Ship tomorrow.
- **Gives up:** No tab-level precision for iTerm/Terminal.app. User must manually find the right tab. Feels janky compared to Ghostty's precise AX routing.
- **Shines when:** You want to ship alpha fast and activation precision isn't the differentiator.
- **Risks:** Poor UX perception — "it just brings up the app, I have to find my session myself." Undermines the "mission control" value prop.
- **Complexity:** Trivial (~20 lines)

### Approach 4b: `open -a` + tmux Session Switch

Bring the terminal to front AND switch the tmux client to the right session. The user sees the right session even if they land on the wrong tab.

- **How it works:** `open -a <Terminal>` to activate. Then `tmux switch-client -t <session>` to ensure the active tmux client shows the right project. If the user has one terminal window with tmux, this is sufficient.
- **Gains:** Simple. Works across all terminals. User sees the right session content immediately.
- **Gives up:** If user has multiple tabs with different tmux clients, the wrong tab might update. No tab focus.
- **Shines when:** Users typically have one terminal window/tab per tmux client.
- **Risks:** Multi-tab users get confused when the wrong tab's content changes.
- **Complexity:** Simple (~50 lines)

---

## Paradigm 5: Hybrid — Tiered Activation Quality
**Core bet:** Different terminals deserve different levels of investment. Ghostty gets premium AX routing, popular terminals get good AppleScript routing, everything else gets basic `open -a`.

### Approach 5a: Three Tiers

```
Tier 1 (Premium):  Ghostty — AX tab routing (existing code)
Tier 2 (Good):     iTerm2, Terminal.app — AppleScript TTY focus
Tier 3 (Basic):    Everything else — `open -a` + tmux switch
```

- **How it works:** No grand abstraction. The activation function has a switch statement. Tier 1 is the existing Ghostty code. Tier 2 adds two AppleScript functions (~30 lines each). Tier 3 is the fallback. New terminals start at Tier 3 and graduate as needed.
- **Gains:** Pragmatic. Ships fast. Each tier is independently simple. Ghostty quality preserved. iTerm/Terminal.app get meaningful improvement over basic activation. No protocol overhead.
- **Gives up:** No formal extensibility story. Adding a Tier 2 terminal means modifying the switch. "Inelegant" by OOP standards.
- **Shines when:** You need to ship multi-terminal support quickly with high confidence and low risk.
- **Risks:** The switch statement accumulates cruft over time. If many terminals need Tier 2, you'll wish you had a protocol.
- **Complexity:** Simple (~200 lines total new code)

### Approach 5b: Three Tiers with Lightweight Registry

Same tiers, but register terminal handlers in a lookup table instead of a switch statement.

```swift
struct TerminalHandler: Sendable {
    let activate: @Sendable (String?, String?) async -> Bool  // tty, sessionName
}

let handlers: [ParentApp: TerminalHandler] = [
    .ghostty:  TerminalHandler(activate: ghosttyAXActivate),
    .iTerm:    TerminalHandler(activate: itermAppleScriptActivate),
    .terminal: TerminalHandler(activate: terminalAppAppleScriptActivate),
]

// Fallback: open -a + tmux switch
```

- **How it works:** Closures instead of protocols. A dictionary maps `ParentApp` to handler. Lookup + call. Falls back to generic activation for unknown terminals.
- **Gains:** Extensible without modifying a switch. Each handler is a standalone function. Testable (swap closures in tests).
- **Gives up:** Less discoverable than a protocol. Closures can accumulate captured state.
- **Shines when:** You want extensibility without protocol ceremony.
- **Risks:** Closure-based registries can become opaque. Debugging dispatch requires knowing the registration site.
- **Complexity:** Simple (~200-250 lines)

---

## Non-obvious options

### Reframe: Terminal-Agnostic via tmux Hooks

Instead of detecting and activating terminals, have tmux notify Capacitor when sessions change focus. Use `tmux set-hook -g client-session-changed` to write an event file. Capacitor watches this file. When the user manually switches terminals/tabs, Capacitor's dashboard updates to reflect what they're looking at — rather than Capacitor trying to control which terminal tab is focused.

This flips the control flow: instead of Capacitor → Terminal ("focus this tab"), it's Terminal → Capacitor ("the user is now looking at session X"). The dashboard becomes a pure observer. Activation becomes optional enhancement, not core functionality.

**Gains:** Works with ANY terminal. Zero per-terminal code. Simplifies the architecture dramatically.
**Gives up:** Loses the "click a card to jump to the session" UX entirely. Dashboard-only.

### Hybrid: TTY Registry + Lazy Strategy Loading

Combine Paradigm 3 (TTY-centric) with Paradigm 1b (minimal protocol) lazily:
- Start with a simple `focusByTty` function with hardcoded AppleScript per terminal (ship fast)
- Behind the scenes, track which approach works for each terminal
- If a terminal needs more sophisticated handling (e.g., Kitty socket protocol), load a richer strategy
- This is an evolutionary approach: start concrete, abstract only when complexity demands it

### iTerm2 tmux Control Mode (-CC)

iTerm2 supports `tmux -CC` which maps tmux panes to native iTerm2 panes. If Capacitor detected iTerm2 with tmux -CC mode, it could skip all AppleScript entirely — iTerm2 already knows exactly which native tab maps to which tmux session. Just activate the iTerm2 window and let tmux -CC handle the rest.

**Gains:** Zero Capacitor code for iTerm2 activation. Deepest possible integration.
**Gives up:** Only works if user runs `tmux -CC` (non-standard). Doesn't help Terminal.app or Ghostty.

---

## Eliminated early

### Full AX implementation for iTerm2 and Terminal.app
Both expose AX tab groups, but their AppleScript APIs are strictly superior — they provide TTY, session state, and direct selection that AX doesn't. AX would be more fragile and less capable. Only Ghostty needs AX because it lacks AppleScript TTY access.

### Python API for iTerm2
The Python API is iTerm2's recommended automation path, but it requires a WebSocket connection, async Python runtime, and Shell Integration. Too heavy for "focus a tab." AppleScript achieves the same result in 10 lines.

### Socket/IPC protocol abstraction
Kitty and WezTerm have socket protocols, but Ghostty and Terminal.app don't. Building an abstraction over heterogeneous IPC mechanisms adds complexity without covering the most important terminals.

### Port Rust resolver to Swift (Approach 2b)
Rewriting 2,345 lines of tested Rust logic in Swift creates a maintenance burden with no clear benefit. Either use the Rust resolver via FFI or don't use it at all.
