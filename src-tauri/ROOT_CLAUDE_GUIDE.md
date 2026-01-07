# Claude HUD - Root Level Development Guide

This document should be placed at the project root as `CLAUDE.md` to guide future Claude instances working on the Claude HUD project. Since this repository has both frontend and backend components, having a comprehensive root-level guide is essential.

---

# CLAUDE.md - Claude HUD Development Guide

Claude HUD is a cross-platform desktop application that serves as a dashboard for Claude Code. It displays project statistics, task tracking, plugin management, and global Claude Code configuration insights. Built with Rust/Tauri backend and TypeScript/Vue 3 frontend.

## Quick Start (Copy-Paste Ready)

**Environment:** Work from the project root `claude-hud/` directory.

**Two Terminals Required:**

Terminal 1:
```bash
pnpm dev
# Starts Vue dev server on http://localhost:5173
```

Terminal 2:
```bash
cd src-tauri
cargo tauri dev
# Launches Tauri app with hot reload
```

Both must run simultaneously. The app auto-connects to localhost:5173.

## Architecture Summary

**Backend:** Single monolithic Rust file (`src-tauri/src/lib.rs`, 1765 lines)
- 4 layers: Data Structures → Utilities → Business Logic → IPC Handlers
- 15 Tauri IPC commands for frontend communication
- Scans `~/.claude/` for Claude Code projects and statistics
- Regex-based JSONL parsing with mtime caching

**Frontend:** Vue 3 + TypeScript
- Pinia state management for caching
- Vue 3 Composition API (no Options API)
- Calls backend via `invoke('command_name', args)`
- Listens for `summary-ready` and `project-summary-ready` events

**Build System:**
- Frontend: pnpm (Node.js)
- Backend: Cargo (Rust 1.77.2+)
- Tauri 2.9.5 framework

## Key Directories

```
claude-hud/
├── src/                        # Vue 3 frontend
│   ├── components/             # Reusable UI components
│   ├── views/                  # Dashboard, Projects, Artifacts, Settings pages
│   └── stores/                 # Pinia state management
├── src-tauri/                  # Rust backend
│   ├── src/lib.rs              # All backend logic (1765 lines)
│   ├── Cargo.toml              # Dependencies
│   └── CLAUDE.md               # Comprehensive backend docs
├── dist/                       # Built frontend (generated)
├── package.json                # Frontend dependencies
├── vite.config.ts              # Frontend build config
└── CLAUDE.md                   # This file
```

## Most Common Commands

```bash
# Frontend development
pnpm install                 # Install dependencies (once)
pnpm dev                     # Start dev server
pnpm type-check              # TypeScript validation
pnpm lint                    # ESLint validation

# Backend development (from src-tauri/)
cargo tauri dev              # Start app with hot reload
cargo fmt                    # Format code (required)
cargo clippy -- -D warnings  # Lint check (required)
cargo test                   # Run tests
cargo test test_name         # Run specific test

# Building for distribution
pnpm build                   # Build frontend (MUST do first)
cd src-tauri
cargo tauri build            # Build app for distribution
```

## Pre-Commit Checklist

From `src-tauri/`:
```bash
cargo fmt                    # Format code
cargo clippy -- -D warnings  # Fix warnings
cargo test                   # Tests must pass
```

From project root:
```bash
pnpm type-check             # TypeScript
pnpm lint                   # ESLint
```

## Understanding the Architecture

### Data Flow

```
User opens app → Vue 3 loads → Pinia calls backend
    ↓
Backend processes: scans ~/.claude/, parses JSON/JSONL
    ↓
Returns JSON to frontend → Pinia caches → Components render
```

### What Each Layer Does

**Data Structures** (lib.rs:10-152)
- Defines types: `Project`, `ProjectStats`, `Task`, `Artifact`, `Plugin`, etc.

**Utilities** (lib.rs:154-762)
- Config loading, stats parsing, file discovery, caching
- Key functions: `parse_stats_from_content()`, `compute_project_stats()`, `collect_artifacts_from_dir()`

**Business Logic** (lib.rs:806-969)
- Project discovery, plugin loading
- Key functions: `has_project_indicators()`, `build_project_from_path()`

**IPC Handlers** (lib.rs:1000-1765)
- 15 commands: `load_dashboard`, `load_projects`, `load_artifacts`, `toggle_plugin`, etc.
- All marked with `#[tauri::command]`

### Key Data Structures

```rust
Project {
    name, path, last_active, task_count,
    stats: ProjectStats, claude_md_preview, ...
}

ProjectStats {
    total_input_tokens, total_output_tokens,
    total_cache_read_tokens, total_cache_creation_tokens,
    opus_messages, sonnet_messages, haiku_messages,
    session_count, latest_summary, first_activity, last_activity
}

Plugin {
    id, name, enabled,
    skill_count, command_count, agent_count, hook_count, ...
}

Artifact {
    artifact_type, name, description, source, path
}
```

## Common Development Tasks

### Add a New IPC Command

1. Add to `src-tauri/src/lib.rs`:
```rust
#[tauri::command]
fn my_command(app: tauri::AppHandle, arg: String) -> Result<Vec<String>, String> {
    Ok(vec![arg])
}
```

2. Register in Tauri builder (~line 1750):
```rust
.invoke_handler(tauri::generate_handler![
    // ... existing ...
    my_command,  // Add this
])
```

3. Call from frontend:
```typescript
const result = await invoke('my_command', { arg: 'test' });
```

### Modify Token Parsing

Edit `parse_stats_from_content()` in `src-tauri/src/lib.rs` (lines 196-255).

Example: Add extraction for a new field:
```rust
if let Some(caps) = Regex::new(r#""my_field":(\d+)"#)?.captures(line) {
    stats.my_field += caps[1].parse::<u64>()?;
}
```

Then clear the cache and test:
```bash
rm ~/.claude/hud-stats-cache.json
cargo tauri dev
```

### Add Project Type Detection

Edit `has_project_indicators()` in `src-tauri/src/lib.rs` (lines 867-888).

Add a check:
```rust
if path.join("your-indicator-file").exists() {
    return true;
}
```

### Debug Statistics Parsing

```bash
# View actual session file
cat ~/.claude/projects/'-Users-user-path'/session.jsonl | jq .

# Test regex pattern
echo '{"input_tokens":1234}' | rg 'input_tokens":(\d+)'

# Clear cache
rm ~/.claude/hud-stats-cache.json

# View cached stats
cat ~/.claude/hud-stats-cache.json | jq .
```

## Code Conventions

**All Code:**
- Prefer readable code over clever code
- No extraneous comments; code should be self-documenting
- Never use IIFEs

**Backend (Rust):**
- Run `cargo fmt` before commits (required)
- Run `cargo clippy -- -D warnings` before commits (required)
- Use `Result<T, String>` for IPC handlers
- Synchronous I/O only (no async)
- Thread spawning with `std::thread::spawn()` for background work

**Frontend (TypeScript):**
- Vue 3 Composition API only (no Options API)
- TypeScript strict mode enabled
- Run `pnpm type-check` before commits
- Run `pnpm lint` before commits

## Important Concepts

### Caching System

**Stats Cache** (`~/.claude/hud-stats-cache.json`):
- Stores file size + mtime + parsed stats
- Invalidated when file size or mtime changes
- Checked in `compute_project_stats()` (lines 257-326)

**Summary Cache** (`~/.claude/hud-summaries.json`):
- Maps session paths to summary text
- Populated by `generate_session_summary()` command

**Project Summary Cache** (`~/.claude/hud-project-summaries.json`):
- Up to 3 bullet points per project
- Generated by `start_background_project_summaries()` command

### Path Encoding

Project paths use `/` → `-` replacement:
- `/Users/peter/Code` becomes `-Users-peter-Code`
- `try_resolve_encoded_path()` (lines 1689-1729) reconstructs paths

### IPC Commands (15 Total)

| Command | Purpose |
|---------|---------|
| `load_dashboard` | Get all dashboard data |
| `load_projects` | Get pinned projects |
| `load_project_details` | Get project with tasks, git status, CLAUDE.md |
| `load_artifacts` | Get global + plugin artifacts |
| `toggle_plugin` | Enable/disable plugin |
| `read_file_content` | Read arbitrary file |
| `open_in_editor` | Open file in system editor |
| `open_folder` | Open folder in file manager |
| `launch_in_terminal` | Launch Warp terminal (macOS only) |
| `generate_session_summary` | Generate summary on demand |
| `start_background_summaries` | Generate summaries in background |
| `start_background_project_summaries` | Generate project overview |
| `add_project` | Pin project |
| `remove_project` | Unpin project |
| `load_suggested_projects` | Discover active projects |

## Testing

```bash
cargo test                      # All tests
cargo test test_name            # Specific test
cargo test -- --nocapture       # Show output
```

**Priority areas lacking tests:**
- `parse_stats_from_content()` - Regex extraction
- `compute_project_stats()` - Cache logic
- `parse_frontmatter()` - YAML parsing
- `try_resolve_encoded_path()` - Path encoding

**Test template:**
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_stats_basic() {
        let content = r#"{"input_tokens":100,"model":"claude-opus"}"#;
        let mut stats = ProjectStats::default();
        parse_stats_from_content(content, &mut stats);
        assert_eq!(stats.total_input_tokens, 100);
        assert_eq!(stats.opus_messages, 1);
    }
}
```

## Runtime Configuration

The app reads from `~/.claude/`:

```
~/.claude/
├── settings.json              # Global Claude Code settings
├── hud.json                   # Pinned projects list
├── hud-stats-cache.json       # Cached token usage (mtime-based)
├── hud-summaries.json         # Session summaries cache
├── hud-project-summaries.json # Project overview cache
├── projects/                  # Session files
│   └── {encoded-path}/
│       └── {sessionid}.jsonl
├── plugins/
│   ├── installed_plugins.json
│   └── {plugin-id}/
│       ├── skills/
│       ├── commands/
│       └── agents/
├── skills/                    # Global skills
├── commands/                  # Global commands
└── agents/                    # Global agents
```

## Performance Notes

- Stats computation: O(file count), cached by mtime
- Project load: O(pinned count) - fast
- Session parsing: O(file size) - regex based
- Artifact discovery: O(directory depth) - with early filtering
- Summary generation: ~1-2 seconds per session (Claude CLI)
- For >1000 session files, consider async refactoring

## Common Issues

| Issue | Solution |
|-------|----------|
| Cache stale | `rm ~/.claude/hud-*.json` |
| Type errors | TypeScript types must match Rust structs (case-sensitive) |
| Path issues | Paths use `/` → `-` encoding; `try_resolve_encoded_path()` handles it |
| Regex not matching | Test against actual JSONL files; malformed lines are skipped |
| Terminal fails | macOS only; requires Warp installed |
| Build fails | Run `cargo clean` then rebuild |
| pnpm issues | Delete `pnpm-lock.yaml` and run `pnpm install` |

## Building for Distribution

```bash
pnpm build                  # Build frontend first (MUST do this)
cd src-tauri
cargo tauri build           # Build for current platform
# or platform-specific:
cargo tauri build --target aarch64-apple-darwin   # macOS ARM
cargo tauri build --target x86_64-apple-darwin    # macOS Intel
cargo tauri build --target x86_64-pc-windows-msvc # Windows
```

## Dependencies

**Frontend:**
- Vue 3
- TypeScript
- Pinia
- Tauri API
- Vite

**Backend:**
- tauri 2.9.5
- serde/serde_json
- regex 1.11
- walkdir 2.5
- dirs 6.0

## For More Details

See `src-tauri/CLAUDE.md` for:
- Complete module organization with line numbers
- All 15 IPC command signatures
- Detailed data structure definitions
- Statistics parsing algorithms
- Caching strategy details
- Debugging techniques
- Platform-specific implementation notes

---

## Instructions for Updating Root CLAUDE.md

To update the root-level CLAUDE.md file in the project:

1. The above content should be placed in `/claude-hud/CLAUDE.md` (project root)
2. It serves as the **quick reference** for all Claude instances
3. Complex backend details are delegated to `src-tauri/CLAUDE.md`
4. Update this guide when:
   - New IPC commands are added
   - Major architectural changes occur
   - Testing strategies change
   - Build process is updated

This separation ensures:
- Root CLAUDE.md is concise and actionable
- Backend-specific docs don't clutter the root
- Future Claude instances can quickly find what they need
