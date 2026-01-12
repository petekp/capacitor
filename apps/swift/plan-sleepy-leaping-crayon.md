# Plan: Seamless Project Launch Workflow

## Overview

Implement three improvements to the HUD's project launch and session tracking:

1. **Tmux-optional flow** - Support users without tmux installed
2. **File lock session detection** - Reliably detect if Claude is running (even after crashes)
3. **Missing project detection** - Show visual indicator for deleted projects

---

## 1. Tmux-Optional Flow

### Current Behavior
- Terminal launch assumes tmux exists
- If tmux not installed, script fails silently

### Proposed Changes

**File: `apps/swift/Sources/ClaudeHUD/Models/AppState.swift`**

Modify `launchTerminal()` to detect tmux installation:

```swift
func launchTerminal(for project: Project) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", """
        SESSION="\(project.name)"
        PROJECT_PATH="\(project.path)"

        # Check if tmux is installed
        if ! command -v tmux &> /dev/null; then
            # NO TMUX: Just open terminal in project directory
            if [ -d "/Applications/Ghostty.app" ]; then
                open -na "Ghostty.app" --args --working-directory="$PROJECT_PATH"
            elif [ -d "/Applications/iTerm.app" ]; then
                osascript -e "tell application \\"iTerm\\" to create window with default profile command \\"cd '$PROJECT_PATH' && exec $SHELL\\""
            elif [ -d "/Applications/Warp.app" ]; then
                open -na "Warp.app" "$PROJECT_PATH"
            else
                open -na "Terminal.app" "$PROJECT_PATH"
            fi
            exit 0
        fi

        # TMUX AVAILABLE: Use existing session logic
        HAS_ATTACHED_CLIENT=$(tmux list-clients 2>/dev/null | head -1)
        # ... rest of existing tmux logic ...
    """]
    try? process.run()
}
```

### Key Changes
- Add `command -v tmux` check at start
- If no tmux: open terminal directly in project directory
- Each terminal app has slightly different directory-opening syntax

---

## 2. File Lock Session Detection

### Challenge
Hooks are individual script invocations - they can't hold persistent locks across the session.

### Solution
Have `UserPromptSubmit` hook spawn a **background lock-holder process** that:
1. Acquires advisory lock on `~/.claude/sessions/{hash}.lock`
2. Monitors Claude's PID via `$PPID`
3. Exits when Claude exits (lock auto-released)

### Implementation

**File: `~/.claude/scripts/hud-state-tracker.sh`**

Add to UserPromptSubmit case:

```bash
"UserPromptSubmit")
    state="working"

    # Start background lock holder
    LOCK_DIR="$HOME/.claude/sessions"
    mkdir -p "$LOCK_DIR"
    LOCK_FILE="$LOCK_DIR/$(echo "$CWD" | md5sum | cut -d' ' -f1).lock"
    CLAUDE_PID=$PPID

    # Spawn lock holder in background
    (
        exec 200>"$LOCK_FILE"
        flock -n 200 || exit 0  # Already locked = another session

        # Write metadata
        echo "{\"pid\": $CLAUDE_PID, \"started\": \"$(date -Iseconds)\", \"path\": \"$CWD\"}" >&200

        # Hold lock while Claude runs
        while kill -0 $CLAUDE_PID 2>/dev/null; do
            sleep 1
        done
        # Claude exited - lock released on exit
    ) &
    disown
    ;;
```

**File: `core/hud-core/src/sessions.rs`**

Add function to check lock status:

```rust
use std::fs::OpenOptions;
use std::os::unix::io::AsRawFd;

pub fn is_session_active(project_path: &str) -> bool {
    let lock_dir = dirs::home_dir()
        .map(|h| h.join(".claude/sessions"))
        .unwrap_or_default();

    let hash = md5::compute(project_path);
    let lock_path = lock_dir.join(format!("{:x}.lock", hash));

    if !lock_path.exists() {
        return false;
    }

    // Try to acquire lock (non-blocking)
    let file = match OpenOptions::new()
        .read(true)
        .write(true)
        .open(&lock_path) {
        Ok(f) => f,
        Err(_) => return false,
    };

    let fd = file.as_raw_fd();
    let result = unsafe {
        libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB)
    };

    if result == 0 {
        // Lock acquired = no one else has it = session NOT active
        unsafe { libc::flock(fd, libc::LOCK_UN) };
        false
    } else {
        // Lock failed = someone else has it = session IS active
        true
    }
}
```

**File: `core/hud-core/src/types.rs`**

Add to `ProjectSessionState`:

```rust
pub struct ProjectSessionState {
    pub state: SessionState,
    // ... existing fields ...
    pub is_locked: bool,  // True if lock file is held
}
```

**File: `apps/swift/Sources/ClaudeHUD/Models/AppState.swift`**

Use lock status to detect stale state:

```swift
func refreshSessionStates() {
    guard let engine = engine else { return }
    sessionStates = engine.getAllSessionStates(projects: projects)

    // Cross-check: if state is "working" but lock isn't held, mark as stale
    for (path, state) in sessionStates {
        if state.state == .working && !state.isLocked {
            // Claude crashed - state file is stale
            sessionStates[path]?.state = .idle
            sessionStates[path]?.workingOn = "(Session ended unexpectedly)"
        }
    }
}
```

---

## 3. Missing Project Detection

### Current Behavior
- Missing projects silently omitted from list
- No indication to user that a pinned project was deleted

### Proposed Changes

**File: `core/hud-core/src/types.rs`**

Add `is_missing` field to Project:

```rust
pub struct Project {
    pub path: String,
    pub name: String,
    // ... existing fields ...
    pub is_missing: bool,  // True if directory doesn't exist
}
```

**File: `core/hud-core/src/projects.rs`**

Modify `load_projects()` to include missing projects:

```rust
pub fn load_projects(pinned_paths: &[String]) -> Vec<Project> {
    pinned_paths.iter().map(|path| {
        if !std::path::Path::new(path).exists() {
            // Return minimal project with is_missing = true
            Project {
                path: path.clone(),
                name: path.split('/').last().unwrap_or("Unknown").to_string(),
                is_missing: true,
                // ... defaults for other fields ...
            }
        } else {
            build_project_from_path(path).unwrap_or_else(|| {
                // Fallback for other load failures
                Project {
                    path: path.clone(),
                    name: path.split('/').last().unwrap_or("Unknown").to_string(),
                    is_missing: true,
                    ..Default::default()
                }
            })
        }
    }).collect()
}
```

**File: `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`**

Add visual indicator for missing projects:

```swift
// In card body, before project name:
if project.isMissing {
    Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 12))
        .foregroundColor(.orange)
}

Text(project.name)
    .font(.system(size: 14, weight: .semibold))
    .foregroundColor(project.isMissing ? .white.opacity(0.5) : .white.opacity(0.9))
    .strikethrough(project.isMissing)
```

**File: `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`**

Add context menu option to remove missing project:

```swift
.contextMenu {
    if project.isMissing {
        Button(role: .destructive, action: {
            appState.removeProject(project)
        }) {
            Label("Remove Missing Project", systemImage: "trash")
        }
    }
    // ... existing menu items ...
}
```

---

## File Summary

| File | Changes |
|------|---------|
| `apps/swift/.../AppState.swift` | tmux detection, stale state handling |
| `~/.claude/scripts/hud-state-tracker.sh` | Background lock holder spawning |
| `core/hud-core/src/sessions.rs` | `is_session_active()` lock check |
| `core/hud-core/src/types.rs` | Add `is_locked`, `is_missing` fields |
| `core/hud-core/src/projects.rs` | Include missing projects with flag |
| `apps/swift/.../ProjectCardView.swift` | Missing project UI indicator |
| `Cargo.toml` | Add `libc` and `md5` dependencies |

---

## Verification

1. **Tmux-optional:**
   - Temporarily rename tmux binary
   - Click project card → should open terminal directly in directory
   - Restore tmux → should use session management

2. **File lock detection:**
   - Start Claude in a project
   - Check `~/.claude/sessions/` for lock file
   - Force-quit terminal
   - HUD should detect stale state within 1-2 seconds

3. **Missing project:**
   - Pin a project, verify it shows
   - Delete the project directory externally
   - Reload HUD → should show with warning indicator
   - Context menu → "Remove Missing Project" should work

---

## Dependencies

Add to `core/hud-core/Cargo.toml`:
```toml
libc = "0.2"
md5 = "0.7"
```
