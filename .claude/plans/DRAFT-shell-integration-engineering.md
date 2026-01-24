# Shell Integration: Engineering Requirements

**Status:** DRAFT
**Companion Doc:** [Shell Integration PRD](./DRAFT-shell-integration-prd.md)
**Created:** 2025-01-23
**Last Updated:** 2025-01-23

---

## Overview

This document specifies the technical implementation for shell integration in Claude HUD. It covers the Rust hook handler, Swift app integration, data schemas, and phased delivery.

---

## Architecture

### System Context

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  User's Shell (zsh/bash/fish)                                               │
│  └── precmd hook fires on every prompt                                      │
└─────────────────────────────────────────┬───────────────────────────────────┘
                                          │
                                          │ Spawns process with args
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  ~/.local/bin/hud-hook cwd <path> <pid> <tty>                               │
│                                                                             │
│  Responsibilities:                                                          │
│  1. Parse arguments                                                         │
│  2. Detect parent application (optional)                                    │
│  3. Update current state (shell-cwd.json)                                   │
│  4. Append to history (shell-history.jsonl)                                 │
│  5. Clean up stale entries                                                  │
│  6. Exit quickly (< 50ms target)                                            │
└─────────────────────────────────────────┬───────────────────────────────────┘
                                          │
                                          │ Writes to filesystem
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  ~/.capacitor/                                                              │
│  ├── shell-cwd.json      Current state (which shells, where)               │
│  └── shell-history.jsonl  Append-only history log                           │
└─────────────────────────────────────────┬───────────────────────────────────┘
                                          │
                                          │ Reads periodically
                                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Claude HUD App (Swift)                                                     │
│                                                                             │
│  Components:                                                                │
│  ├── ShellStateStore      Reads shell-cwd.json, exposes current state      │
│  ├── ShellHistoryStore    Reads shell-history.jsonl, provides analytics    │
│  ├── ProjectResolver      Maps CWD → Project (existing logic)              │
│  └── ActiveProjectEngine  Combines all signals for "active project"        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow Sequence

```
1. User types command, presses Enter
2. Shell executes command
3. Command completes
4. Shell prepares to show next prompt
5. precmd/PROMPT_COMMAND hook fires
6. Hook spawns: hud-hook cwd "$PWD" "$$" "$TTY" &!
7. hud-hook runs in background:
   a. Reads existing shell-cwd.json
   b. Updates entry for this PID
   c. Removes entries for dead PIDs
   d. Writes shell-cwd.json atomically
   e. Appends line to shell-history.jsonl
   f. Exits
8. Shell displays prompt (user never waits for step 7)
9. HUD app reads shell-cwd.json on next poll cycle
10. UI updates to reflect current project
```

---

## Component Specifications

### Component 1: hud-hook `cwd` Subcommand

**Location:** `core/hud-hook/src/`

#### CLI Interface

```
hud-hook cwd <path> <pid> <tty>

Arguments:
  <path>  Absolute path to current working directory
  <pid>   Shell process ID (for tracking multiple shells)
  <tty>   Terminal device path (e.g., /dev/ttys003)

Options:
  --detect-parent    Walk process tree to identify parent app (slower)
  --debug            Write debug info to ~/.capacitor/hud-hook-debug.log

Exit codes:
  0  Success
  1  Invalid arguments
  2  Failed to write state file
```

#### Implementation Outline

```rust
// core/hud-hook/src/cwd.rs

use crate::state::{ShellCwdState, ShellEntry};
use crate::process::detect_parent_app;
use chrono::Utc;
use std::path::PathBuf;

pub fn handle_cwd(args: CwdArgs) -> Result<(), CwdError> {
    let state_dir = dirs::home_dir()
        .ok_or(CwdError::NoHomeDir)?
        .join(".capacitor");

    // Ensure directory exists
    std::fs::create_dir_all(&state_dir)?;

    let cwd_path = state_dir.join("shell-cwd.json");
    let history_path = state_dir.join("shell-history.jsonl");

    // 1. Read existing state (or create empty)
    let mut state = ShellCwdState::load_or_default(&cwd_path)?;

    // 2. Detect parent app if requested
    let parent_app = if args.detect_parent {
        detect_parent_app(args.pid).ok()
    } else {
        None
    };

    // 3. Check if this is a directory change (for history)
    let previous_cwd = state.shells.get(&args.pid.to_string())
        .map(|e| e.cwd.clone());
    let cwd_changed = previous_cwd.as_ref() != Some(&args.path);

    // 4. Update state for this shell
    state.shells.insert(args.pid.to_string(), ShellEntry {
        cwd: args.path.clone(),
        tty: args.tty.clone(),
        parent_app,
        updated_at: Utc::now(),
    });

    // 5. Clean up dead shells (PIDs that no longer exist)
    state.shells.retain(|pid_str, _| {
        pid_str.parse::<u32>()
            .map(|pid| process_exists(pid))
            .unwrap_or(false)
    });

    // 6. Write state atomically
    state.save_atomic(&cwd_path)?;

    // 7. Append to history if CWD changed
    if cwd_changed {
        append_history_entry(&history_path, HistoryEntry {
            cwd: args.path,
            pid: args.pid,
            tty: args.tty,
            parent_app,
            timestamp: Utc::now(),
        })?;
    }

    Ok(())
}

fn process_exists(pid: u32) -> bool {
    // kill -0 checks if process exists without sending signal
    unsafe { libc::kill(pid as i32, 0) == 0 }
}
```

#### Parent App Detection

```rust
// core/hud-hook/src/process.rs

use std::process::Command;

/// Known parent application patterns
const KNOWN_APPS: &[(&str, &str)] = &[
    ("Cursor", "cursor"),
    ("Cursor Helper", "cursor"),
    ("Code", "vscode"),
    ("Code Helper", "vscode"),
    ("Code - Insiders", "vscode-insiders"),
    ("Terminal", "terminal"),
    ("iTerm2", "iterm2"),
    ("iTerm.app", "iterm2"),
    ("Alacritty", "alacritty"),
    ("kitty", "kitty"),
    ("Ghostty", "ghostty"),
    ("WarpTerminal", "warp"),
    ("Warp", "warp"),
    ("tmux", "tmux"),
];

pub fn detect_parent_app(pid: u32) -> Result<String, ProcessError> {
    let mut current_pid = pid;
    let max_depth = 20; // Prevent infinite loops

    for _ in 0..max_depth {
        let parent_pid = get_parent_pid(current_pid)?;

        if parent_pid == 0 || parent_pid == 1 {
            // Reached init/launchd
            return Err(ProcessError::NotFound);
        }

        let process_name = get_process_name(parent_pid)?;

        // Check against known patterns
        for (pattern, app_id) in KNOWN_APPS {
            if process_name.contains(pattern) {
                return Ok(app_id.to_string());
            }
        }

        current_pid = parent_pid;
    }

    Err(ProcessError::NotFound)
}

fn get_parent_pid(pid: u32) -> Result<u32, ProcessError> {
    // Use ps to get parent PID
    let output = Command::new("ps")
        .args(["-o", "ppid=", "-p", &pid.to_string()])
        .output()?;

    let ppid_str = String::from_utf8_lossy(&output.stdout);
    ppid_str.trim()
        .parse()
        .map_err(|_| ProcessError::ParseError)
}

fn get_process_name(pid: u32) -> Result<String, ProcessError> {
    let output = Command::new("ps")
        .args(["-o", "comm=", "-p", &pid.to_string()])
        .output()?;

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}
```

#### Performance Requirements

| Metric | Target | Rationale |
|--------|--------|-----------|
| Total execution time | < 50ms | Must not perceptibly slow prompt |
| Time without --detect-parent | < 10ms | Hot path should be very fast |
| File I/O | Atomic writes | Prevent corruption from concurrent access |
| Memory usage | < 5MB | Spawned on every prompt |

#### Testing Strategy

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_cwd_creates_state_file() {
        let temp = TempDir::new().unwrap();
        let state_path = temp.path().join("shell-cwd.json");

        handle_cwd_with_paths(CwdArgs {
            path: "/test/path".into(),
            pid: 12345,
            tty: "/dev/ttys000".into(),
            detect_parent: false,
        }, &state_path, &temp.path().join("history.jsonl")).unwrap();

        assert!(state_path.exists());
        let state = ShellCwdState::load(&state_path).unwrap();
        assert_eq!(state.shells.get("12345").unwrap().cwd, "/test/path");
    }

    #[test]
    fn test_cwd_cleans_dead_pids() {
        // Create state with a PID that doesn't exist
        let temp = TempDir::new().unwrap();
        let state_path = temp.path().join("shell-cwd.json");

        let mut state = ShellCwdState::default();
        state.shells.insert("99999".into(), ShellEntry {
            cwd: "/old/path".into(),
            tty: "/dev/ttys999".into(),
            parent_app: None,
            updated_at: Utc::now(),
        });
        state.save(&state_path).unwrap();

        // Run cwd with current PID (which exists)
        handle_cwd_with_paths(CwdArgs {
            path: "/test/path".into(),
            pid: std::process::id(),
            tty: "/dev/ttys000".into(),
            detect_parent: false,
        }, &state_path, &temp.path().join("history.jsonl")).unwrap();

        let state = ShellCwdState::load(&state_path).unwrap();
        assert!(!state.shells.contains_key("99999")); // Dead PID removed
    }

    #[test]
    fn test_history_only_appends_on_change() {
        let temp = TempDir::new().unwrap();
        let state_path = temp.path().join("shell-cwd.json");
        let history_path = temp.path().join("history.jsonl");

        // First call
        handle_cwd_with_paths(CwdArgs {
            path: "/path/a".into(),
            pid: 12345,
            tty: "/dev/ttys000".into(),
            detect_parent: false,
        }, &state_path, &history_path).unwrap();

        // Same path again (no change)
        handle_cwd_with_paths(CwdArgs {
            path: "/path/a".into(),
            pid: 12345,
            tty: "/dev/ttys000".into(),
            detect_parent: false,
        }, &state_path, &history_path).unwrap();

        // Different path
        handle_cwd_with_paths(CwdArgs {
            path: "/path/b".into(),
            pid: 12345,
            tty: "/dev/ttys000".into(),
            detect_parent: false,
        }, &state_path, &history_path).unwrap();

        let history = std::fs::read_to_string(&history_path).unwrap();
        let lines: Vec<_> = history.lines().collect();
        assert_eq!(lines.len(), 2); // Only 2 entries (a and b), not 3
    }
}
```

---

### Component 2: Data Schemas

#### shell-cwd.json (Current State)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ShellCwdState",
  "description": "Current state of tracked shell sessions",
  "type": "object",
  "required": ["version", "shells"],
  "properties": {
    "version": {
      "type": "integer",
      "const": 1
    },
    "shells": {
      "type": "object",
      "description": "Map of PID (string) to shell entry",
      "additionalProperties": {
        "$ref": "#/definitions/ShellEntry"
      }
    }
  },
  "definitions": {
    "ShellEntry": {
      "type": "object",
      "required": ["cwd", "tty", "updated_at"],
      "properties": {
        "cwd": {
          "type": "string",
          "description": "Current working directory (absolute path)"
        },
        "tty": {
          "type": "string",
          "description": "Terminal device path"
        },
        "parent_app": {
          "type": ["string", "null"],
          "description": "Detected parent application (vscode, cursor, iterm2, etc.)"
        },
        "updated_at": {
          "type": "string",
          "format": "date-time",
          "description": "ISO 8601 timestamp of last update"
        }
      }
    }
  }
}
```

**Example:**

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

#### shell-history.jsonl (History Log)

JSONL format (one JSON object per line) for efficient appending.

```json
{"cwd":"/Users/dev/Code/my-project","pid":54321,"tty":"/dev/ttys003","parent_app":"cursor","timestamp":"2025-01-15T10:30:00.123Z"}
{"cwd":"/Users/dev/Code/my-project/src","pid":54321,"tty":"/dev/ttys003","parent_app":"cursor","timestamp":"2025-01-15T10:30:45.789Z"}
{"cwd":"/Users/dev/Code/other-project","pid":54400,"tty":"/dev/ttys004","parent_app":"iterm2","timestamp":"2025-01-15T10:31:00.000Z"}
```

**Schema per line:**

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "HistoryEntry",
  "type": "object",
  "required": ["cwd", "pid", "tty", "timestamp"],
  "properties": {
    "cwd": { "type": "string" },
    "pid": { "type": "integer" },
    "tty": { "type": "string" },
    "parent_app": { "type": ["string", "null"] },
    "timestamp": { "type": "string", "format": "date-time" }
  }
}
```

**Why JSONL?**
- Append-only (no read-modify-write)
- Corruption-resistant (one bad line doesn't affect others)
- Easy to tail/stream
- Simple rotation (just truncate or archive)

#### History Retention

```rust
// History cleanup runs periodically (e.g., daily or on app launch)

const DEFAULT_RETENTION_DAYS: u64 = 30;

pub fn cleanup_history(history_path: &Path, retention_days: u64) -> Result<(), HistoryError> {
    let cutoff = Utc::now() - Duration::days(retention_days as i64);

    let temp_path = history_path.with_extension("jsonl.tmp");
    let mut writer = BufWriter::new(File::create(&temp_path)?);

    for line in BufReader::new(File::open(history_path)?).lines() {
        let line = line?;
        if let Ok(entry) = serde_json::from_str::<HistoryEntry>(&line) {
            if entry.timestamp >= cutoff {
                writeln!(writer, "{}", line)?;
            }
        }
    }

    writer.flush()?;
    std::fs::rename(temp_path, history_path)?;

    Ok(())
}
```

---

### Component 3: Swift App Integration

#### ShellStateStore

```swift
// apps/swift/Sources/ClaudeHUD/Stores/ShellStateStore.swift

import Foundation

/// Represents a single shell session
struct ShellEntry: Codable, Equatable {
    let cwd: String
    let tty: String
    let parentApp: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case cwd
        case tty
        case parentApp = "parent_app"
        case updatedAt = "updated_at"
    }
}

/// Current state of all tracked shells
struct ShellCwdState: Codable {
    let version: Int
    let shells: [String: ShellEntry]  // PID string → entry
}

/// Manages shell CWD state
@Observable
final class ShellStateStore {
    private let stateURL: URL
    private let pollInterval: TimeInterval = 0.5  // 500ms
    private var pollTask: Task<Void, Never>?

    private(set) var state: ShellCwdState?
    private(set) var lastError: Error?

    init(stateURL: URL? = nil) {
        self.stateURL = stateURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor")
            .appendingPathComponent("shell-cwd.json")
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
        pollTask = nil
    }

    private func loadState() {
        do {
            let data = try Data(contentsOf: stateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(ShellCwdState.self, from: data)
            lastError = nil
        } catch {
            // File might not exist yet (shell integration not set up)
            if (error as NSError).code != NSFileReadNoSuchFileError {
                lastError = error
            }
        }
    }

    /// Returns the most recently updated shell entry
    var mostRecentShell: ShellEntry? {
        state?.shells.values.max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// Returns shells matching a specific parent app
    func shells(forApp app: String) -> [ShellEntry] {
        state?.shells.values.filter { $0.parentApp == app } ?? []
    }

    /// Returns the CWD that was most recently updated
    var currentCwd: String? {
        mostRecentShell?.cwd
    }
}
```

#### ActiveProjectEngine

```swift
// apps/swift/Sources/ClaudeHUD/Services/ActiveProjectEngine.swift

import Foundation
import AppKit

/// Determines the currently active project by combining multiple signals
@Observable
final class ActiveProjectEngine {
    private let stateStore: StateStore           // Claude session state
    private let shellStateStore: ShellStateStore // Shell CWD state
    private let projectStore: ProjectStore       // Known projects

    private(set) var activeProject: Project?
    private(set) var activeSource: ActiveSource = .none

    enum ActiveSource: Equatable {
        case none
        case claudeSession(sessionId: String)
        case shellCwd(pid: String, app: String?)
        case terminalTracker  // Legacy tmux-based
    }

    init(stateStore: StateStore, shellStateStore: ShellStateStore, projectStore: ProjectStore) {
        self.stateStore = stateStore
        self.shellStateStore = shellStateStore
        self.projectStore = projectStore
    }

    /// Call this on a timer or when state changes
    func updateActiveProject() {
        // Priority 1: Active Claude session
        if let activeSession = stateStore.activeSession,
           let project = projectStore.project(forPath: activeSession.cwd) {
            activeProject = project
            activeSource = .claudeSession(sessionId: activeSession.sessionId)
            return
        }

        // Priority 2: Shell CWD (if terminal is frontmost)
        if isTerminalFrontmost(),
           let shell = shellStateStore.mostRecentShell,
           let project = projectStore.project(forPath: shell.cwd) {
            // Find the PID for this shell
            let pid = shellStateStore.state?.shells.first { $0.value == shell }?.key ?? "unknown"
            activeProject = project
            activeSource = .shellCwd(pid: pid, app: shell.parentApp)
            return
        }

        // Priority 3: Legacy terminal tracker (tmux)
        // ... existing TerminalTracker logic ...

        // No active project detected
        activeProject = nil
        activeSource = .none
    }

    private func isTerminalFrontmost() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let terminalBundleIds = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "org.alacritty",
            "net.kovidgoyal.kitty",
            "dev.warp.Warp-Stable",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",  // Cursor
        ]

        return terminalBundleIds.contains(frontmost.bundleIdentifier ?? "")
    }
}
```

#### Project Matching Logic

```swift
// apps/swift/Sources/ClaudeHUD/Stores/ProjectStore.swift

extension ProjectStore {
    /// Find a project that contains the given path
    func project(forPath path: String) -> Project? {
        let normalizedPath = (path as NSString).standardizingPath

        // Exact match first
        if let project = projects.first(where: { $0.path == normalizedPath }) {
            return project
        }

        // Check if path is within a project directory
        for project in projects {
            if normalizedPath.hasPrefix(project.path + "/") {
                return project
            }
        }

        return nil
    }
}
```

---

### Component 4: Setup Flow

#### Setup Detection

```swift
// apps/swift/Sources/ClaudeHUD/Services/SetupChecker.swift

extension SetupChecker {
    /// Check if shell integration is configured
    func isShellIntegrationConfigured() -> Bool {
        // Check if we've received any shell CWD reports recently
        guard let state = shellStateStore.state else {
            return false
        }

        // If there are any shells tracked, integration is working
        return !state.shells.isEmpty
    }

    /// Returns shell integration setup instructions for the user's shell
    func shellIntegrationInstructions() -> ShellIntegrationInstructions {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        switch shellName {
        case "zsh":
            return ShellIntegrationInstructions(
                shell: "zsh",
                configFile: "~/.zshrc",
                snippet: zshSnippet
            )
        case "bash":
            return ShellIntegrationInstructions(
                shell: "bash",
                configFile: "~/.bashrc",
                snippet: bashSnippet
            )
        case "fish":
            return ShellIntegrationInstructions(
                shell: "fish",
                configFile: "~/.config/fish/config.fish",
                snippet: fishSnippet
            )
        default:
            return ShellIntegrationInstructions(
                shell: shellName,
                configFile: "unknown",
                snippet: "# Shell integration not available for \(shellName)"
            )
        }
    }

    private var zshSnippet: String {
        """
        # Claude HUD shell integration
        if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
          _hud_precmd() {
            "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$TTY" 2>/dev/null &!
          }
          precmd_functions+=(_hud_precmd)
        fi
        """
    }

    private var bashSnippet: String {
        """
        # Claude HUD shell integration
        if [[ -x "$HOME/.local/bin/hud-hook" ]]; then
          _hud_prompt_command() {
            "$HOME/.local/bin/hud-hook" cwd "$PWD" "$$" "$(tty)" 2>/dev/null &
          }
          PROMPT_COMMAND="_hud_prompt_command${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
        fi
        """
    }

    private var fishSnippet: String {
        """
        # Claude HUD shell integration
        if test -x "$HOME/.local/bin/hud-hook"
          function _hud_postexec --on-event fish_postexec
            "$HOME/.local/bin/hud-hook" cwd "$PWD" "$fish_pid" (tty) 2>/dev/null &
          end
        end
        """
    }
}

struct ShellIntegrationInstructions {
    let shell: String
    let configFile: String
    let snippet: String
}
```

#### Setup Card UI

```swift
// apps/swift/Sources/ClaudeHUD/Views/SetupCard+ShellIntegration.swift

struct ShellIntegrationSetupCard: View {
    @Environment(SetupChecker.self) private var setupChecker
    @State private var showingInstructions = false
    @State private var copiedToClipboard = false

    var body: some View {
        SetupCardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    Text("Enhanced Project Tracking")
                        .font(.headline)
                }

                Text("Track your active project across all terminals—not just when Claude is running.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Show Setup") {
                        showingInstructions = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Not Now") {
                        // Dismiss or snooze
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showingInstructions) {
            ShellIntegrationInstructionsSheet(
                instructions: setupChecker.shellIntegrationInstructions(),
                copiedToClipboard: $copiedToClipboard
            )
        }
    }
}

struct ShellIntegrationInstructionsSheet: View {
    let instructions: ShellIntegrationInstructions
    @Binding var copiedToClipboard: Bool
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
                    copiedToClipboard = true
                } label: {
                    Label(
                        copiedToClipboard ? "Copied!" : "Copy to Clipboard",
                        systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }

            Text("After adding, restart your terminal or run `source \(instructions.configFile)`")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 500)
    }
}
```

---

## Integration Points

### Integration with Existing StateStore

The new `ShellStateStore` complements rather than replaces the existing `StateStore`:

```swift
// Existing: Claude session state
StateStore → reads ~/.capacitor/sessions.json
          → provides: active Claude sessions, session states, working_on

// New: Shell CWD state
ShellStateStore → reads ~/.capacitor/shell-cwd.json
               → provides: current CWD per shell, parent app

// Combined in ActiveProjectEngine
ActiveProjectEngine → combines both + frontmost app detection
                   → provides: single "active project" answer
```

### Integration with TerminalTracker

The existing `TerminalTracker` (tmux-based) becomes a fallback:

```swift
func updateActiveProject() {
    // 1. Claude session (highest priority)
    // 2. Shell CWD (new, if terminal frontmost)
    // 3. TerminalTracker/tmux (legacy fallback)
    // 4. None
}
```

Eventually, shell integration may fully replace `TerminalTracker`, but we maintain backward compatibility for users who don't enable shell integration.

### Integration with File Activity

Shell CWD provides "where the user is." File activity provides "what files are changing." Combined:

```swift
// Future: Intelligent project activity detection
struct ProjectActivity {
    let project: Project
    let shellActive: Bool        // User's shell is in this project
    let claudeActive: Bool       // Claude session running here
    let filesChanging: [String]  // Files being modified
    let lastActivity: Date
}
```

---

## Phased Delivery

### Phase 1: Foundation (Target: 1 week)

**Deliverables:**
- [ ] `hud-hook cwd` subcommand (without `--detect-parent`)
- [ ] `ShellCwdState` Rust types and serialization
- [ ] Atomic file writing for `shell-cwd.json`
- [ ] `ShellStateStore` Swift class (read-only)
- [ ] Unit tests for Rust and Swift components
- [ ] Shell snippets (zsh, bash, fish)

**Acceptance criteria:**
- Running `hud-hook cwd /some/path 12345 /dev/ttys000` creates/updates `shell-cwd.json`
- Swift app can read and decode `shell-cwd.json`
- Shell snippets work in respective shells

### Phase 2: App Integration (Target: 1 week)

**Deliverables:**
- [ ] `ActiveProjectEngine` combining signals
- [ ] Project highlighting from shell CWD
- [ ] Setup card for shell integration
- [ ] Instructions sheet with copy-to-clipboard
- [ ] Integration tests

**Acceptance criteria:**
- HUD highlights correct project when user `cd`s in terminal
- Setup flow guides user through shell integration
- Works alongside existing Claude session detection

### Phase 3: History & Parent Detection (Target: 1 week)

**Deliverables:**
- [ ] `shell-history.jsonl` append logic
- [ ] History retention/cleanup
- [ ] `--detect-parent` flag implementation
- [ ] `ShellHistoryStore` Swift class
- [ ] "Recent projects" using shell history
- [ ] Parent app display in UI (optional badge)

**Acceptance criteria:**
- History file grows with CWD changes
- Old entries cleaned up per retention policy
- Parent app detected for VSCode/Cursor shells
- Recent projects reflects shell activity

### Phase 4: Polish & Documentation (Target: 3 days)

**Deliverables:**
- [ ] User documentation
- [ ] Troubleshooting guide
- [ ] Performance benchmarking
- [ ] Edge case handling (symlinks, network paths, etc.)

**Acceptance criteria:**
- Documentation covers setup, troubleshooting, uninstallation
- Performance meets targets (< 50ms execution)
- Graceful handling of edge cases

---

## Testing Strategy

### Unit Tests

| Component | Test Coverage |
|-----------|---------------|
| `hud-hook cwd` | Argument parsing, state updates, dead PID cleanup, atomic writes |
| `detect_parent_app` | Process tree walking, known app matching |
| `ShellCwdState` | Serialization, deserialization, version handling |
| `ShellStateStore` | File reading, polling, error handling |
| `ActiveProjectEngine` | Signal priority, project matching |

### Integration Tests

```rust
// Test: Full flow from shell hook to state file
#[test]
fn test_full_cwd_flow() {
    let temp = TempDir::new().unwrap();
    let state_path = temp.path().join("shell-cwd.json");

    // Simulate shell hook call
    let status = Command::new(env!("CARGO_BIN_EXE_hud-hook"))
        .args(["cwd", "/test/path", &std::process::id().to_string(), "/dev/ttys000"])
        .env("HUD_STATE_DIR", temp.path())
        .status()
        .unwrap();

    assert!(status.success());

    // Verify state file
    let state = ShellCwdState::load(&state_path).unwrap();
    assert!(state.shells.contains_key(&std::process::id().to_string()));
}
```

### Manual Testing Checklist

- [ ] zsh integration: Add snippet, verify hook fires on every prompt
- [ ] bash integration: Add snippet, verify hook fires
- [ ] fish integration: Add snippet, verify hook fires
- [ ] VSCode terminal: Verify shell integration works inside VSCode
- [ ] Cursor terminal: Verify shell integration works inside Cursor
- [ ] Multiple terminals: Open 3 terminals, verify each tracked separately
- [ ] Rapid cd: Cd quickly between directories, verify no corruption
- [ ] Long paths: Test with very long directory paths
- [ ] Special characters: Test paths with spaces, quotes, unicode
- [ ] Symlinks: Test cd via symlink, verify resolved path
- [ ] Network paths: Test with /Volumes or SMB mounts
- [ ] Shell exit: Close terminal, verify PID cleaned up on next write

---

## Error Handling

### Rust Error Types

```rust
#[derive(Debug, thiserror::Error)]
pub enum CwdError {
    #[error("Home directory not found")]
    NoHomeDir,

    #[error("Failed to create state directory: {0}")]
    CreateDir(#[from] std::io::Error),

    #[error("Failed to serialize state: {0}")]
    Serialize(#[from] serde_json::Error),

    #[error("Failed to write state file atomically")]
    AtomicWrite,
}

#[derive(Debug, thiserror::Error)]
pub enum ProcessError {
    #[error("Process not found")]
    NotFound,

    #[error("Failed to parse process info")]
    ParseError,

    #[error("Command failed: {0}")]
    CommandFailed(#[from] std::io::Error),
}
```

### Graceful Degradation

| Failure Mode | Behavior |
|--------------|----------|
| State file locked | Skip update, log warning, exit 0 |
| State file corrupted | Overwrite with new state |
| Parent detection fails | Continue without parent_app field |
| History append fails | Log warning, continue (non-critical) |
| Swift can't read state | Show setup prompt, don't crash |

---

## Security Considerations

### File Permissions

```rust
// State files should be user-readable only
fn set_file_permissions(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let perms = std::fs::Permissions::from_mode(0o600);
    std::fs::set_permissions(path, perms)
}
```

### Path Validation

```rust
fn validate_cwd(path: &str) -> Result<String, CwdError> {
    // Must be absolute path
    if !path.starts_with('/') {
        return Err(CwdError::InvalidPath("Path must be absolute"));
    }

    // Normalize to prevent traversal
    let normalized = std::path::Path::new(path)
        .canonicalize()
        .map_err(|_| CwdError::InvalidPath("Path does not exist"))?;

    Ok(normalized.to_string_lossy().into_owned())
}
```

### No Execution

The shell hook only *reports* CWD—it never executes commands based on CWD. This prevents injection attacks via malicious directory names.

---

## Performance Benchmarks

Run with: `cargo bench --package hud-hook`

```rust
// benches/cwd_benchmark.rs

use criterion::{criterion_group, criterion_main, Criterion};

fn benchmark_cwd_update(c: &mut Criterion) {
    let temp = tempfile::TempDir::new().unwrap();

    c.bench_function("cwd_update_cold", |b| {
        b.iter(|| {
            // Simulate cold start (no existing file)
            let _ = std::fs::remove_file(temp.path().join("shell-cwd.json"));
            handle_cwd_with_paths(/* ... */)
        })
    });

    c.bench_function("cwd_update_warm", |b| {
        // Pre-create state file
        handle_cwd_with_paths(/* ... */);

        b.iter(|| {
            handle_cwd_with_paths(/* ... */)
        })
    });

    c.bench_function("parent_detection", |b| {
        b.iter(|| {
            detect_parent_app(std::process::id())
        })
    });
}

criterion_group!(benches, benchmark_cwd_update);
criterion_main!(benches);
```

**Target benchmarks:**

| Operation | Target | Maximum |
|-----------|--------|---------|
| Cold update (no file) | < 5ms | 20ms |
| Warm update (file exists) | < 3ms | 10ms |
| With parent detection | < 30ms | 50ms |
| History append | < 2ms | 5ms |

---

## Future Considerations

### Potential Optimizations

1. **Debouncing:** If multiple CWD reports come in rapid succession (user typing `cd a && cd b && cd c`), batch them.

2. **Inotify/FSEvents:** Instead of polling, watch `shell-cwd.json` for changes. Reduces CPU usage in HUD app.

3. **Shared memory:** For ultra-low-latency, could use shared memory instead of file. Adds complexity.

4. **Binary format:** JSON is human-readable but slow. Could use MessagePack or FlatBuffers for perf.

### Extensibility Points

1. **Additional metadata:** The shell hook could report more (git branch, virtualenv, node version).

2. **Bidirectional communication:** HUD could write to a file that shells read (e.g., "jump to project X").

3. **Plugin system:** Allow users to add custom detection logic for their specific workflows.

---

## Appendix: File Locations Summary

| File | Purpose | Owner | Format |
|------|---------|-------|--------|
| `~/.local/bin/hud-hook` | Hook binary | HUD | Executable |
| `~/.capacitor/shell-cwd.json` | Current shell state | hud-hook | JSON |
| `~/.capacitor/shell-history.jsonl` | CWD history | hud-hook | JSONL |
| `~/.zshrc` | zsh config | User | Shell |
| `~/.bashrc` | bash config | User | Shell |
| `~/.config/fish/config.fish` | fish config | User | Fish |
