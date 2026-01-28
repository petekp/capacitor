# Terminal Activation API Contract

**Status:** ✅ Complete — Migration finished 2026-01-27
**Last Updated:** 2026-01-27
**Purpose:** Define the exact API boundary between Rust (decision logic) and Swift (execution)

> **Note:** The feature flag (`useRustActivationResolver`) has been removed. Rust is now the only activation path. ~277 lines of legacy Swift decision logic were deleted from `TerminalLauncher.swift`.

---

## 1. Design Principles

### 1.1 Separation of Concerns

| Layer | Responsibility | Language |
|-------|---------------|----------|
| **Decision** | What action to take based on state | Rust |
| **Execution** | Running macOS APIs, AppleScript, processes | Swift |

### 1.2 Key Constraints

1. **Rust is pure** — No side effects, no process spawning, no macOS APIs
2. **Rust is synchronous** — No async runtime required
3. **Swift remains the executor** — All "doing stuff" happens in Swift
4. **API is additive** — Never remove or rename UniFFI exports

---

## 2. Input/Output Boundary

### 2.1 Input: What Rust Receives

```rust
/// The complete shell state, as read from ~/.capacitor/shell-cwd.json
pub struct ShellCwdState {
    pub version: u32,
    pub shells: HashMap<String, ShellEntry>,
}

pub struct ShellEntry {
    pub cwd: String,
    pub tty: String,
    pub parent_app: ParentApp,
    pub tmux_session: Option<String>,
    pub tmux_client_tty: Option<String>,
    pub updated_at: String,  // ISO8601
}

/// Context about tmux state (Swift queries this, passes to Rust)
pub struct TmuxContext {
    /// Session name if one exists at the project path
    pub session_at_path: Option<String>,
    /// Whether any tmux client is currently attached
    pub has_attached_client: bool,
}
```

### 2.2 Output: What Rust Returns

```rust
/// The resolved activation decision
pub struct ActivationDecision {
    /// Primary action to attempt
    pub primary: ActivationAction,
    /// Fallback action if primary fails (Swift reports failure back)
    pub fallback: Option<ActivationAction>,
    /// Debug context for logging
    pub reason: String,
}

/// A single action for Swift to execute
pub enum ActivationAction {
    /// Activate a specific terminal app by TTY lookup (AppleScript)
    ActivateByTTY {
        tty: String,
        terminal_type: TerminalType,
    },

    /// Activate app by bringing its window to front
    ActivateApp {
        app_name: String,
    },

    /// Focus kitty window by shell PID
    ActivateKittyWindow {
        shell_pid: u32,
    },

    /// Activate IDE and run CLI to focus correct window
    ActivateIDEWindow {
        ide_type: IDEType,
        project_path: String,
    },

    /// Switch tmux session in attached client
    SwitchTmuxSession {
        session_name: String,
    },

    /// Discover host terminal via TTY, then switch tmux session
    ActivateHostThenSwitchTmux {
        host_tty: String,
        session_name: String,
    },

    /// Launch new terminal with tmux session
    LaunchTerminalWithTmux {
        session_name: String,
        project_path: String,
    },

    /// Launch new terminal at project path (no tmux)
    LaunchNewTerminal {
        project_path: String,
        project_name: String,
    },

    /// Activate first running terminal from priority list
    ActivatePriorityFallback,

    /// Do nothing
    Skip,
}

pub enum TerminalType {
    ITerm,
    TerminalApp,
    Ghostty,
    Alacritty,
    Kitty,
    Warp,
    Unknown,
}

pub enum IDEType {
    Cursor,
    VSCode,
    VSCodeInsiders,
    Zed,
}
```

---

## 3. Rust API Functions

### 3.1 Primary Resolver

```rust
#[uniffi::export]
impl HudEngine {
    /// Resolves what activation action to take for a project.
    ///
    /// This is the main entry point for terminal activation.
    /// Swift calls this, then executes the returned action.
    ///
    /// # Arguments
    /// * `project_path` - The absolute path to the project
    /// * `shell_state` - Current contents of shell-cwd.json (may be None if file missing)
    /// * `tmux_context` - Tmux state queried by Swift
    ///
    /// # Returns
    /// An `ActivationDecision` with primary action and optional fallback.
    pub fn resolve_activation(
        &self,
        project_path: String,
        shell_state: Option<ShellCwdStateFfi>,
        tmux_context: TmuxContextFfi,
    ) -> ActivationDecision;
}
```

### 3.2 Supporting Functions

```rust
#[uniffi::export]
impl HudEngine {
    /// Check if a shell PID is still alive.
    ///
    /// Used by Swift before executing TTY-based activation.
    /// This is a simple `kill(pid, 0)` check.
    pub fn is_pid_alive(&self, pid: u32) -> bool;

    /// Determine what type of terminal owns a TTY.
    ///
    /// Used when Swift needs to know which AppleScript to run.
    /// This is pure lookup from the shell state.
    pub fn terminal_type_for_tty(
        &self,
        tty: String,
        shell_state: Option<ShellCwdStateFfi>,
    ) -> Option<TerminalType>;
}
```

---

## 4. Action Vocabulary

### 4.1 All Distinct Actions

| Action | Swift Implementation | macOS APIs |
|--------|---------------------|------------|
| `ActivateByTTY` | Query iTerm/Terminal.app via AppleScript for TTY, select tab | `osascript` |
| `ActivateApp` | Find app by name, call `.activate()` | `NSWorkspace.runningApplications` |
| `ActivateKittyWindow` | Run `kitty @ focus-window --match pid:` | `Process` |
| `ActivateIDEWindow` | Activate app, run CLI (`cursor /path`) | `NSWorkspace`, `Process` |
| `SwitchTmuxSession` | Run `tmux switch-client -t '<session>'` | `Process` |
| `ActivateHostThenSwitchTmux` | TTY discovery + tmux switch | `osascript`, `Process` |
| `LaunchTerminalWithTmux` | Launch terminal app with tmux attach | `open -na`, `osascript` |
| `LaunchNewTerminal` | Run bash launch script | `Process` |
| `ActivatePriorityFallback` | Find first running terminal, activate | `NSWorkspace` |
| `Skip` | No-op | — |

### 4.2 Action Dependencies

```
ActivateByTTY
    └── Requires: tty string, terminal type
    └── May need: AppleScript query to confirm TTY exists

ActivateHostThenSwitchTmux
    └── Requires: host_tty (tmux_client_tty or tty), session_name
    └── Sequence: 1) Discover terminal by TTY, 2) Switch tmux session

LaunchTerminalWithTmux
    └── Requires: session_name, project_path
    └── Decision: Which terminal app to launch (priority order)
```

---

## 5. Error Handling

### 5.1 Rust-Side (Input Validation)

| Condition | Rust Behavior |
|-----------|---------------|
| `shell_state` is `None` | Proceed to tmux check or new terminal |
| `shell_state.shells` is empty | Same as None |
| Project path doesn't match any shell | Return tmux-based or new terminal action |
| PID in shell state is stale | Rust doesn't check (Swift filters later) |

### 5.2 Swift-Side (Execution Failures)

| Condition | Swift Behavior |
|-----------|---------------|
| `ActivateByTTY` fails (AppleScript error) | Try fallback action |
| `ActivateKittyWindow` fails (no remote control) | Try fallback action |
| `ActivateIDEWindow` fails (CLI not found) | Try fallback action |
| No fallback available | Log warning, do nothing |

### 5.3 Edge Cases

| Edge Case | Rust Decision |
|-----------|---------------|
| `shell-cwd.json` is empty | `tmux_context.session_at_path` → tmux action, else → `LaunchNewTerminal` |
| `shell-cwd.json` is corrupt | Swift passes `None`, same as empty |
| PID is stale (process died) | Swift filters before calling Rust |
| `tmux` not installed | Swift passes `tmux_context = { session_at_path: None, has_attached_client: false }` |
| Target terminal not running | Strategy fallback chain |
| Multiple shells at same path | Rust picks tmux shells first (more reliable activation) |

---

## 6. Scenario → Action Mapping

### 6.1 Priority Order

1. **Existing shell in shell-cwd.json** → Strategy-based activation
2. **Tmux session exists** → Tmux-based activation
3. **Neither** → Launch new terminal

### 6.2 Existing Shell Actions

Given a `ShellEntry` from shell-cwd.json:

| ParentApp | Tmux? | Action |
|-----------|-------|--------|
| iTerm | No | `ActivateByTTY { terminal_type: ITerm }` |
| iTerm | Yes | `ActivateHostThenSwitchTmux` |
| Terminal | No | `ActivateByTTY { terminal_type: TerminalApp }` |
| Terminal | Yes | `ActivateHostThenSwitchTmux` |
| Ghostty | No | `ActivateApp { app_name: "Ghostty" }` |
| Ghostty | Yes | `ActivateHostThenSwitchTmux` |
| Kitty | No | `ActivateKittyWindow { shell_pid }` |
| Kitty | Yes | `ActivateKittyWindow`, fallback: `SwitchTmuxSession` |
| Cursor | No | `ActivateIDEWindow { ide_type: Cursor }` |
| Cursor | Yes | `ActivateIDEWindow`, fallback: `SwitchTmuxSession` |
| Unknown | No | `ActivateByTTY`, fallback: `ActivatePriorityFallback` |
| Unknown | Yes | `ActivateHostThenSwitchTmux`, fallback: `ActivatePriorityFallback` |

### 6.3 Tmux Session (No Shell in State)

| Has Attached Client | Action |
|---------------------|--------|
| Yes | `SwitchTmuxSession { session_name }`, then `ActivatePriorityFallback` |
| No | `LaunchTerminalWithTmux { session_name, project_path }` |

### 6.4 No Existing Shell, No Tmux

```rust
LaunchNewTerminal { project_path, project_name }
```

---

## 7. Type Definitions (FFI-Safe)

### 7.1 New UniFFI Types

```rust
// ═══════════════════════════════════════════════════════════════════════════
// FFI Types for Terminal Activation
// ═══════════════════════════════════════════════════════════════════════════

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShellCwdStateFfi {
    pub version: u32,
    pub shells: HashMap<String, ShellEntryFfi>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ShellEntryFfi {
    pub cwd: String,
    pub tty: String,
    pub parent_app: ParentApp,  // Reuse existing enum
    pub tmux_session: Option<String>,
    pub tmux_client_tty: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TmuxContextFfi {
    pub session_at_path: Option<String>,
    pub has_attached_client: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ActivationDecision {
    pub primary: ActivationAction,
    pub fallback: Option<ActivationAction>,
    pub reason: String,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum ActivationAction {
    ActivateByTTY { tty: String, terminal_type: TerminalType },
    ActivateApp { app_name: String },
    ActivateKittyWindow { shell_pid: u32 },
    ActivateIDEWindow { ide_type: IDEType, project_path: String },
    SwitchTmuxSession { session_name: String },
    ActivateHostThenSwitchTmux { host_tty: String, session_name: String },
    LaunchTerminalWithTmux { session_name: String, project_path: String },
    LaunchNewTerminal { project_path: String, project_name: String },
    ActivatePriorityFallback,
    Skip,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum TerminalType {
    ITerm,
    TerminalApp,
    Ghostty,
    Alacritty,
    Kitty,
    Warp,
    Unknown,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum IDEType {
    Cursor,
    VSCode,
    VSCodeInsiders,
    Zed,
}
```

---

## 8. Swift Integration

### 8.1 Updated TerminalLauncher

```swift
@MainActor
final class TerminalLauncher {
    private let engine: HudEngine

    func launchTerminal(for project: Project, shellState: ShellCwdState?) async {
        // 1. Query tmux context
        let tmuxContext = await queryTmuxContext(projectPath: project.path)

        // 2. Ask Rust for decision
        let decision = engine.resolveActivation(
            projectPath: project.path,
            shellState: shellState?.toFfi(),
            tmuxContext: tmuxContext
        )

        // 3. Execute primary action
        let success = await executeAction(decision.primary)

        // 4. Try fallback if needed
        if !success, let fallback = decision.fallback {
            _ = await executeAction(fallback)
        }
    }

    private func executeAction(_ action: ActivationAction) async -> Bool {
        switch action {
        case .activateByTTY(let tty, let terminalType):
            return await activateByTTY(tty: tty, type: terminalType)
        case .activateApp(let appName):
            return activateAppByName(appName)
        case .activateKittyWindow(let pid):
            return activateKittyWindow(pid: pid)
        // ... etc
        }
    }
}
```

### 8.2 Feature Flag

```swift
final class TerminalLauncher {
    private var useRustResolver: Bool {
        UserDefaults.standard.bool(forKey: "useRustActivationResolver")
    }

    func launchTerminal(for project: Project, shellState: ShellCwdState?) async {
        if useRustResolver {
            await launchTerminalWithRustResolver(for: project, shellState: shellState)
        } else {
            await launchTerminalLegacy(for: project, shellState: shellState)
        }
    }
}
```

---

## 9. Testing Contract

### 9.1 Test Scenarios for Rust Resolver

| Scenario | Input | Expected Output |
|----------|-------|-----------------|
| Shell at path (Ghostty, no tmux) | `shells["123"] = { cwd: "/proj", parent_app: .ghostty }` | `ActivateApp { "Ghostty" }` |
| Shell at path (iTerm, no tmux) | `shells["123"] = { cwd: "/proj", parent_app: .iterm2 }` | `ActivateByTTY { type: ITerm }` |
| Shell at path (tmux) | `shells["123"] = { cwd: "/proj", tmux_session: "proj" }` | `ActivateHostThenSwitchTmux` |
| No shell, tmux session exists, client attached | `tmux_context = { session: "proj", attached: true }` | `SwitchTmuxSession`, fallback: `ActivatePriorityFallback` |
| No shell, tmux session exists, no client | `tmux_context = { session: "proj", attached: false }` | `LaunchTerminalWithTmux` |
| No shell, no tmux | `shells = {}, tmux_context = { session: None }` | `LaunchNewTerminal` |
| Multiple shells (tmux + non-tmux) | Both exist at same path | Prefer tmux shell (more reliable) |
| Unknown parent app | `parent_app: .unknown` | `ActivateByTTY`, fallback: `ActivatePriorityFallback` |

### 9.2 Edge Case Tests

| Test | Input | Expected |
|------|-------|----------|
| Empty shell state | `shells = {}` | Check tmux context |
| Nil shell state | `shell_state = None` | Check tmux context |
| Path with trailing slash | `"/proj/"` vs `"/proj"` | Normalized, both match |
| Multiple shells at same path | Two entries | Pick tmux shell first |

---

## 10. Open Decisions

### 10.1 Decided

| Question | Decision | Rationale |
|----------|----------|-----------|
| Single action vs fallback chain? | Primary + optional fallback | Matches current Swift behavior |
| Who queries tmux? | Swift queries, passes context to Rust | Keeps Rust pure (no process calls) |
| Dry run mode? | Not for v1 | Adds complexity, revisit later |

### 10.2 Still Open

| Question | Options | Impact |
|----------|---------|--------|
| Should Rust filter stale PIDs? | a) Rust filters, b) Swift filters | If Rust, need `kill(pid, 0)` in Rust. Recommendation: **Swift filters** |
| Config store in Rust? | a) Move to Rust, b) Keep in Swift | Overrides are per-scenario. Recommendation: **Keep in Swift for v1** |

---

## Summary

This contract defines a clean boundary:

1. **Swift provides:** Project path, shell state, tmux context
2. **Rust decides:** Which action(s) to take
3. **Swift executes:** macOS APIs, AppleScript, process calls

The API is:
- **Additive** — New actions can be added without breaking existing clients
- **Pure** — Rust does no side effects
- **Testable** — All Rust logic can be unit tested without mocking macOS
- **Backwards compatible** — Feature flag allows rollback
