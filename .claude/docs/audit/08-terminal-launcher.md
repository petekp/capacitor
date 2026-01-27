# Session 8: Terminal Launcher Audit

**Date:** 2026-01-27
**Files Analyzed:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`, `apps/swift/Sources/Capacitor/Models/ActivationConfig.swift`
**Focus:** TTY matching, AppleScript reliability, terminal activation strategies

---

## Executive Summary

The Terminal Launcher is a **well-designed but complex** system that handles terminal activation across 6+ terminals and 4+ IDEs using a strategy pattern. Key findings:

- **High-severity issue:** Synchronous `Process.waitUntilExit()` on `@MainActor` blocks UI
- **Medium-severity:** AppleScript-based TTY lookup only works for iTerm and Terminal.app
- **Well-designed:** Strategy pattern provides graceful fallback chains
- **Correct:** PID liveness checks, exact-match shell matching, tmux prioritization

---

## Architecture Overview

```
┌──────────────────────┐
│    AppState          │
│  launchTerminal(for:)│
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐     ┌─────────────────────┐
│  TerminalLauncher    │────▶│  ShellStateStore    │
│                      │     │  (shell-cwd.json)   │
└──────────┬───────────┘     └─────────────────────┘
           │
           ├─────────────────────────────────┐
           │                                 │
           ▼                                 ▼
┌──────────────────────┐     ┌──────────────────────────┐
│  tmux direct query   │     │  ActivationConfigStore   │
│  (list-windows -a)   │     │  (strategy selection)    │
└──────────────────────┘     └────────────┬─────────────┘
                                          │
                      ┌───────────────────┼───────────────────┐
                      ▼                   ▼                   ▼
              ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
              │ activateBy  │     │ activateBy  │     │ switchTmux  │
              │ TTY (AS)    │     │ App         │     │ Session     │
              └─────────────┘     └─────────────┘     └─────────────┘
```

---

## Analysis Checklist Results

### 1. Correctness ✅

The launcher correctly implements the documented behavior:

**Shell Lookup Priority:**
1. tmux direct query (`findTmuxSessionForPath`) — most reliable
2. tmux shells from `shell-cwd.json`
3. non-tmux shells from `shell-cwd.json`
4. Launch new terminal if no match

**Evidence:** `launchTerminal(for:)` at lines 81-95

**Exact Match Policy:**
```swift
// Lines 239-245
if let match = shells.first(where: { $0.value.cwd == projectPath }) {
    return ShellMatch(pid: match.key, shell: match.value)
}
return nil
```
Correctly implements exact-match-only (no child path inheritance).

### 2. Atomicity ✅

No file writes occur in TerminalLauncher — it's read-only from `shell-cwd.json`. Strategy behavior overrides are written via `ActivationConfigStore` using `UserDefaults`, which is atomic.

### 3. Race Conditions ⚠️

**Finding 1: Stale Shell State During Activation**

**Severity:** Low
**Type:** Race condition
**Location:** `launchTerminal(for:)` lines 81-95

**Problem:**
The shell state passed to `launchTerminal` is a snapshot. If a shell exits between state capture and activation, the activation attempt will fail silently.

**Mitigation:**
- `isLiveShell()` validates PID with `kill(pid, 0)` before use
- Strategy fallbacks handle failures gracefully
- This is acceptable — the worst case is activating the wrong tab, not data corruption

### 4. Cleanup ✅

No persistent resources to clean up. `Process` objects are local scope and terminate naturally.

### 5. Error Handling ⚠️

**Finding 2: Silent Script Failures**

**Severity:** Medium
**Type:** Design limitation
**Location:** `runAppleScript()` and `runBashScript()` (lines 615-651)

**Problem:**
All script execution methods discard error information:
```swift
// Lines 618-621
try? process.run()  // Errors swallowed
process.waitUntilExit()  // Exit code ignored
```

**Impact:**
When terminal activation fails, there's no visibility into why. Users see no feedback.

**Recommendation:**
Consider logging failures to aid debugging:
```swift
if process.terminationStatus != 0 {
    print("[TerminalLauncher] Script failed with status \(process.terminationStatus)")
}
```

### 6. Documentation Accuracy ⚠️

**Finding 3: Terminal Capability Matrix Not Documented**

**Severity:** Low
**Type:** Missing documentation
**Location:** TTY-based activation methods (lines 310-342)

**Problem:**
The code silently only supports TTY-based tab selection for iTerm and Terminal.app. Other terminals (Ghostty, Alacritty, Warp) get `activateByApp` which activates the entire app but can't select the specific tab/window.

This limitation isn't documented in comments or CLAUDE.md.

**Recommendation:**
Document in file header or CLAUDE.md:
```
## Terminal Capability Matrix
| Terminal | Tab Selection | Method |
|----------|--------------|--------|
| iTerm | ✅ | AppleScript TTY query |
| Terminal.app | ✅ | AppleScript TTY query |
| kitty | ✅ | kitty @ focus-window --match pid: |
| Ghostty | ❌ | App activation only |
| Alacritty | ❌ | App activation only |
| Warp | ❌ | App activation only |
```

### 7. Dead Code ✅

No significant dead code. All strategy implementations are reachable through the config system.

---

## Critical Finding: Main Thread Blocking

**Finding 4: UI Thread Blocked by Synchronous Process Execution**

**Severity:** High
**Type:** Performance issue / Design flaw
**Location:** Multiple methods (lines 615-651)

**Problem:**
`TerminalLauncher` is marked `@MainActor`, but calls `process.waitUntilExit()` synchronously:

```swift
// Lines 619-620
try? process.run()
process.waitUntilExit()  // BLOCKS MAIN THREAD
```

This occurs in:
- `runAppleScript()` — called for TTY queries and activation
- `runAppleScriptWithResult()` — called for TTY discovery
- `hasTmuxClientAttached()` — called on every launch
- `findTmuxSessionForPath()` — called on every launch

**Impact:**
If AppleScript hangs (common with unresponsive apps) or tmux is slow, the entire UI freezes. Typical latency: 50-200ms per AppleScript call. Multiple calls chain up to 500ms+ of UI blocking.

**Evidence of existing awareness:**
```swift
// Line 102 - partial fix attempt with async dispatch
DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
    self?.activateTerminalApp()
}
```

This patterns shows awareness of timing issues but doesn't solve the blocking.

**Recommendation:**
Move process execution off the main thread:

```swift
private func runAppleScript(_ script: String) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
            process.waitUntilExit()
            continuation.resume()
        }
    }
}
```

Or use `Process.terminationHandler` for non-blocking execution.

---

## TTY Matching Analysis

### iTerm TTY Discovery (lines 482-498)

**How it works:**
AppleScript iterates all windows → tabs → sessions and compares TTY:
```applescript
repeat with s in sessions of t
    if tty of s is "/dev/ttys003" then
        return "found"
```

**Reliability:** Good. iTerm's AppleScript API is stable.

**Limitations:**
- Requires iTerm to be responsive
- O(windows × tabs × sessions) complexity

### Terminal.app TTY Discovery (lines 500-514)

**How it works:**
Similar AppleScript iteration, but Terminal.app has simpler structure (tabs directly in windows).

**Reliability:** Good. Terminal.app is always available on macOS.

### Why Other Terminals Aren't Supported

| Terminal | Reason TTY Selection Unavailable |
|----------|----------------------------------|
| Ghostty | No AppleScript support; uses config files |
| Alacritty | Headless terminal; no IPC protocol for window selection |
| Warp | Proprietary app with limited automation API |
| kitty | Has `kitty @` IPC but uses different approach (PID matching) |

---

## Shell Injection Analysis

**Finding 5: Shell Command Construction**

**Severity:** Low (defense in depth needed)
**Type:** Security consideration
**Location:** Multiple script construction sites

**Observation:**
Shell scripts are constructed via string interpolation:

```swift
// Line 101
runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")

// Line 387
runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")
```

**Current Safety:**
- `session` comes from `findTmuxSessionForPath()` which parses `tmux list-windows` output
- `projectPath` comes from internal `Project` struct
- `tty` comes from `shell-cwd.json` written by trusted `hud-hook`

All sources are internal/trusted. However, if tmux session names ever contain shell metacharacters (';', '$()', etc.), they could cause issues.

**Mitigation:**
The single quotes around `'\(session)'` provide basic protection against most injection, but not against single quotes in the session name itself.

**Recommendation:**
For robustness, escape single quotes in session names:
```swift
let safeSession = session.replacingOccurrences(of: "'", with: "'\\''")
```

---

## Strategy Pattern Analysis

### Strategy Dispatch (lines 284-306)

The strategy pattern is well-implemented:

```swift
@discardableResult
private func executeStrategy(_ strategy: ActivationStrategy, context: ActivationContext) -> Bool {
    switch strategy {
    case .activateByTTY: return activateByTTY(context: context)
    case .activateByApp: return activateByApp(context: context)
    // ... etc
    }
}
```

**Strengths:**
- Each strategy returns `Bool` for success/failure
- Fallback chains provide graceful degradation
- Configuration is user-customizable via `ActivationConfigStore`

**Fallback Chain Example (iTerm + tmux):**
1. `activateHostFirst` — find host terminal TTY, switch tmux
2. Falls back to `priorityFallback` — activate first running terminal

### Default Strategy Selection

`ScenarioBehavior.defaultBehavior(for:)` in `ActivationConfig.swift:177-265` provides sensible defaults:

| Category | Context | Strategy |
|----------|---------|----------|
| IDE | direct | `activateIDEWindow` |
| IDE | tmux | `activateIDEWindow` → `switchTmuxSession` |
| Terminal (TTY-capable) | direct | `activateByTTY` |
| Terminal (TTY-capable) | tmux | `activateHostFirst` |
| kitty | any | `activateKittyRemote` |
| Basic terminal | any | `activateByApp` |

---

## Cross-Reference with CLAUDE.md Gotchas

| Gotcha | Verified in Code |
|--------|------------------|
| "Exact-match-only for state resolution" | ✅ `findMatchingShell` line 241 |
| tmux prioritization | ✅ `findExistingShell` lines 177-181 |
| ParentApp string matching | ✅ Via `ParentApp(fromString:)` |

**Missing from CLAUDE.md:**
- TTY selection only works for iTerm and Terminal.app
- UI may briefly freeze during terminal activation

---

## Recommendations

### High Priority (Performance)

1. **Move process execution off main thread**
   - All `runAppleScript`, `runBashScript`, `hasTmuxClientAttached`, `findTmuxSessionForPath` should be async
   - Use `DispatchQueue.global` or Swift concurrency

### Medium Priority (Observability)

2. **Add failure logging**
   - Log when AppleScript fails
   - Log when fallback strategies are triggered
   - Consider debug mode for verbose logging

### Low Priority (Documentation)

3. **Document terminal capability matrix**
   - Which terminals support tab selection
   - Known limitations per terminal

4. **Add shell injection defense**
   - Escape single quotes in tmux session names
   - Defense in depth against future untrusted sources

---

## Summary

| Checklist Item | Status | Notes |
|----------------|--------|-------|
| Correctness | ✅ Pass | Exact-match, tmux prioritization correct |
| Atomicity | ✅ Pass | No file writes |
| Race Conditions | ⚠️ Acceptable | Fallbacks handle failures |
| Cleanup | ✅ Pass | No persistent resources |
| Error Handling | ⚠️ Needs work | Silent failures obscure issues |
| Documentation | ⚠️ Needs work | Capability matrix undocumented |
| Dead Code | ✅ Pass | All strategies reachable |

**Overall Assessment:** TerminalLauncher is functionally correct but has a high-severity performance issue (main thread blocking) that should be addressed. The strategy pattern provides good extensibility for supporting new terminals.

---

## Appendix: File Reference

| Line Range | Function | Purpose |
|------------|----------|---------|
| 81-95 | `launchTerminal(for:)` | Public entry point |
| 170-182 | `findExistingShell` | Shell lookup with tmux priority |
| 186-218 | `findTmuxSessionForPath` | Direct tmux query |
| 259-281 | `activateExistingTerminal` | Strategy dispatch |
| 310-342 | `activateByTTY` | TTY-based activation |
| 518-554 | `activateITermSession/TerminalAppSession` | AppleScript TTY selection |
| 615-651 | Script execution methods | Process spawning (blocks main thread) |
| 656-762 | `TerminalScripts` | Bash script templates |
