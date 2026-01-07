# Claude HUD - Complete Codebase Analysis for Future Development

This document provides a comprehensive analysis of the Claude HUD codebase for future Claude instances. It complements the existing CLAUDE.md files and provides deep architectural insights.

## Executive Summary

**Claude HUD** is a Tauri-based desktop dashboard for Claude Code that:
1. Scans `~/.claude/` for projects and session files
2. Parses token usage from JSONL session files using regex
3. Displays statistics, tasks, artifacts, and plugin management in a Vue 3 UI
4. Generates summaries via Claude CLI (haiku model)
5. Caches everything with mtime-based invalidation

**Key Stats:**
- Backend: 1765 lines of Rust in single file (lib.rs)
- Frontend: Vue 3 + TypeScript + Pinia
- Build: Cargo + pnpm
- Platforms: macOS (Intel/ARM), Windows, Linux
- No async I/O (synchronous, acceptable for desktop)
- No unit tests currently exist

---

## Complete Architecture Breakdown

### Layer 1: Data Structures (lib.rs:10-152)

All types in one location for easy reference:

**Project Management:**
- `Project` - Core project metadata
  - `name`: Display name
  - `path`: Full filesystem path
  - `last_active`: Unix timestamp
  - `task_count`: Number of tasks
  - `stats`: ProjectStats (computed)
  - `claude_md_preview`: First 200 chars of CLAUDE.md
  - `has_local_settings`: Has ~/.claude/settings.json?
  - `display_path`: Shortened path for UI

- `ProjectDetails` - Full project view
  - `project`: Project object
  - `claude_md_content`: Full CLAUDE.md content
  - `tasks`: Vec<Task>
  - `git_branch`: Current git branch (if repo)
  - `git_dirty`: Has uncommitted changes?

- `Task` - Individual session/task
  - `id`: Unique session identifier
  - `name`: Display name
  - `path`: Session file path
  - `last_modified`: Unix timestamp
  - `summary`: Claude-generated summary (optional)
  - `first_message`: First user message in session

**Statistics:**
- `ProjectStats` - Token usage snapshot
  - Input/output token counts
  - Cache read/creation token counts
  - Per-model message counts (opus/sonnet/haiku)
  - Session count
  - Latest summary and timestamps

- `StatsCache` - In-memory cache structure
  - HashMap<project_path, CachedProjectStats>

- `CachedProjectStats` - What gets persisted
  - `file_size`: For invalidation
  - `mtime`: For invalidation
  - `stats`: ProjectStats object

**Artifacts:**
- `Artifact` - Skills, commands, agents
  - `artifact_type`: "skill" | "command" | "agent"
  - `name`: Display name
  - `description`: From frontmatter
  - `source`: "global" or plugin_id
  - `path`: Filesystem path

**Plugins:**
- `Plugin` - Plugin metadata
  - `id`: Plugin identifier
  - `name`: Display name
  - `description`: Plugin description
  - `enabled`: From settings.json
  - `path`: Plugin directory
  - Artifact counts: skills, commands, agents, hooks

- `PluginManifest` - Raw plugin.json structure
- `InstalledPluginsRegistry` - Full registry structure

**Configuration:**
- `GlobalConfig` - Claude Code settings
  - `settings_path`: Path to settings.json
  - `settings_exists`: Cached check
  - Various directory paths
  - Artifact counts

- `HudConfig` - HUD-specific pinned projects
  - `pinned_projects`: Vec<String> (paths)

- `DashboardData` - Complete snapshot for UI
  - `global_config`: GlobalConfig
  - `plugins`: Vec<Plugin>
  - `pinned_projects`: Vec<Project>

**Summaries:**
- `ProjectSummary` - Cache structure
  - `bullets`: Vec<String> (up to 3)
  - `generated_at`: Unix timestamp

---

### Layer 2: Utilities (lib.rs:154-762)

**Configuration Management (154-195):**
- `get_claude_dir() -> Option<PathBuf>` - Resolve ~/.claude using dirs crate
- `get_hud_config_path() -> PathBuf` - ~/.claude/hud.json
- `get_stats_cache_path() -> PathBuf` - ~/.claude/hud-stats-cache.json
- `load_hud_config() -> HudConfig` - Parse pinned projects
- `save_hud_config(config: HudConfig) -> Result<(), String>` - Persist
- `load_stats_cache() -> StatsCache` - Load mtime-based cache
- `save_stats_cache(cache: StatsCache) -> Result<(), String>` - Persist

**Statistics Parsing (196-326):**
- `parse_stats_from_content(content: &str, stats: &mut ProjectStats) -> Result<(), String>`
  - Line-by-line JSONL parsing
  - Regex patterns extract: `"field":(\d+)`
  - Detects model: looks for "opus" / "sonnet" / "haiku" in line
  - Tracks min/max timestamps
  - Returns first_message, latest_summary

- `compute_project_stats(project_path: &str, app: &tauri::AppHandle) -> Result<ProjectStats, String>`
  - Scans all `.jsonl` files in `~/.claude/projects/{encoded-path}/`
  - Checks cache: if file size + mtime unchanged, returns cached
  - If changed, reparses and updates cache
  - Intelligently aggregates multiple files
  - O(file_count) but heavily mtime-cached

**File Discovery (328-472):**
- `count_artifacts_in_dir(dir: &Path) -> (usize, usize, usize)`
  - Returns (skill_count, command_count, agent_count)
  - Skills: directories with SKILL.md or skill.md
  - Commands/Agents: .md files

- `parse_frontmatter(content: &str) -> Option<(String, String)>`
  - Extracts YAML between `---` markers
  - Returns (name, description) fields
  - Handles missing/malformed frontmatter gracefully

- `collect_artifacts_from_dir(dir: &Path, source: &str) -> Vec<Artifact>`
  - Recursively walks directory
  - Creates Artifact objects with metadata
  - Applies early extension filtering for performance

- `count_hooks_in_dir(plugin_path: &Path) -> usize`
  - Counts hooks.json files in plugin directories

**Path Helpers (328-750):**
- `resolve_symlink(path: &Path) -> PathBuf` - Follow symlinks
- `strip_markdown(text: &str) -> String` - Remove markdown syntax
- `extract_text_from_content(content: &str) -> String` - For preview text
- `extract_first_user_message(content: &str) -> Option<String>` - From JSONL
- `format_relative_time(unix_timestamp: u64) -> String` - "2 days ago"
- `get_claude_md_preview(path: &Path) -> String` - First 200 chars
- `count_tasks_in_project(project_path: &str) -> usize` - Count .jsonl files

**Summary Caching (474-647):**
- `load_summary_cache() -> HashMap<String, String>`
- `save_summary_cache(cache: HashMap) -> Result<(), String>`
- `load_project_summary_cache() -> HashMap<String, ProjectSummary>`
- `save_project_summary_cache(cache: HashMap) -> Result<(), String>`
- `get_recent_session_paths(project_path: &str) -> Vec<PathBuf>` - Up to 5 most recent
- `generate_session_summary_sync(session_path: &str) -> Result<String, String>`
  - Calls: `claude-code-assistant-cli --summary <path> --model haiku`
  - Synchronous blocking call
  - Used for background tasks

- `extract_session_context(session_path: &str) -> Result<String, String>`
  - Reads JSONL file
  - Takes up to 6 messages for context
  - Filters out warmup sessions
  - Formats as concatenated user/assistant messages

---

### Layer 3: Business Logic (lib.rs:806-969)

**Plugin Management (806-865):**
```rust
fn load_plugins(app: &tauri::AppHandle) -> Result<Vec<Plugin>, String>
```
- Reads `~/.claude/plugins/installed_plugins.json`
- Parses plugin.json manifest for each plugin
- Checks `settings.json` for enabled status
- Counts artifacts per plugin via `collect_artifacts_from_dir()`
- Returns sorted Vec<Plugin>

**Project Detection (867-888):**
```rust
fn has_project_indicators(path: &Path) -> bool
```
- Checks for 16 project indicator files:
  - `.git/` (git)
  - `package.json` (npm)
  - `Cargo.toml` (Rust)
  - `pyproject.toml` (Python)
  - `tsconfig.json` (TypeScript)
  - `go.mod` (Go)
  - `pom.xml` (Java Maven)
  - `build.gradle` (Java Gradle)
  - `Gemfile` (Ruby)
  - `composer.json` (PHP)
  - `requirements.txt` (Python)
  - `Podfile` (iOS)
  - `AndroidManifest.xml` (Android)
  - `.sln` (C#)
  - `project.json` (Various)
  - `CMakeLists.txt` (C/C++)

**Project Building (890-943):**
```rust
fn build_project_from_path(path: &Path, app: &tauri::AppHandle) -> Result<Project, String>
```
- Constructs Project object
- Calls `has_project_indicators()` to validate
- Loads CLAUDE.md preview via `get_claude_md_preview()`
- Computes stats via `compute_project_stats()`
- Counts tasks via `count_tasks_in_project()`
- Handles symlinks via `resolve_symlink()`

**Project Loading (945-969):**
```rust
fn load_projects_internal(app: &tauri::AppHandle) -> Result<Vec<Project>, String>
```
- Loads HudConfig (pinned projects list)
- For each pinned path:
  - Calls `build_project_from_path()`
  - Skips if project no longer exists
- Sorts by `last_activity` descending (most recent first)

---

### Layer 4: IPC Commands (lib.rs:1000-1765)

All 15 commands use `#[tauri::command]` decorator. Signature pattern:
```rust
#[tauri::command]
fn command_name(app: tauri::AppHandle, arg1: Type1, ...) -> Result<ReturnType, String>
```

**Data Loading Commands:**

1. **`load_dashboard` (line 770)**
   - Returns: `DashboardData`
   - Loads: GlobalConfig, plugins, pinned projects
   - Used on app startup
   - Expensive operation (full scan)

2. **`load_projects` (line 972)**
   - Returns: `Vec<Project>`
   - Calls: `load_projects_internal()`
   - Cheaper than load_dashboard

3. **`load_project_details` (line 978)**
   - Args: `project_path: String`
   - Returns: `ProjectDetails`
   - Includes: CLAUDE.md content, tasks, git status
   - Git checks use `Command::new("git")` for branch/dirty status

4. **`load_artifacts` (line 1121)**
   - Returns: `Vec<Artifact>`
   - Loads from: `~/.claude/` global dirs + all plugins
   - Filters by type using `artifact_type` field

**File Operations:**

5. **`read_file_content` (line 1190)**
   - Args: `file_path: String`
   - Returns: `String`
   - Reads arbitrary file content
   - Used for viewing CLAUDE.md, configs, etc.

6. **`open_in_editor` (line 1196)**
   - Args: `file_path: String`
   - Platform-specific:
     - macOS: `open <file>`
     - Windows: `cmd /c start <file>`
     - Linux: `xdg-open <file>`

7. **`open_folder` (line 1226)**
   - Args: `folder_path: String`
   - Platform-specific file manager launch

8. **`launch_in_terminal` (line 1255)**
   - Args: `folder_path: String`
   - macOS only: Uses osascript to open Warp
   - Other platforms: No-op

**Plugin Management:**

9. **`toggle_plugin` (line 1161)**
   - Args: `plugin_id: String`, `enabled: bool`
   - Updates: `~/.claude/settings.json`
   - Modifies `plugins.{plugin_id}.enabled` field

**Summary Generation:**

10. **`generate_session_summary` (line 1369)**
    - Args: `session_path: String`
    - Returns: `String` (summary text)
    - Workflow:
      1. Load cache from `hud-summaries.json`
      2. If cached, validate with `is_bad_summary()`
      3. If not cached or bad, call Claude CLI
      4. Save to cache
      5. Return summary

11. **`start_background_summaries` (line 1411)**
    - No args
    - Spawns `std::thread::spawn()`
    - Finds recent sessions
    - Generates summaries in background
    - Emits `"summary-ready"` event per session
    - Useful for batch generation

12. **`start_background_project_summaries` (line 1469)**
    - Args: `project_path: String`
    - Spawns background thread
    - Generates up to 5 recent session summaries
    - Creates 3-bullet project overview
    - Emits `"project-summary-ready"` event
    - Caches in `hud-project-summaries.json`

**Project Management:**

13. **`add_project` (line 1580)**
    - Args: `project_path: String`
    - Adds to pinned projects in `hud.json`
    - Persists via `save_hud_config()`

14. **`remove_project` (line 1592)**
    - Args: `project_path: String`
    - Removes from pinned projects
    - Persists via `save_hud_config()`

**Discovery:**

15. **`load_suggested_projects` (line 1600)**
    - Returns: `Vec<SuggestedProject>`
    - Scans `~/.claude/` for all directories
    - Counts tasks in each (size = relevance)
    - Filters out already-pinned projects
    - Sorts by task count descending
    - Returns top suggestions

---

## Frontend Integration

**File Locations:**
- Views: `src/views/*.vue` (Dashboard, Projects, Artifacts, Settings)
- Components: `src/components/*.vue` (Reusable pieces)
- Store: `src/stores/app.ts` (Pinia state management)

**Invocation Pattern:**
```typescript
import { invoke } from '@tauri-apps/api/core';

const projects = await invoke('load_projects');
const details = await invoke('load_project_details', { projectPath: '/home/user/project' });
```

**Event Listening:**
```typescript
import { listen } from '@tauri-apps/api/event';

const unlisten = await listen('summary-ready', (event) => {
  // event.payload contains summary info
});
```

**Type Synchronization Issues to Watch:**
- Rust: `project_path` (snake_case)
- TypeScript: `projectPath` (camelCase)
- Mismatch = silent serialization failure
- Solution: Use `#[serde(rename = "projectPath")]`

---

## Testing Strategy

**Current State:** No unit tests exist

**High-Value Test Targets:**

1. **`parse_stats_from_content()`** (lines 196-255)
   - Test various JSONL formats
   - Test malformed JSON handling
   - Test all model type detections
   - Test token extraction accuracy

2. **`compute_project_stats()`** (lines 257-326)
   - Test cache hit scenarios
   - Test cache miss and recomputation
   - Test mtime-based invalidation
   - Test multiple file aggregation

3. **`parse_frontmatter()`** (lines 380-399)
   - Test valid YAML
   - Test missing fields
   - Test malformed YAML
   - Test special characters

4. **`try_resolve_encoded_path()`** (lines 1689-1729)
   - Test encoding round-trip
   - Test paths with hyphens
   - Test deeply nested paths
   - Test ambiguous paths

**Test Execution:**
```bash
cargo test                      # All
cargo test test_name            # Specific
cargo test -- --nocapture       # With output
cargo test -- --test-threads=1  # Sequential
```

---

## Performance Characteristics

| Operation | Complexity | Cache Status | Notes |
|-----------|------------|--------------|-------|
| Stats computation | O(file_count) | Mtime-cached | ~100ms per project cached |
| Project load | O(pinned_count) | Not cached | Usually fast (<500ms) |
| Session parsing | O(file_size) | File-level cache | Regex-based, linear scan |
| Artifact discovery | O(dir_depth) | Not cached | Early filtering by extension |
| Summary generation | ~2-3 seconds | Per-session cached | Claude CLI call blocking |
| Dashboard load | O(pinned_count + plugins) | Partial | Most expensive operation |

**Scaling Concerns:**
- 100+ pinned projects: Dashboard gets slow
- 1000+ session files: Stats computation bottleneck
- Deep directory trees: Artifact discovery slow
- Solution: Consider async refactoring if hitting limits

---

## Common Patterns in Codebase

**Error Handling:**
```rust
// Always return Result<T, String> for IPC
fn something() -> Result<Vec<String>, String> {
    let path = get_claude_dir().ok_or("Could not find ~/.claude")?;
    let file = fs::read_to_string(&path)?; // Converts std::io::Error
    Ok(vec![file])
}
```

**Optional File Handling:**
```rust
// Gracefully degrade if file missing
fn get_config() -> SomeConfig {
    fs::read_to_string(path)
        .ok()
        .and_then(|c| serde_json::from_str(&c).ok())
        .unwrap_or_default()
}
```

**Directory Walking:**
```rust
for entry in walkdir::WalkDir::new(&path)
    .into_iter()
    .filter_map(|e| e.ok())
    .filter(|e| e.path().extension().map_or(false, |ext| ext == "md"))
{
    // Process markdown files
}
```

**Regex Matching:**
```rust
let re = Regex::new(r#""field":(\d+)"#)?;
if let Some(caps) = re.captures(line) {
    let value: u64 = caps[1].parse()?;
    // Use value
}
```

**Threading for Background Tasks:**
```rust
let handle = app.clone();
std::thread::spawn(move || {
    // Do expensive work
    handle.emit("event-name", data).ok();
});
```

---

## Key Files Reference

| File | Lines | Purpose |
|------|-------|---------|
| `src/lib.rs` | 1765 | All backend logic |
| `src/main.rs` | 6 | Entry point, delegates to lib.rs |
| `Cargo.toml` | ~30 | Dependencies (tauri, serde, regex, walkdir, dirs) |
| `tauri.conf.json` | ~50 | App config (window size, dev URL, etc.) |
| `src/App.vue` | ? | Root Vue component with routing |
| `src/stores/app.ts` | ? | Pinia store for state/caching |
| `vite.config.ts` | ? | Frontend build config |
| `package.json` | ? | Frontend dependencies |

---

## Debugging Checklist

**Problem: Stats not updating**
```bash
rm ~/.claude/hud-stats-cache.json
# Restart app - cache will rebuild
```

**Problem: Types don't match between frontend/backend**
- Check TypeScript interface matches Rust struct
- Check camelCase vs snake_case naming
- Check Optional/nullable field handling
- Run `pnpm type-check` to validate

**Problem: Regex pattern not extracting values**
```bash
# Test against actual JSONL
cat ~/.claude/projects/'-encoded-path'/session.jsonl | rg 'pattern':(\d+)'
# Check JSONL format matches expectations
```

**Problem: Path encoding issues**
- Debug with `try_resolve_encoded_path()` logic
- Paths with hyphens are ambiguous
- Solution: Verify with filesystem checks

**Problem: Plugin not showing up**
- Check `~/.claude/plugins/installed_plugins.json` exists
- Verify plugin directory has plugin.json
- Check `~/.claude/settings.json` enables plugin
- Run `load_dashboard` to see full state

---

## Recommended Reading Order for New Contributors

1. **Start here:** Root CLAUDE.md (quick reference)
2. **Understand data:** Data structures section above (lib.rs:10-152)
3. **Learn utilities:** Utilities section above (lib.rs:154-762)
4. **See business logic:** Business Logic section above (lib.rs:806-969)
5. **Understand commands:** IPC Commands section above
6. **Deep dive:** Read src-tauri/CLAUDE.md for detailed line-by-line documentation

---

## Version Notes

- **Rust:** 1.77.2+ required
- **Tauri:** 2.9.5 (check Cargo.toml for exact version)
- **Node.js:** 18+ (for pnpm)
- **pnpm:** Latest (specified in package.json)

Last updated: 2026-01-05
