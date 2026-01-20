# Capacitor Global Storage Migration

**Status:** Draft
**Created:** 2026-01-19

## Context

Claude HUD is being renamed to **Capacitor** and expanding to support multiple CLI agents (not just Claude Code). Storing artifacts in `~/.claude/` no longer makes sense — the app needs its own namespace.

## Decision

**Global-first storage** in `~/.capacitor/`

We considered project-local storage (`.capacitor/` per project) but opted for global-first because:
- Single-player app — no team sharing concerns
- Portability isn't a current pain point
- Simpler implementation
- Can add project-local later if needed

## New Folder Structure

```
~/.capacitor/
├── sessions.json           # Active session states (v2 format)
├── projects.json           # Tracked projects list
├── summaries.json          # Session summaries cache
├── project-summaries.json  # AI-generated project descriptions
├── stats-cache.json        # Token usage cache
├── file-activity.json      # File activity for project attribution
├── projects/               # Per-project data
│   └── {encoded-path}/
│       ├── ideas.md        # Ideas for this project
│       └── order.json      # Idea ordering
├── agents/                 # Agent registry
│   └── registry.json
├── sessions/               # Lock directories ({hash}.lock/)
└── config.json             # App preferences (future)
```

**Per-project data:** All project-specific data lives under `~/.capacitor/projects/{encoded-path}/`. This keeps the root clean (global files only) and provides a natural extension point for future per-project data (summaries, custom config, etc.).

**Ideas storage change:** Ideas move from project-local (`.claude/ideas.local.md`) to global (`~/.capacitor/projects/{encoded-path}/ideas.md`). This centralizes all Capacitor data and removes the `.local.` convention (not needed for single-player).

## Migration Mapping

| Old Location | New Location |
|--------------|--------------|
| `~/.claude/hud.json` | `~/.capacitor/projects.json` |
| `~/.claude/hud-session-states-v2.json` | `~/.capacitor/sessions.json` |
| `~/.claude/hud-summaries.json` | `~/.capacitor/summaries.json` |
| `~/.claude/hud-project-summaries.json` | `~/.capacitor/project-summaries.json` |
| `~/.claude/hud-stats-cache.json` | `~/.capacitor/stats-cache.json` |
| `~/.claude/hud-file-activity.json` | `~/.capacitor/file-activity.json` |
| `~/.claude/sessions/` | `~/.capacitor/sessions/` |
| `{project}/.claude/ideas.local.md` | `~/.capacitor/projects/{encoded-path}/ideas.md` |
| `~/.claude/ideas-order.json` | `~/.capacitor/projects/{encoded-path}/order.json` (split per project) |

## Implementation Approach

**TDD + Storage Abstraction**

We'll create a `StorageConfig` struct that centralizes all path decisions. This buys us:
- Easy path changes without hunting through code
- Testability (inject mock/temp paths in tests)
- Future flexibility (environment overrides, alternate storage backends)

## Implementation Steps

### Phase 1: Storage Abstraction (TDD)

**1.1 Define `StorageConfig` struct**

```rust
// core/hud-core/src/storage.rs

pub struct StorageConfig {
    /// Root directory for all Capacitor data (default: ~/.capacitor)
    pub root: PathBuf,
}

impl StorageConfig {
    /// Global files
    pub fn sessions_file(&self) -> PathBuf;
    pub fn projects_file(&self) -> PathBuf;
    pub fn summaries_file(&self) -> PathBuf;
    pub fn project_summaries_file(&self) -> PathBuf;
    pub fn stats_cache_file(&self) -> PathBuf;
    pub fn file_activity_file(&self) -> PathBuf;
    pub fn config_file(&self) -> PathBuf;

    /// Directories
    pub fn sessions_dir(&self) -> PathBuf;      // Lock directories
    pub fn projects_dir(&self) -> PathBuf;      // Per-project data
    pub fn agents_dir(&self) -> PathBuf;

    /// Per-project paths
    pub fn project_data_dir(&self, project_path: &str) -> PathBuf;
    pub fn project_ideas_file(&self, project_path: &str) -> PathBuf;
    pub fn project_order_file(&self, project_path: &str) -> PathBuf;

    /// Path encoding
    pub fn encode_path(path: &str) -> String;
    pub fn decode_path(encoded: &str) -> String;
}

impl Default for StorageConfig {
    fn default() -> Self {
        Self { root: dirs::home_dir().unwrap().join(".capacitor") }
    }
}
```

**1.2 Write tests first**

```rust
// core/hud-core/src/storage.rs (tests module)

#[test]
fn test_default_root() {
    let config = StorageConfig::default();
    assert!(config.root.ends_with(".capacitor"));
}

#[test]
fn test_global_file_paths() {
    let config = StorageConfig { root: PathBuf::from("/tmp/test-capacitor") };
    assert_eq!(config.sessions_file(), PathBuf::from("/tmp/test-capacitor/sessions.json"));
    assert_eq!(config.projects_file(), PathBuf::from("/tmp/test-capacitor/projects.json"));
}

#[test]
fn test_project_data_paths() {
    let config = StorageConfig { root: PathBuf::from("/tmp/test-capacitor") };
    let project = "/Users/pete/Code/my-project";

    assert_eq!(
        config.project_ideas_file(project),
        PathBuf::from("/tmp/test-capacitor/projects/-Users-pete-Code-my-project/ideas.md")
    );
}

#[test]
fn test_path_encoding_roundtrip() {
    let original = "/Users/pete/Code/my-project";
    let encoded = StorageConfig::encode_path(original);
    let decoded = StorageConfig::decode_path(&encoded);
    assert_eq!(decoded, original);
}
```

**1.3 Implement `StorageConfig`**

### Phase 2: Migrate Modules to Use StorageConfig

1. **Update `config.rs`**
   - Add `get_capacitor_dir()` → returns `~/.capacitor/`
   - Keep `get_claude_dir()` for reading Claude Code artifacts
   - Create `StorageConfig::default()` factory

2. **Update `HudEngine` to hold `StorageConfig`**
   ```rust
   pub struct HudEngine {
       storage: StorageConfig,
       // ... other fields
   }

   impl HudEngine {
       pub fn new() -> Self {
           Self::with_storage(StorageConfig::default())
       }

       pub fn with_storage(storage: StorageConfig) -> Self {
           // ... enables test injection
       }
   }
   ```

3. **Update each module** (one at a time, with tests):
   - `projects.rs` — Use `storage.projects_file()`
   - `state/store.rs` — Use `storage.sessions_file()`
   - `state/lock.rs` — Use `storage.sessions_dir()`
   - `stats.rs` — Use `storage.stats_cache_file()`
   - `activity.rs` — Use `storage.file_activity_file()`
   - `ideas.rs` — Use `storage.project_ideas_file()`, `storage.project_order_file()`

### Phase 2: Hook Script Updates

1. **Update `~/.claude/scripts/hud-state-tracker.sh`**
   - Change state file path to `~/.capacitor/sessions.json`
   - Change lock directory to `~/.capacitor/sessions/`

2. **Update hook configuration in `~/.claude/settings.json`**
   - Hooks still live in Claude's config (they're Claude Code hooks)
   - But they write to Capacitor's folder

### Phase 3: Swift App Changes

1. **Rename app**
   - `ClaudeHUD` → `Capacitor`
   - Update bundle identifier
   - Update display name

2. **Update any hardcoded paths** (if any exist outside Rust core)

### Phase 4: Manual Migration

```bash
# Create new directory structure
mkdir -p ~/.capacitor/sessions
mkdir -p ~/.capacitor/projects

# Move global files
mv ~/.claude/hud.json ~/.capacitor/projects.json
mv ~/.claude/hud-session-states-v2.json ~/.capacitor/sessions.json
mv ~/.claude/hud-summaries.json ~/.capacitor/summaries.json
mv ~/.claude/hud-project-summaries.json ~/.capacitor/project-summaries.json
mv ~/.claude/hud-stats-cache.json ~/.capacitor/stats-cache.json
mv ~/.claude/hud-file-activity.json ~/.capacitor/file-activity.json
mv ~/.claude/sessions/* ~/.capacitor/sessions/ 2>/dev/null || true

# Clean up old lock directories (ephemeral, safe to delete)
rm -rf ~/.claude/sessions/

# Ideas migration (per-project)
# For each project with ideas in .claude/ideas.local.md:
# 1. Create ~/.capacitor/projects/{encoded-path}/
# 2. Move ideas.local.md → ideas.md
# 3. Extract that project's ordering from ~/.claude/ideas-order.json → order.json
#
# This will be done with a helper script or manually per project.
```

### Phase 5: Documentation Updates

1. Update `CLAUDE.md` references
2. Update `.claude/docs/` documentation
3. Update hook documentation

## Files to Modify

### Phase 1: New File
- `core/hud-core/src/storage.rs` — **NEW** StorageConfig struct + tests

### Phase 2: Rust Core Updates
- `core/hud-core/src/lib.rs` — Add `mod storage;` export
- `core/hud-core/src/config.rs` — Add `get_capacitor_dir()`, keep `get_claude_dir()`
- `core/hud-core/src/engine.rs` — Hold `StorageConfig`, add `with_storage()` constructor
- `core/hud-core/src/projects.rs` — Use `storage.projects_file()`
- `core/hud-core/src/sessions.rs` — Use storage paths
- `core/hud-core/src/state/store.rs` — Use `storage.sessions_file()`
- `core/hud-core/src/state/lock.rs` — Use `storage.sessions_dir()`
- `core/hud-core/src/stats.rs` — Use `storage.stats_cache_file()`
- `core/hud-core/src/activity.rs` — Use `storage.file_activity_file()`
- `core/hud-core/src/ideas.rs` — Use `storage.project_ideas_file()`, `storage.project_order_file()`

### Phase 3: Scripts
- `~/.claude/scripts/hud-state-tracker.sh` — Update paths to `~/.capacitor/`

### Phase 4: Documentation
- `CLAUDE.md`
- `.claude/docs/architecture-overview.md`
- `.claude/docs/hook-operations.md`
- `.claude/docs/status-sync-architecture.md`

## Decisions Made

1. **App renaming scope** — This plan covers **storage migration only**. App rename (ClaudeHUD → Capacitor) will be a separate effort.

2. **Ideas storage** — Ideas move to global storage at `~/.capacitor/ideas/{encoded-path}/ideas.md`. No `.local.` suffix needed (single-player app).

## Future Flexibility

The `StorageConfig` abstraction enables future changes without major refactoring:

| Future Option | How StorageConfig Enables It |
|---------------|------------------------------|
| **Environment override** | `CAPACITOR_DATA_DIR` env var → custom `root` |
| **XDG compliance** | Change default to `~/.local/share/capacitor` |
| **Project-local mode** | Add `StorageConfig::project_local(project_path)` factory |
| **Different file formats** | Change `.json` → `.toml` in path methods |
| **Cloud sync** | Point `root` at synced folder (Dropbox, iCloud) |

None of these require changes to the modules that consume `StorageConfig` — only the config itself.

## Notes

- Claude Code artifacts (JSONL session files, `projects/` folder) stay in `~/.claude/` — we read from there, we don't own that data
- Hooks still configured in `~/.claude/settings.json` — they're Claude Code hooks
- Only Capacitor's own artifacts move to `~/.capacitor/`
- Ideas were previously stored in each project's `.claude/ideas.local.md` — now centralized in `~/.capacitor/projects/{encoded-path}/`
- The `{encoded-path}` format uses the existing convention: `/` → `-` (e.g., `/Users/pete/Code/my-project` → `-Users-pete-Code-my-project`)
