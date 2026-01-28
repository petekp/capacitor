# Terminal Activation System Inventory

**Status:** Phase 1 Complete
**Last Updated:** 2026-01-27
**Purpose:** Complete map of the current terminal activation system before refactoring

---

## 1. Entry Points

### 1.1 Swift Entry Points for TerminalLauncher

| Location | Method | Description |
|----------|--------|-------------|
| `AppState.swift:85` | Instance creation | `let terminalLauncher = TerminalLauncher()` |
| `AppState.swift:437` | `launchTerminal(for:shellState:)` | Primary entry point when user clicks a project card |
| `TerminalLauncher.swift:173` | `activateTerminalApp()` | Public method to activate any running terminal |

### 1.2 Shell State Access Points

| Location | File | Operation | Description |
|----------|------|-----------|-------------|
| `ShellStateStore.swift:42` | `~/.capacitor/shell-cwd.json` | Read (polling) | Polls every 500ms to load shell state |
| `TerminalLauncher.swift:113` | `shell-cwd.json` (via `ShellCwdState`) | Read | Searches for existing shell at project path |
| `cwd.rs:103` | `~/.capacitor/shell-cwd.json` | Write | Hook updates shell state on every precmd |

### 1.3 Current UniFFI Boundaries

| Type | Location | Direction | Notes |
|------|----------|-----------|-------|
| `ParentApp` enum | `types.rs:428-453` | Rust → Swift | Already exported, used for app identification |
| `HudEngine` | `engine.rs:46` | Rust → Swift | Main API facade, no activation logic yet |
| `Project` | `types.rs:102-116` | Rust → Swift | Project info passed to launcher |

**Key Insight:** Currently NO terminal activation logic is exposed via UniFFI. All decision-making happens in Swift.

---

## 2. Activation Flow (Current Behavior)

### 2.1 High-Level Decision Flow

```
User clicks project card
         │
         ▼
AppState.launchTerminal(for:)
         │
         ├── Sets manual override in ActiveProjectResolver
         │
         ▼
TerminalLauncher.launchTerminalAsync(for:shellState:)
         │
         ├── Priority 1: findExistingShell() → activateExistingTerminal()
         │       │
         │       ├── Searches shell-cwd.json for live PIDs at exact path
         │       ├── Prefers tmux shells over non-tmux (tmux switch-client is reliable)
         │       └── Returns ShellMatch(pid, shell) if found
         │
         ├── Priority 2: findTmuxSessionForPath() → switchToTmuxSessionAndActivate()
         │       │
         │       ├── Queries tmux list-windows for session at path
         │       ├── If client attached: tmux switch-client + activate terminal
         │       └── If no client: launchTerminalWithTmuxSession()
         │
         └── Priority 3: launchNewTerminal()
                 │
                 └── Runs bash script to launch preferred terminal with tmux
```

### 2.2 Activation Scenarios (from shell-cwd.json)

When `findExistingShell()` returns a match, the system builds a `ShellScenario`:

```swift
struct ShellScenario {
    let parentApp: ParentApp      // .ghostty, .iTerm, .cursor, etc.
    let context: ShellContext     // .direct or .tmux
    let multiplicity: TerminalMultiplicity  // .single or .multipleTabs
}
```

### 2.3 Strategy Selection Matrix

Based on `ShellScenario`, the system selects a `ScenarioBehavior`:

| Category | Context | Multiplicity | Primary Strategy | Fallback Strategy |
|----------|---------|--------------|------------------|-------------------|
| **IDE** | direct | single/tabs | `activateIDEWindow` | — |
| **IDE** | direct | windows | `activateIDEWindow` | `priorityFallback` |
| **IDE** | tmux | single/tabs | `activateIDEWindow` | `switchTmuxSession` |
| **IDE** | tmux | windows | `activateIDEWindow` | `activateHostFirst` |
| **Terminal (iTerm/Terminal.app)** | direct | any | `activateByTTY` | — |
| **Terminal (iTerm/Terminal.app)** | tmux | single/tabs | `activateHostFirst` | — |
| **Terminal (iTerm/Terminal.app)** | tmux | windows | `activateHostFirst` | `priorityFallback` |
| **Terminal (kitty)** | direct | any | `activateKittyRemote` | `activateByApp` |
| **Terminal (kitty)** | tmux | single/tabs | `activateKittyRemote` | `switchTmuxSession` |
| **Terminal (kitty)** | tmux | windows | `activateKittyRemote` | `activateHostFirst` |
| **Terminal (Ghostty/Alacritty/Warp)** | direct | single | `activateByApp` | — |
| **Terminal (Ghostty/Alacritty/Warp)** | direct | tabs/windows | `activateByApp` | `priorityFallback` |
| **Terminal (Ghostty/Alacritty/Warp)** | tmux | any | `activateHostFirst` | — |
| **Multiplexer (tmux)** | any | single/tabs | `activateHostFirst` | — |
| **Multiplexer (tmux)** | any | windows | `activateHostFirst` | `priorityFallback` |
| **Unknown** | direct | any | `activateByTTY` | `priorityFallback` |
| **Unknown** | tmux | any | `activateHostFirst` | `priorityFallback` |

### 2.4 Strategy Implementations

| Strategy | What It Does | macOS APIs Used |
|----------|--------------|-----------------|
| `activateByTTY` | Query iTerm/Terminal.app via AppleScript for TTY owner, select tab | `osascript`, `NSWorkspace` |
| `activateByApp` | Find running app by name, call `.activate()` | `NSWorkspace.shared.runningApplications` |
| `activateKittyRemote` | Activate kitty app, run `kitty @ focus-window --match pid:` | `Process`, `NSWorkspace` |
| `activateIDEWindow` | Activate IDE, run CLI (`cursor /path`, `code /path`) | `Process`, `NSWorkspace` |
| `switchTmuxSession` | Run `tmux switch-client -t '<session>'` | `Process` |
| `activateHostFirst` | Discover host terminal via `tmux_client_tty`, then switch tmux | AppleScript queries + `Process` |
| `launchNewTerminal` | Run bash script to launch preferred terminal with tmux | `Process` |
| `priorityFallback` | Activate first running terminal from priority list | `NSWorkspace` |
| `skip` | Do nothing | — |

---

## 3. External Dependencies

### 3.1 macOS APIs

| API | Location | Purpose |
|-----|----------|---------|
| `NSWorkspace.shared.runningApplications` | Multiple | Find running apps |
| `NSWorkspace.shared.frontmostApplication` | `activateTerminalApp()` | Get frontmost app |
| `NSRunningApplication.activate()` | Multiple | Bring app to front |
| `Process` / `/bin/bash` | Multiple | Run shell commands |
| `Process` / `/usr/bin/osascript` | AppleScript methods | Run AppleScript |
| `kill(pid, 0)` | `isLiveShell()` | Check if PID is alive |
| `FileManager.default.fileExists` | `isInstalled` | Check if app exists |

### 3.2 Shell Commands

| Command | Purpose | Error Handling |
|---------|---------|----------------|
| `tmux list-windows -a -F '#{session_name}\t#{pane_current_path}'` | Find tmux session at path | Returns nil on failure |
| `tmux list-clients` | Check if any tmux client attached | Empty output = no client |
| `tmux switch-client -t '<session>'` | Switch to tmux session | Stderr suppressed |
| `tmux attach-session -t '<session>'` | Attach to tmux session | Used in new terminal launch |
| `kitty @ focus-window --match pid:<pid>` | Focus kitty window by PID | Requires remote control enabled |
| `cursor <path>` / `code <path>` | Focus IDE window for project | Requires CLI in PATH |
| `open -na "App.app" --args ...` | Launch app with arguments | Used for Ghostty/Alacritty |
| `pgrep -xq "ProcessName"` | Check if process is running | Used in bash scripts |

### 3.3 AppleScript Operations

| Operation | Target | Purpose |
|-----------|--------|---------|
| Query sessions by TTY | iTerm2 | Find which tab owns a TTY |
| Select tab by TTY | iTerm2 | Bring specific tab to front |
| Query tabs by TTY | Terminal.app | Find which tab owns a TTY |
| Select tab by TTY | Terminal.app | Bring specific tab to front |
| Create window with command | iTerm2 | Launch new window with tmux |
| Do script | Terminal.app | Run command in Terminal |
| Activate | Various | Bring app to front |

### 3.4 Terminal App Capabilities

| Terminal | Tab Selection | API | Notes |
|----------|---------------|-----|-------|
| iTerm2 | ✅ Full | AppleScript | Query sessions by TTY |
| Terminal.app | ✅ Full | AppleScript | Query by TTY |
| kitty | ✅ Full | `kitty @` | Requires `allow_remote_control yes` |
| Ghostty | ❌ None | — | No external API |
| Warp | ❌ None | — | No AppleScript/CLI API |
| Alacritty | N/A | — | No tabs, windows only |
| Cursor/VS Code | ⚠️ Window only | CLI | No terminal panel focus |

---

## 4. Data Structures

### 4.1 Shell State (from `shell-cwd.json`)

```json
{
  "version": 1,
  "shells": {
    "12345": {
      "cwd": "/Users/pete/Code/myproject",
      "tty": "/dev/ttys003",
      "parent_app": "ghostty",
      "tmux_session": null,
      "tmux_client_tty": null,
      "updated_at": "2026-01-27T10:30:00Z"
    },
    "67890": {
      "cwd": "/Users/pete/Code/other",
      "tty": "/dev/pts/0",
      "parent_app": "tmux",
      "tmux_session": "myproject",
      "tmux_client_tty": "/dev/ttys003",
      "updated_at": "2026-01-27T10:31:00Z"
    }
  }
}
```

### 4.2 Swift Types (to be migrated)

| Type | Location | Purpose |
|------|----------|---------|
| `ShellEntry` | `ShellStateStore.swift:3-18` | Single shell entry from JSON |
| `ShellCwdState` | `ShellStateStore.swift:20-23` | Full shell state wrapper |
| `ShellMatch` | `TerminalLauncher.swift:56-59` | Match result with pid + shell |
| `ActivationContext` | `TerminalLauncher.swift:63-69` | Context for strategy execution |
| `ShellScenario` | `ActivationConfig.swift:158-166` | Scenario for behavior lookup |
| `ScenarioBehavior` | `ActivationConfig.swift:170-173` | Primary + fallback strategy |
| `ActivationStrategy` | `ActivationConfig.swift:114-154` | Strategy enum with 9 variants |

### 4.3 Rust Types (already exist)

| Type | Location | Purpose |
|------|----------|---------|
| `ParentApp` | `types.rs:428-453` | App identification enum |
| `ShellEntry` | `cwd.rs:65-76` | Shell entry (hook writes this) |
| `ShellCwdState` | `cwd.rs:50-63` | Full state (hook writes this) |

---

## 5. Known Issues / Bugs

### 5.1 Current Bug (Reason for Refactor)

**Scenario:** Tmux session exists at project path, but no client is attached.

**Expected:** Launch new terminal window that attaches to the existing tmux session.

**Actual:** `launchTerminalWithTmuxSession()` is called correctly, but the logic in the bash script may fail or open a new session instead of attaching.

**Location:** `TerminalLauncher.swift:149-171`

### 5.2 Other Issues Noted

| Issue | Impact | Location |
|-------|--------|----------|
| Main thread blocking | UI jank on slow AppleScript | `activateTerminalAsync` and async methods |
| Kitty remote control optional | May fail silently | `activateKittyRemote()` |
| IDE terminal focus impossible | Cannot focus terminal panel | `activateIDEWindow()` |

---

## 6. Decision Points for Phase 2

### 6.1 What Should Move to Rust?

**Candidates:**
1. `findExistingShell()` - Pure logic, reads shell state
2. `ShellScenario` construction - Pure data transformation
3. `ScenarioBehavior` lookup - Pure lookup from scenario
4. Strategy selection - Pure decision-making

**NOT Candidates (must stay in Swift):**
1. All macOS API calls (`NSWorkspace`, `NSRunningApplication`)
2. All AppleScript execution
3. All `Process` execution
4. File system access (handled by existing polling)

### 6.2 API Contract Questions

1. **Input to Rust:** What data does Rust receive?
   - Project path (String)
   - Shell state (full `ShellCwdState` or parsed subset?)
   - Tmux query results? (Or should Rust NOT query tmux?)

2. **Output from Rust:** What does Rust return?
   - Single action enum?
   - Action sequence (primary + fallback)?
   - Decision tree result?

3. **Error handling:**
   - What happens when shell-cwd.json is empty?
   - What happens when a referenced PID is stale?
   - How does Rust communicate "no shell found, check tmux"?

---

## 7. Files to Modify

### 7.1 Rust (New Code)

| File | Purpose |
|------|---------|
| `core/hud-core/src/activation.rs` | New module for activation resolver |
| `core/hud-core/src/lib.rs` | Export new module |
| `core/hud-core/src/engine.rs` | Add UniFFI-exported resolver function |
| `core/hud-core/src/types.rs` | Add activation-related types |

### 7.2 Swift (Modifications)

| File | Change |
|------|--------|
| `TerminalLauncher.swift` | Call Rust resolver, keep strategy execution |
| `ActivationConfig.swift` | May move types to Rust or keep for now |
| `ShellStateStore.swift` | No changes expected |

### 7.3 Tests (New)

| File | Purpose |
|------|---------|
| `core/hud-core/src/activation/tests.rs` | Unit tests for resolver |
| `CapacitorTests/TerminalActivationTests.swift` | Integration tests |

---

## 8. Appendix: Full Strategy Implementation Code

For reference, here are the key strategy implementations from `TerminalLauncher.swift`:

### activateByTTY
```swift
private func activateByTTY(context: ActivationContext) async -> Bool {
    let tty = context.shell.tty
    let parentApp = ParentApp(fromString: context.shell.parentApp)

    // If we know the parent, use direct activation
    if parentApp.category == .terminal {
        switch parentApp {
        case .iTerm: activateITermSession(tty: tty); return true
        case .terminal: activateTerminalAppSession(tty: tty); return true
        default: break
        }
    }

    // Otherwise, discover via AppleScript queries
    if let owningTerminal = await discoverTerminalOwningTTY(tty: tty) {
        // activate based on discovered terminal
    }
    return false
}
```

### activateHostFirst
```swift
private func activateHostFirst(context: ActivationContext) async -> Bool {
    let hostTTY = context.shell.tmuxClientTty ?? context.shell.tty
    let ttyActivated = await activateTerminalByTTYDiscovery(tty: hostTTY)

    if let session = context.shell.tmuxSession {
        runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")
    }
    return ttyActivated
}
```

### switchToTmuxSessionAndActivate
```swift
private func switchToTmuxSessionAndActivate(session: String) async {
    if await hasTmuxClientAttached() {
        runBashScript("tmux switch-client -t '\(session)' 2>/dev/null")
        try? await Task.sleep(nanoseconds: 100_000_000)
        activateTerminalApp()
    } else {
        launchTerminalWithTmuxSession(session)
    }
}
```

---

## Summary

The terminal activation system is a complex piece of Swift code with:
- **~800 lines** in `TerminalLauncher.swift`
- **~320 lines** in `ActivationConfig.swift`
- **9 activation strategies**
- **Heavy macOS integration** (AppleScript, NSWorkspace, Process)
- **Decision logic** that's a good candidate for Rust migration

The goal of the refactor is to move the **decision-making** (which strategy to use) to Rust while keeping the **execution** (actually running AppleScript, activating apps) in Swift.
