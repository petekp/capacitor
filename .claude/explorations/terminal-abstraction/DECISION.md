# Decision: Terminal Abstraction Layer

## Selected Approach

**Hybrid Protocol + Universal Activation** — A single-method protocol (`TerminalActivator`) at the natural boundary where terminals genuinely diverge (tab focus), with universal app/window activation via NSRunningApplication + AX.

## Evidence for This Choice

### From first-principles research:
- **No single channel provides tab-level focus across all three terminals.** This is a hard constraint of what each terminal exposes, not a design choice.
  - Ghostty: AX only (no AppleScript dictionary, no IPC on macOS)
  - iTerm2: AppleScript only (AX doesn't expose individual tabs)
  - Terminal.app: AppleScript or AX (AppleScript more precise via TTY)
- **App activation via AppleScript is 40-400x slower** than NSRunningApplication.activate() + AX raise. Current code uses the slow path.
- **TTY is the most reliable identifier** for iTerm2 and Terminal.app. AX title matching is the only option for Ghostty.
- **In-process NSAppleScript is 20-30ms faster** than subprocess osascript.

### From codebase history:
- Gen 1 (ActivationConfig, 326 lines): Speculative scenario matrix, never wired in. Removed.
- Gen 2 (ActivationActionExecutor + 3 adapter protocols): Too much ceremony. 4 files, 1,200 lines of tests for what was a switch statement. Removed.
- Gen 3 (hardcoded Ghostty): Works but only supports one terminal. Current state.
- **Pattern: abstractions failed when they were too broad (Gen 1-2) or too narrow (Gen 3).** This design targets the exact boundary where terminals diverge.

### From analysis:
- The operation decomposes into universal (app activate, window raise) and per-terminal (tab focus). This is the natural joint.
- The protocol surface is minimal: one method, three implementations. No adapter layers, no scenario matrices.
- ~250 lines of new code. Well within complexity budget.

## Why Not the Alternatives

### Strategy Protocol with multiple methods (Approach 1a)
**Evidence:** Gen 2 had 3 protocols with multiple methods each (TmuxClient, TerminalDiscovery, TerminalLauncherClient). This created ceremony without value because most operations (tmux switching, app launching) don't actually vary by terminal. Only tab focus does. A multi-method protocol would rebuild Gen 2's mistake.

### Rust Resolver FFI reintegration (Approach 2a)
**Evidence:** The Rust resolver solves *which shell to activate* (ranking candidates). The terminal abstraction solves *how to activate a terminal*. These are orthogonal concerns. Coupling them conflates two problems. The resolver was removed from the Swift hot path because data conversion was fragile and added latency. Can be reintegrated independently later if needed.

### TTY-centric dispatch without protocol (Approach 3b)
**Evidence:** A switch statement with inline functions works for 3 terminals, but violates the engineering quality requirement. Functions living as loose closures or in a grab-bag file don't communicate intent. The protocol communicates "this is the boundary where terminals diverge" — which is architecturally true and worth naming.

### Tiered quality (Approach 5a)
**Evidence:** User explicitly requires uniform excellence across all supported terminals. Tiers contradict this requirement.

### Observation-first / de-emphasize activation (Approach 4)
**Evidence:** Multi-terminal support is a key differentiator vs. integrated terminals like cmux. Generic `open -a` is not competitive.

## Architecture

```
TerminalLauncher (orchestrator, existing file)
│
├── 1. Resolve tmux session           ← unchanged
├── 2. Ensure session exists           ← unchanged
├── 3. Switch tmux client              ← unchanged
├── 4. NSRunningApplication.activate() ← NEW: universal, 5ms
├── 5. AX window raise                 ← NEW: universal, 10ms
└── 6. activator.focusSession(...)     ← NEW: per-terminal dispatch
        │
        ├── GhosttyActivator    → AX tab title match → AXPress
        ├── ITermActivator      → NSAppleScript TTY match → select
        └── TerminalAppActivator → NSAppleScript TTY match → set selected
```

### Protocol

```swift
/// Focuses the correct tab/session within an already-activated terminal app.
protocol TerminalActivator: Sendable {
    func focusSession(sessionName: String, tty: String?) async -> Bool
}
```

### Detection & Factory

```swift
enum TerminalActivatorFactory {
    static func activator(for parentApp: ParentApp) -> (any TerminalActivator)? {
        switch parentApp {
        case .ghostty:  return GhosttyActivator()
        case .iTerm:    return ITermActivator()
        case .terminal: return TerminalAppActivator()
        default:        return nil  // unsupported terminal, app-level activation only
        }
    }
}
```

Detection sources (in priority order):
1. `ParentApp` from runtime snapshot (hud-hook already detects TERM_PROGRAM)
2. `NSWorkspace.shared.runningApplications` scan for known bundle IDs

### Files

| File | Status | Lines | Purpose |
|------|--------|-------|---------|
| `TerminalActivator.swift` | New | ~40 | Protocol + factory + universal activation helper |
| `GhosttyActivator.swift` | New | ~60 | AX tab focus, delegates to existing GhosttyAXReader |
| `ITermActivator.swift` | New | ~80 | NSAppleScript TTY-based session/tab focus |
| `TerminalAppActivator.swift` | New | ~70 | NSAppleScript TTY-based tab focus |
| `TerminalLauncher.swift` | Modified | -50/+30 | Extract Ghostty code, add activator dispatch |
| `GhosttyAXReader.swift` | Unchanged | — | Existing AX reading stays as-is |

## Implementation Plan

### Step 1: Create protocol and factory
- Create `TerminalActivator.swift` with the protocol, factory, and universal activation helpers
- Universal helpers: `activateApp(bundleId:)` via NSRunningApplication, `raiseWindow(_:)` via AX
- No behavior change yet

### Step 2: Extract GhosttyActivator
- Create `GhosttyActivator.swift`
- Move Ghostty-specific tab focus logic from `TerminalLauncher.performUnifiedActivation()` into `GhosttyActivator.focusSession()`
- GhosttyActivator calls existing `GhosttyAXReader` — no AX logic rewritten
- Wire into TerminalLauncher: replace inline Ghostty code with activator call
- Verify: Ghostty activation still works identically

### Step 3: Implement ITermActivator
- Create `ITermActivator.swift`
- In-process NSAppleScript: enumerate windows/tabs/sessions, match by TTY, select
- Handle edge cases: multiple windows, split panes, TTY matching failure
- Test manually with iTerm2

### Step 4: Implement TerminalAppActivator
- Create `TerminalAppActivator.swift`
- In-process NSAppleScript: enumerate windows/tabs, match by TTY, set selected
- Handle edge cases: multiple windows, no TTY match
- Test manually with Terminal.app

### Step 5: Replace slow AppleScript activation with universal path
- Replace `tell application "Ghostty" to activate` with `NSRunningApplication.activate()`
- Replace any `activateAppByName()` AppleScript calls with the universal AX path
- This is a perf win for ALL terminals including Ghostty

### Step 6: Wire up detection and dispatch
- Read `ParentApp` from runtime snapshot in TerminalLauncher
- Fall back to NSWorkspace bundle ID scan if snapshot doesn't have it
- Route to correct activator via factory
- Fall back to app-level activation (no tab focus) for unsupported terminals

### Step 7: Test and verify
- Manual QA: Ghostty (regression test), iTerm2, Terminal.app
- Verify tab focus precision for each
- Verify fallback behavior for unsupported terminals
- Run existing test suite to confirm no regressions

## Known Risks and Mitigations

### Risk: iTerm2 AppleScript TTY bug (GitLab #2921)
The `tty` property historically returned the same TTY for all split panes.
**Mitigation:** Test with split panes. If TTY is ambiguous, fall back to session name matching or tab index.

### Risk: AppleScript latency variability
NSAppleScript can take 100-500ms depending on window/tab count.
**Mitigation:** Acceptable for user-initiated activation. Add timeout handling. Consider caching window enumeration if repeated calls are needed.

### Risk: Swift 6.2 Sendable compliance
NSAppleScript isn't Sendable. In-process execution needs care.
**Mitigation:** Run AppleScript on a dedicated actor or use `@unchecked Sendable` wrapper. Or use `nonisolated(unsafe)` for the script compilation.

### Risk: AX permission requirement
Tab focus via AX (Ghostty) requires Accessibility permission.
**Mitigation:** Already required by current Ghostty code. No new permission needed. For iTerm2/Terminal.app, AppleScript doesn't require AX permission.

### Risk: Future Ghostty App Intents
Ghostty may add tab focus via App Intents (issue #10756), which would be cleaner than AX.
**Mitigation:** The protocol makes this a drop-in replacement. `GhosttyActivator` internals change, nothing else does.
