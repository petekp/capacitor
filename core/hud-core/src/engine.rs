//! HudEngine - The main entry point for Claude HUD clients.
//!
//! The HudEngine provides a unified, client-agnostic API for all HUD functionality.
//! It's designed to be:
//! - **Synchronous**: No async runtime required
//! - **Client-agnostic**: Works with Swift, TUI, mobile, etc.
//! - **Stateless**: Each call is independent (caching happens at lower levels)
//!
//! ## Example Usage
//!
//! ```rust,ignore
//! use hud_core::HudEngine;
//!
//! let engine = HudEngine::new().expect("Failed to initialize");
//! let projects = engine.list_projects().unwrap_or_default();
//! let states = engine.get_all_session_states(&projects);
//! ```

use crate::artifacts::{collect_artifacts_from_dir, count_artifacts_in_dir, count_hooks_in_dir};
use crate::config::{
    get_claude_dir, load_hud_config, resolve_symlink, save_hud_config,
};
use crate::error::HudFfiError;
use crate::projects::{has_project_indicators, load_projects};
use crate::sessions::{detect_session_state_v2, get_all_session_states_v2, read_project_status, ProjectStatus};
use crate::types::{
    Artifact, DashboardData, GlobalConfig, HudConfig, Plugin, PluginManifest, Project,
    ProjectSessionState, SuggestedProject,
};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

/// The main engine for Claude HUD operations.
///
/// Provides a unified API for all HUD functionality, suitable for any client type.
/// This is the primary FFI interface for Swift/Kotlin/Python clients.
#[derive(uniffi::Object)]
pub struct HudEngine {
    claude_dir: PathBuf,
}

#[uniffi::export]
impl HudEngine {
    /// Creates a new HudEngine instance.
    ///
    /// Returns an error if the Claude directory (~/.claude) cannot be found.
    #[uniffi::constructor]
    pub fn new() -> Result<Self, HudFfiError> {
        let claude_dir = get_claude_dir().ok_or_else(|| HudFfiError::from("Could not find Claude directory"))?;
        Ok(Self { claude_dir })
    }

    /// Returns the path to the Claude directory as a string.
    pub fn claude_dir(&self) -> String {
        self.claude_dir.to_string_lossy().to_string()
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Projects API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Lists all pinned projects, sorted by most recent activity.
    pub fn list_projects(&self) -> Result<Vec<Project>, HudFfiError> {
        load_projects().map_err(HudFfiError::from)
    }

    /// Gets the HUD configuration (pinned projects, terminal app, etc.)
    pub fn get_config(&self) -> HudConfig {
        load_hud_config()
    }

    /// Adds a project to the pinned projects list.
    pub fn add_project(&self, path: String) -> Result<(), HudFfiError> {
        let mut config = load_hud_config();

        if !std::path::Path::new(&path).exists() {
            return Err(HudFfiError::from(format!("Path does not exist: {}", path)));
        }

        if config.pinned_projects.contains(&path) {
            return Err(HudFfiError::from(format!("Project already pinned: {}", path)));
        }

        config.pinned_projects.push(path);
        save_hud_config(&config).map_err(HudFfiError::from)
    }

    /// Removes a project from the pinned projects list.
    pub fn remove_project(&self, path: String) -> Result<(), HudFfiError> {
        let mut config = load_hud_config();
        config.pinned_projects.retain(|p| p != &path);
        save_hud_config(&config).map_err(HudFfiError::from)
    }

    /// Discovers suggested projects based on activity in ~/.claude/projects.
    pub fn get_suggested_projects(&self) -> Result<Vec<SuggestedProject>, HudFfiError> {
        let projects_dir = self.claude_dir.join("projects");
        if !projects_dir.exists() {
            return Ok(Vec::new());
        }

        let config = load_hud_config();
        let pinned_set: std::collections::HashSet<_> = config.pinned_projects.iter().collect();

        let mut suggestions: Vec<(SuggestedProject, u32)> = Vec::new();

        if let Ok(entries) = fs::read_dir(&projects_dir) {
            for entry in entries.filter_map(|e| e.ok()) {
                if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }

                let encoded_name = entry.file_name().to_string_lossy().to_string();

                // Try to resolve the encoded path
                if let Some(real_path) = crate::projects::try_resolve_encoded_path(&encoded_name) {
                    if pinned_set.contains(&real_path) {
                        continue;
                    }

                    let project_path = PathBuf::from(&real_path);
                    let has_indicators = has_project_indicators(&project_path);
                    let has_claude_md = project_path.join("CLAUDE.md").exists();

                    let task_count = fs::read_dir(entry.path())
                        .map(|entries| {
                            entries
                                .filter_map(|e| e.ok())
                                .filter(|e| {
                                    e.path().extension().is_some_and(|ext| ext == "jsonl")
                                })
                                .count() as u32
                        })
                        .unwrap_or(0);

                    let display_path = if real_path.starts_with("/Users/") {
                        format!(
                            "~/{}",
                            real_path.split('/').skip(3).collect::<Vec<_>>().join("/")
                        )
                    } else {
                        real_path.clone()
                    };

                    let name = real_path
                        .split('/')
                        .next_back()
                        .unwrap_or(&real_path)
                        .to_string();

                    suggestions.push((
                        SuggestedProject {
                            path: real_path,
                            display_path,
                            name,
                            task_count,
                            has_claude_md,
                            has_project_indicators: has_indicators,
                        },
                        task_count,
                    ));
                }
            }
        }

        suggestions.sort_by(|a, b| b.1.cmp(&a.1));
        Ok(suggestions.into_iter().map(|(s, _)| s).collect())
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Session State API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Gets the session state for a single project.
    /// Uses the new v2 state resolution with session-ID keyed state and lock detection.
    pub fn get_session_state(&self, project_path: String) -> ProjectSessionState {
        detect_session_state_v2(&project_path)
    }

    /// Gets session states for multiple projects.
    /// Uses v2 state resolution with session-ID keyed state and lock detection.
    ///
    /// Takes a Vec instead of slice for FFI compatibility.
    pub fn get_all_session_states(&self, projects: Vec<Project>) -> HashMap<String, ProjectSessionState> {
        let paths: Vec<String> = projects.iter().map(|p| p.path.clone()).collect();
        get_all_session_states_v2(&paths)
    }

    /// Gets project status from .claude/hud-status.json.
    pub fn get_project_status(&self, project_path: String) -> Option<ProjectStatus> {
        read_project_status(&project_path)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Artifacts API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Lists all artifacts (skills, commands, agents) from global and plugin sources.
    pub fn list_artifacts(&self) -> Vec<Artifact> {
        let mut artifacts = Vec::new();

        // Global artifacts
        if let Some(skills_dir) = resolve_symlink(&self.claude_dir.join("skills")) {
            artifacts.extend(collect_artifacts_from_dir(&skills_dir, "skill", "Global"));
        }
        if let Some(commands_dir) = resolve_symlink(&self.claude_dir.join("commands")) {
            artifacts.extend(collect_artifacts_from_dir(&commands_dir, "command", "Global"));
        }
        if let Some(agents_dir) = resolve_symlink(&self.claude_dir.join("agents")) {
            artifacts.extend(collect_artifacts_from_dir(&agents_dir, "agent", "Global"));
        }

        // Plugin artifacts
        if let Ok(plugins) = self.list_plugins() {
            for plugin in plugins {
                if plugin.enabled {
                    let plugin_path = PathBuf::from(&plugin.path);
                    artifacts.extend(collect_artifacts_from_dir(
                        &plugin_path.join("skills"),
                        "skill",
                        &plugin.name,
                    ));
                    artifacts.extend(collect_artifacts_from_dir(
                        &plugin_path.join("commands"),
                        "command",
                        &plugin.name,
                    ));
                    artifacts.extend(collect_artifacts_from_dir(
                        &plugin_path.join("agents"),
                        "agent",
                        &plugin.name,
                    ));
                }
            }
        }

        // Sort by type first, then by name (matching lib.rs behavior)
        artifacts.sort_by(|a, b| {
            let type_order = a.artifact_type.cmp(&b.artifact_type);
            if type_order == std::cmp::Ordering::Equal {
                a.name.to_lowercase().cmp(&b.name.to_lowercase())
            } else {
                type_order
            }
        });
        artifacts
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Plugins API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Lists all installed plugins.
    pub fn list_plugins(&self) -> Result<Vec<Plugin>, HudFfiError> {
        let registry_path = self.claude_dir.join("plugins").join("installed_plugins.json");
        if !registry_path.exists() {
            return Ok(Vec::new());
        }

        let content = fs::read_to_string(&registry_path)
            .map_err(|e| HudFfiError::from(format!("Failed to read plugin registry: {}", e)))?;

        #[derive(serde::Deserialize)]
        struct Registry {
            plugins: HashMap<String, Vec<PluginInfo>>,
        }

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct PluginInfo {
            install_path: String,
        }

        let registry: Registry = serde_json::from_str(&content)
            .map_err(|e| HudFfiError::from(format!("Failed to parse plugin registry: {}", e)))?;

        // Load settings to check enabled status
        let settings_path = self.claude_dir.join("settings.json");
        let enabled_plugins: HashMap<String, bool> = if settings_path.exists() {
            #[derive(serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Settings {
                enabled_plugins: Option<HashMap<String, bool>>,
            }

            fs::read_to_string(&settings_path)
                .ok()
                .and_then(|c| serde_json::from_str::<Settings>(&c).ok())
                .and_then(|s| s.enabled_plugins)
                .unwrap_or_default()
        } else {
            HashMap::new()
        };

        let mut plugins = Vec::new();

        for (id, installs) in registry.plugins {
            if let Some(install) = installs.first() {
                let plugin_path = PathBuf::from(&install.install_path);

                let manifest_path = plugin_path.join(".claude-plugin").join("plugin.json");
                let manifest: Option<PluginManifest> = fs::read_to_string(&manifest_path)
                    .ok()
                    .and_then(|c| serde_json::from_str(&c).ok());

                let name = manifest
                    .as_ref()
                    .map(|m| m.name.clone())
                    .unwrap_or_else(|| id.clone());
                let description = manifest
                    .as_ref()
                    .and_then(|m| m.description.clone())
                    .unwrap_or_default();

                let enabled = enabled_plugins.get(&id).copied().unwrap_or(true);

                plugins.push(Plugin {
                    id: id.clone(),
                    name,
                    description,
                    enabled,
                    path: install.install_path.clone(),
                    skill_count: count_artifacts_in_dir(&plugin_path.join("skills"), "skills"),
                    command_count: count_artifacts_in_dir(&plugin_path.join("commands"), "commands"),
                    agent_count: count_artifacts_in_dir(&plugin_path.join("agents"), "agents"),
                    hook_count: count_hooks_in_dir(&plugin_path),
                });
            }
        }

        plugins.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        Ok(plugins)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Dashboard API
    // ─────────────────────────────────────────────────────────────────────────────

    /// Loads all dashboard data in one call.
    pub fn load_dashboard(&self) -> Result<DashboardData, HudFfiError> {
        let settings_path = self.claude_dir.join("settings.json");
        let instructions_path = self.claude_dir.join("CLAUDE.md");

        let skills_dir = resolve_symlink(&self.claude_dir.join("skills"));
        let commands_dir = resolve_symlink(&self.claude_dir.join("commands"));
        let agents_dir = resolve_symlink(&self.claude_dir.join("agents"));

        let global = GlobalConfig {
            settings_path: settings_path.to_string_lossy().to_string(),
            settings_exists: settings_path.exists(),
            instructions_path: if instructions_path.exists() {
                Some(instructions_path.to_string_lossy().to_string())
            } else {
                None
            },
            skills_dir: skills_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            commands_dir: commands_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            agents_dir: agents_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            skill_count: skills_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "skills"))
                .unwrap_or(0),
            command_count: commands_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "commands"))
                .unwrap_or(0),
            agent_count: agents_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "agents"))
                .unwrap_or(0),
        };

        let plugins = self.list_plugins().unwrap_or_default();
        let projects = self.list_projects().unwrap_or_default();

        Ok(DashboardData {
            global,
            plugins,
            projects,
        })
    }
}
