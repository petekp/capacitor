# Capacitor Side Effects Map

Comprehensive audit of all external side effects produced by Capacitor, organized by component and type.

## Detailed Analyses

In-depth side effect documentation for specific subsystems:

| Subsystem | Side Effects | Audit | Status |
|-----------|--------------|-------|--------|
| Lock System | [side-effects/lock-system.md](side-effects/lock-system.md) | [audit/01-lock-system.md](audit/01-lock-system.md) | ✅ Complete |
| Lock Holder | [side-effects/lock-holder.md](side-effects/lock-holder.md) | [audit/02-lock-holder.md](audit/02-lock-holder.md) | ✅ Complete |
| Session State | *Pending* | *Pending* | |
| Cleanup | *Pending* | *Pending* | |
| Tombstone | *Pending* | *Pending* | |
| Shell Tracking | *Pending* | *Pending* | |
| Hook Setup | *Pending* | *Pending* | |

---

## Quick Reference

| Category | Write Locations | Read Locations |
|----------|-----------------|----------------|
| Session State | `~/.capacitor/sessions.json` | Same |
| Locks | `~/.capacitor/sessions/*.lock/` | Same |
| Shell Tracking | `~/.capacitor/shell-cwd.json`, `shell-history.jsonl` | Same |
| Activity | `~/.capacitor/activities/{hash}.json` | Same |
| User Config | `~/.capacitor/config.json`, `projects.json` | Same |
| Claude Config | `~/.claude/settings.json` (hooks only) | `~/.claude/settings.json`, `~/.claude/projects/` |
| Logs | `~/.capacitor/hud-hook-debug.*.log` | N/A |
| Hook Binary | `~/.local/bin/hud-hook` | N/A |
| UserDefaults | `com.capacitor.app` domain | Same |

---

## 1. Rust Core (`core/hud-core/`, `core/hud-hook/`)

### 1.1 Filesystem Writes

#### Session State (`~/.capacitor/sessions.json`)
- **Writer:** `store.rs` via `StateStore::save()`
- **Trigger:** Hook events (SessionStart, ToolUse, etc.)
- **Atomicity:** Uses `tempfile` + `persist()` for atomic writes
- **Content:** JSON map of session records keyed by path hash

```rust
// core/hud-core/src/state/store.rs
pub fn save(&self, state: &HashMap<String, SessionRecord>) -> Result<(), StateError>
```

#### Lock Directories (`~/.capacitor/sessions/{session_id}-{pid}.lock/`)

> **Deep dive:** [Lock System Side Effects](side-effects/lock-system.md)

- **Writers:**
  - `lock.rs:create_session_lock()` - creates lock directories
  - `lock_holder.rs` - maintains lock presence via background process
- **Trigger:** SessionStart event
- **Content:** Directory with `pid` and `meta.json` files
- **Cleanup:** Automatic via `cleanup.rs` on startup, `lock_holder.rs` on exit

```rust
// core/hud-core/src/state/lock.rs
pub fn create_session_lock(session_id: &str, pid: u32, path: &str) -> io::Result<PathBuf>
```

#### Shell CWD State (`~/.capacitor/shell-cwd.json`)
- **Writer:** `cwd.rs` via `update_shell_cwd()`
- **Trigger:** `cd` command from shell hook
- **Atomicity:** Uses `tempfile` + `persist()` for atomic writes
- **Content:** JSON with `shells` map (PID → shell entry) and `updated_at`

```rust
// core/hud-hook/src/cwd.rs
pub fn update_shell_cwd(path: &Path, pid: &str, cwd: &str, ...) -> Result<(), CwdError>
```

#### Shell History (`~/.capacitor/shell-history.jsonl`)
- **Writer:** `cwd.rs` via `append_to_history()`
- **Trigger:** Each `cd` event
- **Format:** JSON Lines (append-only)
- **Content:** Historical shell CWD changes

```rust
// core/hud-hook/src/cwd.rs
pub fn append_to_history(path: &Path, event: &HistoryEvent) -> Result<(), CwdError>
```

#### Activity Files (`~/.capacitor/activities/{hash}.json`)
- **Writer:** `handle.rs` via `write_activity_file()`
- **Trigger:** Hook events (ToolUse, SessionStart, etc.)
- **Content:** JSON with last activity timestamp and hook event type

```rust
// core/hud-hook/src/handle.rs
fn write_activity_file(path: &str, event: &HookEvent) { ... }
```

#### Tombstones (`~/.capacitor/ended-sessions/{session_id}`)
- **Writer:** `handle.rs` via `create_tombstone()` / `remove_tombstone()`
- **Trigger:** SessionEnd (create), SessionStart (clear for reuse), cleanup after 60s (clear)
- **Purpose:** Prevents race conditions where late-arriving events could recreate deleted sessions
- **Content:** Empty file (existence is the signal)

```rust
// core/hud-hook/src/handle.rs
fn create_tombstone(tombstones_dir: &Path, session_id: &str) { ... }
fn remove_tombstone(tombstones_dir: &Path, session_id: &str) { ... }
```

#### User Config (`~/.capacitor/config.json`)
- **Writer:** `config.rs` via `UserConfig::save()`
- **Trigger:** User settings changes in UI
- **Atomicity:** Uses `tempfile` + `persist()`
- **Content:** User preferences (watched directories, etc.)

#### Projects Cache (`~/.capacitor/projects.json`)
- **Writer:** `projects.rs` via `ProjectsCache::save()`
- **Trigger:** Project discovery refresh
- **Content:** Cached project metadata

#### Ideas Persistence (`~/.capacitor/ideas.json`)
- **Writer:** `ideas.rs` via `IdeasStore::save()`
- **Trigger:** User adds/removes ideas in UI
- **Content:** List of user's saved ideas

#### Stats Cache (`~/.capacitor/stats_cache.json`)
- **Writer:** `stats.rs`
- **Trigger:** Stats calculation
- **Content:** Cached project statistics

#### Debug Logs (`~/.capacitor/hud-hook-debug.{date}.log`)
- **Writer:** `logging.rs` via `tracing-appender`
- **Trigger:** Any `tracing::debug!`, `info!`, `warn!`, `error!` call
- **Rotation:** Daily, keeps 7 days
- **Fallback:** stderr if file appender fails

```rust
// core/hud-hook/src/logging.rs
RollingFileAppender::builder()
    .rotation(Rotation::DAILY)
    .max_log_files(7)
```

#### Hook Binary (`~/.local/bin/hud-hook`)
- **Writer:** `setup.rs` via `install_hook_binary_from_path()`
- **Trigger:** App startup, "Install Hooks" button
- **Atomicity:** Copy to temp, then rename
- **Permissions:** Sets executable bit (0o755)

```rust
// core/hud-core/src/setup.rs
pub fn install_hook_binary_from_path(&self, source_path: String) -> Result<InstallResult, HudFfiError>
```

#### Claude Settings (`~/.claude/settings.json`)
- **Writer:** `setup.rs` via `configure_hooks()`
- **Trigger:** "Install Hooks" button
- **Atomicity:** Read → merge → atomic write
- **Scope:** Only modifies `hooks` section, preserves other settings

```rust
// core/hud-core/src/setup.rs
pub fn configure_hooks(&self) -> Result<ConfigResult, HudFfiError>
```

### 1.2 Filesystem Reads

| File | Reader | Purpose |
|------|--------|---------|
| `~/.capacitor/sessions.json` | `store.rs` | Load session state |
| `~/.capacitor/sessions/*.lock/` | `lock.rs` | Check for active locks |
| `~/.capacitor/shell-cwd.json` | `cwd.rs`, Swift | Shell state for activation |
| `~/.capacitor/activities/*.json` | `activity.rs` | Activity timestamps |
| `~/.capacitor/config.json` | `config.rs` | User preferences |
| `~/.capacitor/projects.json` | `projects.rs` | Cached projects |
| `~/.claude/settings.json` | `setup.rs`, `agents/claude.rs` | Hook validation, agent config |
| `~/.claude/projects/*/settings.json` | `projects.rs` | Project-local settings |
| `~/.claude/projects/*/*.md` | `artifacts.rs` | Conversation artifacts |

### 1.3 Process Spawning

#### Lock Holder Process
- **Spawner:** `handle.rs` via `spawn_lock_holder()`
- **Binary:** `hud-hook --lock-holder`
- **Lifecycle:** Spawned on SessionStart, exits on SessionEnd or parent death
- **Purpose:** Maintains lock directory presence

```rust
// core/hud-hook/src/handle.rs
fn spawn_lock_holder(lock_dir: &Path, session_id: &str, parent_pid: u32) { ... }
```

#### Binary Verification
- **Spawner:** `setup.rs`
- **Command:** `hud-hook --version`
- **Purpose:** Verify installed binary works before enabling hooks

```rust
// core/hud-core/src/setup.rs
let output = Command::new(&binary_path).args(["--version"]).spawn()...
```

#### tmux Queries
- **Spawner:** `cwd.rs`
- **Command:** `tmux display-message -p "#{client_tty}"`
- **Purpose:** Detect tmux client TTY for shell tracking

```rust
// core/hud-hook/src/cwd.rs
let output = Command::new("tmux").args(args).output().ok()?;
```

#### Which Command
- **Spawner:** `setup.rs`
- **Command:** `which {binary}`
- **Purpose:** Find claude binary location

### 1.4 Process Signals

#### SIGTERM to Stale Lock Holders
- **Sender:** `cleanup.rs` via `send_sigterm()`
- **Trigger:** Startup cleanup finds orphaned lock-holder process
- **Purpose:** Clean termination of orphaned processes

```rust
// core/hud-core/src/state/cleanup.rs
if libc::kill(holder_pid, libc::SIGTERM) == 0 { ... }
```

#### kill(pid, 0) Liveness Checks
- **Locations:** `lock.rs`, `cwd.rs`, `lock_holder.rs`
- **Purpose:** Check if a process is still alive (sends no signal)

---

## 2. Swift App (`apps/swift/`)

### 2.1 UserDefaults Storage

All UserDefaults use the app's default domain (`com.capacitor.app`).

| Key | File | Purpose |
|-----|------|---------|
| `windowFrame.vertical` | `WindowFrameStore.swift` | Vertical layout window position |
| `windowFrame.dock` | `WindowFrameStore.swift` | Dock layout window position |
| `activation_behavior_overrides` | `ActivationConfig.swift` | Terminal activation strategy overrides |
| `showTipTooltip` | `TipTooltipView.swift` | Whether to show tip tooltip |
| `pinnedProjectPaths` | `AppState.swift` | User's pinned projects |

### 2.2 AppleScript / osascript Execution

All AppleScript is executed via `/usr/bin/osascript`.

#### TTY-Based Tab Selection
- **File:** `TerminalLauncher.swift`
- **Target Apps:** iTerm2, Terminal.app
- **Purpose:** Find and activate the correct tab/session by TTY

```swift
// TerminalLauncher.swift - iTerm
tell application "iTerm" to select t
```

#### App Activation
- **File:** `TerminalLauncher.swift`
- **Target Apps:** Ghostty, iTerm, Alacritty, kitty, Warp, Terminal
- **Purpose:** Bring terminal app to foreground

```swift
osascript -e 'tell application "Ghostty" to activate'
```

#### New Terminal Window
- **File:** `TerminalLauncher.swift`
- **Target Apps:** iTerm, Terminal
- **Purpose:** Create new window with tmux session

```swift
osascript -e "tell application \"iTerm\" to create window with default profile command \"$TMUX_CMD\""
```

### 2.3 Process Spawning

#### Terminal Launch
- **File:** `TerminalLauncher.swift`
- **Commands:** `open -na`, `kitty`, CLI commands
- **Purpose:** Launch terminal apps with specific arguments

#### tmux Commands
- **File:** `TerminalLauncher.swift`
- **Commands:** `tmux switch-client`, `tmux list-windows`, `tmux list-clients`
- **Purpose:** Session switching and discovery

#### kitty Remote Control
- **File:** `TerminalLauncher.swift`
- **Command:** `kitty @ focus-window --match pid:{pid}`
- **Purpose:** Focus specific kitty window

#### IDE CLI Commands
- **File:** `TerminalLauncher.swift`
- **Commands:** `cursor`, `code`, `code-insiders`, `zed`
- **Purpose:** Focus IDE window on specific project

### 2.4 NSWorkspace Integration

- **File:** `TerminalLauncher.swift`
- **APIs Used:**
  - `NSWorkspace.shared.frontmostApplication` - Detect current app
  - `NSWorkspace.shared.runningApplications` - Find running apps
  - `NSRunningApplication.activate()` - Bring app to foreground

### 2.5 Filesystem Reads (Swift)

| File | Reader | Purpose |
|------|--------|---------|
| `~/.capacitor/shell-cwd.json` | `ShellStateStore.swift` | Shell state for project activation |
| `~/.capacitor/shell-history.jsonl` | `ShellHistoryStore.swift` | Shell navigation history |
| `/Applications/*.app` | `TerminalLauncher.swift` | Check which terminals are installed |

---

## 3. Side Effect Triggers Summary

| Trigger | Side Effects |
|---------|--------------|
| **App Launch** | Read all state files, cleanup stale locks (SIGTERM), verify hooks |
| **SessionStart Hook** | Create lock dir, spawn lock-holder, write state, write activity |
| **ToolUse Hook** | Update state, write activity |
| **SessionEnd Hook** | Create tombstone, remove session record, release lock |
| **cd Command** | Update shell-cwd.json, append to shell-history.jsonl |
| **Project Click** | AppleScript/osascript, tmux commands, app activation |
| **Install Hooks** | Copy binary, modify ~/.claude/settings.json |
| **Window Move** | UserDefaults write |
| **Settings Change** | config.json write, UserDefaults write |

---

## 4. Namespace Boundaries

### Capacitor's Namespace (`~/.capacitor/`)
- **Full control** - Capacitor owns all files here
- Safe to create, modify, delete anything

### Claude's Namespace (`~/.claude/`)
- **Read-mostly** - Only modify `settings.json` hooks section
- **Never touch:** `projects/`, `transcripts/`, `memory/`, etc.
- Changes to settings.json preserve all non-hook sections

### System Namespace (`~/.local/bin/`)
- **Single file:** `hud-hook` symlink or binary
- Standard user bin directory convention

---

## 5. Cleanup & Self-Healing

### Startup Cleanup (`cleanup.rs`)
1. Find all lock directories in `~/.capacitor/sessions/`
2. Check if lock-holder PID is alive
3. If dead: SIGTERM any stale processes, remove lock directory
4. Remove tombstone files older than 60 seconds

### Session End Cleanup (`lock_holder.rs`)
1. Catch SIGTERM or detect parent death
2. Remove own lock directory
3. Exit cleanly

### Shell State Cleanup (`cwd.rs`)
1. On each update, filter out dead PIDs from shells map
2. Atomic rewrite of state file
