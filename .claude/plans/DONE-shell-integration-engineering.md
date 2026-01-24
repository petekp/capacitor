# Shell Integration: Engineering Specification

**Status:** DONE
**Companion Doc:** [Shell Integration PRD](./ACTIVE-shell-integration-prd.md)
**Created:** 2025-01-23
**Last Updated:** 2025-01-24

---

## Overview

This document specifies the technical implementation for shell integration in Capacitor. The architecture is designed from first principles for accuracy and simplicity—no legacy compatibility concerns.

**Core principle:** The shell knows where you are. Instead of polling external tools (tmux) and guessing, we let the shell *push* state changes as they happen.

---

## Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SIGNAL SOURCES                                     │
│                                                                             │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │ Claude Sessions │  │  Shell CWD      │  │ Frontmost App   │             │
│  │ (sessions.json) │  │ (shell-cwd.json)│  │ (NSWorkspace)   │             │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘             │
│           │                    │                    │                       │
│           └────────────────────┼────────────────────┘                       │
│                                ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    ActiveProjectResolver                             │   │
│  │                                                                      │   │
│  │  Resolution Order:                                                   │   │
│  │  1. Active Claude session (user explicitly started Claude here)     │   │
│  │  2. Most recently updated shell CWD (user is/was just here)        │   │
│  │                                                                      │   │
│  │  Output: activeProject + source attribution                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
User types `cd ~/Code/my-project` and presses Enter
    ↓
Command executes, shell prepares next prompt
    ↓
Shell precmd hook fires (zsh/bash/fish)
    ↓
Hook spawns: hud-hook cwd "$PWD" "$$" "$TTY" &!
    ↓ (backgrounded, <10ms, user never waits)
hud-hook:
  1. Reads existing shell-cwd.json
  2. Updates/inserts entry for this PID
  3. Removes entries for dead PIDs
  4. Detects parent app (Cursor, VSCode, iTerm, etc.)
  5. Writes shell-cwd.json atomically
  6. Appends to shell-history.jsonl (if CWD changed)
  7. Exits
    ↓
Shell displays next prompt (user continues working)
    ↓
Capacitor app polls shell-cwd.json (500ms interval)
    ↓
ActiveProjectResolver combines signals
    ↓
UI updates: correct project card highlighted
```

### Key Design Decisions

#### Push vs. Pull

**Old approach (pull):** Poll tmux every 500ms with subprocess calls, walk process trees, fuzzy-match session names.

**New approach (push):** Shell tells us exactly when CWD changes. We just read a file.

Benefits:
- **Faster:** File read vs. multiple subprocess spawns
- **Accurate:** Exact CWD, not heuristic matching
- **Universal:** Works in any terminal, with or without tmux
- **Simpler:** No process tree walking, no fuzzy matching

#### Parent App Detection

Detected once per CWD change in the hook (not via polling). The hook walks the process tree to find known terminal/IDE applications:

- Cursor, VSCode, VSCode Insiders
- Ghostty, iTerm2, Terminal, Alacritty, kitty, Warp
- tmux (if present in tree)

This is done asynchronously after writing state, so it doesn't block the shell.

#### What Gets Deleted

| Component | Reason for Removal |
|-----------|-------------------|
| `TerminalTracker.swift` | tmux-specific polling; replaced by shell push |
| tmux session matching | Shell CWD is authoritative |
| Process tree polling | Parent detected by hook, not Swift |
| Fuzzy name matching | No longer needed |

---

## Component Specifications

### Component 1: `hud-hook cwd` Subcommand

**Location:** `core/hud-hook/src/cwd.rs`

#### CLI Interface

```
hud-hook cwd <path> <pid> <tty>

Arguments:
  <path>  Absolute path to current working directory
  <pid>   Shell process ID
  <tty>   Terminal device path (e.g., /dev/ttys003)

Exit codes:
  0  Success
  1  Invalid arguments
  2  Failed to write state file
```

#### Implementation

```rust
// core/hud-hook/src/cwd.rs

use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Serialize, Deserialize)]
pub struct ShellCwdState {
    pub version: u32,
    pub shells: HashMap<String, ShellEntry>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ShellEntry {
    pub cwd: String,
    pub tty: String,
    pub parent_app: Option<String>,
    pub updated_at: chrono::DateTime<Utc>,
}

pub fn handle_cwd(path: &str, pid: u32, tty: &str) -> Result<(), CwdError> {
    let state_dir = dirs::home_dir()
        .ok_or(CwdError::NoHomeDir)?
        .join(".capacitor");

    std::fs::create_dir_all(&state_dir)?;

    let cwd_path = state_dir.join("shell-cwd.json");
    let history_path = state_dir.join("shell-history.jsonl");

    // 1. Load existing state
    let mut state = load_state(&cwd_path).unwrap_or_else(|_| ShellCwdState {
        version: 1,
        shells: HashMap::new(),
    });

    // 2. Check if CWD actually changed (for history)
    let previous_cwd = state.shells.get(&pid.to_string()).map(|e| e.cwd.clone());
    let cwd_changed = previous_cwd.as_deref() != Some(path);

    // 3. Detect parent app (done inline, fast enough)
    let parent_app = detect_parent_app(pid).ok();

    // 4. Update entry for this shell
    state.shells.insert(pid.to_string(), ShellEntry {
        cwd: path.to_string(),
        tty: tty.to_string(),
        parent_app: parent_app.clone(),
        updated_at: Utc::now(),
    });

    // 5. Clean up dead shells
    state.shells.retain(|pid_str, _| {
        pid_str.parse::<u32>()
            .map(process_exists)
            .unwrap_or(false)
    });

    // 6. Write state atomically
    write_state_atomic(&cwd_path, &state)?;

    // 7. Append to history if CWD changed
    if cwd_changed {
        append_history(&history_path, path, pid, tty, parent_app.as_deref())?;
    }

    Ok(())
}

fn process_exists(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn write_state_atomic(path: &Path, state: &ShellCwdState) -> Result<(), CwdError> {
    let temp = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
    serde_json::to_writer_pretty(&temp, state)?;
    temp.persist(path)?;
    Ok(())
}

fn append_history(
    path: &Path,
    cwd: &str,
    pid: u32,
    tty: &str,
    parent_app: Option<&str>,
) -> Result<(), CwdError> {
    use std::io::Write;

    let entry = serde_json::json!({
        "cwd": cwd,
        "pid": pid,
        "tty": tty,
        "parent_app": parent_app,
        "timestamp": Utc::now().to_rfc3339(),
    });

    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;

    writeln!(file, "{}", entry)?;
    Ok(())
}
```

#### Parent App Detection

```rust
// core/hud-hook/src/cwd.rs (continued)

const KNOWN_APPS: &[(&str, &str)] = &[
    // IDEs (check first - they contain terminal emulators)
    ("Cursor Helper", "cursor"),
    ("Cursor", "cursor"),
    ("Code Helper", "vscode"),
    ("Code - Insiders", "vscode-insiders"),
    ("Code", "vscode"),
    // Terminal emulators
    ("Ghostty", "ghostty"),
    ("iTerm2", "iterm2"),
    ("Terminal", "terminal"),
    ("Alacritty", "alacritty"),
    ("kitty", "kitty"),
    ("WarpTerminal", "warp"),
    ("Warp", "warp"),
    // Multiplexers
    ("tmux", "tmux"),
];

fn detect_parent_app(pid: u32) -> Result<String, ProcessError> {
    let mut current_pid = pid;

    for _ in 0..20 {  // Max depth to prevent infinite loops
        let ppid = get_parent_pid(current_pid)?;

        if ppid <= 1 {
            return Err(ProcessError::NotFound);
        }

        let name = get_process_name(ppid)?;

        for (pattern, app_id) in KNOWN_APPS {
            if name.contains(pattern) {
                return Ok(app_id.to_string());
            }
        }

        current_pid = ppid;
    }

    Err(ProcessError::NotFound)
}

fn get_parent_pid(pid: u32) -> Result<u32, ProcessError> {
    use std::process::Command;

    let output = Command::new("ps")
        .args(["-o", "ppid=", "-p", &pid.to_string()])
        .output()?;

    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .map_err(|_| ProcessError::ParseError)
}

fn get_process_name(pid: u32) -> Result<String, ProcessError> {
    use std::process::Command;

    let output = Command::new("ps")
        .args(["-o", "comm=", "-p", &pid.to_string()])
        .output()?;

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}
```

#### Performance Requirements

| Metric | Target | Maximum |
|--------|--------|---------|
| Total execution time | < 15ms | 50ms |
| File I/O | Atomic | - |
| Memory | < 5MB | 10MB |

---

### Component 2: Data Schemas

#### shell-cwd.json (Current State)

```json
{
  "version": 1,
  "shells": {
    "54321": {
      "cwd": "/Users/dev/Code/my-project",
      "tty": "/dev/ttys003",
      "parent_app": "cursor",
      "updated_at": "2025-01-15T10:30:00.123Z"
    },
    "54400": {
      "cwd": "/Users/dev/Code/other-project",
      "tty": "/dev/ttys004",
      "parent_app": "iterm2",
      "updated_at": "2025-01-15T10:28:15.456Z"
    }
  }
}
```

#### shell-history.jsonl (Append-Only Log)

One JSON object per line:

```jsonl
{"cwd":"/Users/dev/Code/my-project","pid":54321,"tty":"/dev/ttys003","parent_app":"cursor","timestamp":"2025-01-15T10:30:00Z"}
{"cwd":"/Users/dev/Code/my-project/src","pid":54321,"tty":"/dev/ttys003","parent_app":"cursor","timestamp":"2025-01-15T10:30:45Z"}
```

**Why JSONL?**
- Append-only (no read-modify-write)
- Corruption-resistant (bad line doesn't affect others)
- Simple rotation (truncate or archive)

#### History Retention

```rust
const DEFAULT_RETENTION_DAYS: u64 = 30;

pub fn cleanup_history(history_path: &Path, retention_days: u64) -> Result<(), Error> {
    let cutoff = Utc::now() - chrono::Duration::days(retention_days as i64);

    // Read, filter, rewrite atomically
    let temp = tempfile::NamedTempFile::new_in(history_path.parent().unwrap())?;
    let mut writer = std::io::BufWriter::new(&temp);

    for line in std::io::BufReader::new(std::fs::File::open(history_path)?).lines() {
        let line = line?;
        if let Ok(entry) = serde_json::from_str::<HistoryEntry>(&line) {
            if entry.timestamp >= cutoff {
                writeln!(writer, "{}", line)?;
            }
        }
    }

    writer.flush()?;
    temp.persist(history_path)?;
    Ok(())
}
```

---

### Component 3: Swift App Integration

#### ShellStateStore

Reads `shell-cwd.json` with polling. Simple, no business logic.

```swift
// apps/swift/Sources/Capacitor/Stores/ShellStateStore.swift

import Foundation

struct ShellEntry: Codable, Equatable {
    let cwd: String
    let tty: String
    let parentApp: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case cwd, tty
        case parentApp = "parent_app"
        case updatedAt = "updated_at"
    }
}

struct ShellCwdState: Codable {
    let version: Int
    let shells: [String: ShellEntry]
}

@Observable
final class ShellStateStore {
    private let stateURL: URL
    private var pollTask: Task<Void, Never>?

    private(set) var state: ShellCwdState?

    init() {
        self.stateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor/shell-cwd.json")
    }

    func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.loadState()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let decoded = try? JSONDecoder.iso8601.decode(ShellCwdState.self, from: data) else {
            return
        }
        state = decoded
    }

    /// Returns the most recently updated shell entry with its PID
    var mostRecentShell: (pid: String, entry: ShellEntry)? {
        state?.shells
            .max(by: { $0.value.updatedAt < $1.value.updatedAt })
            .map { ($0.key, $0.value) }
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
```

#### ActiveProjectResolver

The **single source of truth** for active project. Replaces `TerminalTracker`.

```swift
// apps/swift/Sources/Capacitor/Services/ActiveProjectResolver.swift

import Foundation

enum ActiveSource: Equatable {
    case claude(sessionId: String)
    case shell(pid: String, app: String?)
    case none
}

@Observable
final class ActiveProjectResolver {
    private let sessionStateManager: SessionStateManager
    private let shellStateStore: ShellStateStore
    private let projectStore: ProjectStore

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    init(
        sessionStateManager: SessionStateManager,
        shellStateStore: ShellStateStore,
        projectStore: ProjectStore
    ) {
        self.sessionStateManager = sessionStateManager
        self.shellStateStore = shellStateStore
        self.projectStore = projectStore
    }

    /// Call on timer or when underlying state changes
    func resolve() {
        // Priority 1: Active Claude session
        if let session = sessionStateManager.activeSession,
           let project = projectStore.project(containing: session.cwd) {
            activeProject = project
            activeSource = .claude(sessionId: session.sessionId)
            return
        }

        // Priority 2: Most recent shell CWD
        if let (pid, shell) = shellStateStore.mostRecentShell,
           let project = projectStore.project(containing: shell.cwd) {
            activeProject = project
            activeSource = .shell(pid: pid, app: shell.parentApp)
            return
        }

        // No active project
        activeProject = nil
        activeSource = .none
    }
}
```

#### TerminalLauncher (Simplified)

Keep terminal launching, remove tracking.

```swift
// apps/swift/Sources/Capacitor/Services/TerminalLauncher.swift

import AppKit

@MainActor
final class TerminalLauncher {

    func launchTerminal(for project: Project, claudePath: String) {
        let script = launchScript(project: project, claudePath: claudePath)
        runBashScript(script)

        // Give terminal time to open, then activate it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.activateTerminalApp()
        }
    }

    func activateTerminalApp() {
        // If a terminal is already frontmost, just activate it
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           isTerminalApp(frontmost) {
            frontmost.activate()
            return
        }

        // Otherwise, find and activate first available terminal
        for terminal in TerminalApp.priorityOrder {
            if let app = findRunningTerminal(terminal) {
                app.activate()
                return
            }
        }
    }

    private func isTerminalApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleId = app.bundleIdentifier else { return false }
        return TerminalApp.allBundleIds.contains(bundleId)
    }

    private func findRunningTerminal(_ terminal: TerminalApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            app.bundleIdentifier == terminal.bundleId
        }
    }

    private func runBashScript(_ script: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.environment = Self.shellEnvironment
        try? process.run()
    }

    private static var shellEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let paths = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = paths + ":" + (env["PATH"] ?? "")
        return env
    }

    private func launchScript(project: Project, claudePath: String) -> String {
        // Simplified: just cd and optionally attach to tmux if available
        """
        cd "\(project.path)"
        if command -v tmux &>/dev/null && [ -n "$TMUX" ]; then
            tmux new-window -c "\(project.path)" 2>/dev/null || true
        fi
        """
    }
}
```

#### AppState Integration

```swift
// In AppState.swift, replace terminalIntegration usage:

@Observable
final class AppState {
    // Old (remove)
    // let terminalIntegration = TerminalIntegration()

    // New
    let shellStateStore = ShellStateStore()
    let activeProjectResolver: ActiveProjectResolver
    let terminalLauncher = TerminalLauncher()

    var activeProject: Project? {
        activeProjectResolver.activeProject
    }

    var activeSource: ActiveSource {
        activeProjectResolver.activeSource
    }

    // In initialization, wire up resolver
    init(...) {
        self.activeProjectResolver = ActiveProjectResolver(
            sessionStateManager: sessionStateManager,
            shellStateStore: shellStateStore,
            projectStore: projectStore
        )
    }

    func startTracking() {
        shellStateStore.startPolling()
        // Resolve on timer alongside existing session state refresh
    }
}
```

---

### Component 4: Setup Flow

#### Setup Detection

Add shell integration to existing setup checks.

```swift
// In SetupChecker or SetupRequirementsManager

func isShellIntegrationConfigured() -> Bool {
    // Check if we've received shell CWD reports
    guard let state = shellStateStore.state else {
        return false
    }
    return !state.shells.isEmpty
}

func shellIntegrationInstructions() -> ShellSetupInstructions {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let shellName = URL(fileURLWithPath: shell).lastPathComponent

    switch shellName {
    case "zsh":  return .zsh
    case "bash": return .bash
    case "fish": return .fish
    default:     return .unsupported(shellName)
    }
}

enum ShellSetupInstructions {
    case zsh
    case bash
    case fish
    case unsupported(String)

    var configFile: String {
        switch self {
        case .zsh:  return "~/.zshrc"
        case .bash: return "~/.bashrc"
        case .fish: return "~/.config/fish/config.fish"
        case .unsupported: return ""
        }
    }

    var snippet: String {
        switch self {
        case .zsh:
            return """
            # Capacitor shell integration
            if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
              _capacitor_precmd() {
                "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$TTY" 2>/dev/null &!
              }
              precmd_functions+=(_capacitor_precmd)
            fi
            """
        case .bash:
            return """
            # Capacitor shell integration
            if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
              _capacitor_prompt() {
                "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$(tty)" 2>/dev/null &
              }
              PROMPT_COMMAND="_capacitor_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
            fi
            """
        case .fish:
            return """
            # Capacitor shell integration
            if test -x "$HOME/.local/bin/hud-hook"
              function _capacitor_postexec --on-event fish_postexec
                "$HOME/.local/bin/hud-hook" cwd "$PWD" "$fish_pid" (tty) 2>/dev/null &
              end
            end
            """
        case .unsupported(let name):
            return "# Shell integration not available for \(name)"
        }
    }
}
```

#### Setup Card UI

Add to existing setup card system.

```swift
struct ShellIntegrationSetupCard: View {
    @Environment(AppState.self) private var appState
    @State private var showingInstructions = false
    @State private var copied = false

    var body: some View {
        SetupCard(
            icon: "terminal",
            title: "Shell Integration",
            description: "Track your active project across all terminals",
            isComplete: appState.isShellIntegrationConfigured,
            action: { showingInstructions = true }
        )
        .sheet(isPresented: $showingInstructions) {
            ShellInstructionsSheet(copied: $copied)
        }
    }
}

struct ShellInstructionsSheet: View {
    let instructions = ShellSetupInstructions.current
    @Binding var copied: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to \(instructions.configFile)")
                .font(.headline)

            ScrollView {
                Text(instructions.snippet)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(8)
            }
            .frame(maxHeight: 200)

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(instructions.snippet, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Done") { dismiss() }
            }

            Text("Restart your terminal after adding this snippet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 500)
    }
}
```

---

## Files to Delete

After implementing shell integration, remove these legacy files:

| File | Reason |
|------|--------|
| `apps/swift/Sources/Capacitor/Utils/TerminalTracker.swift` | Replaced by shell push model |
| tmux querying code in `TerminalIntegration.swift` | No longer needed |
| Process tree walking for terminal detection | Parent app detected by hook |

---

## Phased Delivery

### Phase 1: Foundation (Target: 1 week)

**Rust:**
- [ ] Add `cwd` subcommand to `hud-hook` CLI
- [ ] Implement `ShellCwdState` types and serialization
- [ ] Atomic state file writes
- [ ] Dead PID cleanup on write
- [ ] Parent app detection
- [ ] Unit tests

**Swift:**
- [ ] `ShellStateStore` (read-only, polling)
- [ ] Shell snippet constants

**Acceptance Criteria:**
- `hud-hook cwd /path 12345 /dev/ttys000` creates `shell-cwd.json`
- Swift app reads and decodes state file
- Parent app correctly detected for Cursor/VSCode/terminals

### Phase 2: Integration (Target: 1 week)

**Swift:**
- [ ] `ActiveProjectResolver` combining all signals
- [ ] Replace `TerminalTracker` usage in `AppState`
- [ ] Delete `TerminalTracker.swift`
- [ ] Simplify `TerminalIntegration` → `TerminalLauncher`
- [ ] Project highlighting from resolver
- [ ] Integration tests

**Acceptance Criteria:**
- HUD highlights correct project when user `cd`s
- Works in VSCode/Cursor integrated terminals
- Works without tmux installed
- Existing Claude session detection still works

### Phase 3: Setup & History (Target: 1 week)

**Setup:**
- [ ] Shell integration check in setup flow
- [ ] Setup card with instructions
- [ ] Copy-to-clipboard functionality

**History:**
- [ ] `shell-history.jsonl` append on CWD change
- [ ] History retention/cleanup (30 days default)
- [ ] `ShellHistoryStore` for reading history
- [ ] Recent projects from shell history (optional, v1.1)

**Acceptance Criteria:**
- New users guided through shell setup
- History file grows with CWD changes
- Old entries cleaned up automatically

### Phase 4: Polish (Target: 3 days)

- [ ] Performance benchmarking (< 15ms hook execution)
- [ ] Edge cases: symlinks, network paths, special characters
- [ ] Error handling and graceful degradation
- [ ] Documentation update

---

## Testing Strategy

### Unit Tests (Rust)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_cwd_creates_state_file() {
        let temp = TempDir::new().unwrap();
        // ... test atomic creation
    }

    #[test]
    fn test_cwd_cleans_dead_pids() {
        // Insert entry with non-existent PID
        // Run cwd with valid PID
        // Assert dead PID removed
    }

    #[test]
    fn test_history_appends_only_on_change() {
        // Same CWD twice → 1 history entry
        // Different CWD → 2 history entries
    }

    #[test]
    fn test_parent_app_detection() {
        // Mock process tree
        // Assert correct app detected
    }
}
```

### Integration Tests (Swift)

```swift
final class ActiveProjectResolverTests: XCTestCase {
    func testClaudeSessionTakesPriority() {
        // Setup: Claude session active + shell in different project
        // Assert: Claude session's project is active
    }

    func testShellCwdUsedWhenNoClaudeSession() {
        // Setup: No Claude session, shell CWD set
        // Assert: Shell's project is active
    }

    func testMostRecentShellWins() {
        // Setup: Multiple shell entries
        // Assert: Most recently updated is used
    }
}
```

### Manual Testing Checklist

- [ ] zsh: Add snippet, `cd` to project, verify highlight
- [ ] bash: Add snippet, `cd` to project, verify highlight
- [ ] VSCode integrated terminal: Verify parent_app = "vscode"
- [ ] Cursor integrated terminal: Verify parent_app = "cursor"
- [ ] Multiple terminals: Each tracked separately
- [ ] Rapid `cd`: No corruption, latest wins
- [ ] Long paths, spaces, unicode: All handled correctly
- [ ] Close terminal: PID cleaned up on next hook invocation

---

## Error Handling

### Graceful Degradation

| Failure | Behavior |
|---------|----------|
| State file locked | Skip update, exit 0 |
| State file corrupted | Overwrite with new state |
| Parent detection fails | Continue without parent_app |
| History append fails | Log, continue (non-critical) |
| Swift can't read state | Show setup prompt |

### Security

- State files: 0600 permissions (user-only)
- Path validation: Must be absolute, canonicalized
- No command execution based on untrusted paths

---

## File Locations

| File | Purpose |
|------|---------|
| `~/.local/bin/hud-hook` | Hook binary |
| `~/.capacitor/shell-cwd.json` | Current shell state |
| `~/.capacitor/shell-history.jsonl` | CWD history log |
| `~/.zshrc` / `~/.bashrc` / `~/.config/fish/config.fish` | User shell config |
