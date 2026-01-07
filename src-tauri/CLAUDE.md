# Claude HUD Backend - Development Guide

Claude HUD is a cross-platform desktop application that serves as a dashboard for Claude Code. It displays project statistics, task tracking, plugin management, and global Claude Code configuration. Built with Rust/Tauri backend and React 19/TypeScript frontend.

> **Development Workflow:** The app should be running during development via `pnpm dev` (terminal 1) and `cargo tauri dev` (terminal 2). Changes auto-rebuild and hot-reload. Claude should make changes incrementally and verify results in the running app.

**Quick note:** Backend work happens in `src-tauri/`, frontend work in `src/`. Most instructions assume you're running commands from the **project root** (`claude-hud/`), but this file documents backend-specific details.

## Quick Start

### Prerequisites
- **Node.js** 18+ and **pnpm** (frontend build)
- **Rust** 1.77.2+ and **Cargo** (backend)
- **Tauri CLI** (usually pre-installed)

### Initial Setup
```bash
# From project root - install frontend dependencies
pnpm install

# Quick verification
cargo check      # Rust syntax check
pnpm type-check  # TypeScript check
```

### Development (Two Terminals Required)

**IMPORTANT: The app should be running during development.** When making changes, the app auto-rebuilds and hot-reloads so you can immediately see results.

**Terminal 1 - Frontend (from project root):**
```bash
pnpm dev
# Starts Vite dev server on http://localhost:5173 with hot reload
```

**Terminal 2 - Desktop app (from project root):**
```bash
cd src-tauri
cargo tauri dev
# Watches frontend + backend, auto-rebuilds on any change
```

Both terminals must run simultaneously. Changes to either frontend or backend automatically trigger rebuilds.

### Auto-Rebuild Behavior

When the app is running via `cargo tauri dev`:
- **Frontend changes** (`src/*.tsx`, `src/*.css`) → Instant hot reload via Vite
- **Backend changes** (`src-tauri/src/*.rs`) → Auto-recompiles and restarts app (~5-10 seconds)

**Claude should keep the app running** and make changes incrementally. After each change, the app will automatically rebuild so you can verify the result immediately.

## Commands Reference

### Frontend (from project root)
```bash
pnpm dev              # Start dev server with hot reload (localhost:5173)
pnpm build            # Build for production to dist/ (includes type check)
pnpm preview          # Preview production build locally
pnpm lint             # Run ESLint (run before commits)
npx tsc --noEmit      # TypeScript type checking only
```

### Backend (from src-tauri/)
```bash
# Development
cargo tauri dev              # Start with hot reload (watches both frontend & backend)
cargo check                  # Quick syntax check without building
cargo build                  # Debug build
cargo build --release        # Optimized release build

# Linting & Formatting (required before commits)
cargo fmt                    # Format code (must pass before every commit)
cargo clippy -- -D warnings  # Lint check (fix all warnings, required)

# Testing
cargo test                   # Run all tests
cargo test test_name         # Run specific test by name
cargo test -- --nocapture    # Show println! output
cargo test -- --test-threads=1  # Run sequentially (if needed)

# Distribution (must run pnpm build first from project root)
cargo tauri build                              # Build for current platform
cargo tauri build --target aarch64-apple-darwin   # macOS Apple Silicon
cargo tauri build --target x86_64-apple-darwin    # macOS Intel
cargo tauri build --target x86_64-pc-windows-msvc # Windows
```

### Pre-Commit Checklist

**From src-tauri/:**
```bash
cargo fmt                    # Format code (required)
cargo clippy -- -D warnings  # Fix all lint warnings (required)
cargo test                   # All tests must pass (required)
```

**From project root:**
```bash
pnpm lint                   # ESLint must pass
npx tsc --noEmit            # TypeScript must pass
```

## Core Architecture at a Glance

### What is Claude HUD?

Claude HUD is a dashboard application that:
1. **Scans `~/.claude/`** for Claude Code projects, sessions, and configuration
2. **Extracts statistics** from JSONL session files (token usage, model usage)
3. **Provides a UI** to browse projects, view artifacts (skills/commands/agents), and manage plugins
4. **Generates summaries** of Claude Code sessions using Claude CLI

### How It Works

```
User opens Claude HUD app (Tauri window)
            ↓
React 19 frontend loads (connects to localhost:5173 in dev, or static bundle in prod)
            ↓
useState hooks + invoke() call backend via Tauri IPC
            ↓
Rust backend (lib.rs) handles command:
  - Scans ~/.claude/ directories
  - Parses JSONL files with regex
  - Caches results by mtime
  - Loads/saves JSON config files
            ↓
Results serialized to JSON and returned to frontend
            ↓
React component re-renders with data
```

**Background tasks** emit events to update frontend without blocking.

### File Structure (What You Edit)

**Most changes go in one of these two places:**

| If you're modifying... | File | Key Functions |
|------------------------|------|---|
| Statistics parsing, project discovery, artifact counting | `src-tauri/src/lib.rs` | `parse_stats_from_content()`, `has_project_indicators()`, `count_artifacts_in_dir()` |
| UI, dashboard layout, forms | `src/App.tsx` | React components (all in one file) |
| Type definitions | `src/types.ts` | TypeScript interfaces (must match Rust structs) |

### Backend Organization (src-tauri/src/lib.rs - 1907 lines)

The entire backend is **one 1907-line file** organized in 4 layers:

| Layer | Lines | Purpose |
|-------|-------|---------|
| **Data Structures** | 10–136 | Rust types: `Project`, `ProjectStats`, `Task`, `Artifact`, `Plugin`, etc. |
| **Utilities** | 154–810 | Config loading, stats parsing, artifact discovery, caching, path resolution |
| **Business Logic** | 837–1039 | Project discovery, plugin loading, path encoding/decoding |
| **IPC Handlers** | 839–1907 | 14 `#[tauri::command]` functions that frontend calls |

**Key insight:** When frontend calls `invoke('load_projects')`, it triggers the corresponding `#[tauri::command]` function in lib.rs, which does all the work.

### The 14 IPC Commands

| Command | Purpose | Returns |
|---------|---------|---------|
| `load_dashboard` | All dashboard data: config, plugins, projects | `DashboardData` |
| `load_projects` | Pinned projects only | `Vec<Project>` |
| `load_project_details` | Full project: tasks, git status, CLAUDE.md | `ProjectDetails` |
| `load_artifacts` | Global + plugin skills/commands/agents | `Vec<Artifact>` |
| `toggle_plugin` | Enable/disable plugin in settings | `()` |
| `read_file_content` | Read arbitrary file | `String` |
| `open_in_editor` | Open file in system editor | `()` |
| `open_folder` | Open folder in file manager | `()` |
| `launch_in_terminal` | Open Warp terminal (macOS) | `()` |
| `generate_session_summary` | On-demand summary generation | `String` |
| `start_background_summaries` | Background task with event emission | `()` |
| `start_background_project_summaries` | Multi-session project overview | `()` |
| `add_project` | Add to pinned projects | `()` |
| `remove_project` | Remove from pinned projects | `()` |
| `load_suggested_projects` | Discover active projects | `Vec<SuggestedProject>` |

## Common Development Tasks

### Add a New IPC Command

1. Add a `#[tauri::command]` function in `src-tauri/src/lib.rs` (around line 1720+):

```rust
#[tauri::command]
fn my_new_command(project_id: String) -> Result<Vec<String>, String> {
    // Your logic here
    Ok(vec!["result1".to_string()])
}
```

2. Register it in the Tauri builder (around line 1887):
```rust
.invoke_handler(tauri::generate_handler![
    // ... existing commands ...
    my_new_command,  // Add this
])
```

3. From frontend, call it:
```typescript
const result = await invoke<string[]>('my_new_command', { projectId: 'test' });
```

### Modify Stats Parsing (Token Extraction)

Edit `parse_stats_from_content()` in `src-tauri/src/lib.rs`:

**Current patterns:**
```rust
if let Some(caps) = Regex::new(r#""input_tokens":(\d+)"#)?.captures(line) {
    stats.total_input_tokens += caps[1].parse::<u64>()?;
}
```

**To add a new field:**
```rust
if let Some(caps) = Regex::new(r#""my_new_field":(\d+)"#)?.captures(line) {
    stats.my_new_field += caps[1].parse::<u64>()?;
}
```

**Test it:**
```bash
cargo test test_parse_stats
rm ~/.claude/hud-stats-cache.json  # Force recomputation
cargo tauri dev
```

### Add Project Type Detection

Edit `has_project_indicators()` in `src-tauri/src/lib.rs`:

```rust
// Current: checks for .git, package.json, Cargo.toml, etc.
// Add yours:
if path.join("gradle.build").exists() {
    return true;  // Gradle project detected
}
```

### Change a Data Structure

When modifying `Project`, `Task`, `ProjectStats`:

1. **Backend:** Update struct in `src-tauri/src/lib.rs` (lines 10–136)
   ```rust
   pub struct ProjectStats {
       pub new_field: String,  // Add this
       // ... existing fields ...
   }
   ```

2. **Frontend:** Update TypeScript interface in `src/types.ts`
   ```typescript
   export interface ProjectStats {
       new_field: string;  // Match the field name
       // ... existing fields ...
   }
   ```

3. **Handle serialization mismatch** (if names differ):
   ```rust
   #[serde(rename = "newField")]
   pub new_field: String,
   ```

### Debug Stats Parsing

**See what's being parsed:**
```bash
cat ~/.claude/projects/'-Users-peter-Code'/session_id.jsonl | jq .
```

**Test regex pattern:**
```bash
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'
```

**Force recalculation:**
```bash
rm ~/.claude/hud-stats-cache.json
```

## Code Style & Conventions

**All Code:**
- Prefer easy-to-read code over clever code
- Don't add extraneous comments; code should be self-documenting
- Never use IIFEs in React components

**Backend (Rust):**
- Run `cargo fmt` before every commit (enforced)
- Run `cargo clippy -- -D warnings` and fix all warnings
- No async I/O (single-threaded, synchronous file operations acceptable)
- Thread spawning via `std::thread::spawn()` for background work

**Frontend (TypeScript/React):**
- React 19 with hooks (useState, useEffect)
- TypeScript strict mode enabled
- Run ESLint before commits
- Don't run dev server unless actively developing

## Project Structure

### High-Level Layout
```
claude-hud/
├── CLAUDE.md                    # Development guide (root)
├── package.json                 # Frontend dependencies
├── tsconfig.json                # TypeScript config
├── vite.config.ts               # Vite bundler config
├── pnpm-lock.yaml               # Frontend lock file
├── src/                         # React 19 frontend
│   ├── main.tsx                 # Entry point
│   ├── App.tsx                  # Root component (all UI, 1342 lines)
│   ├── types.ts                 # TypeScript interfaces
│   ├── index.css                # Tailwind CSS theme
│   ├── lib/utils.ts             # Utility functions
│   └── components/ui/           # shadcn/ui components
├── dist/                        # Built frontend (generated)
└── src-tauri/                   # Rust backend
    ├── src/
    │   ├── main.rs              # Tauri app entry (6 lines)
    │   └── lib.rs               # All backend logic (1907 lines)
    ├── Cargo.toml               # Rust dependencies
    ├── Cargo.lock               # Rust lock file
    ├── tauri.conf.json          # Tauri app config
    ├── build.rs                 # Build script
    ├── capabilities/            # Security definitions
    └── icons/                   # App icons for all platforms
```

### Runtime Configuration
The app reads from `~/.claude/`:
```
~/.claude/
├── settings.json                  # Global Claude Code config
├── hud.json                       # Pinned projects
├── hud-stats-cache.json           # Cached token usage
├── hud-summaries.json             # Session summaries cache
├── hud-project-summaries.json     # Project overview bullets
├── projects/                      # Session files ({encoded-path}/{sessionid}.jsonl)
├── plugins/
│   ├── installed_plugins.json     # Plugin registry
│   └── {plugin-id}/
│       ├── plugin.json
│       ├── skills/
│       ├── commands/
│       ├── agents/
│       └── hooks/
│           └── hooks.json
├── skills/                        # Global skills directory
├── commands/                      # Global commands directory
└── agents/                        # Global agents directory
```

## Core Data Structures

Located in `src/lib.rs:10–136`

**Global Configuration (`GlobalConfig`)**
- Reads from ~/.claude/settings.json
- Tracks skills, commands, agents, and instructions paths
- Core state synced to frontend

**Project Tracking (`Project`, `ProjectDetails`, `Task`)**
- Scans for projects with .claude directories
- Extracts CLAUDE.md files for project-specific documentation
- Caches project statistics from Claude Code task metadata
- Tracks task counts and last activity timestamps

**Statistics & Caching (`ProjectStats`, `StatsCache`, `CachedProjectStats`)**
- Parses token usage from Claude Code task files using regex
- Tracks input/output tokens, cache tokens, model usage (Opus/Sonnet/Haiku)
- Caches file metadata (size, mtime) to avoid re-parsing unchanged files
- Implements smart caching in `~/.claude/hud-stats-cache.json`

**Plugins (`Plugin`, `PluginManifest`)**
- Reads from Claude Code plugin registry (`~/.claude/plugins/installed_plugins.json`)
- Counts skills, commands, agents per plugin
- Tracks enabled/disabled status from settings

**Config Management (`HudConfig`)**
- Stores pinned projects in `~/.claude/hud.json`
- JSON-based persistence with Serde

## Key Functions & Modules

### Configuration & Path Management (lines 154-195)
- `get_claude_dir()` - Resolves ~/.claude directory using `dirs` crate
- `get_hud_config_path()` / `get_stats_cache_path()` - File path construction
- `load_hud_config()` / `save_hud_config()` - Pinned projects persistence
- `load_stats_cache()` / `save_stats_cache()` - Token stats caching

### Statistics & Parsing (lines 196-326)
- `parse_stats_from_content()` - Regex-based extraction from JSONL:
  - Extracts input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens
  - Detects model type (opus/sonnet/haiku)
  - Extracts first/last activity timestamps and summaries
- `compute_project_stats()` - Intelligent caching:
  - Checks file size and mtime against cached values
  - Only re-parses files that have changed
  - Stores metadata to avoid redundant file reads

### File Discovery & Artifacts (lines 336-472)
- `count_artifacts_in_dir()` - Counts skills/commands/agents
  - Skills: directories containing SKILL.md or skill.md
  - Commands/Agents: .md files
- `parse_frontmatter()` - Extracts YAML frontmatter from MD files
  - Parses name and description fields
- `collect_artifacts_from_dir()` - Gathers artifact objects with metadata
- `count_hooks_in_dir()` - Checks for hooks.json in plugin directories

### Project Management (lines 937-1039)
- `has_project_indicators()` - Detects project type by file presence
  - .git, package.json, Cargo.toml, pyproject.toml, tsconfig.json, etc.
- `build_project_from_path()` - Constructs single project object
- `load_projects_internal()` - Loads pinned projects from HUD config
  - Sorts by most recent activity

### Session Summarization (lines 569-605, 1462-1606)
- `generate_session_summary()` - Invokes Claude CLI for summary
  - Caches summaries in `~/.claude/hud-summaries.json`
  - Validates summaries with `is_bad_summary()`
  - Uses model=haiku for fast generation
- `extract_session_context()` - Parses JSONL session files
  - Takes up to 6 messages for context
  - Filters out warmup sessions and empty content
- `generate_session_summary_sync()` - Synchronous version for background tasks
- `start_background_summaries()` - Thread-based background generation
  - Emits "summary-ready" events to frontend
- `start_background_project_summaries()` - Multi-step project summarization
  - Generates summaries for up to 5 recent sessions
  - Creates 3-bullet project overview
  - Caches in `~/.claude/hud-project-summaries.json`

### Plugin Management (lines 876-934)
- `load_plugins()` - Reads from installed plugins registry
  - Parses plugin.json for manifest
  - Checks enabled status in settings.json
  - Counts artifacts per plugin

## Architecture Overview

**Tech Stack:**
- **Backend:** Rust with Tauri v2.9.5
- **Frontend:** TypeScript/React 19 (builds to `../dist`)
- **Build System:** Cargo + pnpm + Vite
- **Platform:** macOS, Windows, Linux

**High-Level Design:**
- `src/lib.rs` (1907 lines) contains the entire backend — no module structure
- Single monolithic file with 4 conceptual layers:
  1. **Data Structures** (lines 10-136) — Rust types for all domain concepts
  2. **Utilities** (lines 154-810) — Config loading, path resolution, file operations
  3. **Business Logic** (lines 837-1039) — Data discovery and aggregation
  4. **IPC Handlers** (lines 839-1907) — Frontend API via `#[tauri::command]`

**File Organization:**
- `src/lib.rs` — Application logic (data structures, utilities, command handlers)
- `src/main.rs` — Minimal entry point (6 lines, delegates to lib.rs)
- `Cargo.toml` — Dependencies and project metadata
- `tauri.conf.json` — App configuration (window size, app name, dev server URL)
- `capabilities/` — Tauri security definitions
- `icons/` — App icons for all platforms

**Key Concepts:**

1. **Data Discovery** — Scans `~/.claude/` for Claude Code config, projects, plugins
2. **Statistics Parsing** — Extracts token usage from JSONL session files (mtime-cached)
3. **Artifact Discovery** — Counts skills, commands, agents in global + plugin directories
4. **IPC Commands** — Frontend API with 14 command handlers (all in src/lib.rs)
5. **Background Tasks** — Async summary generation via threads with event emission

**Data Flow:**
- Frontend → `invoke('command_name')` → Tauri IPC → Command Handler → File I/O → JSON response
- Backend → `app_handle.emit('event-name')` → Frontend event listener
- Cache: `~/.claude/hud-stats-cache.json` (mtime-based, auto-created)

### Frontend Architecture (TypeScript/React 19)

The frontend is a **single-file React application** (`src/App.tsx`, 1342 lines):

- **State Management:** React `useState` hooks (no external state library)
- **IPC:** `invoke()` from `@tauri-apps/api/core`
- **Events:** `listen()` from `@tauri-apps/api/event`
- **UI Components:** shadcn/ui (Radix primitives + Tailwind CSS)
- **Styling:** Tailwind CSS 4 with oklch color scheme

### Data Flow

```
React Component (App.tsx)
        ↓
    invoke('command')  (Tauri IPC)
        ↓
Backend Command Handler (src-tauri/lib.rs)
        ↓
File I/O (reads ~/.claude/...)
        ↓
Serialize to JSON
        ↓
Return to Frontend
        ↓
useState updates
        ↓
React component re-renders
```

Background tasks emit events back to frontend:
```
app_handle.emit('event-name') → listen() callback → setState() → UI update
```

## Testing

### Running Tests

```bash
# From src-tauri/
cargo test                    # Run all tests
cargo test test_name          # Run specific test by name
cargo test -- --nocapture     # Show println! output
cargo test -- --test-threads=1  # Run sequentially if needed
```

### Priority Areas for New Tests

- `parse_stats_from_content()` - Regex extraction with various JSONL formats
- `parse_frontmatter()` - YAML parsing edge cases
- `try_resolve_encoded_path()` - Path encoding/decoding
- `compute_project_stats()` - Cache logic and mtime handling

### Test Template

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_stats_basic() {
        let content = r#"{"input_tokens":100,"output_tokens":50,"model":"claude-opus"}"#;
        let mut stats = ProjectStats::default();
        parse_stats_from_content(content, &mut stats);
        assert_eq!(stats.total_input_tokens, 100);
        assert_eq!(stats.total_output_tokens, 50);
        assert_eq!(stats.opus_messages, 1);
    }

    #[test]
    fn test_parse_frontmatter_valid() {
        let content = "---\nname: Test Skill\ndescription: A test\n---\nContent here";
        let (name, desc) = parse_frontmatter(content).unwrap_or_default();
        assert_eq!(name, "Test Skill");
    }
}
```

Run tests with: `cargo test`

Run with detailed output: `cargo test -- --nocapture`

## Code Patterns & Conventions

**IPC Commands:**
- All public commands use `#[tauri::command]` decorator in `src/lib.rs`
- Function signature: `fn command_name(app: tauri::AppHandle, args...) -> Result<ReturnType, String>`
- Return type must be serializable (implements `Serialize`)
- Frontend calls via `invoke('command_name', { args })`
- Errors become rejection messages on frontend

**Error Handling:**
- Functions return `Result<T, String>` for Tauri command compatibility
- Errors are propagated to frontend as error messages
- File operations gracefully degrade (return empty defaults on missing files)
- Use `?` operator to propagate errors

**Serialization:**
- All data structures use `#[derive(Serialize, Deserialize, Clone, Debug)]`
- Tauri automatically serializes/deserializes for IPC via serde_json
- Clone required for passing data between threads in background tasks

**Configuration Loading:**
- Uses `Option<PathBuf>` to handle missing home directory gracefully
- Falls back to empty/default values if files don't exist
- Cache misses trigger re-computation without error

**File Operations:**
- Uses `std::fs` for synchronous file I/O (blocking acceptable)
- `walkdir` for directory traversal with early extension filtering
- `regex` for pattern matching in JSONL files
- No async I/O (single-threaded Tauri command handlers)

**Threading & Background Tasks:**
- `std::thread::spawn()` for non-blocking background work
- `app_handle.emit()` to send events back to frontend
- Statistics computed eagerly (not lazy-loaded)
- Clone all necessary data before moving into thread closure

## Performance Notes

- **Stats Computation:** O(file count) but mtime-cached
- **Project Load:** O(pinned count) - fast for typical use
- **Session Parsing:** O(file size) - regex-based
- **Artifact Discovery:** O(directory depth) - early filtering
- **Summary Generation:** ~1-2 seconds per session via Claude CLI
- **Scaling:** For projects with >1000 session files, consider async refactor

## Common Gotchas

**Frontend/Backend Sync Issues:**
- When modifying Rust data struct definitions, ensure TypeScript interfaces in `src/types.ts` match
- Mismatched field names or types cause serialization failures silently
- Use `#[serde(rename)]` or `#[serde(default)]` to handle version differences

**Path Encoding Problems:**
- Projects are stored with `/` encoded to `-` (e.g., `/Users/john/Code` → `-Users-john-Code`)
- Paths with existing hyphens are indistinguishable from separator hyphens
- `try_resolve_encoded_path()` handles reconstruction, but be aware for debugging

**Cache Invalidation:**
- Cache is based on file mtime, not content hash
- If a file's modification time changes without content changing, stats will recompute
- Delete `~/.claude/hud-stats-cache.json` to force full recalculation

**Regex Matching Issues:**
- Patterns in `parse_stats_from_content()` assume JSONL format (one object per line)
- Malformed JSON lines are silently skipped, not reported as errors
- Test regex patterns with actual session files before deploying

**Terminal Launch (macOS Only):**
- `launch_in_terminal()` uses osascript to open Warp terminal
- Will fail silently if Warp is not installed (falls back gracefully)
- On other platforms, this command is a no-op

## Debugging & Troubleshooting

### Common Debug Commands

**Inspect Runtime Files:**
```bash
# View cached statistics
cat ~/.claude/hud-stats-cache.json | jq .

# View HUD configuration (pinned projects)
cat ~/.claude/hud.json | jq .

# View plugin registry
cat ~/.claude/plugins/installed_plugins.json | jq .

# Check a specific session file
cat ~/.claude/projects/'-Users-petepetrash-Code-projectname'/sessionid.jsonl | jq .

# Validate JSON (reformat if invalid)
cat ~/.claude/hud.json | jq . > /tmp/hud.json && mv /tmp/hud.json ~/.claude/hud.json
```

**Debug Regex Patterns:**
```bash
# Test stats parsing regex
echo '{"input_tokens":1234,"output_tokens":567,"model":"claude-opus","timestamp":"2025-01-05T12:00:00Z"}' | rg 'input_tokens":(\d+)'

# Find all projects with activity
find ~/.claude/projects -name "*.jsonl" -type f -mtime -7
```

**Enable Debug Logging:**
```bash
# Run with debug output
RUST_LOG=debug cargo tauri dev

# Check app logs (macOS)
cat ~/Library/Logs/Claude\ HUD/main.log

# Watch log file in real-time (macOS)
tail -f ~/Library/Logs/Claude\ HUD/main.log
```

### Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| Cache is stale | `rm ~/.claude/hud-stats-cache.json` then restart app |
| Type mismatch between frontend/backend | Verify TypeScript types in `src/types.ts` match Rust struct definitions (case-sensitive) |
| Path encoding issues | Paths with `/` become `-` (e.g., `/a/b` → `-a-b`); `try_resolve_encoded_path()` handles reconstruction |
| Regex not matching | Test against actual JSONL files; malformed JSON is silently skipped |
| macOS terminal launch fails | Requires Warp to be installed; fails gracefully if unavailable |
| cargo build fails with permission errors | Run `cargo clean` then rebuild |
| pnpm install issues | Delete `pnpm-lock.yaml` and run `pnpm install` again |

## Important Architecture Notes

- **Path Encoding:** `/` → `-` (lossy for paths with hyphens, but recoverable)
  - Encoded example: `/Users/peter/Code` → `-Users-peter-Code`
  - `try_resolve_encoded_path()` intelligently reconstructs paths

- **Frontend Integration:** TypeScript types in `src/types.ts` must match Rust struct definitions
  - Changes to `Project`, `Task`, `ProjectStats` require frontend updates

- **Performance:** Stats parsing runs on Tauri command thread (blocking acceptable)
  - Consider async refactor if projects have >1000 session files

- **Platform-Specific:**
  - File operations: `open` (macOS), `explorer` (Windows), `xdg-open` (Linux)
  - Terminal: Warp integration via osascript (macOS only)
  - Paths: PathBuf handles OS-specific separators

- **Dependencies (from Cargo.toml):**
  - `tauri 2.9.5` - Desktop framework
  - `tauri-plugin-shell` - Execute system commands
  - `tauri-plugin-dialog` - File dialogs
  - `tauri-plugin-log` - Logging
  - `serde/serde_json` - JSON serialization
  - `regex 1.11` - Pattern matching
  - `walkdir 2.5` - Directory traversal
  - `dirs 6.0` - Platform paths

## Frontend Integration

The frontend communicates with the backend via Tauri IPC. Key points:

**Invoking Commands from TypeScript:**
```typescript
import { invoke } from '@tauri-apps/api/core';

const dashboard = await invoke<DashboardData>('load_dashboard');
const projects = await invoke<Project[]>('load_projects');
```

**Listening to Events:**
```typescript
import { listen } from '@tauri-apps/api/event';

const unlisten = await listen<[string, string]>('summary-ready', (event) => {
  const [sessionPath, summary] = event.payload;
  // Update state
});
```

**Type Safety:**
- Define TypeScript interfaces in `src/types.ts` that match Rust struct definitions exactly
- Field names and types must align (use `#[serde(rename)]` if they don't)
- Optional fields in Rust (`Option<T>`) must be optional in TypeScript (`T | null`)

## Building for Distribution

```bash
# From project root - build frontend first
pnpm build

# Then from src-tauri/
cargo tauri build              # Build optimized app for current platform
# Output: src-tauri/target/release/bundle/

# Platform-specific builds
cargo tauri build --target aarch64-apple-darwin  # macOS Apple Silicon
cargo tauri build --target x86_64-apple-darwin   # macOS Intel
cargo tauri build --target x86_64-pc-windows-msvc # Windows
```

## Notes for Future Developers

- **No async I/O:** All file operations are synchronous (acceptable for desktop app)
- **Single monolithic backend:** src-tauri/src/lib.rs contains everything - consider modularization if >2000 lines
- **Type synchronization:** Changes to backend structs require matching TypeScript interfaces in `src/types.ts`
- **Frontend build required:** Must run `pnpm build` before `cargo tauri build` for distribution
- **Cache-driven design:** Many operations are mtime-cached for performance
- **Platform handling:** Code includes Windows, macOS (Intel/ARM), and Linux support
- **Don't run dev server unless needed:** Per CLAUDE.md conventions, only start pnpm dev when actively developing frontend
- **Claude CLI path:** Summary generation uses `/opt/homebrew/bin/claude` (macOS Homebrew only)
